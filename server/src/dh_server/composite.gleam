//// Stitched interiors (M3.1, reworked for deck-plan v3): build one combined
//// multi-deck plan from a station concourse plus every docked ship's plan
//// moored at a berth. Ships moor SIDE-ON: each docked deck is rotated 90°
//// CCW (nose west, port flank south) so the docking corridor's port END
//// faces the station, and a `tube_length`-tile docking tube of generated
//// walkable tiles bridges the gap between the dormer and the berth stub.
////
//// v3 is multi-deck (Option B): composite decks are indexed by LEVEL relative
//// to the concourse plane. A docked ship's deck is at level
//// `ship_deck - mooring_index`, so its MOORING deck (its `spawn_deck`) sits at
//// level 0 — the same plane as the concourse, merged in and tube-connected —
//// and its other decks land one level above/below. This keeps
//// physically-adjacent decks index-adjacent so `deck±1` stairs survive docking
//// whatever the mooring deck's spot in the ship's stack. Every level hosts all
//// docked ships' decks at that relative level (at their berths). Tube tiles
//// belong to the STATION (a body mid-tube stays ashore on undock). Ship
//// console ids are namespaced "s{ship_id}:{id}", `deck` remapped to the
//// composite index. The output is an ordinary DeckPlan the sim and client walk.

import dh_server/deckplan.{
  type DeckGrid, type DeckPlan, type Edge, type Tile, Console, DeckGrid,
  DeckPlan, Floor, Open, Void,
}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Docking-tube length, tiles: the walkable gap generated between a moored
/// ship's port dormer and its berth stub. Four tiles clears the
/// Mockingbird's fins off the bar apron with a little room for bigger hulls.
pub const tube_length = 4

/// An authored docking port on a concourse: the walkable stub tile a ship
/// moors onto (`x`, `y`, composite frame, deck 0) PLUS the exterior mooring
/// pose. `orientation` is the port's outward normal in world radians (y-up,
/// 0 = +x/east); `anchor_x`/`anchor_y` place the mooring point as a
/// world-unit offset from the station centre (issue #13/#14). The interior
/// stitch (`build`) reads only x/y — orientation/anchor drive the space-side
/// pose only.
pub type Berth {
  Berth(x: Int, y: Int, orientation: Float, anchor_x: Float, anchor_y: Float)
}

/// The side-on default port normal: north (+y), i.e. pi/2 radians. Callers
/// that only have a tile (legacy `[x, y]` berths, tests) default here.
pub const default_orientation = 1.5707963267948966

/// One docked ship to moor: its id, claimed berth index, and (unrotated,
/// multi-deck) deck plan.
pub type DockedShip {
  DockedShip(ship_id: Int, berth: Int, plan: DeckPlan)
}

