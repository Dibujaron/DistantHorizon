//// The composite (stitched) plan: concourse + docked-ship moorings.
//// Iteration 4: ships moor SIDE-ON (plans rotated 90 CCW, nose west,
//// port flank south) at the end of a 4-tile generated docking tube.

import dh_server/composite.{Berth, DockedShip, Mooring}
import dh_server/deckplan.{type DeckPlan, Console, DeckPlan, Grid, Room}
import gleam/list

/// The Mockingbird deck plan, matching server/classes/mockingbird.json:
/// 14x23, nose up, split-level. Docking corridor 'B' row 22 cols 5-8; the
/// spawn/gangway is its PORT end (5,22) — rotated side-on for mooring,
/// that end faces the station.
fn mockingbird_plan() -> DeckPlan {
  DeckPlan(
    grid: Grid(width: 14, height: 23),
    walkable: [
      "..............",
      "..............",
      "..............",
      "..............",
      "......UU......",
      "......UU......",
      "......UU......",
      ".....2222.....",
      "....222222....",
      "...22222222...",
      "...22222222...",
      "...22222222...",
      "...22222222...",
      "...22222222...",
      "...22222222...",
      "...22222222...",
      "....222222....",
      "....222222....",
      "....222222....",
      ".....2222.....",
      ".....2222.....",
      ".....LUUL.....",
      ".....BBBB.....",
    ],
    rooms: [
      Room(id: "cockpit", name: "Cockpit", x: 6, y: 4, w: 2, h: 3, deck: "upper"),
      Room(id: "dock", name: "Docking Deck", x: 5, y: 21, w: 4, h: 2, deck: ""),
    ],
    consoles: [
      Console(id: "helm_main", kind: "helm", x: 6, y: 4),
      Console(id: "cargo_main", kind: "cargo", x: 5, y: 21),
    ],
    spawn_tile: #(5, 22),
  )
}

fn floor_row() -> String {
  ".############################################################################################."
}

/// The Meridian concourse: 94x6, three berth stubs on the top edge with
/// 32 tiles of clearance (side-on ships are ~30 tiles long).
fn meridian_concourse() -> DeckPlan {
  DeckPlan(
    grid: Grid(width: 94, height: 6),
    walkable: [
      "..............................................................................................",
      "......................#...............................#...............................#.......",
      floor_row(),
      floor_row(),
      floor_row(),
      "..............................................................................................",
    ],
    rooms: [
      Room(id: "concourse", name: "Concourse", x: 1, y: 2, w: 92, h: 3, deck: ""),
    ],
    consoles: [
      Console(id: "broker_main", kind: "broker", x: 10, y: 3),
      Console(id: "broker_east", kind: "broker", x: 62, y: 3),
    ],
    spawn_tile: #(47, 3),
  )
}

fn meridian_berths() -> List(composite.Berth) {
  [Berth(x: 22, y: 1), Berth(x: 54, y: 1), Berth(x: 86, y: 1)]
}

pub fn empty_composite_is_the_concourse_at_origin_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [])
  assert c.concourse_dx == 0
  assert c.concourse_dy == 0
  assert c.moorings == []
  assert c.plan == meridian_concourse()
}

pub fn rotate_ccw_lays_the_ship_side_on_test() {
  let r = deckplan.rotate_ccw(mockingbird_plan())
  assert r.grid == Grid(width: 23, height: 14)
  // Port dormer (5,22) -> (22,8): the corridor's SOUTH end, nose west.
  assert r.spawn_tile == #(22, 8)
  assert deckplan.char_at(r, 22, 8) == "B"
  // Helm (6,4) -> (4,7), still upper.
  assert deckplan.char_at(r, 4, 7) == "U"
  let assert Ok(helm) = deckplan.find_console(r, "helm_main")
  assert helm.x == 4 && helm.y == 7
  // The port 'L' half-flight (5,21) -> (21,8).
  assert deckplan.char_at(r, 21, 8) == "L"
  // Rooms rotate as rects: cockpit (6,4,2,3) -> (4, 14-6-2=6, 3, 2).
  let assert Ok(cockpit) = list.find(r.rooms, fn(rm) { rm.id == "cockpit" })
  assert cockpit.x == 4 && cockpit.y == 6 && cockpit.w == 3 && cockpit.h == 2
}

