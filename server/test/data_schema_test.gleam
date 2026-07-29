import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import simplifile

// Reuses quest_schema_ffi's validate/2 — it is already schema-agnostic
// (Dynamic schema, Dynamic value in; Result(Nil, String) out), so world and
// hull documents ride the same jesse wiring quests use rather than
// standing up a second FFI entry point.
@external(erlang, "quest_schema_ffi", "validate")
fn validate_with_schema(schema: Dynamic, value: Dynamic) -> Result(Nil, String)

const world_schema_path = "schemas/world.schema.json"

const hull_schema_path = "schemas/hull.schema.json"

const station_class_schema_path = "schemas/station_class.schema.json"

const station_classes_dir = "stationclasses"

const glyphs_schema_path = "schemas/glyphs.schema.json"

const glyphs_path = "glyphs.json"

const worlds_dir = "worlds"

const hulls_dir = "shipclasses"

const module_schema_path = "schemas/module.schema.json"

const part_schema_path = "schemas/part.schema.json"

const modules_dir = "modules"

const parts_dir = "parts"

fn read_json(path: String) -> Dynamic {
  let assert Ok(text) = simplifile.read(path)
  parse_json(text)
}

fn parse_json(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn json_files(dir: String) -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(dir)
  entries
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
}

/// Every `*.json` one level down from `dir`, as full paths. Modules are filed
/// per hull (`server/modules/<hull>/<id>.json`), so a flat listing would find
/// nothing but the `.gitkeep` — this mirrors `module.load_all`'s own walk.
fn nested_json_files(dir: String) -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(dir)
  entries
  |> list.sort(string.compare)
  |> list.flat_map(fn(entry) {
    let path = dir <> "/" <> entry
    case simplifile.is_directory(path) {
      Ok(True) -> list.map(json_files(path), fn(name) { path <> "/" <> name })
      _ -> []
    }
  })
}

fn assert_all_validate(schema_path: String, dir: String) -> Nil {
  assert_paths_validate(
    schema_path,
    json_files(dir)
      |> list.map(fn(f) { dir <> "/" <> f }),
  )
}

fn assert_paths_validate(schema_path: String, paths: List(String)) -> Nil {
  let schema = read_json(schema_path)
  // Guards against a typo'd glob silently validating nothing.
  assert paths != []
  list.each(paths, fn(path) {
    let value = read_json(path)
    case validate_with_schema(schema, value) {
      Ok(Nil) -> Nil
      Error(message) -> panic as { path <> ": " <> message }
    }
  })
}

pub fn all_worlds_match_schema_test() {
  assert_all_validate(world_schema_path, worlds_dir)
}

pub fn all_hulls_match_schema_test() {
  assert_all_validate(hull_schema_path, hulls_dir)
}

pub fn all_station_classes_match_schema_test() {
  assert_all_validate(station_class_schema_path, station_classes_dir)
}

pub fn all_modules_match_schema_test() {
  assert_paths_validate(module_schema_path, nested_json_files(modules_dir))
}

pub fn all_parts_match_schema_test() {
  assert_all_validate(part_schema_path, parts_dir)
}

pub fn glyph_registry_matches_schema_test() {
  let schema = read_json(glyphs_schema_path)
  let value = read_json(glyphs_path)
  let assert Ok(Nil) = validate_with_schema(schema, value)
}

pub fn world_rejects_a_one_element_berth_test() {
  let schema = read_json(world_schema_path)
  let invalid_world =
    parse_json(
      "{\"schema\": 1, \"name\": \"invalid\", \"seed\": 1, \"bodies\": [], \"stations\": [{\"id\": \"s1\", \"name\": \"S1\", \"parent\": \"b1\", \"orbit\": {\"radius\": 1.0, \"period_s\": 1.0, \"phase\": 0.0}, \"dock_radius\": 1.0, \"berths\": [[1]]}], \"spawn_station\": \"s1\"}",
    )
  assert validate_with_schema(schema, invalid_world) != Ok(Nil)
}