/// Where one ship's tiles landed in the composite frame: ship-local tile
/// `(x, y)` on ship deck `sd` maps to composite tile `(x + dx, y + dy)` on
/// composite deck `deck_map[sd]`. `ship_width` is the ship plan's (unrotated)
/// deck width, needed to invert the moor rotation.
pub type Mooring {
  Mooring(
    ship_id: Int,
    dx: Int,
    dy: Int,
    deck_map: List(#(Int, Int)),
    ship_width: Int,
  )
}

/// The stitched plan. `concourse_dx/dy` is the translation applied to
/// concourse tiles (grows when a mooring extends past the concourse's
/// top/left edge); `base_level` is the concourse-relative level of composite
/// deck 0 (composite decks are indexed by level, so `level = deck + base_level`
/// — see `build`); moorings carry each ship's translation + deck mapping.
pub type Composite {
  Composite(
    plan: DeckPlan,
    concourse_dx: Int,
    concourse_dy: Int,
    base_level: Int,
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

/// The composite deck index a ship-local deck maps to (its concourse-relative
/// level, offset into the composite's deck list). Unmapped ship decks -> 0.
pub fn composite_deck_of(mooring: Mooring, ship_deck: Int) -> Int {
  case list.find(mooring.deck_map, fn(p) { p.0 == ship_deck }) {
    Ok(#(_, cd)) -> cd
    Error(Nil) -> 0
  }
}

/// The ship-local deck a composite deck maps back to for this mooring, or
/// `Error(Nil)` if that composite deck is not this ship's.
pub fn ship_deck_of(mooring: Mooring, composite_deck: Int) -> Result(Int, Nil) {
  case list.find(mooring.deck_map, fn(p) { p.1 == composite_deck }) {
    Ok(#(sd, _)) -> Ok(sd)
    Error(Nil) -> Error(Nil)
  }
}

/// Remap a composite deck index from one composite to another across a
/// rebuild. Composite decks are indexed by concourse-relative LEVEL, and a
/// body's level is preserved even as the index base shifts (a taller ship
/// docking/undocking changes how many decks sit above the concourse). So the
/// remap is a pure shift by the difference of the two bases; a body whose ship
/// then vanished lands where its tiles used to be and the caller's walkability
/// check re-floors it.
pub fn remap_deck(from: Composite, to: Composite, deck: Int) -> Int {
  deck + from.base_level - to.base_level
}

/// Whether composite-frame position `(x, y)` on composite deck `deck` stands
/// on a walkable tile of this mooring — the undock split test: bodies on ship
/// tiles leave with the ship, bodies on station tiles (concourse + docking
/// tube) stay. `ship_plan` is the UNROTATED class plan.
pub fn tile_on_mooring(
  mooring: Mooring,
  ship_plan: DeckPlan,
  deck: Int,
  x: Float,
  y: Float,
) -> Bool {
  case ship_deck_of(mooring, deck) {
    Error(Nil) -> False
    Ok(sd) ->
      case deckplan.deck_at(ship_plan, sd) {
        Error(Nil) -> False
        Ok(grid) -> {
          let tx = float_floor(x) - mooring.dx
          let ty = float_floor(y) - mooring.dy
          deckplan.is_walkable(rotate_ccw_grid(grid), tx, ty)
        }
      }
  }
}

/// Map a body's composite-frame position into the UNROTATED ship frame (the
/// undock transform, planar). Inverse of the CCW moor rotation:
/// ship-frame `(x, y) = (width - ry, rx)` for mooring-local `(rx, ry)`.
pub fn to_ship_frame(mooring: Mooring, x: Float, y: Float) -> #(Float, Float) {
  let rx = x -. int.to_float(mooring.dx)
  let ry = y -. int.to_float(mooring.dy)
  #(int.to_float(mooring.ship_width) -. ry, rx)
}

/// Map a ship-frame position into mooring-local (rotated) coordinates — the
/// dock-join transform (add the mooring's dx/dy afterwards). `ship_width` is
/// the ship plan's (unrotated) deck width.
pub fn from_ship_frame(ship_width: Int, x: Float, y: Float) -> #(Float, Float) {
  #(y, int.to_float(ship_width) -. x)
}

/// The ship plan's (unrotated) deck width — decks are authored uniform, so
/// deck 0's width serves the whole ship. 0 if the plan has no decks.
pub fn plan_width(plan: DeckPlan) -> Int {
  case deckplan.deck_at(plan, 0) {
    Ok(g) -> g.width
    Error(Nil) -> 0
  }
}

// -------------------------------------------------------------- build --

/// A ship resolved for placement: its input, berth, rotated decks, mooring
/// deck index, and raw (pre-normalization) concourse-frame offset.
type Placed {
  Placed(
    ship: DockedShip,
    rotated: List(DeckGrid),
    mooring_index: Int,
    dx: Int,
    dy: Int,
  )
}

/// Build the composite plan. Errors: "unknown_berth" (berth index out of
/// range), "no_concourse_deck", and "berth_blocked" (two walkable tiles land
/// on the same composite tile — authored berth spacing must prevent this).
pub fn build(
  concourse: DeckPlan,
  berths: List(Berth),
  docked: List(DockedShip),
) -> Result(Composite, String) {
  use concourse_grid <- result.try(
    deckplan.deck_at(concourse, 0)
    |> result.replace_error("no_concourse_deck"),
  )
  use placed <- result.try(place_ships(berths, docked))

  // Bounding box over the concourse rect and every ship's rotated footprint.
  let #(min_x, min_y, max_x, max_y) =
    list.fold(
      placed,
      #(0, 0, concourse_grid.width, concourse_grid.height),
      fn(acc, p) {
        let #(mnx, mny, mxx, mxy) = acc
        let g = mooring_grid(p)
        #(
          int.min(mnx, p.dx),
          int.min(mny, p.dy),
          int.max(mxx, p.dx + g.width),
          int.max(mxy, p.dy + g.height),
        )
      },
    )
  let shift_x = -min_x
  let shift_y = -min_y
  let width = max_x - min_x
  let height = max_y - min_y

  // Index composite decks by LEVEL relative to the concourse plane: a ship
  // deck's level is `ship_deck - mooring_index` (the mooring deck -> level 0,
  // the plane it merges into). This keeps physically-adjacent decks
  // index-adjacent so `deck±1` stairs work after docking, wherever the mooring
  // deck sits in the ship's own stack. Level 0 also hosts the concourse; other
  // levels host every ship's deck at that relative level (at their berths).
  let levels =
    list.flat_map(placed, fn(p) {
      list.map(range(0, list.length(p.rotated)), fn(sd) { sd - p.mooring_index })
    })
  let min_level = list.fold(levels, 0, int.min)
  let max_level = list.fold(levels, 0, int.max)
  let concourse_index = -min_level

  use decks <- result.try(
    list.try_map(range(min_level, max_level + 1), fn(level) {
      compose_level(
        concourse_grid,
        placed,
        berths,
        level,
        shift_x,
        shift_y,
        width,
        height,
      )
    }),
  )
  let moorings = build_moorings(placed, min_level, shift_x, shift_y)

  let consoles =
    compose_consoles(
      concourse,
      placed,
      moorings,
      concourse_index,
      shift_x,
      shift_y,
    )
  let #(spawn_x, spawn_y) = concourse.spawn_tile
  let plan =
    DeckPlan(
      decks: decks,
      consoles: consoles,
      spawn_deck: concourse_index,
      spawn_tile: #(spawn_x + shift_x, spawn_y + shift_y),
    )
  case deckplan.validate(plan) {
    Error(e) -> Error("invalid composite: " <> e)
    Ok(plan) ->
      Ok(Composite(
        plan: plan,
        concourse_dx: shift_x,
        concourse_dy: shift_y,
        base_level: min_level,
        moorings: moorings,
      ))
  }
}

fn place_ships(
  berths: List(Berth),
  docked: List(DockedShip),
) -> Result(List(Placed), String) {
  list.try_map(docked, fn(ship) {
    case berth_at(berths, ship.berth) {
      Error(Nil) -> Error("unknown_berth")
      Ok(berth) -> {
        let rotated = list.map(ship.plan.decks, rotate_ccw_grid)
        let mooring_index = ship.plan.spawn_deck
        let sw = plan_width(ship.plan)
        let #(sx, sy) = ship.plan.spawn_tile
        // Rotated spawn position (point rotation in a width-sw grid).
        let #(rsx, rsy) = rotate_point(sx, sy, sw)
        let dx = berth.x - rsx
        let dy = berth.y - 1 - tube_length - rsy
        Ok(Placed(
          ship: ship,
          rotated: rotated,
          mooring_index: mooring_index,
          dx: dx,
          dy: dy,
        ))
      }
    }
  })
}

/// The rotated mooring deck for a placed ship (falls back to an empty grid
/// if the mooring index is somehow out of range — validation prevents it).
fn mooring_grid(p: Placed) -> DeckGrid {
  case list.drop(p.rotated, p.mooring_index) |> list.first {
    Ok(g) -> g
    Error(Nil) -> DeckGrid(name: "", width: 0, height: 0, tiles: [], edges: [])
  }
}

/// Build each ship's mooring: its translation, ship_width, and the deck_map
/// from ship deck index to composite deck index. A ship deck's composite index
/// is its level minus `min_level`, where level = `ship_deck - mooring_index`.
fn build_moorings(
  placed: List(Placed),
  min_level: Int,
  shift_x: Int,
  shift_y: Int,
) -> List(Mooring) {
  list.map(placed, fn(p) {
    let deck_map =
      list.map(range(0, list.length(p.rotated)), fn(sd) {
        #(sd, sd - p.mooring_index - min_level)
      })
    Mooring(
      ship_id: p.ship.ship_id,
      dx: p.dx + shift_x,
      dy: p.dy + shift_y,
      deck_map: deck_map,
      ship_width: plan_width(p.ship.plan),
    )
  })
}

/// The rotated ship deck that sits at composite `level` for a placed ship
/// (`ship_deck = level + mooring_index`), or Error if the ship has no deck
/// there.
fn deck_at_level(p: Placed, level: Int) -> Result(DeckGrid, Nil) {
  case level + p.mooring_index >= 0 {
    False -> Error(Nil)
    True -> list.drop(p.rotated, level + p.mooring_index) |> list.first
  }
}

/// Compose the composite deck at `level`: the concourse (only at level 0)
/// merged with every ship's rotated deck sitting at that relative level, then
/// — at level 0 — the docking tubes carved north of each berth. Exactly one
/// non-void source may claim each tile (else "berth_blocked").
fn compose_level(
  concourse: DeckGrid,
  placed: List(Placed),
  berths: List(Berth),
  level: Int,
  shift_x: Int,
  shift_y: Int,
  width: Int,
  height: Int,
) -> Result(DeckGrid, String) {
  use tiles_edges <- result.try(
    list.try_map(range(0, height), fn(y) {
      list.try_map(range(0, width), fn(x) {
        let concourse_cells = case level == 0 {
          True -> [cell(concourse, x - shift_x, y - shift_y)]
          False -> []
        }
        let ship_cells =
          list.filter_map(placed, fn(p) {
            case deck_at_level(p, level) {
              Ok(g) -> Ok(cell(g, x - p.dx - shift_x, y - p.dy - shift_y))
              Error(Nil) -> Error(Nil)
            }
          })
        let sources =
          list.append(concourse_cells, ship_cells)
          |> list.filter(fn(c) { c.0 != Void })
        case sources {
          [] -> Ok(#(Void, open_edges()))
          [one] -> Ok(one)
          _ -> Error("berth_blocked")
        }
      })
    }),
  )
  let name = case level == 0 {
    True -> "concourse"
    False -> "deck"
  }
  let g = grid_from_cells(name, width, height, tiles_edges)
  case level == 0 {
    True -> carve_tubes(g, placed, berths, shift_x, shift_y)
    False -> Ok(g)
  }
}

/// Overwrite the `tube_length` void tiles directly north of each occupied
/// berth with generated walkable floor. Anything but void there is a
/// spacing/authoring bug: "berth_blocked".
fn carve_tubes(
  g: DeckGrid,
  placed: List(Placed),
  berths: List(Berth),
  shift_x: Int,
  shift_y: Int,
) -> Result(DeckGrid, String) {
  list.fold(placed, Ok(g), fn(acc, p) {
    case acc {
      Error(e) -> Error(e)
      Ok(g) ->
        case berth_at(berths, p.ship.berth) {
          Error(Nil) -> Error("unknown_berth")
          Ok(berth) ->
            list.fold(range(1, tube_length + 1), Ok(g), fn(acc2, k) {
              case acc2 {
                Error(e) -> Error(e)
                Ok(g) -> carve_tile(g, berth.x + shift_x, berth.y - k + shift_y)
              }
            })
        }
    }
  })
}

fn carve_tile(g: DeckGrid, x: Int, y: Int) -> Result(DeckGrid, String) {
  case deckplan.tile_at(g, x, y) {
    Void -> Ok(DeckGrid(..g, tiles: set_2d(g.tiles, x, y, Floor)))
    _ -> Error("berth_blocked")
  }
}

fn compose_consoles(
  concourse: DeckPlan,
  placed: List(Placed),
  moorings: List(Mooring),
  concourse_index: Int,
  shift_x: Int,
  shift_y: Int,
) -> List(deckplan.Console) {
  let concourse_consoles =
    list.map(concourse.consoles, fn(c) {
      Console(..c, deck: concourse_index, x: c.x + shift_x, y: c.y + shift_y)
    })
  let ship_consoles =
    list.flat_map(placed, fn(p) {
      let sw = plan_width(p.ship.plan)
      let mooring = mooring_for(moorings, p.ship.ship_id)
      list.map(p.ship.plan.consoles, fn(c) {
        let #(rx, ry) = rotate_point(c.x, c.y, sw)
        Console(
          id: namespace_id(p.ship.ship_id, c.id),
          kind: c.kind,
          deck: composite_deck_of(mooring, c.deck),
          x: rx + p.dx + shift_x,
          y: ry + p.dy + shift_y,
        )
      })
    })
  list.append(concourse_consoles, ship_consoles)
}

fn mooring_for(moorings: List(Mooring), ship_id: Int) -> Mooring {
  case list.find(moorings, fn(m) { m.ship_id == ship_id }) {
    Ok(m) -> m
    Error(Nil) -> Mooring(ship_id, 0, 0, [], 0)
  }
}

// ------------------------------------------------------------ rotation --

/// Rotate a deck grid 90° CCW: a nose-up ship lies nose-WEST, port side
/// SOUTH. Rotated tile `(x', y')` = original `(width-1-y', x')`; each tile's
/// edges rotate `(n, e, s, w) -> (e, s, w, n)`.
fn rotate_ccw_grid(g: DeckGrid) -> DeckGrid {
  let new_w = g.height
  let new_h = g.width
  let cells =
    list.map(range(0, new_h), fn(y) {
      list.map(range(0, new_w), fn(x) {
        let ox = g.width - 1 - y
        let oy = x
        let #(n, e, s, w) = case deckplan.edges_at(g, ox, oy) {
          Ok(edges) -> edges
          Error(Nil) -> open_edges()
        }
        #(deckplan.tile_at(g, ox, oy), #(e, s, w, n))
      })
    })
  grid_from_cells(g.name, new_w, new_h, cells)
}

/// Rotate a point `(x, y)` in a width-`w` grid 90° CCW: `(y, w-1-x)`.
fn rotate_point(x: Int, y: Int, w: Int) -> #(Int, Int) {
  #(y, w - 1 - x)
}

// -------------------------------------------------------------- cells --

/// A tile plus its four edges — the unit `compose`/`lift` shuffle around.
type Cell =
  #(Tile, #(Edge, Edge, Edge, Edge))

fn open_edges() -> #(Edge, Edge, Edge, Edge) {
  #(Open, Open, Open, Open)
}

