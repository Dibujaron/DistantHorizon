import dh_server/module
import dh_server/part
import gleam/dict

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

pub fn ragged_patch_is_rejected_test() {
  let bad =
    "{ \"schema\": 1, \"id\": \"a\", \"hull\": \"h\", \"slot\": \"s\",
    \"name\": \"A\", \"mass\": 1.0,
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 0, \"grid\": [\"###\", \"# #\"] } ] }"
  let assert Error(_) = module.decode(bad)
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
