//// Stitched interiors (M3.1): build one combined deck plan from a station
//// concourse plus every docked ship's plan moored on at a berth, airlock
//// to airlock. A berth is a walkable stub tile authored on the concourse;
//// a docked ship is placed so its airlock (spawn tile) sits directly north
//// of its berth tile. All tiles are then translated into one positive
//// frame (bounding-box normalization); ship room/console ids are
//// namespaced "s{ship_id}:{id}" so several moorings never collide. This is
//// level generation, not coordinate gymnastics: the output is an ordinary
//// DeckPlan the character sim and the client walk unchanged.

import dh_server/deckplan.{
  type Console, type DeckPlan, type Room, Console, DeckPlan, Grid, Room,
}
import gleam/int
import gleam/list
import gleam/string

/// An authored berth: the walkable concourse stub tile a ship moors onto.
pub type Berth {
  Berth(x: Int, y: Int)
}

/// One docked ship to moor: its id, claimed berth index, and deck plan.
pub type DockedShip {
  DockedShip(ship_id: Int, berth: Int, plan: DeckPlan)
}

/// Where one ship's tiles landed in the composite frame: ship-local tile
/// (x, y) maps to composite tile (x + dx, y + dy).
pub type Mooring {
  Mooring(ship_id: Int, dx: Int, dy: Int)
}

/// The stitched plan. `concourse_dx/dy` is the translation applied to
/// concourse tiles (grows when a mooring extends past the concourse's
/// top/left edge); moorings carry each ship's translation.
pub type Composite {
  Composite(
    plan: DeckPlan,
    concourse_dx: Int,
    concourse_dy: Int,
    moorings: List(Mooring),
  )
}

/// "s{ship_id}:{id}" — the composite-frame id of a ship console or room.
pub fn namespace_id(ship_id: Int, id: String) -> String {
  "s" <> int.to_string(ship_id) <> ":" <> id
}

