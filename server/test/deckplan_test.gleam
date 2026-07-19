import dh_server/deckplan.{Console, DeckPlan}

// ------------------------------------------------- docking ports (#31) --

pub fn docking_ports_north_facing_test() {
  // A dock tile at (0,1): its north edge is a door, and the tile to its
  // north (0,0) is void — so its outward normal is N (the station berth case).
  let rows = ["   ", " . ", "   ", " = ", "   ", "   "]
  let assert Ok(g) = deckplan.parse_deck("d", rows)
  let plan =
    DeckPlan(
      decks: [g],
      consoles: [Console("dock", "dock", 0, 0, 1)],
      spawn_deck: 0,
      spawn_tile: #(0, 1),
    )
  assert deckplan.docking_ports(plan) == [#(0, 0, 1, deckplan.N)]
}

pub fn docking_ports_skips_port_with_no_void_facing_door_test() {
  // A 1x1 dock tile with no doors and no void-facing edge is not a berth.
  let assert Ok(g) = deckplan.parse_deck("d", ["   ", "   ", "   "])
  let plan =
    DeckPlan(
      decks: [g],
      consoles: [Console("dock", "dock", 0, 0, 0)],
      spawn_deck: 0,
      spawn_tile: #(0, 0),
    )
  assert deckplan.docking_ports(plan) == []
}

// ------------------------------------------------------------- parsing --

pub fn parse_deck_two_rooms_test() {
  // Two 1x1 rooms side by side, double wall between, a door in each south
  // edge. (Rows are 3*width chars, 3*height rows.)
  let rows = ["######", "# ## #", "#=##=#"]
  let assert Ok(g) = deckplan.parse_deck("d", rows)
  assert g.width == 2
  assert g.height == 1
  // tile (0,0): floor centre, north/east/west walls, south door.
  let assert Ok(#(n, e, s, w)) = deckplan.edges_at(g, 0, 0)
  assert n == deckplan.Wall
  assert e == deckplan.Wall
  assert s == deckplan.Door
  assert w == deckplan.Wall
  assert deckplan.tile_at(g, 0, 0) == deckplan.Floor
}

pub fn parse_deck_center_glyphs_test() {
  // Centre glyphs (at col 3x+1): space floor, '.' void, 'x' stairs.
  let rows = ["         ", "    .  x ", "         "]
  let assert Ok(g) = deckplan.parse_deck("d", rows)
  assert g.width == 3
  assert deckplan.tile_at(g, 0, 0) == deckplan.Floor
  assert deckplan.tile_at(g, 1, 0) == deckplan.Void
  assert deckplan.tile_at(g, 2, 0) == deckplan.Stairs
}

pub fn parse_deck_fixture_edge_test() {
  // A letter on an edge-mid is a wall-mounted fixture (blocks like a wall).
  // The north edge of tile (0,0) is at row 0, col 1.
  let rows = [" v ", "   ", "   "]
  let assert Ok(g) = deckplan.parse_deck("d", rows)
  let assert Ok(#(n, _e, _s, _w)) = deckplan.edges_at(g, 0, 0)
  assert n == deckplan.Fixture("v")
}

pub fn parse_deck_rejects_ragged_rows_test() {
  let assert Error(_) = deckplan.parse_deck("d", ["######", "# #"])
}

pub fn parse_deck_rejects_non_multiple_of_three_test() {
  let assert Error(_) = deckplan.parse_deck("d", ["####", "#  #", "####"])
}

// ------------------------------------------------------ edge collision --

fn edge_grid(mid: String) -> deckplan.DeckGrid {
  // Two floors side by side; `mid` is the middle row that sets the shared
  // boundary (cols 2 and 3 are tile0.E and tile1.W).
  let assert Ok(g) = deckplan.parse_deck("d", ["      ", mid, "      "])
  g
}

pub fn edge_blocks_open_passage_test() {
  let g = edge_grid("      ")
  assert !deckplan.edge_blocks(g, 0, 0, deckplan.E)
}

pub fn edge_blocks_double_wall_test() {
  let g = edge_grid("  ##  ")
  assert deckplan.edge_blocks(g, 0, 0, deckplan.E)
  // OR-rule: blocked from the other side too.
  assert deckplan.edge_blocks(g, 1, 0, deckplan.W)
}

pub fn edge_blocks_one_sided_wall_test() {
  // Only tile1's west edge is a wall; the OR-rule still blocks the crossing.
  let g = edge_grid("   #  ")
  assert deckplan.edge_blocks(g, 0, 0, deckplan.E)
}

pub fn edge_blocks_door_is_passable_test() {
  let g = edge_grid("  ==  ")
  assert !deckplan.edge_blocks(g, 0, 0, deckplan.E)
}

// -------------------------------------------------------------- stairs --

fn stairs_grid() -> deckplan.DeckGrid {
  let assert Ok(g) = deckplan.parse_deck("s", ["   ", " x ", "   "])
  g
}

fn two_deck_plan() -> deckplan.DeckPlan {
  DeckPlan(
    decks: [stairs_grid(), stairs_grid()],
    consoles: [],
    spawn_deck: 0,
    spawn_tile: #(0, 0),
  )
}

pub fn stairs_target_connects_aligned_deck_test() {
  let plan = two_deck_plan()
  // From deck 0's stairs tile, the aligned stairs on deck 1 is the target.
  assert deckplan.stairs_target(plan, 0, 0, 0) == Ok(1)
  // From deck 1, deck 2 is out of range, so it falls back to deck 0.
  assert deckplan.stairs_target(plan, 1, 0, 0) == Ok(0)
}

pub fn stairs_target_rejects_non_stairs_test() {
  let plan =
    DeckPlan(..two_deck_plan(), decks: [
      {
        let assert Ok(g) = deckplan.parse_deck("f", ["   ", "   ", "   "])
        g
      },
      stairs_grid(),
    ])
  assert deckplan.stairs_target(plan, 0, 0, 0) == Error(Nil)
}

// ------------------------------------------------------ consoles/valid --

fn plan() -> deckplan.DeckPlan {
  let assert Ok(g) = deckplan.parse_deck("main", ["      ", "      ", "      "])
  DeckPlan(
    decks: [g],
    consoles: [Console(id: "desk", kind: "broker", deck: 0, x: 1, y: 0)],
    spawn_deck: 0,
    spawn_tile: #(0, 0),
  )
}

pub fn find_console_by_id_and_kind_test() {
  let assert Ok(c) = deckplan.find_console(plan(), "desk")
  assert c.kind == "broker"
  assert deckplan.find_console(plan(), "nope") == Error(Nil)
  let assert Ok(_) = deckplan.find_console_of_kind(plan(), "broker")
  assert deckplan.find_console_of_kind(plan(), "helm") == Error(Nil)
}

pub fn validate_accepts_good_plan_test() {
  assert deckplan.validate(plan()) == Ok(plan())
}

pub fn validate_rejects_console_off_walkable_test() {
  // A console on a void tile of its deck.
  let assert Ok(g) = deckplan.parse_deck("main", ["   ", " . ", "   "])
  let bad =
    DeckPlan(
      decks: [g],
      consoles: [Console(id: "d", kind: "broker", deck: 0, x: 0, y: 0)],
      spawn_deck: 0,
      spawn_tile: #(0, 0),
    )
  let assert Error(_) = deckplan.validate(bad)
}

pub fn validate_rejects_bad_spawn_tile_test() {
  let assert Ok(g) = deckplan.parse_deck("main", ["   ", " . ", "   "])
  let bad =
    DeckPlan(decks: [g], consoles: [], spawn_deck: 0, spawn_tile: #(0, 0))
  let assert Error(_) = deckplan.validate(bad)
}

pub fn validate_rejects_out_of_range_deck_test() {
  let bad =
    DeckPlan(..plan(), consoles: [
      Console(id: "d", kind: "broker", deck: 5, x: 0, y: 0),
    ])
  let assert Error(_) = deckplan.validate(bad)
}

pub fn deck_to_rows_round_trips_test() {
  // Re-serialising a parsed deck and parsing it back preserves tiles+edges.
  let rows = ["######", "# ## #", "#=##=#"]
  let assert Ok(g) = deckplan.parse_deck("d", rows)
  let assert Ok(g2) = deckplan.parse_deck("d", deckplan.deck_to_rows(g))
  assert g2.tiles == g.tiles
  assert g2.edges == g.edges
}
