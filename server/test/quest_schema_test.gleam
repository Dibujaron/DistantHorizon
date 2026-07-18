import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

@external(erlang, "quest_schema_ffi", "validate")
fn validate_with_schema(schema: Dynamic, value: Dynamic) -> Result(Nil, String)

const schema_path = "schemas/quest.schema.json"

const quests_dir = "quests"

/// Dotted interpolation forms legal on character slots (${x.<form>}).
const character_forms = [
  "given", "family", "short", "title", "ey", "em", "eir", "eirs", "emself", "Ey",
  "Em", "Eir", "Eirs", "Emself",
]

const ship_forms = ["role"]

/// Leaves that only mean something when generating a principal.
const generation_leaves = ["race_is", "wealth_is", "gender_is", "role_is"]

const character_legal = [
  "any", "all", "not", "race_is", "faction_is", "wealth_is", "gender_is",
]

const ship_legal = [
  "any", "all", "not", "role_is", "faction_is", "manufacturer_is",
]

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

type ItemRef {
  ItemRef(id: String, principal: String)
}

type QuestRefs {
  QuestRefs(
    id: String,
    acquisition: String,
    trigger_targets: List(String),
    slot_kinds: dict.Dict(String, String),
    parent_refs: List(String),
    items: List(ItemRef),
  )
}

