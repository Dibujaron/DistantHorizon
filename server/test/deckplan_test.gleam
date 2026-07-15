import dh_server/deckplan.{Console, DeckPlan, Grid, Room}

fn plan() -> deckplan.DeckPlan {
  DeckPlan(
    grid: Grid(width: 3, height: 2),
    walkable: ["###", ".##"],
    rooms: [Room(id: "r", name: "Room", x: 0, y: 0, w: 3, h: 2)],
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
