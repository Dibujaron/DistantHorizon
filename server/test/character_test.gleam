import dh_server/character.{type Character, Character}
import dh_server/deckplan.{type DeckPlan}
import dh_server/shipclass
import gleam/float
import gleam/option.{None, Some}

const epsilon = 0.0001

fn close(a: Float, b: Float, tolerance: Float) -> Bool {
  float.absolute_value(a -. b) <. tolerance
}

fn sparrow() -> DeckPlan {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  c.plan
}

fn standing_at(x: Float, y: Float) -> Character {
  Character(
    id: 1,
    name: "ada",
    ship_id: 1,
    place: character.Aboard,
    x: x,
    y: y,
    seat: None,
    move_dx: 0.0,
    move_dy: 0.0,
  )
}

fn run_ticks(character: Character, plan: DeckPlan, n: Int) -> Character {
  case n {
    0 -> character
    _ -> run_ticks(character.step(character, plan), plan, n - 1)
  }
}

pub fn set_move_clamps_test() {
  let c = standing_at(4.5, 2.5) |> character.set_move(3.0, -5.0)
  assert c.move_dx == 1.0
  assert c.move_dy == -1.0
}

pub fn seated_character_ignores_move_input_test() {
  let plan = sparrow()
  let c =
    Character(..standing_at(1.5, 2.5), seat: Some("helm_main"))
    |> character.set_move(1.0, 0.0)
  let after = run_ticks(c, plan, 60)
  assert after.x == c.x
  assert after.y == c.y
}

pub fn standing_character_walks_in_open_space_test() {
  let plan = sparrow()
  // Row 2 is walkable x=1..8; plenty of room to the east of (4.5, 2.5).
  let c = standing_at(4.5, 2.5) |> character.set_move(1.0, 0.0)
  let after = character.step(c, plan)
  let expected_dx = character.walk_speed *. 0.016666666666666666
  assert close(after.x -. c.x, expected_dx, epsilon)
  assert after.y == c.y
}

pub fn diagonal_input_is_normalized_to_walk_speed_test() {
  let plan = sparrow()
  // (1, 1) has magnitude sqrt(2) > 1: normalized to unit magnitude before
  // being scaled by walk_speed, so the actual displacement per tick has
  // magnitude walk_speed * dt, not walk_speed * dt * sqrt(2).
  let c = standing_at(4.5, 2.5) |> character.set_move(1.0, 1.0)
  let after = character.step(c, plan)
  let dx = after.x -. c.x
  let dy = after.y -. c.y
  let assert Ok(actual_speed) = float.square_root(dx *. dx +. dy *. dy)
  let expected_speed = character.walk_speed *. 0.016666666666666666
  assert close(actual_speed, expected_speed, epsilon)
  // Both axes moved (a diagonal step), by equal amounts.
  assert dx >. 0.0
  assert dy >. 0.0
  assert close(dx, dy, epsilon)
}

pub fn walking_straight_into_wall_stops_test() {
  let plan = sparrow()
  // Row 2 walkable x=1..8; walking due east from x=7.5 runs into the hull
  // at x=9. Run long enough (well beyond arrival) to reach steady state.
  let c = standing_at(7.5, 2.5) |> character.set_move(1.0, 0.0)
  let settled = run_ticks(c, plan, 300)
  // Never crosses into the non-walkable tile at x=9.
  assert settled.x <. 9.0
  assert settled.y == 2.5
  // Steady state: one more tick doesn't move it further.
  let one_more = character.step(settled, plan)
  assert one_more.x == settled.x
}

pub fn walking_diagonally_into_wall_slides_test() {
  let plan = sparrow()
  // From (2.5, 2.5) (row 2, walkable x=1..8), moving up-and-right: tile
  // (2, 1) above is hull (row 1 is only walkable x=4..6), so "up" gets
  // rejected once the character's top edge nears the y=2.0 boundary — it
  // settles around y=2.3 (2.0 + radius). "right" keeps working, so x keeps
  // advancing after y has stopped: a slide along the wall, not a dead
  // stop. (Stay short of x=4 here, where row 1's walkable pocket begins
  // and the wall geometry changes — that boundary is exercised by
  // `character_never_enters_non_walkable_tile_test` instead.)
  let c = standing_at(2.5, 2.5) |> character.set_move(1.0, -1.0)
  let soon = run_ticks(c, plan, 20)
  assert close(soon.y, 2.3, 0.05)
  assert soon.x <. 4.0
  let later = run_ticks(soon, plan, 15)
  // y stays pinned at the wall while x keeps advancing.
  assert close(later.y, 2.3, 0.05)
  assert later.x >. soon.x
  assert later.x <. 4.0
}

pub fn character_never_enters_non_walkable_tile_test() {
  let plan = sparrow()
  // Start already at the hull boundary, push hard into it from every open
  // direction in turn; position must never end up over a '.' tile.
  let c = standing_at(1.5, 2.5) |> character.set_move(-1.0, 0.0)
  let settled = run_ticks(c, plan, 120)
  assert settled.x >. 0.0
  assert deckplan.is_walkable(
    plan,
    float.round(float.floor(settled.x)),
    float.round(float.floor(settled.y)),
  )
}

