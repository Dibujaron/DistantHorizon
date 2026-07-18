import dh_server/character.{type Character, Character}
import dh_server/deckplan.{type DeckPlan}
import dh_server/shipclass
import gleam/float
import gleam/option.{None, Some}

const epsilon = 0.0001

fn close(a: Float, b: Float, tolerance: Float) -> Bool {
  float.absolute_value(a -. b) <. tolerance
}

/// The bundled Mockingbird: 14x19, nose up, ~1 m tiles. Upper deck:
/// cockpit col 6-7 rows 2-4; '2' midbody rows 5-19 (mess/commons above
/// the hold). Row 20 stairs: L(5) U(6) U(7) L(8). Row 21: 'B' docking
/// corridor, port dormer (5,21). Helm at (6,2), cargo console at (5,20).
fn mockingbird() -> DeckPlan {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
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
    deck: deckplan.Upper,
    seat: None,
    move_dx: 0.0,
    move_dy: 0.0,
  )
}

fn standing_lower(x: Float, y: Float) -> Character {
  Character(..standing_at(x, y), deck: deckplan.Lower)
}

fn run_ticks(character: Character, plan: DeckPlan, n: Int) -> Character {
  case n {
    0 -> character
    _ -> run_ticks(character.step(character, plan), plan, n - 1)
  }
}

pub fn set_move_clamps_test() {
  let c = standing_at(6.5, 7.5) |> character.set_move(3.0, -5.0)
  assert c.move_dx == 1.0
  assert c.move_dy == -1.0
}

pub fn seated_character_ignores_move_input_test() {
  let plan = mockingbird()
  let c =
    Character(..standing_at(6.5, 2.5), seat: Some("helm_main"))
    |> character.set_move(1.0, 0.0)
  let after = run_ticks(c, plan, 60)
  assert after.x == c.x
  assert after.y == c.y
}

pub fn standing_character_walks_in_open_space_test() {
  let plan = mockingbird()
  // Mid-body row 7 is walkable x=3..10; plenty of room east of (4.5, 7.5).
  let c = standing_at(4.5, 7.5) |> character.set_move(1.0, 0.0)
  let after = character.step(c, plan)
  let expected_dx = character.walk_speed *. 0.016666666666666666
  assert close(after.x -. c.x, expected_dx, epsilon)
  assert after.y == c.y
}

pub fn diagonal_input_is_normalized_to_walk_speed_test() {
  let plan = mockingbird()
  // (1, 1) has magnitude sqrt(2) > 1: normalized to unit magnitude before
  // being scaled by walk_speed, so the actual displacement per tick has
  // magnitude walk_speed * dt, not walk_speed * dt * sqrt(2).
  let c = standing_at(4.5, 7.5) |> character.set_move(1.0, 1.0)
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
  let plan = mockingbird()
  // Row 7 walkable x=3..10; due east from (9.5, 7.5) runs into the hull
  // at x=11. Run long enough (well beyond arrival) for steady state.
  let c = standing_at(9.5, 7.5) |> character.set_move(1.0, 0.0)
  let settled = run_ticks(c, plan, 300)
  // Never crosses into the non-walkable tile at x=11.
  assert settled.x <. 11.0
  assert settled.y == 7.5
  // Steady state: one more tick doesn't move it further.
  let one_more = character.step(settled, plan)
  assert one_more.x == settled.x
}

pub fn walking_diagonally_into_wall_slides_test() {
  let plan = mockingbird()
  // From (3.5, 8.5), moving up-and-left: tile (2, y) west is hull, so
  // "left" pins at x = 3.3 (3.0 + radius) almost immediately, while "up"
  // keeps working until the body's north taper above col 3 (tile (3,6) is
  // void — row 6 starts at col 4) pins y at 7.3 — a slide along the west
  // wall, not a dead stop.
  let c = standing_at(3.5, 8.5) |> character.set_move(-1.0, -1.0)
  let soon = run_ticks(c, plan, 16)
  assert close(soon.x, 3.3, 0.05)
  assert soon.y <. 8.2
  assert soon.y >. 7.4
  let later = run_ticks(soon, plan, 30)
  // x stays pinned at the wall while y has advanced to its own wall.
  assert close(later.x, 3.3, 0.05)
  assert close(later.y, 7.3, 0.05)
}

