//// The composite (stitched) plan for deck-plan v3 (Option B, multi-deck):
//// composite deck 0 is the concourse + every docked ship's MOORING deck
//// (tube-connected); each ship's other decks become their own composite
//// decks. Ships moor SIDE-ON (plans rotated 90 CCW).

import dh_server/composite.{Berth, DockedShip, Mooring}
import dh_server/deckplan.{type DeckPlan, Console, DeckPlan}
import gleam/int
import gleam/list

// A tiny two-deck ship, uniform 2x2 tiles per deck. Deck 0 "upper" carries
// the helm and a stairs at (1,1); deck 1 "lower" is the MOORING deck
// (spawn_deck = 1), spawn/gangway at (0,0), cargo console at (0,1), stairs at
// (1,1) aligned with the upper deck.
fn ship_plan() -> DeckPlan {
  let assert Ok(upper) = deckplan.parse_deck("upper", deck_rows())
  let assert Ok(lower) = deckplan.parse_deck("lower", deck_rows())
  DeckPlan(
    decks: [upper, lower],
    consoles: [
      Console(id: "helm_main", kind: "helm", deck: 0, x: 0, y: 0),
      Console(id: "cargo_main", kind: "cargo", deck: 1, x: 0, y: 1),
    ],
    spawn_deck: 1,
    spawn_tile: #(0, 0),
  )
}

// 2 tiles wide x 2 tall, all floor, stairs at (1,1).
fn deck_rows() -> List(String) {
  ["      ", "      ", "      ", "      ", "    x ", "      "]
}

// A small concourse: 5 tiles wide x 3 tall. Row y=0 is all void (so tubes
// carve above the berth), a single walkable berth stub at (2,1), a floor
// walkway at y=2. Spawn + broker on the walkway.
fn concourse() -> DeckPlan {
  let rows = [
    "               ",
    " .  .  .  .  . ",
    "               ",
    "               ",
    " .  .     .  . ",
    "               ",
    "               ",
    "               ",
    "               ",
  ]
  let assert Ok(g) = deckplan.parse_deck("concourse", rows)
  DeckPlan(
    decks: [g],
    consoles: [Console(id: "broker_main", kind: "broker", deck: 0, x: 1, y: 2)],
    spawn_deck: 0,
    spawn_tile: #(2, 2),
  )
}

fn berths() -> List(composite.Berth) {
  [berth(2, 1)]
}

fn berth(x: Int, y: Int) -> composite.Berth {
  Berth(x: x, y: y, orientation: composite.default_orientation)
}

pub fn empty_composite_is_the_concourse_test() {
  let assert Ok(c) = composite.build(concourse(), berths(), [])
  assert c.concourse_dx == 0
  assert c.concourse_dy == 0
  assert c.moorings == []
  assert c.plan == concourse()
}

pub fn one_ship_adds_its_non_mooring_deck_test() {
  let assert Ok(c) =
    composite.build(concourse(), berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: ship_plan()),
    ])
  // Concourse (1 deck) + the ship's mooring deck merged into deck 0 + its one
  // non-mooring deck as its own composite deck = 2 decks total.
  assert list.length(c.plan.decks) == 2
  // Frame shifts down to make room for the moored ship north of the berth.
  assert c.concourse_dx == 0
  assert c.concourse_dy == 5
  let assert Ok(m) = composite.find_mooring(c, 1)
  assert m.dx == 2
  assert m.dy == 0
  assert m.ship_width == 2
}

pub fn deck_map_indexes_by_level_test() {
  let assert Ok(c) =
    composite.build(concourse(), berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: ship_plan()),
    ])
  let assert Ok(m) = composite.find_mooring(c, 1)
  // Decks are indexed by concourse-relative level: the mooring deck (ship
  // deck 1) is level 0 -> composite deck 1; the upper deck (ship deck 0, one
  // above) is level -1 -> composite deck 0.
  assert composite.composite_deck_of(m, 1) == 1
  assert composite.composite_deck_of(m, 0) == 0
  assert composite.ship_deck_of(m, 0) == Ok(0)
  assert composite.ship_deck_of(m, 1) == Ok(1)
  assert composite.ship_deck_of(m, 9) == Error(Nil)
}

