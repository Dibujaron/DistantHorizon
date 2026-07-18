//// Stitched interiors (M3.1, reworked M3.5 iteration 4): build one
//// combined deck plan from a station concourse plus every docked ship's
//// plan moored at a berth. Ships moor SIDE-ON: each docked plan is
//// rotated 90° CCW (nose west, port flank south) so the docking
//// corridor's port END faces the station, and a `tube_length`-tile
//// docking tube of generated walkable tiles bridges the gap between the
//// dormer and the berth stub — the hull floats clear of the bar. Tube
//// tiles belong to the STATION (a body mid-tube stays ashore on undock).
//// All tiles are then translated into one positive frame (bounding-box
//// normalization); ship room/console ids are namespaced "s{ship_id}:{id}"
//// so several moorings never collide. This is level generation, not
//// coordinate gymnastics: the output is an ordinary DeckPlan the
//// character sim and the client walk unchanged.

import dh_server/deckplan.{
  type Console, type DeckPlan, type Room, Console, DeckPlan, Grid, Room,
}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Docking-tube length, tiles: the walkable gap generated between a moored
/// ship's port dormer and its berth stub.
pub const tube_length = 3

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
/// this mooring — the undock split test: bodies on ship tiles leave with
/// the ship, bodies on station tiles (including the docking tube) stay.
/// `ship_plan` is the UNROTATED class plan; the mooring frame is rotated.
pub fn tile_on_mooring(
  mooring: Mooring,
  ship_plan: DeckPlan,
  x: Float,
  y: Float,
) -> Bool {
  let tx = float_floor(x) - mooring.dx
  let ty = float_floor(y) - mooring.dy
  deckplan.is_walkable(deckplan.rotate_ccw(ship_plan), tx, ty)
}

/// Map a body's composite-frame position into the UNROTATED ship frame
/// (the undock transform). Inverse of the CCW moor rotation: ship-frame
/// (x, y) = (width - ry, rx) for mooring-local (rx, ry).
pub fn to_ship_frame(
  mooring: Mooring,
  ship_plan: DeckPlan,
  x: Float,
  y: Float,
) -> #(Float, Float) {
  let rx = x -. int.to_float(mooring.dx)
  let ry = y -. int.to_float(mooring.dy)
  #(int.to_float(ship_plan.grid.width) -. ry, rx)
}

/// Map a ship-frame position into mooring-local (rotated) coordinates —
/// the dock-join transform (add the mooring's dx/dy afterwards).
pub fn from_ship_frame(
  ship_plan: DeckPlan,
  x: Float,
  y: Float,
) -> #(Float, Float) {
  #(y, int.to_float(ship_plan.grid.width) -. x)
}

/// A ship's raw (pre-normalization, concourse-frame) offset: rotate the
/// plan side-on, then place its spawn/port-dormer tile `tube_length + 1`
/// tiles north of its berth tile (the tube bridges the gap).
fn raw_offset(berth: Berth, rotated: DeckPlan) -> #(Int, Int) {
  let #(sx, sy) = rotated.spawn_tile
  #(berth.x - sx, berth.y - 1 - tube_length - sy)
}

/// Build the composite plan. Errors: "unknown_berth" (berth index out of
/// range) and "berth_blocked" (two walkable tiles land on the same
/// composite tile — authored berth spacing must prevent this).
pub fn build(
  concourse: DeckPlan,
  berths: List(Berth),
  docked: List(DockedShip),
) -> Result(Composite, String) {
  // Rotate each ship side-on, resolve its berth and raw offset.
  let placed =
    list.try_map(docked, fn(ship) {
      case berth_at(berths, ship.berth) {
        Error(Nil) -> Error("unknown_berth")
        Ok(berth) -> {
          let moored = DockedShip(..ship, plan: deckplan.rotate_ccw(ship.plan))
          let #(dx, dy) = raw_offset(berth, moored.plan)
          Ok(#(moored, berth, dx, dy))
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
            let #(ship, _berth, dx, dy) = entry
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
          let #(ship, _berth, dx, dy) = entry
          Mooring(ship_id: ship.ship_id, dx: dx + shift_x, dy: dy + shift_y)
        })
      case
        compose_walkable(concourse, placed, shift_x, shift_y, width, height)
        |> result.try(carve_tubes(_, placed, shift_x, shift_y))
      {
        Error(e) -> Error(e)
        Ok(walkable) -> {
          let rooms =
            list.map(concourse.rooms, translate_room(_, shift_x, shift_y))
            |> list.append(
              list.flat_map(placed, fn(entry) {
                let #(ship, _berth, dx, dy) = entry
                list.map(ship.plan.rooms, fn(room) {
                  let translated =
                    translate_room(room, dx + shift_x, dy + shift_y)
                  Room(..translated, id: namespace_id(ship.ship_id, room.id))
                })
              }),
            )
          let consoles =
            list.map(concourse.consoles, translate_console(_, shift_x, shift_y))
            |> list.append(
              list.flat_map(placed, fn(entry) {
                let #(ship, _berth, dx, dy) = entry
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
/// one source plan. Two sources claiming one tile is "berth_blocked". The
/// claiming source's walkable char is carried through unchanged so
/// split-level ship plans keep their deck alphabet in the composite.
fn compose_walkable(
  concourse: DeckPlan,
  placed: List(#(DockedShip, Berth, Int, Int)),
  shift_x: Int,
  shift_y: Int,
  width: Int,
  height: Int,
) -> Result(List(String), String) {
  list.try_map(range(0, height), fn(y) {
    list.try_map(range(0, width), fn(x) {
      let ship_chars =
        list.filter_map(placed, fn(entry) {
          let #(ship, _berth, dx, dy) = entry
          case deckplan.char_at(ship.plan, x - dx - shift_x, y - dy - shift_y) {
            "." -> Error(Nil)
            ch -> Ok(ch)
          }
        })
      let claims = case deckplan.char_at(concourse, x - shift_x, y - shift_y) {
        "." -> ship_chars
        ch -> [ch, ..ship_chars]
      }
      case claims {
        [] -> Ok(".")
        [ch] -> Ok(ch)
        _ -> Error("berth_blocked")
      }
    })
    |> result_map_concat
  })
}

/// Overwrite the `tube_length` void tiles directly north of each occupied
/// berth with generated '#' docking-tube floor. Anything but '.' there
/// means an authoring/spacing bug: "berth_blocked".
fn carve_tubes(
  walkable: List(String),
  placed: List(#(DockedShip, Berth, Int, Int)),
  shift_x: Int,
  shift_y: Int,
) -> Result(List(String), String) {
  list.fold(placed, Ok(walkable), fn(acc, entry) {
    let #(_ship, berth, _dx, _dy) = entry
    list.fold(range(1, tube_length + 1), acc, fn(acc2, k) {
      case acc2 {
        Error(e) -> Error(e)
        Ok(rows) ->
          carve_tile(rows, berth.x + shift_x, berth.y - k + shift_y)
      }
    })
  })
}

fn carve_tile(
  rows: List(String),
  x: Int,
  y: Int,
) -> Result(List(String), String) {
  let out =
    list.index_map(rows, fn(row, i) {
      case i == y {
        False -> row
        True ->
          string.slice(row, 0, x)
          <> "#"
          <> string.slice(row, x + 1, string.length(row))
      }
    })
  // The carved tile must have been void ('.'): anything else means the
  // tube would punch through a hull or floor.
  let was = case list.drop(rows, y) |> list.first {
    Ok(row) -> string.slice(row, x, 1)
    Error(Nil) -> ""
  }
  case was {
    "." -> Ok(out)
    _ -> Error("berth_blocked")
  }
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