/// The cell at `(x, y)` on `g`; void + open edges out of bounds.
fn cell(g: DeckGrid, x: Int, y: Int) -> Cell {
  case deckplan.edges_at(g, x, y) {
    Ok(edges) -> #(deckplan.tile_at(g, x, y), edges)
    Error(Nil) -> #(Void, open_edges())
  }
}

fn grid_from_cells(
  name: String,
  width: Int,
  height: Int,
  cells: List(List(Cell)),
) -> DeckGrid {
  DeckGrid(
    name: name,
    width: width,
    height: height,
    tiles: list.map(cells, fn(row) { list.map(row, fn(c) { c.0 }) }),
    edges: list.map(cells, fn(row) { list.map(row, fn(c) { c.1 }) }),
  )
}

/// Replace the value at `(x, y)` in a `[y][x]` 2D list, leaving others.
fn set_2d(rows: List(List(a)), x: Int, y: Int, value: a) -> List(List(a)) {
  list.index_map(rows, fn(row, ry) {
    case ry == y {
      False -> row
      True ->
        list.index_map(row, fn(cellv, rx) {
          case rx == x {
            False -> cellv
            True -> value
          }
        })
    }
  })
}

fn berth_at(berths: List(Berth), index: Int) -> Result(Berth, Nil) {
  case index >= 0 {
    False -> Error(Nil)
    True -> list.drop(berths, index) |> list.first
  }
}

/// [from, to) as a list of ints.
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
