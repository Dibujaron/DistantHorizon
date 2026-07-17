import dh_server/names
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}

pub fn parse_names_file_test() {
  let text =
    "{ \"schema\": 1,
       \"tags\": { \"type\": \"character\", \"part\": \"family\", \"faction\": \"wake\" },
       \"entries\": [ \"Okafor\", { \"name\": \"Adeyemi\", \"tags\": { \"wealth\": \"high\" } } ] }"
  let assert Ok([first, second]) = names.parse_names_file(text)
  assert first.name == "Okafor"
  assert first.tags.type_ == "character"
  assert first.tags.part == "family"
  assert first.tags.faction == Some("wake")
  assert first.tags.wealth == None
  // Entry-level tags override/extend the file defaults, never replace them.
  assert second.name == "Adeyemi"
  assert second.tags.faction == Some("wake")
  assert second.tags.wealth == Some("high")
}

pub fn parse_names_file_rejects_garbage_test() {
  let assert Error(_) = names.parse_names_file("{ \"entries\": [] }")
}

pub fn load_real_pools_test() {
  // Integration against the shipped data: the merge is across ALL files.
  let assert Ok(entries) = names.load("names")
  assert entries != []
}

fn parse_json_dynamic(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

pub fn constraint_satisfaction_test() {
  let wake_or_breakers =
    names.Any([
      names.AttrIs("faction", "wake"),
      names.AttrIs("faction", "breakers"),
    ])
  let attrs = names.satisfying_character_attrs(Some(wake_or_breakers))
  assert attrs != []
  list.each(attrs, fn(a) {
    assert a.faction == "wake" || a.faction == "breakers"
  })

  let not_high = names.Not(names.AttrIs("wealth", "high"))
  let modest = names.satisfying_character_attrs(Some(not_high))
  assert modest != []
  list.each(modest, fn(a) { assert a.wealth != "high" })

  // Contradictions produce the empty list, not a crash.
  let impossible =
    names.All([names.AttrIs("race", "senti"), names.AttrIs("race", "human")])
  assert names.satisfying_character_attrs(Some(impossible)) == []

  // Unconstrained = the whole domain: 4 races x 5 factions x 3 wealth x 3 genders.
  assert list.length(names.satisfying_character_attrs(None)) == 180
}

pub fn ship_constraint_satisfaction_test() {
  let packet = names.AttrIs("role", "packet")
  let attrs = names.satisfying_ship_attrs(Some(packet))
  // 1 role x 5 factions x 10 manufacturers.
  assert list.length(attrs) == 50
  list.each(attrs, fn(a) { assert a.role == "packet" })
}

pub fn parse_constraint_test() {
  let dyn =
    parse_json_dynamic(
      "{ \"faction_is\": \"${patron}\", \"not\": { \"wealth_is\": \"high\" } }",
    )
  let resolve = fn(slot) {
    case slot {
      "patron" -> Ok("wake")
      _ -> Error("unknown slot " <> slot)
    }
  }
  let assert Ok(constraint) = names.parse_constraint(dyn, resolve)
  let attrs = names.satisfying_character_attrs(Some(constraint))
  assert attrs != []
  list.each(attrs, fn(a) {
    assert a.faction == "wake"
    assert a.wealth != "high"
  })
}

pub fn parse_constraint_rejects_bind_leaves_test() {
  // Bind-context keys (station_is etc.) are not generation vocabulary.
  let dyn = parse_json_dynamic("{ \"station_is\": \"solis_ring\" }")
  let assert Error(_) = names.parse_constraint(dyn, fn(_) { Error("no slots") })
}
