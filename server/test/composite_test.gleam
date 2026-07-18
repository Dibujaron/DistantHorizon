//// The composite (stitched) plan: concourse + docked-ship moorings.

import dh_server/composite.{Berth, DockedShip, Mooring}
import dh_server/deckplan.{type DeckPlan, Console, DeckPlan, Grid, Room}
import gleam/list

/// The Mockingbird deck plan, matching server/classes/mockingbird.json:
/// 7x10, nose up, split-level (U upper / L lower / 2 stacked / B
/// between-level docking deck). Docking ports are SIDE dormers at the
/// waist — the spawn/gangway tile is the PORT one at (2,9), so a moored
/// ship sits one tile east of its berth column, flank to the gangway.
fn mockingbird_plan() -> DeckPlan {
  DeckPlan(
    grid: Grid(width: 7, height: 10),
    walkable: [
      ".......",
      "...U...",
      "...U...",
      "..UUU..",
      "..UUU..",
      "..222..",
      "..222..",
      "..222..",
      "..LUL..",
      "..BBB..",
    ],
    rooms: [
      Room(id: "cockpit", name: "Cockpit", x: 3, y: 1, w: 1, h: 2, deck: "upper"),
      Room(id: "dock", name: "Docking Deck", x: 2, y: 9, w: 3, h: 1, deck: ""),
    ],
    consoles: [
      Console(id: "helm_main", kind: "helm", x: 3, y: 1),
      Console(id: "cargo_main", kind: "cargo", x: 2, y: 8),
    ],
    spawn_tile: #(2, 9),
  )
}

/// The Meridian concourse: 34x6, three berth stubs on the top edge.
fn meridian_concourse() -> DeckPlan {
  DeckPlan(
    grid: Grid(width: 34, height: 6),
    walkable: [
      "..................................",
      "......#.........#.........#.......",
      ".################################.",
      ".################################.",
      ".################################.",
      "..................................",
    ],
    rooms: [
      Room(id: "concourse", name: "Concourse", x: 1, y: 2, w: 32, h: 3, deck: ""),
    ],
    consoles: [
      Console(id: "broker_main", kind: "broker", x: 10, y: 3),
      Console(id: "broker_east", kind: "broker", x: 24, y: 3),
    ],
    spawn_tile: #(16, 3),
  )
}

fn meridian_berths() -> List(composite.Berth) {
  [Berth(x: 6, y: 1), Berth(x: 16, y: 1), Berth(x: 26, y: 1)]
}

pub fn empty_composite_is_the_concourse_at_origin_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [])
  assert c.concourse_dx == 0
  assert c.concourse_dy == 0
  assert c.moorings == []
  assert c.plan == meridian_concourse()
}

pub fn one_ship_moors_above_its_berth_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: mockingbird_plan()),
    ])
  // Ship rows extend 9 above the concourse: everything shifts down by 9.
  assert c.concourse_dx == 0
  assert c.concourse_dy == 9
  assert c.moorings == [Mooring(ship_id: 1, dx: 4, dy: 0)]
  assert c.plan.grid == Grid(width: 34, height: 15)
  // Ship spawn/port-dormer tile (2,9) -> composite (6,9); berth stub (6,1)
  // -> (6,10): adjacent, gangway to flank, both walkable.
  assert deckplan.is_walkable(c.plan, 6, 9)
  assert deckplan.is_walkable(c.plan, 6, 10)
  // Ship helm tile (3,1) -> composite (7,1).
  assert deckplan.is_walkable(c.plan, 7, 1)
  // Concourse broker tile (10,3) -> composite (10,12).
  assert deckplan.is_walkable(c.plan, 10, 12)
  // Void stays void: composite (0,0) is above the concourse, beside the ship.
  assert !deckplan.is_walkable(c.plan, 0, 0)
}

pub fn composite_preserves_deck_alphabet_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: mockingbird_plan()),
    ])
  // Split-level chars carry through the stitch unchanged...
  assert deckplan.char_at(c.plan, 7, 1) == "U"
  assert deckplan.char_at(c.plan, 7, 5) == "2"
  assert deckplan.char_at(c.plan, 6, 8) == "L"
  assert deckplan.char_at(c.plan, 7, 8) == "U"
  assert deckplan.char_at(c.plan, 6, 9) == "B"
  // ...and the concourse stays generic.
  assert deckplan.char_at(c.plan, 10, 12) == "#"
}

pub fn ship_console_and_room_ids_are_namespaced_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 3, berth: 0, plan: mockingbird_plan()),
    ])
  let assert Ok(helm) = deckplan.find_console(c.plan, "s3:helm_main")
  assert helm.kind == "helm"
  assert helm.x == 7
  assert helm.y == 1
  // Concourse consoles keep their plain ids, translated.
  let assert Ok(broker) = deckplan.find_console(c.plan, "broker_main")
  assert broker.x == 10
  assert broker.y == 12
  // Ship rooms are namespaced too, and keep their deck tag.
  let assert Ok(cockpit) =
    list.find(c.plan.rooms, fn(r) { r.id == "s3:cockpit" })
  assert cockpit.deck == "upper"
  assert list.any(c.plan.rooms, fn(r) { r.id == "concourse" })
}

pub fn three_ships_moor_side_by_side_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: mockingbird_plan()),
      DockedShip(ship_id: 2, berth: 1, plan: mockingbird_plan()),
      DockedShip(ship_id: 3, berth: 2, plan: mockingbird_plan()),
    ])
  let assert Ok(g1) = composite.find_mooring(c, 1)
  let assert Ok(g2) = composite.find_mooring(c, 2)
  let assert Ok(g3) = composite.find_mooring(c, 3)
  assert g1 == Mooring(ship_id: 1, dx: 4, dy: 0)
  assert g2 == Mooring(ship_id: 2, dx: 14, dy: 0)
  assert g3 == Mooring(ship_id: 3, dx: 24, dy: 0)
  // Each ship's helm console exists under its own namespace.
  let assert Ok(_) = deckplan.find_console(c.plan, "s1:helm_main")
  let assert Ok(_) = deckplan.find_console(c.plan, "s2:helm_main")
  let assert Ok(_) = deckplan.find_console(c.plan, "s3:helm_main")
}

pub fn unknown_berth_index_is_an_error_test() {
  assert composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 9, plan: mockingbird_plan()),
    ])
    == Error("unknown_berth")
}

pub fn overlapping_moorings_are_an_error_test() {
  // Two ships forced onto the same berth overlap tile-for-tile.
  assert composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: mockingbird_plan()),
      DockedShip(ship_id: 2, berth: 0, plan: mockingbird_plan()),
    ])
    == Error("berth_blocked")
}

pub fn namespace_round_trip_test() {
  assert composite.namespace_id(7, "helm_main") == "s7:helm_main"
  assert composite.parse_namespaced("s7:helm_main") == Ok(#(7, "helm_main"))
  assert composite.parse_namespaced("broker_main") == Error(Nil)
  assert composite.parse_namespaced("sx:oops") == Error(Nil)
}

pub fn tile_on_mooring_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: mockingbird_plan()),
    ])
  let assert Ok(g) = composite.find_mooring(c, 1)
  // Composite (7.5, 1.5) is the moored helm tile; (10.5, 12.5) is concourse.
  assert composite.tile_on_mooring(g, mockingbird_plan(), 7.5, 1.5)
  assert !composite.tile_on_mooring(g, mockingbird_plan(), 10.5, 12.5)
  // The berth stub belongs to the concourse, not the ship.
  assert !composite.tile_on_mooring(g, mockingbird_plan(), 6.5, 10.5)
}
