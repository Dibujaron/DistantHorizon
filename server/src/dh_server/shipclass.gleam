//// Ship class documents: static, hand-authored deck plans (DESIGN.md
//// "content is data"). One class exists in M2 (`server/classes/sparrow.json`,
//// path overridable via `DH_SHIP_CLASS`); every ship in the sim is spawned
//// from the same loaded `ShipClass`. Interior coordinates are tile units,
//// ship-local, y-down; tile `(x,y)` spans `[x, x+1) x [y, y+1)`, center
//// `(x+0.5, y+0.5)`.
////
//// The whole document is sent verbatim to clients as `ship_class` in the
//// `welcome` message, so `encode` round-trips exactly what was loaded.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type Grid {
  Grid(width: Int, height: Int)
}

/// A labelled rectangle of tiles, for rendering/labels only (no door graph
/// in M2).
pub type Room {
  Room(id: String, name: String, x: Int, y: Int, w: Int, h: Int)
}

/// A single-tile interactable. `kind` is e.g. `"helm"` or `"cargo"`; only
/// `"helm"` consoles are functional in M2.
pub type Console {
  Console(id: String, kind: String, x: Int, y: Int)
}

pub type ShipClass {
  ShipClass(
    schema: Int,
    id: String,
    name: String,
    grid: Grid,
    /// One string per row, top to bottom; `'#'` walkable, anything else
    /// (canonically `'.'`) hull/void.
    walkable: List(String),
    rooms: List(Room),
    consoles: List(Console),
    /// Tile where boarding characters appear (the airlock end).
    spawn_tile: #(Int, Int),
  )
}

/// Read and decode a ship class document from a file. `path` is resolved
/// relative to the process's working directory.
pub fn load(path: String) -> Result(ShipClass, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read ship class file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Decode a ship class document from a JSON string, validating that the
/// `walkable` grid matches `grid.width`/`grid.height` and that every
/// console and the spawn tile sit on a walkable tile.
pub fn decode(json_text: String) -> Result(ShipClass, String) {
  case json.parse(json_text, ship_class_decoder()) {
    Ok(class) -> validate(class)
    Error(err) -> Error("invalid ship class document: " <> string.inspect(err))
  }
}

/// Encode a ship class document, e.g. for the `welcome` message.
pub fn encode(class: ShipClass) -> Json {
  json.object([
    #("schema", json.int(class.schema)),
    #("id", json.string(class.id)),
    #("name", json.string(class.name)),
    #("grid", encode_grid(class.grid)),
    #("walkable", json.array(class.walkable, json.string)),
    #("rooms", json.array(class.rooms, encode_room)),
    #("consoles", json.array(class.consoles, encode_console)),
    #("spawn_tile", encode_tile(class.spawn_tile)),
  ])
}

/// Whether tile `(x, y)` is in bounds and walkable.
pub fn is_walkable(class: ShipClass, x: Int, y: Int) -> Bool {
  case x >= 0 && x < class.grid.width && y >= 0 && y < class.grid.height {
    False -> False
    True -> {
      let assert Ok(row) = list.drop(class.walkable, y) |> list.first
      string.slice(from: row, at_index: x, length: 1) == "#"
    }
  }
}

/// Look up a console by id.
pub fn find_console(
  class: ShipClass,
  console_id: String,
) -> Result(Console, Nil) {
  list.find(class.consoles, fn(c) { c.id == console_id })
}

/// The first console of kind `"helm"`, if any.
pub fn helm_console(class: ShipClass) -> Result(Console, Nil) {
  list.find(class.consoles, fn(c) { c.kind == "helm" })
}

fn validate(class: ShipClass) -> Result(ShipClass, String) {
  use <- guard(
    list.length(class.walkable) == class.grid.height,
    "walkable row count does not match grid.height",
  )
  use <- guard(
    !list.any(class.walkable, fn(row) { string.length(row) != class.grid.width }),
    "a walkable row's length does not match grid.width",
  )
  use <- guard(
    !list.any(class.consoles, fn(c) { !is_walkable(class, c.x, c.y) }),
    "a console is not on a walkable tile",
  )
  let #(sx, sy) = class.spawn_tile
  use <- guard(
    is_walkable(class, sx, sy),
    "spawn_tile is not on a walkable tile",
  )
  use <- guard(result.is_ok(helm_console(class)), "no console of kind \"helm\"")
  Ok(class)
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

fn ship_class_decoder() -> decode.Decoder(ShipClass) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use grid <- decode.field("grid", grid_decoder())
  use walkable <- decode.field("walkable", decode.list(decode.string))
  use rooms <- decode.field("rooms", decode.list(room_decoder()))
  use consoles <- decode.field("consoles", decode.list(console_decoder()))
  use spawn_tile <- decode.field("spawn_tile", tile_decoder())
  decode.success(ShipClass(
    schema: schema,
    id: id,
    name: name,
    grid: grid,
    walkable: walkable,
    rooms: rooms,
    consoles: consoles,
    spawn_tile: spawn_tile,
  ))
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
