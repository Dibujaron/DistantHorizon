import dh_server/module
import dh_server/part
import gleam/dict
import gleam/string

const module_doc = "{
  \"schema\": 1,
  \"id\": \"testhull.cockpit.stock\",
  \"hull\": \"testhull\",
  \"slot\": \"cockpit\",
  \"name\": \"Stock cockpit\",
  \"mass\": 4.0,
  \"provides\": { \"seats\": 1 },
  \"requires\": { \"power\": 2 },
  \"patches\": [
    { \"deck\": 0, \"x\": 6, \"y\": 3, \"grid\": [\"#h#\", \"#e \", \"## \"] }
  ]
}"

pub fn decode_module_document_test() {
  let assert Ok(m) = module.decode(module_doc)
  assert m.id == "testhull.cockpit.stock"
  assert m.hull == "testhull"
  assert m.slot == "cockpit"
  assert m.mass == 4.0
  assert dict.get(m.requires, "power") == Ok(2)
  let assert [p] = m.patches
  assert p.deck == 0
  assert p.x == 6
  assert p.y == 3
  assert p.rows == ["#h#", "#e ", "## "]
}

pub fn patch_row_count_not_multiple_of_three_is_rejected_test() {
  let bad =
    "{ \"schema\": 1, \"id\": \"a\", \"hull\": \"h\", \"slot\": \"s\",
    \"name\": \"A\", \"mass\": 1.0,
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 0, \"grid\": [\"###\", \"# #\"] } ] }"
  let assert Error(_) = module.decode(bad)
}

pub fn ragged_patch_is_rejected_test() {
  let bad =
    "{ \"schema\": 1, \"id\": \"a\", \"hull\": \"h\", \"slot\": \"s\",
    \"name\": \"A\", \"mass\": 1.0,
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 0,
      \"grid\": [\"###\", \"##  ##\", \"###\"] } ] }"
  // Row lengths 3/6/3: each is independently a legal multiple of 3, so this
  // isolates the rectangularity check rather than tripping the
  // every-row-is-a-multiple-of-3 check first.
  let assert Error(_) = module.decode(bad)
}

pub fn negative_origin_patch_is_rejected_test() {
  let bad =
    "{ \"schema\": 1, \"id\": \"a\", \"hull\": \"h\", \"slot\": \"s\",
    \"name\": \"A\", \"mass\": 1.0,
    \"patches\": [ { \"deck\": 0, \"x\": -3, \"y\": 0,
      \"grid\": [\"###\", \"###\", \"###\"] } ] }"
  let assert Error(_) = module.decode(bad)
}

pub fn zero_size_patch_is_rejected_test() {
  let bad =
    "{ \"schema\": 1, \"id\": \"a\", \"hull\": \"h\", \"slot\": \"s\",
    \"name\": \"A\", \"mass\": 1.0,
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 0, \"grid\": [] } ] }"
  let assert Error(_) = module.decode(bad)
}

pub fn load_all_walks_per_hull_subdirectories_test() {
  let assert Ok(modules) = module.load_all("test/fixtures/modules_ok")
  let assert Ok(m) = dict.get(modules, "testhull.cockpit.stock")
  assert m.hull == "testhull"
  assert m.slot == "cockpit"
}

pub fn load_all_rejects_duplicate_ids_across_hull_subdirectories_test() {
  let assert Error(msg) = module.load_all("test/fixtures/modules_dup")
  assert string.contains(msg, "dup.module")
}

pub fn part_load_all_indexes_by_id_test() {
  let assert Ok(parts) = part.load_all("test/fixtures/parts_ok")
  let assert Ok(a) = dict.get(parts, "part.a")
  let assert Ok(b) = dict.get(parts, "part.b")
  assert a.size == "s"
  assert b.size == "m"
}

pub fn part_load_all_rejects_duplicate_ids_test() {
  let assert Error(msg) = part.load_all("test/fixtures/parts_dup")
  assert string.contains(msg, "dup.part")
}

const part_doc = "{
  \"schema\": 1,
  \"id\": \"test.engine\",
  \"name\": \"Test engine\",
  \"kind\": \"engine\",
  \"size\": \"m\",
  \"mass\": 0.0,
  \"provides\": { \"engine\": 1 },
  \"requires\": { \"power\": 3 },
  \"thrust\": 4800.0,
  \"torque\": 21600.0,
  \"sprite\": \"engine_consol\"
}"

pub fn decode_part_document_test() {
  let assert Ok(p) = part.decode(part_doc)
  assert p.kind == "engine"
  assert p.size == "m"
  assert p.thrust == 4800.0
  assert p.torque == 21_600.0
  assert dict.get(p.provides, "engine") == Ok(1)
}

pub fn size_rank_orders_the_scale_test() {
  assert part.size_rank("s") == Ok(0)
  assert part.size_rank("m") == Ok(1)
  assert part.size_rank("l") == Ok(2)
  assert part.size_rank("xl") == Error(Nil)
}