pub fn one_ship_moors_side_on_at_a_tube_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: mockingbird_plan()),
    ])
  // Rotated ship at berth 22: raw offset (22-22, 1-1-4-8) = (0, -12) ->
  // shift (0, 12): the frame is x-stable however many ships are moored.
  assert c.concourse_dx == 0
  assert c.concourse_dy == 12
  assert c.moorings == [Mooring(ship_id: 1, dx: 0, dy: 0)]
  assert c.plan.grid == Grid(width: 94, height: 18)
  // Dormer at (22,8); FOUR generated tube tiles; berth stub at (22,13).
  assert deckplan.char_at(c.plan, 22, 8) == "B"
  assert deckplan.char_at(c.plan, 22, 9) == "#"
  assert deckplan.char_at(c.plan, 22, 10) == "#"
  assert deckplan.char_at(c.plan, 22, 11) == "#"
  assert deckplan.char_at(c.plan, 22, 12) == "#"
  assert deckplan.char_at(c.plan, 22, 13) == "#"
  // Beside the tube: still void — the hull floats clear of the bar.
  assert !deckplan.is_walkable(c.plan, 21, 10)
  assert !deckplan.is_walkable(c.plan, 23, 10)
  // Moored helm at (4,7), upper; deck alphabet carries through rotation.
  assert deckplan.char_at(c.plan, 4, 7) == "U"
  assert deckplan.char_at(c.plan, 21, 8) == "L"
  assert deckplan.char_at(c.plan, 10, 7) == "2"
  // Concourse broker tile (10,3) -> composite (10,15), still generic.
  assert deckplan.char_at(c.plan, 10, 15) == "#"
}

pub fn ship_console_and_room_ids_are_namespaced_test() {
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 3, berth: 0, plan: mockingbird_plan()),
    ])
  let assert Ok(helm) = deckplan.find_console(c.plan, "s3:helm_main")
  assert helm.kind == "helm"
  assert helm.x == 4
  assert helm.y == 7
  // Concourse consoles keep their plain ids, translated.
  let assert Ok(broker) = deckplan.find_console(c.plan, "broker_main")
  assert broker.x == 10
  assert broker.y == 15
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
  assert g1 == Mooring(ship_id: 1, dx: 0, dy: 0)
  assert g2 == Mooring(ship_id: 2, dx: 32, dy: 0)
  assert g3 == Mooring(ship_id: 3, dx: 64, dy: 0)
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
  // Composite (4.5, 7.5) is the moored helm tile; (10.5, 15.5) concourse.
  assert composite.tile_on_mooring(g, mockingbird_plan(), 4.5, 7.5)
  assert !composite.tile_on_mooring(g, mockingbird_plan(), 10.5, 15.5)
  // The docking TUBE belongs to the station, not the ship: a body caught
  // mid-tube on undock stays ashore.
  assert !composite.tile_on_mooring(g, mockingbird_plan(), 22.5, 10.5)
  // The berth stub belongs to the concourse too.
  assert !composite.tile_on_mooring(g, mockingbird_plan(), 22.5, 13.5)
}

pub fn ship_frame_round_trip_test() {
  let plan = mockingbird_plan()
  let assert Ok(c) =
    composite.build(meridian_concourse(), meridian_berths(), [
      DockedShip(ship_id: 1, berth: 0, plan: plan),
    ])
  let assert Ok(g) = composite.find_mooring(c, 1)
  // The moored dormer center maps back to the unrotated spawn center.
  let #(sx, sy) = composite.to_ship_frame(g, plan, 22.5, 8.5)
  assert sx == 5.5
  assert sy == 22.5
  // And forward again (dock join): ship frame -> mooring-local + offset.
  let #(rx, ry) = composite.from_ship_frame(plan, 5.5, 22.5)
  assert rx == 22.5
  assert ry == 8.5
}
