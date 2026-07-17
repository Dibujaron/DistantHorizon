import gleam/dict
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

type QuestRefs {
  QuestRefs(
    id: String,
    acquisition: String,
    trigger_targets: List(String),
    slot_names: List(String),
    parent_refs: List(String),
    item_ids: List(String),
  )
}

fn refs_decoder() -> decode.Decoder(QuestRefs) {
  let trigger = {
    use quest <- decode.field("quest", decode.string)
    decode.success(quest)
  }
  let slot_from = {
    use from <- decode.optional_field("from", "", decode.string)
    decode.success(from)
  }
  let item = {
    use id <- decode.field("id", decode.string)
    decode.success(id)
  }
  use id <- decode.field("id", decode.string)
  use acquisition <- decode.field("acquisition", decode.string)
  use slots <- decode.optional_field(
    "slots",
    dict.new(),
    decode.dict(decode.string, slot_from),
  )
  use items <- decode.optional_field("items", [], decode.list(item))
  use on_complete <- decode.optional_field("on_complete", [], decode.list(trigger))
  use on_failed <- decode.optional_field("on_failed", [], decode.list(trigger))
  use on_expired <- decode.optional_field("on_expired", [], decode.list(trigger))
  decode.success(QuestRefs(
    id:,
    acquisition:,
    trigger_targets: list.flatten([on_complete, on_failed, on_expired]),
    slot_names: dict.keys(slots),
    parent_refs: dict.values(slots)
      |> list.filter(string.starts_with(_, "parent.")),
    item_ids: items,
  ))
}

fn load_refs() -> List(QuestRefs) {
  list.map(quest_files(), fn(file) {
    let assert Ok(text) = simplifile.read(quests_dir <> "/" <> file)
    let assert Ok(refs) = json.parse(text, refs_decoder())
    // Filename coherence checked here so every test that loads refs enforces it.
    assert refs.id <> ".json" == file
    refs
  })
}

pub fn quest_ids_match_filenames_test() {
  // The assert lives in load_refs; calling it is the test.
  let _ = load_refs()
  Nil
}

pub fn quest_triggers_are_coherent_test() {
  let quests = load_refs()
  let ids = list.map(quests, fn(refs) { refs.id })
  let targets = list.flat_map(quests, fn(refs) { refs.trigger_targets })
  // Every trigger target must exist in the folder.
  list.each(targets, fn(target) { assert list.contains(ids, target) })
  list.each(quests, fn(refs) {
    // acquisition "triggered" if and only if some quest triggers it.
    let referenced = list.contains(targets, refs.id)
    assert referenced == { refs.acquisition == "triggered" }
    // parent.* bindings only live in slot "from" fields, and only make sense
    // in triggered quests.
    case refs.parent_refs {
      [] -> Nil
      _ -> {
        assert refs.acquisition == "triggered"
        Nil
      }
    }
  })
}

pub fn broker_quests_declare_offer_broker_test() {
  list.each(load_refs(), fn(refs) {
    // acquisition "broker" implies the reserved offer_broker slot exists —
    // it names the broker where the offer is posted.
    case refs.acquisition == "broker" {
      True -> {
        assert list.contains(refs.slot_names, "offer_broker")
        Nil
      }
      False -> Nil
    }
  })
}

pub fn parent_bindings_exist_in_all_triggering_parents_test() {
  let quests = load_refs()
  list.each(quests, fn(child) {
    let parents =
      list.filter(quests, fn(p) { list.contains(p.trigger_targets, child.id) })
    list.each(child.parent_refs, fn(ref) {
      // ref is "parent.<slot>" or "parent.item.<itemId>". A child can be
      // triggered by any of its parents, so EVERY parent must satisfy it.
      let assert Ok(#("parent", rest)) = string.split_once(ref, ".")
      list.each(parents, fn(parent) {
        case string.split_once(rest, ".") {
          Ok(#("item", item_id)) ->
            case list.contains(parent.item_ids, item_id) {
              True -> Nil
              False ->
                panic as {
                  child.id <> ": " <> ref <> " is not an item of parent " <> parent.id
                }
            }
          _ ->
            case list.contains(parent.slot_names, rest) {
              True -> Nil
              False ->
                panic as {
                  child.id <> ": " <> ref <> " is not a slot of parent " <> parent.id
                }
            }
        }
      })
    })
  })
}

pub fn quest_interpolations_resolve_test() {
  list.each(quest_files(), fn(file) {
    let assert Ok(text) = simplifile.read(quests_dir <> "/" <> file)
    let assert Ok(refs) = json.parse(text, refs_decoder())
    // Every ${token} anywhere in the file must name a declared slot —
    // a typo'd interpolation validates against the schema and would
    // otherwise only surface engine-side.
    string.split(text, "${")
    |> list.drop(1)
    |> list.each(fn(chunk) {
      case string.split_once(chunk, "}") {
        Ok(#(token, _)) ->
          case list.contains(refs.slot_names, token) {
            True -> Nil
            False ->
              panic as {
                file <> ": ${" <> token <> "} does not name a declared slot"
              }
          }
        Error(Nil) -> panic as { file <> ": unterminated ${ interpolation" }
      }
    })
  })
}
