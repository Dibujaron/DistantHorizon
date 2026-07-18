import dh_server/deckplan.{Console, DeckPlan, Grid, Room}

fn plan() -> deckplan.DeckPlan {
  DeckPlan(
    grid: Grid(width: 3, height: 2),
    walkable: ["###", ".##"],
    rooms: [Room(id: "r", name: "Room", x: 0, y: 0, w: 3, h: 2, deck: "")],
    consoles: [Console(id: "desk", kind: "broker", x: 1, y: 0)],
    spawn_tile: #(1, 1),
  )
}

pub fn is_walkable_and_bounds_test() {
  assert deckplan.is_walkable(plan(), 0, 0)
  assert !deckplan.is_walkable(plan(), 0, 1)
  assert !deckplan.is_walkable(plan(), -1, 0)
  assert !deckplan.is_walkable(plan(), 3, 0)
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
  let bad =
    DeckPlan(..plan(), consoles: [Console(id: "d", kind: "broker", x: 0, y: 1)])
  let assert Error(_) = deckplan.validate(bad)
}

pub fn validate_rejects_bad_spawn_tile_test() {
  let bad = DeckPlan(..plan(), spawn_tile: #(0, 1))
  let assert Error(_) = deckplan.validate(bad)
}

pub fn validate_rejects_row_count_mismatch_test() {
  let bad = DeckPlan(..plan(), walkable: ["###"])
  let assert Error(_) = deckplan.validate(bad)
}

// ---------------------------------------------------------------- decks --
// Split-level alphabet (M3.5 iteration 3): '.' void, '#' generic single
// floor, 'L' lower-only, 'U' upper-only, '2' two stacked floors, 'B'
// between-level (one floor connecting both decks).

fn deck_plan() -> deckplan.DeckPlan {
  DeckPlan(
    grid: Grid(width: 3, height: 2),
    walkable: ["#LU", "2B."],
    rooms: [],
    consoles: [],
    spawn_tile: #(0, 0),
  )
}

pub fn deck_alphabet_is_walkable_test() {
  assert deckplan.is_walkable(deck_plan(), 0, 0)
  assert deckplan.is_walkable(deck_plan(), 1, 0)
  assert deckplan.is_walkable(deck_plan(), 2, 0)
  assert deckplan.is_walkable(deck_plan(), 0, 1)
  assert deckplan.is_walkable(deck_plan(), 1, 1)
  assert !deckplan.is_walkable(deck_plan(), 2, 1)
}

pub fn walkable_for_deck_test() {
  // '#', '2', 'B' admit both decks
  assert deckplan.walkable_for(deck_plan(), deckplan.Lower, 0, 0)
  assert deckplan.walkable_for(deck_plan(), deckplan.Upper, 0, 0)
  assert deckplan.walkable_for(deck_plan(), deckplan.Lower, 0, 1)
  assert deckplan.walkable_for(deck_plan(), deckplan.Upper, 0, 1)
  assert deckplan.walkable_for(deck_plan(), deckplan.Lower, 1, 1)
  assert deckplan.walkable_for(deck_plan(), deckplan.Upper, 1, 1)
  // 'L' / 'U' are exclusive
  assert deckplan.walkable_for(deck_plan(), deckplan.Lower, 1, 0)
  assert !deckplan.walkable_for(deck_plan(), deckplan.Upper, 1, 0)
  assert !deckplan.walkable_for(deck_plan(), deckplan.Lower, 2, 0)
  assert deckplan.walkable_for(deck_plan(), deckplan.Upper, 2, 0)
  // void and out of bounds admit nobody
  assert !deckplan.walkable_for(deck_plan(), deckplan.Lower, 2, 1)
  assert !deckplan.walkable_for(deck_plan(), deckplan.Upper, -1, 0)
}

pub fn deck_of_tile_updates_on_exclusive_tiles_test() {
  // L/U tiles force the deck; '#', '2', 'B' keep the current one.
  assert deckplan.deck_of_tile(deck_plan(), deckplan.Upper, 1, 0)
    == deckplan.Lower
  assert deckplan.deck_of_tile(deck_plan(), deckplan.Lower, 2, 0)
    == deckplan.Upper
  assert deckplan.deck_of_tile(deck_plan(), deckplan.Lower, 0, 1)
    == deckplan.Lower
  assert deckplan.deck_of_tile(deck_plan(), deckplan.Upper, 1, 1)
    == deckplan.Upper
}

pub fn validate_rejects_unknown_walkable_char_test() {
  let bad = DeckPlan(..deck_plan(), walkable: ["#X.", "2B."])
  let assert Error(_) = deckplan.validate(bad)
}
