//// Shared interior deck-plan geometry (format v3, `docs/deckplan-format.md`):
//// a ship or station interior is a list of independent **decks**, each its
//// own grid of tiles. Every tile is a 3x3 block of characters: the centre
//// says what the tile IS (floor / void / stairs) and the four edge-mid
//// characters say what's on each SIDE (wall / door / fixture). Decks connect
//// only through `x` stairs tiles (vertically-aligned across adjacent decks).
////
//// Interior coordinates are tile units, y-down; tile `(x, y)` spans
//// `[x, x+1) x [y, y+1)`, centre `(x+0.5, y+0.5)`. Both ship classes
//// (shipclass.gleam) and station concourses (world.gleam) are built from a
//// `DeckPlan`; the same parser runs server-side and (mirrored) client-side.

import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/string

/// What a tile's edge carries. `Open` is passable; `Wall` and `Fixture`
/// (a wall that also mounts art, e.g. a viewscreen) block; `Door` is a
/// passable opening (auto-opens for now).
pub type Edge {
  Open
  Wall
  Door
  Fixture(kind: String)
}

/// What a tile IS at its centre. `Void` is outside the hull (never walkable);
/// `Floor` is open walkable floor; `Stairs` is a walkable ladder/stair tile
/// that connects to the vertically-aligned tile on an adjacent deck.
pub type Tile {
  Void
  Floor
  Stairs
}

/// A cardinal direction, y-down: `N` is -y, `S` is +y, `E` is +x, `W` is -x.
pub type Dir {
  N
  E
  S
  W
}

