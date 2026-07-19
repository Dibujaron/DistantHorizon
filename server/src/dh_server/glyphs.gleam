//// The tile-glyph registry: the canonical vocabulary for interior deck-plan
//// maps (`docs/deckplan-format.md`), loaded at startup from `server/glyphs.json`
//// so the parser interprets maps from DATA rather than hardcoded tables. The
//// console/dock/spawn legend AND the client's `id -> sprite` mapping live in
//// that one file (the server ignores `sprite`/`description`), so adding a tile
//// is a registry entry plus a sprite, not a code change — the modding path
//// (issues #24/#28/#32).
////
//// `deckplan` consults a `Registry` to interpret center glyphs (tile kind,
//// console kind, dock port, spawn) and edge glyphs (open/wall/door/fixture).
//// `default()` is a built-in copy of the shipped `glyphs.json`, used as a
//// dev fallback when the file is unreadable and by unit tests that build decks
//// without a file; `glyphs_test` asserts it stays byte-identical to the file.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The tile-kind a center glyph denotes. `Floor` and `Stairs` are walkable;
/// `Void` is outside the hull. Consoles / dock ports / spawn tiles are all
/// `Floor`-kind with extra flags (see `CenterSpec`).
pub type TileKind {
  Floor
  Void
  Stairs
}

/// What an edge glyph denotes. `Open`/`Door` are passable; `Wall`/`Fixture`
/// block. `Fixture` is a named wall-mounted decoration; the parser keeps the
/// glyph's own char as the fixture kind.
pub type EdgeKind {
  Open
  Wall
  Door
  Fixture
}

/// One center-glyph entry: long-form `id` (the client's sprite key), tile
/// kind, the console `kind` it installs (if any), whether it is a docking
/// port, and whether it is a bare spawn tile.
pub type CenterSpec {
  CenterSpec(
    id: String,
    tile: TileKind,
    console: Option(String),
    dock: Bool,
    spawn: Bool,
  )
}

/// One edge-glyph entry: long-form `id` and edge kind.
pub type EdgeSpec {
  EdgeSpec(id: String, kind: EdgeKind)
}

/// The loaded vocabulary: center and edge glyphs, each keyed by their single
/// glyph char. Unknown glyphs fall back (center -> `Floor`, edge -> `Fixture`)
/// to honour the format's "nothing is ever a syntax error" rule.
pub type Registry {
  Registry(centers: Dict(String, CenterSpec), edges: Dict(String, EdgeSpec))
}

/// Look up a center glyph; an unknown glyph is plain `Floor` (the format's
/// "any other center char is floor" fallback).
pub fn center(reg: Registry, glyph: String) -> CenterSpec {
  case dict.get(reg.centers, glyph) {
    Ok(spec) -> spec
    Error(Nil) ->
      CenterSpec(
        id: "floor",
        tile: Floor,
        console: None,
        dock: False,
        spawn: False,
      )
  }
}

/// Look up an edge glyph; an unknown glyph is a generic `Fixture` (the
/// format's "any other edge char is a wall-fixture" fallback).
pub fn edge(reg: Registry, glyph: String) -> EdgeSpec {
  case dict.get(reg.edges, glyph) {
    Ok(spec) -> spec
    Error(Nil) -> EdgeSpec(id: "fixture", kind: Fixture)
  }
}

/// The console kind a center glyph installs, or `Error(Nil)` if it is not a
/// console. Dock ports read as a console of kind `"dock"`.
pub fn console_kind(reg: Registry, glyph: String) -> Result(String, Nil) {
  option.to_result(center(reg, glyph).console, Nil)
}