pub fn character_never_enters_non_walkable_tile_test() {
  let plan = mockingbird()
  // Start at the hull boundary, push hard into it; position must never end
  // up over a '.' tile.
  let c = standing_at(3.5, 7.5) |> character.set_move(-1.0, 0.0)
  let settled = run_ticks(c, plan, 120)
  assert settled.x >. 3.0
  assert deckplan.is_walkable(
    plan,
    float.round(float.floor(settled.x)),
    float.round(float.floor(settled.y)),
  )
}

// ------------------------------------------------------------------ decks --

pub fn lower_walker_cannot_enter_upper_tile_test() {
  let plan = mockingbird()
  // A lower walker in the hold must not climb into the cockpit: from
  // (6.5, 6.5) ('2', deck lower) walking north, tile (6, 4) is 'U' —
  // blocked at the row-4 boundary.
  let c = standing_lower(6.5, 6.5) |> character.set_move(0.0, -1.0)
  let settled = run_ticks(c, plan, 180)
  assert settled.y >. 5.0
  assert settled.deck == deckplan.Lower
}

pub fn upper_walker_walks_toward_the_cockpit_test() {
  let plan = mockingbird()
  // Same route, same tiles, upper deck: passes freely into row 4.
  let c = standing_at(6.5, 6.5) |> character.set_move(0.0, -1.0)
  let moved = run_ticks(c, plan, 120)
  assert moved.y <. 5.0
  assert moved.deck == deckplan.Upper
}

pub fn between_level_switches_deck_via_stairs_test() {
  let plan = mockingbird()
  // A lower walker on the docking corridor ('B') may step onto the 'U'
  // stair (deck-agnostic access from 'B') and arrives committed to Upper.
  let c = standing_lower(6.5, 21.45) |> character.set_move(0.0, -1.0)
  let climbed = run_ticks(c, plan, 40)
  assert climbed.y <. 21.0
  assert climbed.deck == deckplan.Upper
}

pub fn upper_walker_descends_to_lower_via_stairs_test() {
  let plan = mockingbird()
  // Upper walker on 'B' steps onto the port 'L' half-flight at (5, 20)
  // and becomes Lower.
  let c = standing_at(5.5, 21.45) |> character.set_move(0.0, -1.0)
  let descended = run_ticks(c, plan, 40)
  assert descended.y <. 21.0
  assert descended.deck == deckplan.Lower
}

pub fn upper_walker_cannot_use_lower_stair_off_b_test() {
  let plan = mockingbird()
  // NOT standing on 'B': an upper walker on the 'U' stair (6, 20) cannot
  // sidestep onto the 'L' stair (5, 20).
  let c = standing_at(6.5, 20.5) |> character.set_move(-1.0, 0.0)
  let settled = run_ticks(c, plan, 60)
  assert settled.x >. 6.0
  assert settled.deck == deckplan.Upper
}

// ------------------------------------------------------------------- seats --

pub fn is_at_helm_false_when_standing_test() {
  let plan = mockingbird()
  let c = standing_at(6.5, 3.5)
  assert !character.is_at_helm(c, plan)
}

pub fn is_at_helm_false_when_seated_at_non_helm_console_test() {
  let plan = mockingbird()
  let c = Character(..standing_lower(5.5, 20.5), seat: Some("cargo_main"))
  assert !character.is_at_helm(c, plan)
}