fn refs_decoder() -> decode.Decoder(QuestRefs) {
  let trigger = {
    use quest <- decode.field("quest", decode.string)
    decode.success(quest)
  }
  let slot = {
    use kind <- decode.optional_field("kind", "", decode.string)
    use from <- decode.optional_field("from", "", decode.string)
    decode.success(#(kind, from))
  }
  let item = {
    use id <- decode.field("id", decode.string)
    use principal <- decode.optional_field("principal", "", decode.string)
    decode.success(ItemRef(id:, principal:))
  }
  use id <- decode.field("id", decode.string)
  use acquisition <- decode.field("acquisition", decode.string)
  use slots <- decode.optional_field(
    "slots",
    dict.new(),
    decode.dict(decode.string, slot),
  )
  use items <- decode.optional_field("items", [], decode.list(item))
  use on_complete <- decode.optional_field(
    "on_complete",
    [],
    decode.list(trigger),
  )
  use on_failed <- decode.optional_field("on_failed", [], decode.list(trigger))
  use on_expired <- decode.optional_field(
    "on_expired",
    [],
    decode.list(trigger),
  )
  decode.success(QuestRefs(
    id:,
    acquisition:,
    trigger_targets: list.flatten([on_complete, on_failed, on_expired]),
    slot_kinds: dict.map_values(slots, fn(_, pair) { pair.0 }),
    parent_refs: dict.values(slots)
      |> list.map(fn(pair) { pair.1 })
      |> list.filter(string.starts_with(_, "parent.")),
    items:,
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
  list.each(targets, fn(target) {
    assert list.contains(ids, target)
  })
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
        assert dict.has_key(refs.slot_kinds, "offer_broker")
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
            case
              list.contains(list.map(parent.items, fn(i) { i.id }), item_id)
            {
              True -> Nil
              False ->
                panic as {
                  child.id
                  <> ": "
                  <> ref
                  <> " is not an item of parent "
                  <> parent.id
                }
            }
          _ ->
            case dict.has_key(parent.slot_kinds, rest) {
              True -> Nil
              False ->
                panic as {
                  child.id
                  <> ": "
                  <> ref
                  <> " is not a slot of parent "
                  <> parent.id
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
    // Every ${token} anywhere in the file must name a declared slot, and a
    // dotted ${slot.form} must use a legal form for that slot's kind — a
    // typo'd interpolation validates against the schema and would otherwise
    // only surface engine-side.
    string.split(text, "${")
    |> list.drop(1)
    |> list.each(fn(chunk) {
      case string.split_once(chunk, "}") {
        Error(Nil) -> panic as { file <> ": unterminated ${ interpolation" }
        Ok(#(token, _)) -> {
          let #(slot, form) = case string.split_once(token, ".") {
            Ok(pair) -> pair
            Error(Nil) -> #(token, "")
          }
          let kind = case dict.get(refs.slot_kinds, slot) {
            Ok(kind) -> kind
            Error(Nil) ->
              panic as {
                file <> ": ${" <> token <> "} does not name a declared slot"
              }
          }
          case form, kind {
            "", _ -> Nil
            f, "character" ->
              case list.contains(character_forms, f) {
                True -> Nil
                False ->
                  panic as {
                    file <> ": unknown character form ${" <> token <> "}"
                  }
              }
            f, "ship" ->
              case list.contains(ship_forms, f) {
                True -> Nil
                False ->
                  panic as { file <> ": unknown ship form ${" <> token <> "}" }
              }
            _, _ ->
              panic as {
                file
                <> ": dotted form ${"
                <> token
                <> "} on a non-generated slot"
              }
          }
        }
      }
    })
  })
}

pub fn item_principals_name_character_slots_test() {
  list.each(load_refs(), fn(refs) {
    list.each(refs.items, fn(item) {
      case item.principal {
        "" -> Nil
        principal ->
          case dict.get(refs.slot_kinds, principal) {
            Ok("character") -> Nil
            _ ->
              panic as {
                refs.id
                <> ": item "
                <> item.id
                <> " principal "
                <> principal
                <> " is not a character slot"
              }
          }
      }
    })
  })
}

type SlotInfo {
  SlotInfo(kind: String, constraints: Option(Dynamic))
}

fn slot_info_decoder() -> decode.Decoder(SlotInfo) {
  use kind <- decode.optional_field("kind", "", decode.string)
  use constraints <- decode.optional_field(
    "constraints",
    None,
    decode.map(decode.dynamic, Some),
  )
  decode.success(SlotInfo(kind:, constraints:))
}

fn quest_slot_infos(file: String) -> dict.Dict(String, SlotInfo) {
  let assert Ok(text) = simplifile.read(quests_dir <> "/" <> file)
  let decoder = {
    use slots <- decode.optional_field(
      "slots",
      dict.new(),
      decode.dict(decode.string, slot_info_decoder()),
    )
    decode.success(slots)
  }
  let assert Ok(slots) = json.parse(text, decoder)
  slots
}

fn collect_constraint_keys(dyn: Dynamic) -> List(String) {
  case decode.run(dyn, decode.dict(decode.string, decode.dynamic)) {
    Error(_) -> []
    Ok(fields) ->
      dict.to_list(fields)
      |> list.flat_map(fn(field) {
        case field.0 {
          "any" | "all" ->
            case decode.run(field.1, decode.list(decode.dynamic)) {
              Ok(items) -> [
                field.0,
                ..list.flat_map(items, collect_constraint_keys)
              ]
              Error(_) -> [field.0]
            }
          "not" -> [field.0, ..collect_constraint_keys(field.1)]
          key -> [key]
        }
      })
  }
}

pub fn generation_constraint_vocabulary_test() {
  // Generation leaves only on generated slots; generated slots only use
  // generation-legal vocabulary. Same spirit as the from-only-in-triggered
  // rule.
  list.each(quest_files(), fn(file) {
    quest_slot_infos(file)
    |> dict.to_list
    |> list.each(fn(pair) {
      let #(name, info) = pair
      let keys = case info.constraints {
        Some(dyn) -> collect_constraint_keys(dyn)
        None -> []
      }
      case info.kind {
        "character" | "ship" -> {
          let legal = case info.kind {
            "character" -> character_legal
            _ -> ship_legal
          }
          list.each(keys, fn(key) {
            case list.contains(legal, key) {
              True -> Nil
              False ->
                panic as {
                  file
                  <> " slot "
                  <> name
                  <> ": key "
                  <> key
                  <> " is not legal on a generated slot"
                }
            }
          })
        }
        _ ->
          list.each(keys, fn(key) {
            case list.contains(generation_leaves, key) {
              True ->
                panic as {
                  file
                  <> " slot "
                  <> name
                  <> ": generation leaf "
                  <> key
                  <> " on a bind slot"
                }
              False -> Nil
            }
          })
      }
    })
  })
}
