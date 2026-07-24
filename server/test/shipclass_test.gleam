import dh_server/deckplan
import dh_server/glyphs
import dh_server/shipclass
import gleam/json

const rows = [
  "#h#######",
  "#       #",
  "#########",
  "#########",
  "=Q     p#",
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
