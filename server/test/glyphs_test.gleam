import dh_server/glyphs
import gleam/option.{None, Some}

const registry_path = "glyphs.json"

pub fn loads_shipped_registry_test() {
  let assert Ok(_) = glyphs.load(registry_path)
}

/// The built-in `default()` must stay byte-identical to the shipped file, so
/// the fallback and unit-test legend can never silently drift from canon.
pub fn default_matches_shipped_file_test() {
  let assert Ok(loaded) = glyphs.load(registry_path)
  assert loaded == glyphs.default()
}

pub fn center_floor_and_void_test() {
  let reg = glyphs.default()
  assert glyphs.center(reg, " ").tile == glyphs.Floor
  assert glyphs.center(reg, ".").tile == glyphs.Void
  assert glyphs.center(reg, "x").tile == glyphs.Stairs
}

pub fn center_console_and_dock_test() {
  let reg = glyphs.default()
  // Consoles are wall (edge) fixtures now; `q` is the only centre console (dock).
  assert glyphs.center(reg, "b").console == None
  assert glyphs.edge_console_kind(reg, "b") == Ok("broker")
  assert glyphs.center(reg, "q").console == Some("dock")
  assert glyphs.center(reg, "q").dock == True
  assert glyphs.center(reg, "s").spawn == True
  assert glyphs.center(reg, "s").console == None
}

pub fn unknown_center_is_floor_test() {
  let reg = glyphs.default()
  // The format never errors on an unknown glyph — it is plain floor.
  assert glyphs.center(reg, "?").tile == glyphs.Floor
  assert glyphs.center(reg, "?").console == None
}

pub fn edge_kinds_test() {
  let reg = glyphs.default()
  assert glyphs.edge(reg, " ").kind == glyphs.Open
  assert glyphs.edge(reg, "#").kind == glyphs.Wall
  assert glyphs.edge(reg, "=").kind == glyphs.Door
  assert glyphs.edge(reg, "v").kind == glyphs.Fixture
}

pub fn unknown_edge_is_fixture_test() {
  let reg = glyphs.default()
  // An unnamed edge char is a generic wall-fixture (blocks + carries art).
  assert glyphs.edge(reg, "z").kind == glyphs.Fixture
}

pub fn console_kind_and_glyph_roundtrip_test() {
  let reg = glyphs.default()
  // `q` (dock) is the only centre console; helm/cargo/broker are wall fixtures.
  assert glyphs.console_kind(reg, "q") == Ok("dock")
  assert glyphs.console_kind(reg, "h") == Error(Nil)
  assert glyphs.console_kind(reg, " ") == Error(Nil)
  assert glyphs.console_glyph(reg, "dock") == "q"
  assert glyphs.console_glyph(reg, "helm") == ""
  assert glyphs.console_glyph(reg, "nope") == ""
}

pub fn edge_console_kind_test() {
  let reg = glyphs.default()
  assert glyphs.edge_console_kind(reg, "h") == Ok("helm")
  assert glyphs.edge_console_kind(reg, "b") == Ok("broker")
  assert glyphs.edge_console_kind(reg, "#") == Error(Nil)
  assert glyphs.edge_console_kind(reg, "w") == Error(Nil)
}

pub fn is_decor_test() {
  let reg = glyphs.default()
  assert glyphs.is_decor(reg, "r") == True
  // seat, bed, pallet are decor; plain floor / stairs / console / dock / spawn are not
  assert glyphs.is_decor(reg, "d") == True
  assert glyphs.is_decor(reg, "p") == True
  assert glyphs.is_decor(reg, " ") == False
  assert glyphs.is_decor(reg, "x") == False
  assert glyphs.is_decor(reg, "h") == False
  assert glyphs.is_decor(reg, "q") == False
  assert glyphs.is_decor(reg, "s") == False
}

/// The dock port is lowercase like every other glyph that says what a tile
/// IS. Uppercase is reserved wholesale for slot membership — see
/// `docs/deckplan-format.md`. `Q` was the one exception and it is gone.
pub fn the_dock_port_glyph_is_lowercase_test() {
  let reg = glyphs.default()
  assert glyphs.center(reg, "q").dock == True
  assert glyphs.center(reg, "Q").dock != True
}