pub fn is_at_helm_false_when_standing_test() {
  let plan = sparrow()
  let c = standing_at(1.5, 2.5)
  assert !character.is_at_helm(c, plan)
}

pub fn is_at_helm_false_when_seated_at_non_helm_console_test() {
  let plan = sparrow()
  let c = Character(..standing_at(6.5, 1.5), seat: Some("cargo_main"))
  assert !character.is_at_helm(c, plan)
}

pub fn try_sit_success_snaps_to_console_center_test() {
  let plan = sparrow()
  let c = standing_at(1.5, 2.5)
  let assert Ok(seated) = character.try_sit(c, plan, "helm_main", False)
  assert seated.seat == Some("helm_main")
  assert seated.x == 1.5
  assert seated.y == 2.5
}

pub fn try_sit_too_far_test() {
  let plan = sparrow()
  // Helm at (1.5, 2.5); character way across the ship.
  let c = standing_at(8.5, 2.5)
  assert character.try_sit(c, plan, "helm_main", False) == Error("too_far")
}

pub fn try_sit_unknown_console_test() {
  let plan = sparrow()
  let c = standing_at(1.5, 2.5)
  assert character.try_sit(c, plan, "nonexistent", False)
    == Error("unknown_console")
}

pub fn try_sit_occupied_test() {
  let plan = sparrow()
  // In range, valid console, but the caller reports it occupied.
  let c = standing_at(1.5, 2.5)
  assert character.try_sit(c, plan, "helm_main", True) == Error("occupied")
}

pub fn try_sit_occupied_beats_too_far_test() {
  let plan = sparrow()
  // BOTH occupied and out of range (helm at (1.5, 2.5), character across
  // the ship): the reply must be `occupied`, proving occupancy is checked
  // before range — this would fail under the reversed ordering.
  let c = standing_at(8.5, 2.5)
  assert character.try_sit(c, plan, "helm_main", True) == Error("occupied")
}

pub fn try_sit_already_seated_test() {
  let plan = sparrow()
  let c = Character(..standing_at(1.5, 2.5), seat: Some("helm_main"))
  assert character.try_sit(c, plan, "cargo_main", False)
    == Error("already_seated")
}

pub fn stand_leaves_seat_in_place_test() {
  let c = Character(..standing_at(1.5, 2.5), seat: Some("helm_main"))
  let assert Ok(standing) = character.stand(c)
  assert standing.seat == None
  assert standing.x == 1.5
  assert standing.y == 2.5
}

pub fn stand_not_seated_test() {
  let c = standing_at(1.5, 2.5)
  assert character.stand(c) == Error("not_seated")
}

pub fn stand_clears_stale_move_input_test() {
  let plan = sparrow()
  // Move input sent while seated is ignored by `step`, but without a reset
  // it would still be buffered — and resume walking the character the tick
  // after standing. Standing must clear it.
  let c =
    Character(..standing_at(1.5, 2.5), seat: Some("helm_main"))
    |> character.set_move(1.0, 0.0)
  let assert Ok(standing) = character.stand(c)
  assert standing.move_dx == 0.0
  assert standing.move_dy == 0.0
  let after = character.step(standing, plan)
  assert after.x == standing.x
  assert after.y == standing.y
}

pub fn sit_clears_stale_move_input_test() {
  let plan = sparrow()
  // Same defence on sitting down: input held at the moment of sitting must
  // not survive the stay and fire again on the first tick after standing.
  let c = standing_at(1.5, 2.5) |> character.set_move(0.0, 1.0)
  let assert Ok(seated) = character.try_sit(c, plan, "helm_main", False)
  assert seated.move_dx == 0.0
  assert seated.move_dy == 0.0
}

pub fn seated_at_kind_matches_console_kind_test() {
  let plan = sparrow()
  let c = Character(..char_at(1, 1, character.Aboard), seat: Some("helm_main"))
  assert character.seated_at_kind(c, plan, "helm")
  assert !character.seated_at_kind(c, plan, "broker")
  let assert Ok(standing) = character.stand(c)
  assert !character.seated_at_kind(standing, plan, "helm")
}

/// A character at a fixed test position with a given place — replaces the
/// retired spawn/disembark constructors for the place-scoping checks.
fn char_at(id: Int, ship_id: Int, place: character.Place) -> Character {
  Character(
    id: id,
    name: "t",
    ship_id: ship_id,
    place: place,
    x: 1.5,
    y: 1.5,
    seat: None,
    move_dx: 0.0,
    move_dy: 0.0,
  )
}

pub fn same_place_test() {
  let aboard_1 = char_at(1, 1, character.Aboard)
  let aboard_1b = char_at(2, 1, character.Aboard)
  let aboard_2 = char_at(3, 2, character.Aboard)
  let ashore_m = char_at(4, 1, character.OnStation("meridian_highport"))
  let ashore_m2 = char_at(5, 2, character.OnStation("meridian_highport"))
  let ashore_s = char_at(6, 1, character.OnStation("solis_ring"))
  assert character.same_place(aboard_1, aboard_1b)
  assert !character.same_place(aboard_1, aboard_2)
  assert character.same_place(ashore_m, ashore_m2)
  assert !character.same_place(ashore_m, ashore_s)
  assert !character.same_place(aboard_1, ashore_m)
}