pub fn try_sit_success_snaps_to_console_center_test() {
  let plan = mockingbird()
  let c = standing_at(6.5, 3.5)
  let assert Ok(seated) = character.try_sit(c, plan, "helm_main", False)
  assert seated.seat == Some("helm_main")
  assert seated.x == 6.5
  assert seated.y == 2.5
}

pub fn try_sit_too_far_test() {
  let plan = mockingbird()
  // Helm at (6.5, 2.5); character on the stairs at the stern.
  let c = standing_at(6.5, 20.5)
  assert character.try_sit(c, plan, "helm_main", False) == Error("too_far")
}

pub fn try_sit_wrong_deck_is_too_far_test() {
  let plan = mockingbird()
  // The cargo console (5, 20) is the port 'L' half-flight; an upper
  // walker on the adjacent 'B' corridor tile is within planar range
  // (1.0 < 1.2) but a floor away.
  let c = standing_at(5.5, 21.5)
  assert character.try_sit(c, plan, "cargo_main", False) == Error("too_far")
  // The same body on the lower deck sits fine.
  let assert Ok(seated) =
    character.try_sit(standing_lower(5.5, 21.5), plan, "cargo_main", False)
  assert seated.seat == Some("cargo_main")
  assert seated.deck == deckplan.Lower
}

pub fn try_sit_unknown_console_test() {
  let plan = mockingbird()
  let c = standing_at(6.5, 3.5)
  assert character.try_sit(c, plan, "nonexistent", False)
    == Error("unknown_console")
}

pub fn try_sit_occupied_test() {
  let plan = mockingbird()
  // In range, valid console, but the caller reports it occupied.
  let c = standing_at(6.5, 3.5)
  assert character.try_sit(c, plan, "helm_main", True) == Error("occupied")
}

pub fn try_sit_occupied_beats_too_far_test() {
  let plan = mockingbird()
  // BOTH occupied and out of range: the reply must be `occupied`, proving
  // occupancy is checked before range.
  let c = standing_at(6.5, 20.5)
  assert character.try_sit(c, plan, "helm_main", True) == Error("occupied")
}

pub fn try_sit_already_seated_test() {
  let plan = mockingbird()
  let c = Character(..standing_at(6.5, 2.5), seat: Some("helm_main"))
  assert character.try_sit(c, plan, "cargo_main", False)
    == Error("already_seated")
}

pub fn stand_leaves_seat_in_place_test() {
  let c = Character(..standing_at(6.5, 2.5), seat: Some("helm_main"))
  let assert Ok(standing) = character.stand(c)
  assert standing.seat == None
  assert standing.x == 6.5
  assert standing.y == 2.5
}

pub fn stand_not_seated_test() {
  let c = standing_at(6.5, 3.5)
  assert character.stand(c) == Error("not_seated")
}

pub fn stand_clears_stale_move_input_test() {
  let plan = mockingbird()
  // Move input sent while seated is ignored by `step`, but without a reset
  // it would still be buffered — and resume walking the character the tick
  // after standing. Standing must clear it.
  let c =
    Character(..standing_at(6.5, 2.5), seat: Some("helm_main"))
    |> character.set_move(1.0, 0.0)
  let assert Ok(standing) = character.stand(c)
  assert standing.move_dx == 0.0
  assert standing.move_dy == 0.0
  let after = character.step(standing, plan)
  assert after.x == standing.x
  assert after.y == standing.y
}

pub fn sit_clears_stale_move_input_test() {
  let plan = mockingbird()
  // Same defence on sitting down: input held at the moment of sitting must
  // not survive the stay and fire again on the first tick after standing.
  let c = standing_at(6.5, 3.5) |> character.set_move(0.0, 1.0)
  let assert Ok(seated) = character.try_sit(c, plan, "helm_main", False)
  assert seated.move_dx == 0.0
  assert seated.move_dy == 0.0
}

pub fn seated_at_kind_matches_console_kind_test() {
  let plan = mockingbird()
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
    x: 6.5,
    y: 2.5,
    deck: deckplan.Upper,
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
