//// Shared interior deck-plan geometry: the tile grid, rooms, consoles and
//// spawn tile that both ship classes (shipclass.gleam) and station
//// concourses (world.gleam) are built from. Interior coordinates are tile
//// units, y-down; tile `(x, y)` spans `[x, x+1) x [y, y+1)`, center
//// `(x+0.5, y+0.5)`.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/string

pub type Grid {
  Grid(width: Int, height: Int)
}

/// A labelled rectangle of tiles, for rendering/labels only (no door graph).
pub type Room {
  Room(id: String, name: String, x: Int, y: Int, w: Int, h: Int)
}

/// A single-tile interactable. `kind` is e.g. `"helm"`, `"cargo"` or
/// `"broker"`.
pub type Console {
  Console(id: String, kind: String, x: Int, y: Int)
}

pub type DeckPlan {
  DeckPlan(
    grid: Grid,
    /// One string per row, top to bottom; `'#'` walkable, anything else
    /// (canonically `'.'`) hull/void.
    walkable: List(String),
    rooms: List(Room),
    consoles: List(Console),
    /// Tile where arriving characters appear (the airlock end).
    spawn_tile: #(Int, Int),
  )
}

/// Whether tile `(x, y)` is in bounds and walkable.
pub fn is_walkable(plan: DeckPlan, x: Int, y: Int) -> Bool {
  case x >= 0 && x < plan.grid.width && y >= 0 && y < plan.grid.height {
    False -> False
    True -> {
      let assert Ok(row) = list.drop(plan.walkable, y) |> list.first
      string.slice(from: row, at_index: x, length: 1) == "#"
    }
  }
}

/// Look up a console by id.
pub fn find_console(
  plan: DeckPlan,
  console_id: String,
) -> Result(Console, Nil) {
  list.find(plan.consoles, fn(c) { c.id == console_id })
}

/// The first console of `kind`, if any.
pub fn find_console_of_kind(
  plan: DeckPlan,
  kind: String,
) -> Result(Console, Nil) {
  list.find(plan.consoles, fn(c) { c.kind == kind })
}

/// Geometry validation shared by every deck-plan host: walkable rows match
/// the grid, every console and the spawn tile sit on walkable tiles.
/// Host-specific console requirements (a ship class needs a helm, a trading
/// concourse needs a broker) live with the host document.
pub fn validate(plan: DeckPlan) -> Result(DeckPlan, String) {
  use <- guard(
    list.length(plan.walkable) == plan.grid.height,
    "walkable row count does not match grid.height",
  )
  use <- guard(
    !list.any(plan.walkable, fn(row) { string.length(row) != plan.grid.width }),
    "a walkable row's length does not match grid.width",
  )
  use <- guard(
    !list.any(plan.consoles, fn(c) { !is_walkable(plan, c.x, c.y) }),
    "a console is not on a walkable tile",
  )
  let #(sx, sy) = plan.spawn_tile
  use <- guard(
    is_walkable(plan, sx, sy),
    "spawn_tile is not on a walkable tile",
  )
  Ok(plan)
}

fn guard(
  condition: Bool,
  error: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(error)
  }
}

/// Decodes the deck-plan fields (grid/walkable/rooms/consoles/spawn_tile)
/// from the *current* JSON object — ship class docs carry them at their top
/// level, station concourses as a nested object; the same decoder serves
/// both.
pub fn decoder() -> decode.Decoder(DeckPlan) {
  use grid <- decode.field("grid", grid_decoder())
  use walkable <- decode.field("walkable", decode.list(decode.string))
  use rooms <- decode.field("rooms", decode.list(room_decoder()))
  use consoles <- decode.field("consoles", decode.list(console_decoder()))
  use spawn_tile <- decode.field("spawn_tile", tile_decoder())
  decode.success(DeckPlan(
    grid: grid,
    walkable: walkable,
    rooms: rooms,
    consoles: consoles,
    spawn_tile: spawn_tile,
  ))
}

/// The deck-plan fields as a key/value list, for hosts that embed them at
/// the top level of their own object (ship class docs).
pub fn encode_fields(plan: DeckPlan) -> List(#(String, Json)) {
  [
    #("grid", encode_grid(plan.grid)),
    #("walkable", json.array(plan.walkable, json.string)),
    #("rooms", json.array(plan.rooms, encode_room)),
    #("consoles", json.array(plan.consoles, encode_console)),
    #("spawn_tile", encode_tile(plan.spawn_tile)),
  ]
}

/// A deck plan as its own JSON object (station concourses).
pub fn encode(plan: DeckPlan) -> Json {
  json.object(encode_fields(plan))
}

fn grid_decoder() -> decode.Decoder(Grid) {
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  decode.success(Grid(width: width, height: height))
}

fn room_decoder() -> decode.Decoder(Room) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  use w <- decode.field("w", decode.int)
  use h <- decode.field("h", decode.int)
  decode.success(Room(id: id, name: name, x: x, y: y, w: w, h: h))
}

fn console_decoder() -> decode.Decoder(Console) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  decode.success(Console(id: id, kind: kind, x: x, y: y))
}

fn tile_decoder() -> decode.Decoder(#(Int, Int)) {
  use coords <- decode.then(decode.list(decode.int))
  case coords {
    [x, y] -> decode.success(#(x, y))
    _ -> decode.failure(#(0, 0), "two-element [x, y] array")
  }
}

fn encode_grid(grid: Grid) -> Json {
  json.object([
    #("width", json.int(grid.width)),
    #("height", json.int(grid.height)),
  ])
}

fn encode_room(room: Room) -> Json {
  json.object([
    #("id", json.string(room.id)),
    #("name", json.string(room.name)),
    #("x", json.int(room.x)),
    #("y", json.int(room.y)),
    #("w", json.int(room.w)),
    #("h", json.int(room.h)),
  ])
}

fn encode_console(console: Console) -> Json {
  json.object([
    #("id", json.string(console.id)),
    #("kind", json.string(console.kind)),
    #("x", json.int(console.x)),
    #("y", json.int(console.y)),
  ])
}

fn encode_tile(tile: #(Int, Int)) -> Json {
  let #(x, y) = tile
  json.preprocessed_array([json.int(x), json.int(y)])
}