pub fn tube_is_carved_north_of_the_berth_test() {
  let assert Ok(c) =
    composite.build(concourse(), berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: ship_plan()),
    ])
  // The concourse plane is composite deck 1 (level 0): the ship's one deck
  // above it makes level 0 the second entry.
  let assert Ok(plane) = deckplan.deck_at(c.plan, 1)
  // Berth (2,1) shifts to (2,6); four tube tiles are carved at y=2..5.
  assert deckplan.is_walkable(plane, 2, 5)
  assert deckplan.is_walkable(plane, 2, 4)
  assert deckplan.is_walkable(plane, 2, 3)
  assert deckplan.is_walkable(plane, 2, 2)
  // Beside the tube stays void — the hull floats clear.
  assert !deckplan.is_walkable(plane, 1, 3)
  assert !deckplan.is_walkable(plane, 3, 3)
}

pub fn ship_console_ids_are_namespaced_and_deck_remapped_test() {
  let assert Ok(c) =
    composite.build(concourse(), berths(), [
      DockedShip(ship_id: 3, berth: 0, plan: ship_plan()),
    ])
  // Helm was on ship deck 0 (upper, level -1) -> composite deck 0.
  let assert Ok(helm) = deckplan.find_console(c.plan, "s3:helm_main")
  assert helm.kind == "helm"
  assert helm.deck == 0
  // Cargo was on the mooring deck (ship deck 1, level 0) -> composite deck 1.
  let assert Ok(cargo) = deckplan.find_console(c.plan, "s3:cargo_main")
  assert cargo.deck == 1
  // Concourse consoles keep their plain ids on the concourse plane (deck 1).
  let assert Ok(broker) = deckplan.find_console(c.plan, "broker_main")
  assert broker.deck == 1
}

pub fn unknown_berth_index_is_an_error_test() {
  assert composite.build(concourse(), berths(), [
      DockedShip(ship_id: 1, berth: 9, plan: ship_plan()),
    ])
    == Error("unknown_berth")
}

pub fn overlapping_moorings_are_an_error_test() {
  assert composite.build(concourse(), berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: ship_plan()),
      DockedShip(ship_id: 2, berth: 0, plan: ship_plan()),
    ])
    == Error("berth_blocked")
}

pub fn namespace_round_trip_test() {
  assert composite.namespace_id(7, "helm_main") == "s7:helm_main"
  assert composite.parse_namespaced("s7:helm_main") == Ok(#(7, "helm_main"))
  assert composite.parse_namespaced("broker_main") == Error(Nil)
  assert composite.parse_namespaced("sx:oops") == Error(Nil)
}

pub fn tile_on_mooring_splits_ship_from_station_test() {
  let plan = ship_plan()
  let assert Ok(c) =
    composite.build(concourse(), berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: plan),
    ])
  let assert Ok(m) = composite.find_mooring(c, 1)
  // The moored dormer is on the mooring plane (composite deck 1), tile (2,1).
  assert composite.tile_on_mooring(m, plan, 1, 2.5, 1.5)
  // A concourse floor tile (deck 1, (2,7)) is not a ship tile.
  assert !composite.tile_on_mooring(m, plan, 1, 2.5, 7.5)
  // A tube tile belongs to the station.
  assert !composite.tile_on_mooring(m, plan, 1, 2.5, 3.5)
}

pub fn ship_frame_round_trip_test() {
  // The pure planar transforms invert each other around the mooring offset.
  let m = Mooring(ship_id: 1, dx: 2, dy: 0, deck_map: [], ship_width: 2)
  // Composite dormer centre -> unrotated spawn centre and back.
  let #(sx, sy) = composite.to_ship_frame(m, 2.5, 1.5)
  assert sx == 0.5
  assert sy == 0.5
  let #(rx, ry) = composite.from_ship_frame(m.ship_width, 0.5, 0.5)
  assert rx +. int.to_float(m.dx) == 2.5
  assert ry +. int.to_float(m.dy) == 1.5
}
