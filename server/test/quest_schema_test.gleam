import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import simplifile

@external(erlang, "quest_schema_ffi", "validate")
fn validate_with_schema(schema: Dynamic, value: Dynamic) -> Result(Nil, String)

const schema_path = "schemas/quest.schema.json"

const quests_dir = "quests"

fn read_json(path: String) -> Dynamic {
  let assert Ok(text) = simplifile.read(path)
  parse_json(text)
}

fn quest_files() -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(quests_dir)
  entries
  |> list.filter(string.ends_with(_, ".json"))
  |> list.sort(string.compare)
}

fn parse_json(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

pub fn jesse_wiring_test() {
  let schema = parse_json("{\"type\": \"object\"}")
  assert validate_with_schema(schema, parse_json("{}")) == Ok(Nil)
  assert validate_with_schema(schema, parse_json("[]")) != Ok(Nil)
}

pub fn all_quests_match_schema_test() {
  let schema = read_json(schema_path)
  let files = quest_files()
  // Guards against a typo'd glob silently validating nothing.
  assert files != []
  list.each(files, fn(file) {
    let value = read_json(quests_dir <> "/" <> file)
    case validate_with_schema(schema, value) {
      Ok(Nil) -> Nil
      Error(message) -> panic as { file <> ": " <> message }
    }
  })
}
