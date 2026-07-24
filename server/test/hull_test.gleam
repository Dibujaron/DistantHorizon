import dh_server/hull
import dh_server/shipclass
import gleam/dict
import gleam/string

const doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 100.0,
  \"provides\": { \"power\": 10, \"engine_mount\": 1 },
  \"slots\": [
    { \"digit\": 1, \"id\": \"cockpit\", \"name\": \"Cockpit\" }
  ],
  \"mounts\": [
    { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" }
  ],
  \"default_loadout\": {
    \"modules\": { \"cockpit\": \"testhull.cockpit.stock\" },
    \"parts\": { \"engine_center\": \"test.engine\" }
  },
  \"decks\": [
    { \"name\": \"Main\", \"grid\": [\"###\", \"# #\", \"1##\"] }
  ],
  \"cargo\": { \"capacity\": 4, \"handling\": \"breakbulk\" }
}"

pub fn decode_hull_document_test() {
  let assert Ok(h) = hull.decode(doc)
  assert h.id == "testhull"
  assert h.mass == 100.0
  assert dict.get(h.provides, "power") == Ok(10)
  // Deck rows are kept as TEXT — the refit bake re-stamps them.
  assert h.decks == [#("Main", ["###", "# #", "1##"])]
  assert h.default_modules == [#("cockpit", "testhull.cockpit.stock")]
  assert h.default_parts == [#("engine_center", "test.engine")]
}

pub fn slot_lookup_test() {
  let assert Ok(h) = hull.decode(doc)
  let assert Ok(slot) = hull.slot_by_id(h, "cockpit")
  assert slot.digit == 1
  assert hull.slot_by_id(h, "nope") == Error(Nil)
}

pub fn mount_lookup_test() {
  let assert Ok(h) = hull.decode(doc)
  let assert Ok(mount) = hull.mount_by_id(h, "engine_center")
  assert mount.kind == "engine"
  assert mount.size == "m"
}

pub fn duplicate_slot_digit_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"digit\": 1, \"id\": \"a\", \"name\": \"A\" },
                    { \"digit\": 1, \"id\": \"b\", \"name\": \"B\" } ],
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
       \"slots\": [ { \"digit\": 1, \"id\": \"a\", \"name\": \"A\" },
                    { \"digit\": 2, \"id\": \"a\", \"name\": \"B\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

pub fn slot_digit_out_of_range_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"digit\": 16, \"id\": \"a\", \"name\": \"A\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
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