/// Parse "s{ship_id}:{id}" back into #(ship_id, id). Plain (concourse) ids
/// are Error(Nil).
pub fn parse_namespaced(id: String) -> Result(#(Int, String), Nil) {
  case string.starts_with(id, "s") {
    False -> Error(Nil)
    True ->
      case string.split_once(string.drop_start(id, 1), ":") {
        Error(Nil) -> Error(Nil)
        Ok(#(number, rest)) ->
          case int.parse(number) {
            Error(Nil) -> Error(Nil)
            Ok(ship_id) -> Ok(#(ship_id, rest))
          }
      }
  }
}

/// Find the ship's mooring in this composite, if it is docked here.
pub fn find_mooring(
  composite: Composite,
  ship_id: Int,
) -> Result(Mooring, Nil) {
  list.find(composite.moorings, fn(g) { g.ship_id == ship_id })
}

/// Whether composite-frame position (x, y) stands on a walkable tile of
/// this mooring — the undock split test: bodies on ship tiles leave with the
/// ship, bodies on station tiles stay.
pub fn tile_on_mooring(
  mooring: Mooring,
  ship_plan: DeckPlan,
  x: Float,
  y: Float,
) -> Bool {
  let tx = float_floor(x) - mooring.dx
  let ty = float_floor(y) - mooring.dy
  deckplan.is_walkable(ship_plan, tx, ty)
}

/// A ship's raw (pre-normalization, concourse-frame) offset: place its
/// spawn/airlock tile directly north of its berth tile.
fn raw_offset(berth: Berth, plan: DeckPlan) -> #(Int, Int) {
  let #(sx, sy) = plan.spawn_tile
  #(berth.x - sx, berth.y - 1 - sy)
}

/// Build the composite plan. Errors: "unknown_berth" (berth index out of
/// range) and "berth_blocked" (two walkable tiles land on the same
/// composite tile — authored berth spacing must prevent this).
pub fn build(
  concourse: DeckPlan,
  berths: List(Berth),
  docked: List(DockedShip),
) -> Result(Composite, String) {
  // Resolve each ship's berth and raw offset first.
  let placed =
    list.try_map(docked, fn(ship) {
      case berth_at(berths, ship.berth) {
        Error(Nil) -> Error("unknown_berth")
        Ok(berth) -> {
          let #(dx, dy) = raw_offset(berth, ship.plan)
          Ok(#(ship, dx, dy))
        }
      }
    })
  case placed {
    Error(e) -> Error(e)
    Ok(placed) -> {
      // Bounding box over the concourse rect and every ship rect.
      let #(min_x, min_y, max_x, max_y) =
        list.fold(
          placed,
          #(0, 0, concourse.grid.width, concourse.grid.height),
          fn(acc, entry) {
            let #(mnx, mny, mxx, mxy) = acc
            let #(ship, dx, dy) = entry
            #(
              int.min(mnx, dx),
              int.min(mny, dy),
              int.max(mxx, dx + ship.plan.grid.width),
              int.max(mxy, dy + ship.plan.grid.height),
            )
          },
        )
      let shift_x = -min_x
      let shift_y = -min_y
      let width = max_x - min_x
      let height = max_y - min_y
      let moorings =
        list.map(placed, fn(entry) {
          let #(ship, dx, dy) = entry
          Mooring(ship_id: ship.ship_id, dx: dx + shift_x, dy: dy + shift_y)
        })
      case
        compose_walkable(concourse, placed, shift_x, shift_y, width, height)
      {
        Error(e) -> Error(e)
        Ok(walkable) -> {
          let rooms =
            list.map(concourse.rooms, translate_room(_, shift_x, shift_y))
            |> list.append(
              list.flat_map(placed, fn(entry) {
                let #(ship, dx, dy) = entry
                list.map(ship.plan.rooms, fn(room) {
                  let translated =
                    translate_room(room, dx + shift_x, dy + shift_y)
                  Room(
                    id: namespace_id(ship.ship_id, room.id),
                    name: translated.name,
                    x: translated.x,
                    y: translated.y,
                    w: translated.w,
                    h: translated.h,
                  )
                })
              }),
            )
          let consoles =
            list.map(concourse.consoles, translate_console(_, shift_x, shift_y))
            |> list.append(
              list.flat_map(placed, fn(entry) {
                let #(ship, dx, dy) = entry
                list.map(ship.plan.consoles, fn(console) {
                  let translated =
                    translate_console(console, dx + shift_x, dy + shift_y)
                  Console(
                    id: namespace_id(ship.ship_id, console.id),
                    kind: translated.kind,
                    x: translated.x,
                    y: translated.y,
                  )
                })
              }),
            )
          let #(spawn_x, spawn_y) = concourse.spawn_tile
          let plan =
            DeckPlan(
              grid: Grid(width: width, height: height),
              walkable: walkable,
              rooms: rooms,
              consoles: consoles,
              spawn_tile: #(spawn_x + shift_x, spawn_y + shift_y),
            )
          case deckplan.validate(plan) {
            Error(e) -> Error("invalid composite: " <> e)
            Ok(plan) ->
              Ok(Composite(
                plan: plan,
                concourse_dx: shift_x,
                concourse_dy: shift_y,
                moorings: moorings,
              ))
          }
        }
      }
    }
  }
}

/// Row strings for the composite: each tile is walkable in exactly zero or
/// one source plan. Two sources claiming one tile is "berth_blocked".
fn compose_walkable(
  concourse: DeckPlan,
  placed: List(#(DockedShip, Int, Int)),
  shift_x: Int,
  shift_y: Int,
  width: Int,
  height: Int,
) -> Result(List(String), String) {
  list.try_map(range(0, height), fn(y) {
    list.try_map(range(0, width), fn(x) {
      let from_concourse =
        deckplan.is_walkable(concourse, x - shift_x, y - shift_y)
      let ship_claims =
        list.count(placed, fn(entry) {
          let #(ship, dx, dy) = entry
          deckplan.is_walkable(ship.plan, x - dx - shift_x, y - dy - shift_y)
        })
      let claims =
        ship_claims
        + case from_concourse {
          True -> 1
          False -> 0
        }
      case claims {
        0 -> Ok(".")
        1 -> Ok("#")
        _ -> Error("berth_blocked")
      }
    })
    |> result_map_concat
  })
}

fn result_map_concat(
  cells: Result(List(String), String),
) -> Result(String, String) {
  case cells {
    Error(e) -> Error(e)
    Ok(cells) -> Ok(string.concat(cells))
  }
}

fn berth_at(berths: List(Berth), index: Int) -> Result(Berth, Nil) {
  case index >= 0 {
    False -> Error(Nil)
    True -> list.drop(berths, index) |> list.first
  }
}

fn translate_room(room: Room, dx: Int, dy: Int) -> Room {
  Room(..room, x: room.x + dx, y: room.y + dy)
}

fn translate_console(console: Console, dx: Int, dy: Int) -> Console {
  Console(..console, x: console.x + dx, y: console.y + dy)
}

/// [from, to) as a list of ints, e.g. `range(0, 3) == [0, 1, 2]`. The pinned
/// gleam_stdlib (1.0.3) has no `list.range`; matches the local helper idiom
/// used in test/noise_test.gleam.
fn range(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

fn float_floor(v: Float) -> Int {
  let truncated = float_truncate(v)
  case int.to_float(truncated) >. v {
    True -> truncated - 1
    False -> truncated
  }
}

@external(erlang, "erlang", "trunc")
fn float_truncate(v: Float) -> Int