/// The center glyph that installs console kind `kind` (inverse of
/// `console_kind`), or `""` if the registry has none.
pub fn console_glyph(reg: Registry, kind: String) -> String {
  let match =
    list.find(dict.to_list(reg.centers), fn(kv) {
      let #(_, spec) = kv
      spec.console == Some(kind)
    })
  case match {
    Ok(#(glyph, _)) -> glyph
    Error(Nil) -> ""
  }
}

// ---------------------------------------------------------------- load ----

/// Read and decode a glyph registry from a file.
pub fn load(path: String) -> Result(Registry, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read glyph registry " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Decode a glyph registry from a JSON string.
pub fn decode(json_text: String) -> Result(Registry, String) {
  json.parse(json_text, registry_decoder())
  |> result.map_error(fn(err) {
    "invalid glyph registry: " <> string.inspect(err)
  })
}

fn registry_decoder() -> decode.Decoder(Registry) {
  use centers <- decode.field("centers", decode.list(center_decoder()))
  use edges <- decode.field("edges", decode.list(edge_decoder()))
  decode.success(Registry(
    centers: from_pairs(centers),
    edges: from_pairs(edges),
  ))
}

fn from_pairs(pairs: List(#(String, a))) -> Dict(String, a) {
  list.fold(pairs, dict.new(), fn(d, kv) { dict.insert(d, kv.0, kv.1) })
}

fn center_decoder() -> decode.Decoder(#(String, CenterSpec)) {
  use glyph <- decode.field("glyph", decode.string)
  use id <- decode.field("id", decode.string)
  use tile <- decode.field("tile", tile_kind_decoder())
  use console <- decode.optional_field(
    "console",
    None,
    decode.map(decode.string, Some),
  )
  use dock <- decode.optional_field("dock", False, decode.bool)
  use spawn <- decode.optional_field("spawn", False, decode.bool)
  decode.success(#(
    glyph,
    CenterSpec(id: id, tile: tile, console: console, dock: dock, spawn: spawn),
  ))
}

fn edge_decoder() -> decode.Decoder(#(String, EdgeSpec)) {
  use glyph <- decode.field("glyph", decode.string)
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", edge_kind_decoder())
  decode.success(#(glyph, EdgeSpec(id: id, kind: kind)))
}

fn tile_kind_decoder() -> decode.Decoder(TileKind) {
  use raw <- decode.then(decode.string)
  case raw {
    "floor" -> decode.success(Floor)
    "void" -> decode.success(Void)
    "stairs" -> decode.success(Stairs)
    _ -> decode.failure(Floor, "tile kind \"floor\" | \"void\" | \"stairs\"")
  }
}

fn edge_kind_decoder() -> decode.Decoder(EdgeKind) {
  use raw <- decode.then(decode.string)
  case raw {
    "open" -> decode.success(Open)
    "wall" -> decode.success(Wall)
    "door" -> decode.success(Door)
    "fixture" -> decode.success(Fixture)
    _ ->
      decode.failure(
        Open,
        "edge kind \"open\" | \"wall\" | \"door\" | \"fixture\"",
      )
  }
}

// ------------------------------------------------------------- default ----

/// The built-in registry — a code mirror of the shipped `glyphs.json`. Used
/// as a fallback when the file cannot be read and by unit tests. Kept in sync
/// with the file by `glyphs_test`.
pub fn default() -> Registry {
  Registry(
    centers: dict.from_list([
      #(" ", CenterSpec("floor", Floor, None, False, False)),
      #(".", CenterSpec("void", Void, None, False, False)),
      #("x", CenterSpec("stairs", Stairs, None, False, False)),
      #("h", CenterSpec("helm_console", Floor, Some("helm"), False, False)),
      #("c", CenterSpec("cargo_console", Floor, Some("cargo"), False, False)),
      #("b", CenterSpec("broker_console", Floor, Some("broker"), False, False)),
      #("Q", CenterSpec("docking_port", Floor, Some("dock"), True, False)),
      #("s", CenterSpec("spawn", Floor, None, False, True)),
    ]),
    edges: dict.from_list([
      #(" ", EdgeSpec("open", Open)),
      #("#", EdgeSpec("wall", Wall)),
      #("=", EdgeSpec("door", Door)),
      #("v", EdgeSpec("viewscreen", Fixture)),
    ]),
  )
}