pub fn hull_rejects_an_unknown_handling_value_test() {
  let schema = read_json(hull_schema_path)
  let hull_doc = fn(handling: String) {
    parse_json(
      "{\"schema\": 3, \"id\": \"x\", \"name\": \"X\", \"decks\": [{\"name\": \"M\", \"grid\": [\"   \", \" Q \", \"   \"]}], \"cargo\": {\"capacity\": 1, \"handling\": \""
      <> handling
      <> "\"}}",
    )
  }
  // The control: the same document with a legal handling value passes, so the
  // refusal below is about `handling` and not about the rest of the document.
  let assert Ok(Nil) = validate_with_schema(schema, hull_doc("breakbulk"))
  assert validate_with_schema(schema, hull_doc("magnets")) != Ok(Nil)
}

/// The whole point of `additionalProperties: false`: the decoder would ignore
/// a misspelled `rows` and silently stamp nothing.
pub fn module_rejects_a_misspelled_patch_field_test() {
  let schema = read_json(module_schema_path)
  let invalid_module =
    parse_json(
      "{\"schema\": 1, \"id\": \"h.s.m\", \"hull\": \"h\", \"slot\": \"s\", \"name\": \"M\", \"patches\": [{\"deck\": 0, \"x\": 0, \"y\": 0, \"rows\": [\"   \"]}]}",
    )
  assert validate_with_schema(schema, invalid_module) != Ok(Nil)
}

/// Proves the schema's `oneOf`/`not` construct is actually LIVE under jesse
/// rather than silently ignored (jesse would still validate every shipped
/// document either way, so nothing else in this file would notice if `oneOf`
/// were inert). The positive control is a `targets`-only document — the
/// canonical spelling with none of the flat-shorthand fields — which must
/// still pass; the negative case adds a stray top-level `hull`/`slot`
/// alongside `targets`, matching neither `oneOf` branch (branch 1 forbids
/// `hull`/`slot`; branch 2 forbids `targets`), which the decoder would
/// silently ignore but the schema must refuse.
pub fn module_rejects_targets_alongside_a_stray_top_level_slot_test() {
  let schema = read_json(module_schema_path)
  let targets_only =
    parse_json(
      "{\"schema\": 1, \"id\": \"m.targets_only\", \"name\": \"M\",
        \"targets\": [{\"hull\": \"h\", \"slots\": [\"s\"]}]}",
    )
  let assert Ok(Nil) = validate_with_schema(schema, targets_only)
  let both_spellings =
    parse_json(
      "{\"schema\": 1, \"id\": \"m.both\", \"name\": \"M\", \"hull\": \"h\",
        \"slot\": \"s\",
        \"targets\": [{\"hull\": \"h\", \"slots\": [\"s\"]}]}",
    )
  assert validate_with_schema(schema, both_spellings) != Ok(Nil)
}

/// Also proves the `$defs` tag ref actually resolves under jesse rather than
/// being silently skipped, which would make every tag object unvalidated.
pub fn part_rejects_a_non_integer_tag_amount_test() {
  let schema = read_json(part_schema_path)
  let invalid_part =
    parse_json(
      "{\"schema\": 1, \"id\": \"p\", \"name\": \"P\", \"kind\": \"engine\", \"size\": \"m\", \"provides\": {\"engine\": \"one\"}}",
    )
  assert validate_with_schema(schema, invalid_part) != Ok(Nil)
}

pub fn part_rejects_an_unknown_size_test() {
  let schema = read_json(part_schema_path)
  let invalid_part =
    parse_json(
      "{\"schema\": 1, \"id\": \"p\", \"name\": \"P\", \"kind\": \"engine\", \"size\": \"xl\"}",
    )
  assert validate_with_schema(schema, invalid_part) != Ok(Nil)
}