/// One deck: a `width` x `height` grid of tiles, each with its own four
/// edges. `tiles[y][x]` is the centre; `edges[y][x]` is `#(n, e, s, w)` for
/// that tile. A partition between two rooms is a *double* wall — each tile
/// owns its own side — so `edge_blocks` ORs the two facing edges.
pub type DeckGrid {
  DeckGrid(
    name: String,
    width: Int,
    height: Int,
    tiles: List(List(Tile)),
    edges: List(List(#(Edge, Edge, Edge, Edge))),
  )
}

/// A labelled rectangle of tiles on one deck, for rendering/labels only (no
/// door graph). `deck` is the deck index it lives on.
pub type Room {
  Room(id: String, name: String, deck: Int, x: Int, y: Int, w: Int, h: Int)
}

/// A single-tile interactable on one deck. `kind` is e.g. `"helm"`,
/// `"cargo"` or `"broker"`; `deck` is the deck index it lives on.
pub type Console {
  Console(id: String, kind: String, deck: Int, x: Int, y: Int)
}

/// A whole interior: its decks, the labelled rooms/consoles that sit on
/// them, and where arriving characters appear (deck + tile).
pub type DeckPlan {
  DeckPlan(
    decks: List(DeckGrid),
    rooms: List(Room),
    consoles: List(Console),
    spawn_deck: Int,
    spawn_tile: #(Int, Int),
  )
}

// ---------------------------------------------------------------- parse --

/// Parse a `width` x `height` deck from `3*height` rows of `3*width`
/// characters (the 3x3-per-tile block format). Errors if the row count or
/// any row length is not a multiple of 3, or rows differ in length.
///
/// Per tile `(x, y)` the block origin is `(3x, 3y)`: centre at row `3y+1`
/// col `3x+1`; N at row `3y` col `3x+1`; S at row `3y+2` col `3x+1`; W at
/// row `3y+1` col `3x`; E at row `3y+1` col `3x+2`. Corners are cosmetic and
/// ignored. Centre glyphs: space -> Floor, `.` -> Void, `x` -> Stairs. Edge
/// glyphs: space -> Open, `#` -> Wall, `=` -> Door, any other char ->
/// Fixture(that char).
pub fn parse_deck(
  name: String,
  rows: List(String),
) -> Result(DeckGrid, String) {
  let row_count = list.length(rows)
  use <- guard(row_count > 0, "deck \"" <> name <> "\" has no rows")
  use <- guard(
    row_count % 3 == 0,
    "deck \"" <> name <> "\" row count is not a multiple of 3",
  )
  let lengths = list.map(rows, string.length)
  let assert Ok(first_len) = list.first(lengths)
  use <- guard(
    !list.any(lengths, fn(l) { l != first_len }),
    "deck \"" <> name <> "\" rows are not all the same length",
  )
  use <- guard(
    first_len > 0 && first_len % 3 == 0,
    "deck \"" <> name <> "\" row length is not a positive multiple of 3",
  )
  let width = first_len / 3
  let height = row_count / 3
  // Index once into a grid of graphemes; repeated slicing on strings is O(n).
  let cells = list.map(rows, string.to_graphemes)
  let tiles =
    list.map(range(0, height), fn(y) {
      list.map(range(0, width), fn(x) {
        parse_center(cell_at(cells, 3 * y + 1, 3 * x + 1))
      })
    })
  let edges =
    list.map(range(0, height), fn(y) {
      list.map(range(0, width), fn(x) {
        #(
          parse_edge(cell_at(cells, 3 * y, 3 * x + 1)),
          parse_edge(cell_at(cells, 3 * y + 1, 3 * x + 2)),
          parse_edge(cell_at(cells, 3 * y + 2, 3 * x + 1)),
          parse_edge(cell_at(cells, 3 * y + 1, 3 * x)),
        )
      })
    })
  Ok(DeckGrid(
    name: name,
    width: width,
    height: height,
    tiles: tiles,
    edges: edges,
  ))
}

fn parse_center(ch: String) -> Tile {
  case ch {
    "." -> Void
    "x" -> Stairs
    _ -> Floor
  }
}

fn parse_edge(ch: String) -> Edge {
  case ch {
    " " -> Open
    "#" -> Wall
    "=" -> Door
    other -> Fixture(other)
  }
}

fn cell_at(cells: List(List(String)), r: Int, c: Int) -> String {
  case list.drop(cells, r) |> list.first {
    Error(Nil) -> " "
    Ok(row) ->
      case list.drop(row, c) |> list.first {
        Error(Nil) -> " "
        Ok(ch) -> ch
      }
  }
}

// -------------------------------------------------------------- queries --

/// The deck grid at index `i`, or `Error(Nil)`.
pub fn deck_at(plan: DeckPlan, i: Int) -> Result(DeckGrid, Nil) {
  case i >= 0 {
    False -> Error(Nil)
    True -> list.drop(plan.decks, i) |> list.first
  }
}

/// The tile at `(x, y)` on `g`; `Void` out of bounds.
pub fn tile_at(g: DeckGrid, x: Int, y: Int) -> Tile {
  case in_bounds(g, x, y) {
    False -> Void
    True ->
      case list.drop(g.tiles, y) |> list.first {
        Error(Nil) -> Void
        Ok(row) ->
          case list.drop(row, x) |> list.first {
            Error(Nil) -> Void
            Ok(t) -> t
          }
      }
  }
}

/// The four edges `#(n, e, s, w)` of tile `(x, y)` on `g`; `Error(Nil)` out
/// of bounds.
pub fn edges_at(
  g: DeckGrid,
  x: Int,
  y: Int,
) -> Result(#(Edge, Edge, Edge, Edge), Nil) {
  case in_bounds(g, x, y) {
    False -> Error(Nil)
    True ->
      case list.drop(g.edges, y) |> list.first {
        Error(Nil) -> Error(Nil)
        Ok(row) -> list.drop(row, x) |> list.first
      }
  }
}

/// Whether `(x, y)` is a walkable tile of `g` (Floor or Stairs, in bounds).
pub fn is_walkable(g: DeckGrid, x: Int, y: Int) -> Bool {
  case tile_at(g, x, y) {
    Void -> False
    Floor -> True
    Stairs -> True
  }
}

/// Whether a step from tile `(x, y)` across its `dir` edge is blocked. The
/// double-wall OR rule: blocked if EITHER this tile's `dir` edge or the
/// neighbour tile's opposite edge is a wall or wall-fixture. Doors and open
/// edges are passable. (Void targets are rejected separately by
/// `is_walkable` on the destination.)
pub fn edge_blocks(g: DeckGrid, x: Int, y: Int, dir: Dir) -> Bool {
  let #(nx, ny) = neighbor(x, y, dir)
  blocks(edge_in(g, x, y, dir)) || blocks(edge_in(g, nx, ny, opposite(dir)))
}

/// The adjacent deck index a `Stairs` tile at `(x, y)` on `deck` connects to:
/// the nearer deck (`deck-1` or `deck+1`) that also has a `Stairs` tile at
/// the same `(x, y)`. `Error(Nil)` if `(x, y)` is not stairs, or no aligned
/// adjacent stairs exists. Authored layouts keep the two stair columns of a
/// three-deck ship at distinct `(x, y)` so this is unambiguous; if both
/// neighbours qualify, `deck+1` (downward) wins.
pub fn stairs_target(
  plan: DeckPlan,
  deck: Int,
  x: Int,
  y: Int,
) -> Result(Int, Nil) {
  case deck_at(plan, deck) {
    Error(Nil) -> Error(Nil)
    Ok(g) ->
      case tile_at(g, x, y) {
        Stairs ->
          case stairs_here(plan, deck + 1, x, y) {
            True -> Ok(deck + 1)
            False ->
              case stairs_here(plan, deck - 1, x, y) {
                True -> Ok(deck - 1)
                False -> Error(Nil)
              }
          }
        _ -> Error(Nil)
      }
  }
}

fn stairs_here(plan: DeckPlan, deck: Int, x: Int, y: Int) -> Bool {
  case deck_at(plan, deck) {
    Error(Nil) -> False
    Ok(g) -> tile_at(g, x, y) == Stairs
  }
}

fn in_bounds(g: DeckGrid, x: Int, y: Int) -> Bool {
  x >= 0 && x < g.width && y >= 0 && y < g.height
}

fn edge_in(g: DeckGrid, x: Int, y: Int, dir: Dir) -> Edge {
  case edges_at(g, x, y) {
    Error(Nil) -> Open
    Ok(#(n, e, s, w)) ->
      case dir {
        N -> n
        E -> e
        S -> s
        W -> w
      }
  }
}

fn blocks(edge: Edge) -> Bool {
  case edge {
    Wall -> True
    Fixture(_) -> True
    Open -> False
    Door -> False
  }
}

fn neighbor(x: Int, y: Int, dir: Dir) -> #(Int, Int) {
  case dir {
    N -> #(x, y - 1)
    E -> #(x + 1, y)
    S -> #(x, y + 1)
    W -> #(x - 1, y)
  }
}

fn opposite(dir: Dir) -> Dir {
  case dir {
    N -> S
    E -> W
    S -> N
    W -> E
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

/// Centre of tile (x, y) in tile units.
pub fn tile_center(x: Int, y: Int) -> #(Float, Float) {
  #(int.to_float(x) +. 0.5, int.to_float(y) +. 0.5)
}

// ------------------------------------------------------------- validate --

/// Geometry validation shared by every deck-plan host: at least one deck,
/// every console and room sits on a valid deck index with the console on a
/// walkable tile, and the spawn deck/tile is walkable. Host-specific console
/// requirements (a ship needs a helm, a trading concourse a broker) live
/// with the host document.
pub fn validate(plan: DeckPlan) -> Result(DeckPlan, String) {
  let deck_count = list.length(plan.decks)
  use <- guard(deck_count > 0, "deck plan has no decks")
  use <- guard(
    !list.any(plan.rooms, fn(r) { r.deck < 0 || r.deck >= deck_count }),
    "a room references an out-of-range deck",
  )
  use _ <- try_each(plan.consoles, fn(c) {
    case deck_at(plan, c.deck) {
      Error(Nil) -> Error("a console references an out-of-range deck")
      Ok(g) ->
        case is_walkable(g, c.x, c.y) {
          True -> Ok(Nil)
          False -> Error("console \"" <> c.id <> "\" is not on a walkable tile")
        }
    }
  })
  let #(sx, sy) = plan.spawn_tile
  case deck_at(plan, plan.spawn_deck) {
    Error(Nil) -> Error("spawn_deck is out of range")
    Ok(g) ->
      case is_walkable(g, sx, sy) {
        True -> Ok(plan)
        False -> Error("spawn_tile is not on a walkable tile")
      }
  }
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

fn try_each(
  items: List(a),
  check: fn(a) -> Result(Nil, String),
  next: fn(Nil) -> Result(b, String),
) -> Result(b, String) {
  case list.try_map(items, check) {
    Error(e) -> Error(e)
    Ok(_) -> next(Nil)
  }
}

// -------------------------------------------------------- decode/encode --

/// Decode the deck-plan fields (`decks`/`rooms`/`consoles`/`spawn`) from the
/// current JSON object — ship class docs carry them at their top level,
/// station concourses as a nested object; the same decoder serves both.
pub fn decoder() -> decode.Decoder(DeckPlan) {
  use decks <- decode.field("decks", decode.list(deck_grid_decoder()))
  use rooms <- decode.optional_field("rooms", [], decode.list(room_decoder()))
  use consoles <- decode.optional_field(
    "consoles",
    [],
    decode.list(console_decoder()),
  )
  use spawn <- decode.field("spawn", spawn_decoder())
  let #(spawn_deck, spawn_tile) = spawn
  decode.success(DeckPlan(
    decks: decks,
    rooms: rooms,
    consoles: consoles,
    spawn_deck: spawn_deck,
    spawn_tile: spawn_tile,
  ))
}

/// The deck-plan fields as a key/value list, for hosts that embed them at
/// the top level of their own object (ship class docs). Decks are emitted as
/// raw 3x3 grid rows so the client re-parses them with the same rules.
pub fn encode_fields(plan: DeckPlan) -> List(#(String, Json)) {
  [
    #("decks", json.array(plan.decks, encode_deck)),
    #("rooms", json.array(plan.rooms, encode_room)),
    #("consoles", json.array(plan.consoles, encode_console)),
    #("spawn", encode_spawn(plan.spawn_deck, plan.spawn_tile)),
  ]
}

/// A deck plan as its own JSON object (station concourses).
pub fn encode(plan: DeckPlan) -> Json {
  json.object(encode_fields(plan))
}

fn deck_grid_decoder() -> decode.Decoder(DeckGrid) {
  use name <- decode.field("name", decode.string)
  use grid <- decode.field("grid", decode.list(decode.string))
  case parse_deck(name, grid) {
    Ok(g) -> decode.success(g)
    Error(e) -> decode.failure(empty_grid(name), "valid deck grid: " <> e)
  }
}

fn empty_grid(name: String) -> DeckGrid {
  DeckGrid(name: name, width: 0, height: 0, tiles: [], edges: [])
}

fn room_decoder() -> decode.Decoder(Room) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use deck <- decode.optional_field("deck", 0, decode.int)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  use w <- decode.field("w", decode.int)
  use h <- decode.field("h", decode.int)
  decode.success(Room(id: id, name: name, deck: deck, x: x, y: y, w: w, h: h))
}

fn console_decoder() -> decode.Decoder(Console) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use deck <- decode.optional_field("deck", 0, decode.int)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  decode.success(Console(id: id, kind: kind, deck: deck, x: x, y: y))
}

fn spawn_decoder() -> decode.Decoder(#(Int, #(Int, Int))) {
  use deck <- decode.optional_field("deck", 0, decode.int)
  use tile <- decode.field("tile", decode.list(decode.int))
  case tile {
    [x, y] -> decode.success(#(deck, #(x, y)))
    _ -> decode.failure(#(0, #(0, 0)), "spawn.tile as a two-element [x, y]")
  }
}

fn encode_deck(g: DeckGrid) -> Json {
  json.object([
    #("name", json.string(g.name)),
    #("grid", json.array(deck_to_rows(g), json.string)),
  ])
}

/// Re-serialise a deck grid back to 3x3-per-tile rows (the inverse of
/// `parse_deck`, up to cosmetic corners): centre + four edges are exact, so
/// it round-trips. Corners render `#` when either adjacent edge is closed so
/// the hull reads cleanly.
pub fn deck_to_rows(g: DeckGrid) -> List(String) {
  list.flat_map(range(0, g.height), fn(y) {
    let cells = list.map(range(0, g.width), fn(x) { tile_block(g, x, y) })
    let top = string.concat(list.map(cells, fn(c) { c.0 }))
    let mid = string.concat(list.map(cells, fn(c) { c.1 }))
    let bot = string.concat(list.map(cells, fn(c) { c.2 }))
    [top, mid, bot]
  })
}

fn tile_block(g: DeckGrid, x: Int, y: Int) -> #(String, String, String) {
  let #(n, e, s, w) = case edges_at(g, x, y) {
    Ok(edges) -> edges
    Error(Nil) -> #(Open, Open, Open, Open)
  }
  let c = center_glyph(tile_at(g, x, y))
  let top = corner(n, w) <> edge_glyph(n) <> corner(n, e)
  let mid = edge_glyph(w) <> c <> edge_glyph(e)
  let bot = corner(s, w) <> edge_glyph(s) <> corner(s, e)
  #(top, mid, bot)
}

fn center_glyph(tile: Tile) -> String {
  case tile {
    Void -> "."
    Floor -> " "
    Stairs -> "x"
  }
}

fn edge_glyph(edge: Edge) -> String {
  case edge {
    Open -> " "
    Wall -> "#"
    Door -> "="
    Fixture(kind) -> kind
  }
}

fn corner(a: Edge, b: Edge) -> String {
  case blocks(a) || blocks(b) {
    True -> "#"
    False -> " "
  }
}

fn encode_room(room: Room) -> Json {
  json.object([
    #("id", json.string(room.id)),
    #("name", json.string(room.name)),
    #("deck", json.int(room.deck)),
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
    #("deck", json.int(console.deck)),
    #("x", json.int(console.x)),
    #("y", json.int(console.y)),
  ])
}

fn encode_spawn(deck: Int, tile: #(Int, Int)) -> Json {
  let #(x, y) = tile
  json.object([
    #("deck", json.int(deck)),
    #("tile", json.preprocessed_array([json.int(x), json.int(y)])),
  ])
}

/// [from, to) as a list of ints (the pinned gleam_stdlib has no
/// `list.range`; matches the local helper idiom used elsewhere).
fn range(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
