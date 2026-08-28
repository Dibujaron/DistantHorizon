import dh_server/deckplan
import dh_server/glyphs
import dh_server/shipclass
import gleam/json

const rows = [
  "#h#######",
  "#       #",
  "#########",
  "#########",
  "=q     p#",
  "#########",
]

fn a_class() -> shipclass.ShipClass {
  let reg = glyphs.default()
  let assert Ok(plan) = deckplan.from_rows(reg, [#("Main", rows)])
  let assert Ok(c) =
    shipclass.from_plan(
      reg,
      "testhull",
      "Test Hull",
      3,
      plan,
      7,
      shipclass.BreakBulk,
      90.0,
      20.0,
      shipclass.Flight(accel: 40.0, turn_rate: 180.0),
    )
  c
}

pub fn from_plan_derives_capacity_from_pallets_test() {
  // The single `p` tile on the map beats the authored fallback of 7.
  assert a_class().cargo_capacity == 1
}

pub fn from_plan_requires_a_helm_test() {
  let reg = glyphs.default()
  let assert Ok(plan) =
    deckplan.from_rows(reg, [
      #("Main", ["#########", "#       #", "#########"]),
    ])
  let assert Error(e) =
    shipclass.from_plan(
      reg,
      "h",
      "H",
      3,
      plan,
      0,
      shipclass.BreakBulk,
      90.0,
      20.0,
      shipclass.Flight(accel: 1.0, turn_rate: 1.0),
    )
  assert e == "no console of kind \"helm\""
}

pub fn decode_encode_round_trips_test() {
  let c = a_class()
  let text = shipclass.encode(c) |> json.to_string
  let assert Ok(c2) = shipclass.decode(text)
  assert c == c2
}

pub fn helm_console_is_found_test() {
  let assert Ok(console) = shipclass.helm_console(a_class())
  assert console.kind == "helm"
}

// `shipclass.gleam` carries a SECOND, independent copy of the "derived pallet
// count beats the authored capacity" rule in `ship_class_decoder` (the
// `from_plan` copy above is separate code). These two decode through the wire
// path, with authored capacity and derived pallet count deliberately set to
// DIFFERENT numbers, so either copy diverging or being deleted fails them —
// unlike `decode_encode_round_trips_test`, whose fixture has capacity 1 and
// one pallet and so can't tell "derived" from "authored" apart.

pub fn capacity_derives_from_pallet_tiles_on_decode_test() {
  let doc =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\",
       \"decks\": [ { \"name\": \"Main\", \"grid\": [
         \"#h#######\", \"#   p  p#\", \"#########\",
         \"#########\", \"=q     p#\", \"#########\" ] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" },
       \"flight\": { \"accel\": 40.0, \"turn_rate\": 180.0 } }"
  let assert Ok(c) = shipclass.decode(doc)
  // Three `p` tiles beat the authored capacity of 0.
  assert c.cargo_capacity == 3
}

pub fn capacity_falls_back_to_authored_value_when_no_pallets_are_drawn_test() {
  let doc =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\",
       \"decks\": [ { \"name\": \"Main\", \"grid\": [
         \"#h#######\", \"#       #\", \"#########\",
         \"#########\", \"=q      #\", \"#########\" ] } ],
       \"cargo\": { \"capacity\": 10, \"handling\": \"breakbulk\" },
       \"flight\": { \"accel\": 40.0, \"turn_rate\": 180.0 } }"
  let assert Ok(c) = shipclass.decode(doc)
  // No `p` tiles drawn: falls back to the authored capacity of 10.
  assert c.cargo_capacity == 10
}
