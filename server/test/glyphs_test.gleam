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
  assert glyphs.center(reg, "b").console == Some("broker")
  assert glyphs.center(reg, "Q").console == Some("dock")
  assert glyphs.center(reg, "Q").dock == True
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
  assert glyphs.console_kind(reg, "h") == Ok("helm")
  assert glyphs.console_kind(reg, " ") == Error(Nil)
  assert glyphs.console_glyph(reg, "helm") == "h"
  assert glyphs.console_glyph(reg, "dock") == "Q"
  assert glyphs.console_glyph(reg, "nope") == ""
}
