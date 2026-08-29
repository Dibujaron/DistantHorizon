import dh_server/hull
import dh_server/shipclass
import gleam/dict
import gleam/list
import gleam/string

const doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 100.0,
  \"provides\": { \"power\": 10, \"engine_mount\": 1 },
  \"slots\": [
    { \"marker\": \"B\", \"id\": \"cockpit\", \"name\": \"Cockpit\" }
  ],
  \"mounts\": [
    { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" }
  ],
  \"default_loadout\": {
    \"modules\": { \"cockpit\": \"testhull.cockpit.stock\" },
    \"parts\": { \"engine_center\": \"test.engine\" }
  },
  \"decks\": [
    { \"name\": \"Main\", \"grid\": [\"###\", \"#B#\", \"###\"] }
  ],
  \"cargo\": { \"capacity\": 4, \"handling\": \"breakbulk\" }
}"

pub fn decode_hull_document_test() {
  let assert Ok(h) = hull.decode(doc)
  assert h.id == "testhull"
  assert h.mass == 100.0
  assert dict.get(h.provides, "power") == Ok(10)
  // Deck rows are kept as TEXT — the refit bake re-stamps them.
  assert h.decks == [#("Main", ["###", "#B#", "###"])]
  assert h.default_modules == [#("cockpit", "testhull.cockpit.stock")]
  assert h.default_parts == [#("engine_center", "test.engine")]
}

/// The schemas type `mass` as `number`, and JSON Schema draft-06 cannot say
/// "float-spelled only" — `4.0` is an integer to a validator too — so the
/// decoder accepts either spelling rather than the schema pretending to
/// forbid one (`hull.number_decoder`).
pub fn a_bare_integer_mass_decodes_test() {
  let assert Ok(h) = hull.decode(string.replace(doc, "100.0", "100"))
  assert h.mass == 100.0
}

pub fn slot_lookup_test() {
  let assert Ok(h) = hull.decode(doc)
  let assert Ok(slot) = hull.slot_by_id(h, "cockpit")
  assert slot.marker == "B"
  assert hull.slot_by_id(h, "nope") == Error(Nil)
}

pub fn mount_lookup_test() {
  let assert Ok(h) = hull.decode(doc)
  let assert Ok(mount) = hull.mount_by_id(h, "engine_center")
  assert mount.kind == "engine"
  assert mount.size == "m"
}

pub fn duplicate_slot_marker_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"marker\": \"B\", \"id\": \"a\", \"name\": \"A\" },
                    { \"marker\": \"B\", \"id\": \"b\", \"name\": \"B\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

// ----------------------------------------------------- slot markers (M4) --

pub fn a_slot_authored_with_marker_decodes_directly_test() {
  let doc =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"marker\": \"D\", \"id\": \"a\", \"name\": \"A\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Ok(h) = hull.decode(doc)
  let assert Ok(slot) = hull.slot_by_id(h, "a")
  assert slot.marker == "D"
}

pub fn a_multi_letter_slot_marker_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"marker\": \"AB\", \"id\": \"a\", \"name\": \"A\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

pub fn a_lowercase_slot_marker_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"marker\": \"a\", \"id\": \"a\", \"name\": \"A\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

/// A digit is not a marker: the `digit` field is gone, and a `marker` field
/// holding a digit character doesn't get treated as one either — a marker
/// must be a single uppercase A-Z letter, full stop.
pub fn a_digit_is_not_a_marker_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"marker\": \"1\", \"id\": \"a\", \"name\": \"A\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

pub fn load_all_indexes_by_id_test() {
  let assert Ok(hulls) = hull.load_all("shipclasses")
  let assert Ok(mb) = dict.get(hulls, "mockingbird")
  assert mb.name == "Mockingbird"
}

pub fn load_all_rejects_duplicate_ids_test() {
  let assert Error(msg) = hull.load_all("test/fixtures/duplicate_hulls")
  assert string.contains(msg, "dupid")
}

pub fn duplicate_slot_id_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"marker\": \"A\", \"id\": \"a\", \"name\": \"A\" },
                    { \"marker\": \"B\", \"id\": \"a\", \"name\": \"B\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

/// Twenty-six letters, so twenty-six slots. The old ceiling was sixteen
/// because a slot was one hex digit in a corner.
pub fn a_hull_may_carry_twenty_six_slots_test() {
  let markers =
    string.to_graphemes("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    |> list.map(fn(m) {
      "{ \"marker\": \""
      <> m
      <> "\", \"id\": \"s"
      <> m
      <> "\", \"name\": \"S\" }"
    })
    |> string.join(", ")
  let doc = "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [" <> markers <> "],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Ok(h) = hull.decode(doc)
  assert list.length(h.slots) == 26
}

pub fn non_positive_mass_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 0.0,
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

pub fn unknown_cargo_handling_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"antigrav\" } }"
  let assert Error(_) = hull.decode(bad)
}

pub fn missing_cargo_block_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ] }"
  let assert Error(_) = hull.decode(bad)
}

pub fn dock_standoff_reads_the_authored_value_test() {
  let doc =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"dock_standoff\": 42.0,
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Ok(h) = hull.decode(doc)
  assert h.dock_standoff == 42.0
}

pub fn dock_standoff_defaults_when_omitted_test() {
  let doc =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Ok(h) = hull.decode(doc)
  assert h.dock_standoff == shipclass.default_dock_standoff
}

pub fn garbage_input_is_rejected_test() {
  let assert Error(_) = hull.decode("not json")
}

// -------------------------------------------------------- sprite (M4 2c) --

pub fn hull_sprite_defaults_to_id_test() {
  let json =
    "{\"schema\":3,\"id\":\"testbed\",\"name\":\"Testbed\","
    <> "\"decks\":[{\"name\":\"Main\",\"grid\":[\"...\"]}],"
    <> "\"cargo\":{\"capacity\":1,\"handling\":\"breakbulk\"}}"
  let assert Ok(h) = hull.decode(json)
  assert h.sprite == "testbed"
}

pub fn hull_sprite_is_authored_when_present_test() {
  let json =
    "{\"schema\":3,\"id\":\"testbed\",\"name\":\"Testbed\","
    <> "\"sprite\":\"other_art\","
    <> "\"decks\":[{\"name\":\"Main\",\"grid\":[\"...\"]}],"
    <> "\"cargo\":{\"capacity\":1,\"handling\":\"breakbulk\"}}"
  let assert Ok(h) = hull.decode(json)
  assert h.sprite == "other_art"
}

pub fn shipped_hulls_author_their_sprite_test() {
  let assert Ok(hulls) = hull.load_all("shipclasses")
  let assert Ok(mb) = dict.get(hulls, "mockingbird")
  let assert Ok(sp) = dict.get(hulls, "sparrow")
  let assert Ok(gf) = dict.get(hulls, "goldfinch")
  assert mb.sprite == "mockingbird"
  assert sp.sprite == "sparrow"
  assert gf.sprite == "goldfinch"
}
