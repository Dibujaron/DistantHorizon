import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import simplifile

// Reuses quest_schema_ffi's validate/2 — it is already schema-agnostic
// (Dynamic schema, Dynamic value in; Result(Nil, String) out), so world and
// ship-class documents ride the same jesse wiring quests use rather than
// standing up a second FFI entry point.
@external(erlang, "quest_schema_ffi", "validate")
fn validate_with_schema(schema: Dynamic, value: Dynamic) -> Result(Nil, String)

const world_schema_path = "schemas/world.schema.json"

const ship_class_schema_path = "schemas/ship_class.schema.json"

const station_class_schema_path = "schemas/station_class.schema.json"

const station_classes_dir = "stationclasses"

const glyphs_schema_path = "schemas/glyphs.schema.json"

const glyphs_path = "glyphs.json"

const worlds_dir = "worlds"

const classes_dir = "shipclasses"

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

fn assert_all_validate(schema_path: String, dir: String) -> Nil {
  let schema = read_json(schema_path)
  let files = json_files(dir)
  // Guards against a typo'd glob silently validating nothing.
  assert files != []
  list.each(files, fn(file) {
    let value = read_json(dir <> "/" <> file)
    case validate_with_schema(schema, value) {
      Ok(Nil) -> Nil
      Error(message) -> panic as { file <> ": " <> message }
    }
  })
}

pub fn all_worlds_match_schema_test() {
  assert_all_validate(world_schema_path, worlds_dir)
}

pub fn all_ship_classes_match_schema_test() {
  assert_all_validate(ship_class_schema_path, classes_dir)
}

pub fn all_station_classes_match_schema_test() {
  assert_all_validate(station_class_schema_path, station_classes_dir)
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

pub fn ship_class_rejects_an_unknown_handling_value_test() {
  let schema = read_json(ship_class_schema_path)
  let invalid_class =
    parse_json(
      "{\"schema\": 1, \"id\": \"x\", \"name\": \"X\", \"grid\": {\"width\": 1, \"height\": 1}, \"walkable\": [\"#\"], \"rooms\": [], \"consoles\": [], \"spawn_tile\": [0, 0], \"cargo\": {\"capacity\": 1, \"handling\": \"magnets\"}}",
    )
  assert validate_with_schema(schema, invalid_class) != Ok(Nil)
}
