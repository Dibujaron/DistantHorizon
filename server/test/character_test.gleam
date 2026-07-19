import dh_server/character.{type Character, Character}
import dh_server/deckplan.{type DeckPlan, Console, DeckPlan}
import gleam/float
import gleam/option.{None, Some}

const epsilon = 0.0001

const dt = 0.016666666666666666

fn close(a: Float, b: Float, tolerance: Float) -> Bool {
  float.absolute_value(a -. b) <. tolerance
}

// A 5-wide x 1-tall walled corridor with an internal wall between tiles 2
// and 3 (a double wall: tile2's east edge and tile3's west edge). Floors are
// open; the hull walls the perimeter.
fn corridor_wall() -> DeckPlan {
  single_deck(["###############", "#       ##    #", "###############"])
}

// Same corridor, but the tile2|tile3 boundary is a door (passable).
fn corridor_door() -> DeckPlan {
  single_deck(["###############", "#       ==    #", "###############"])
}

// A floor tile beside a void tile with an OPEN edge: the void (not a wall)
// is what stops the walker. tile0 floor, tile1 void.
fn corridor_void() -> DeckPlan {
  single_deck(["######", "#  .  ", "######"])
}

fn single_deck(rows: List(String)) -> DeckPlan {
  let assert Ok(g) = deckplan.parse_deck("d", rows)
  DeckPlan(decks: [g], rooms: [], consoles: [], spawn_deck: 0, spawn_tile: #(
    0,
    0,
  ))
}

// Two decks, uniform 3x1, both with a stairs tile at (1,0) — the vertical
// connector. Floors elsewhere, walled perimeter.
fn stairs_plan() -> DeckPlan {
  let assert Ok(upper) = deckplan.parse_deck("upper", stairs_rows())
  let assert Ok(lower) = deckplan.parse_deck("lower", stairs_rows())
  DeckPlan(
    decks: [upper, lower],
    rooms: [],
    consoles: [],
    spawn_deck: 0,
    spawn_tile: #(0, 0),
  )
}

fn stairs_rows() -> List(String) {
  ["#########", "#   x   #", "#########"]
}

// Two decks with a helm console on deck 0 and a cargo console on deck 1,
// both at tile (1,0).
fn console_plan() -> DeckPlan {
  let assert Ok(upper) =
    deckplan.parse_deck("upper", ["#########", "#       #", "#########"])
  let assert Ok(lower) =
    deckplan.parse_deck("lower", ["#########", "#       #", "#########"])
  DeckPlan(
    decks: [upper, lower],
    rooms: [],
    consoles: [
      Console(id: "helm_main", kind: "helm", deck: 0, x: 1, y: 0),
      Console(id: "cargo_main", kind: "cargo", deck: 1, x: 1, y: 0),
    ],
    spawn_deck: 0,
    spawn_tile: #(0, 0),
  )
}

fn standing_at(x: Float, y: Float) -> Character {
  standing_on(0, x, y)
}

fn standing_on(deck: Int, x: Float, y: Float) -> Character {
  Character(
    id: 1,
    name: "ada",
    ship_id: 1,
    place: character.Aboard,
    x: x,
    y: y,
    deck: deck,
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
  let c = standing_at(1.5, 0.5) |> character.set_move(3.0, -5.0)
  assert c.move_dx == 1.0
  assert c.move_dy == -1.0
}

pub fn seated_character_ignores_move_input_test() {
  let plan = console_plan()
  let c =
    Character(..standing_at(1.5, 0.5), seat: Some("helm_main"))
    |> character.set_move(1.0, 0.0)
  let after = run_ticks(c, plan, 60)
  assert after.x == c.x
  assert after.y == c.y
}

pub fn standing_character_walks_in_open_space_test() {
  let plan = corridor_wall()
  // From (0.5, 0.5) there is open floor east into tile 1.
  let c = standing_at(0.5, 0.5) |> character.set_move(1.0, 0.0)
  let after = character.step(c, plan)
  let expected_dx = character.walk_speed *. dt
  assert close(after.x -. c.x, expected_dx, epsilon)
  assert after.y == c.y
}

pub fn diagonal_input_is_normalized_to_walk_speed_test() {
  // Open 3x3 room (9 rows) so a diagonal step is unobstructed on both axes.
  let plan =
    single_deck([
      "#########", "#       #", "#       #", "#       #", "#       #",
      "#       #", "#       #", "#       #", "#########",
    ])
  let c = standing_on(0, 1.5, 1.5) |> character.set_move(1.0, 1.0)
  let after = character.step(c, plan)
  let dx = after.x -. c.x
  let dy = after.y -. c.y
  let assert Ok(actual_speed) = float.square_root(dx *. dx +. dy *. dy)
  let expected_speed = character.walk_speed *. dt
  assert close(actual_speed, expected_speed, epsilon)
  assert dx >. 0.0
  assert dy >. 0.0
  assert close(dx, dy, epsilon)
}

pub fn walking_straight_into_wall_stops_test() {
  let plan = corridor_wall()
  // Walking east runs into the internal wall on tile 2's east side (x=3):
  // stops one radius short, at x = 2.7.
  let c = standing_at(0.5, 0.5) |> character.set_move(1.0, 0.0)
  let settled = run_ticks(c, plan, 300)
  assert close(settled.x, 3.0 -. character.radius, 0.001)
  assert settled.y == 0.5
  let one_more = character.step(settled, plan)
  assert one_more.x == settled.x
}

pub fn door_boundary_is_passable_test() {
  let plan = corridor_door()
  // The tile2|tile3 door lets the walker through to the far hull (x=5),
  // stopping one radius short at x = 4.7.
  let c = standing_at(0.5, 0.5) |> character.set_move(1.0, 0.0)
  let settled = run_ticks(c, plan, 400)
  assert close(settled.x, 5.0 -. character.radius, 0.001)
}

pub fn void_tile_stops_walker_test() {
  let plan = corridor_void()
  // No wall on tile0's east edge, but tile1 is void: the collision circle
  // may not overlap it, so the walker stops one radius short of x=1.
  let c = standing_at(0.5, 0.5) |> character.set_move(1.0, 0.0)
  let settled = run_ticks(c, plan, 120)
  // Discrete steps settle just short of the void boundary (x=1); never past.
  assert settled.x <. 1.0 -. character.radius +. 0.001
  assert settled.x >. 0.6
  assert deckplan.is_walkable(
    {
      let assert Ok(g) = deckplan.deck_at(plan, 0)
      g
    },
    float.round(float.floor(settled.x)),
    float.round(float.floor(settled.y)),
  )
}

pub fn walking_diagonally_into_wall_slides_test() {
  let plan = corridor_wall()
  // Pushing up-and-east against the internal wall: east pins at x=2.7 while
  // north is free to the hull (y pins at 0.3), a slide not a dead stop.
  let c = standing_at(0.5, 0.5) |> character.set_move(1.0, -1.0)
  let settled = run_ticks(c, plan, 300)
  // East pins hard at the internal wall; north slid up to the hull (within a
  // step of y=0.3), proving a slide rather than a dead stop.
  assert close(settled.x, 3.0 -. character.radius, 0.01)
  assert settled.y <. 0.36
  assert settled.y >. 0.29
}

// ------------------------------------------------------------------ decks --

pub fn walking_onto_stairs_switches_deck_test() {
  let plan = stairs_plan()
  // Walking east from deck 0's tile 0 onto the stairs at tile 1 lands the
  // body on the aligned deck 1.
  let c = standing_on(0, 0.5, 0.5) |> character.set_move(1.0, 0.0)
  let after = run_ticks(c, plan, 40)
  assert after.deck == 1
  assert after.x >. 1.0
}

pub fn leaving_stairs_does_not_re_switch_test() {
  let plan = stairs_plan()
  // Continuing east off the stairs onto deck 1's floor must not bounce the
  // body back to deck 0.
  let c = standing_on(0, 0.5, 0.5) |> character.set_move(1.0, 0.0)
  let after = run_ticks(c, plan, 120)
  assert after.deck == 1
  assert after.x >. 2.0
}

pub fn no_stairs_no_deck_change_test() {
  let plan = corridor_wall()
  let c = standing_at(0.5, 0.5) |> character.set_move(1.0, 0.0)
  let after = run_ticks(c, plan, 60)
  assert after.deck == 0
}

// ------------------------------------------------------------------- seats --

pub fn is_at_helm_false_when_standing_test() {
  let plan = console_plan()
  let c = standing_at(1.5, 0.5)
  assert !character.is_at_helm(c, plan)
}

pub fn is_at_helm_false_when_seated_at_non_helm_console_test() {
  let plan = console_plan()
  let c = Character(..standing_on(1, 1.5, 0.5), seat: Some("cargo_main"))
  assert !character.is_at_helm(c, plan)
}

pub fn try_sit_success_snaps_to_console_center_test() {
  let plan = console_plan()
  let c = standing_at(1.5, 0.9)
  let assert Ok(seated) = character.try_sit(c, plan, "helm_main", False)
  assert seated.seat == Some("helm_main")
  assert seated.x == 1.5
  assert seated.y == 0.5
}

pub fn try_sit_too_far_test() {
  let plan = console_plan()
  // Helm at (1.5, 0.5); a body across the corridor is out of sit_range.
  let c = standing_at(6.5, 0.5)
  assert character.try_sit(c, plan, "helm_main", False) == Error("too_far")
}

pub fn try_sit_wrong_deck_is_too_far_test() {
  let plan = console_plan()
  // In planar range of the cargo console (1,0) but on the wrong deck.
  let c = standing_on(0, 1.5, 0.5)
  assert character.try_sit(c, plan, "cargo_main", False) == Error("too_far")
  // The same spot on deck 1 sits fine.
  let assert Ok(seated) =
    character.try_sit(standing_on(1, 1.5, 0.5), plan, "cargo_main", False)
  assert seated.seat == Some("cargo_main")
  assert seated.deck == 1
}

pub fn try_sit_unknown_console_test() {
  let plan = console_plan()
  let c = standing_at(1.5, 0.5)
  assert character.try_sit(c, plan, "nonexistent", False)
    == Error("unknown_console")
}

pub fn try_sit_occupied_test() {
  let plan = console_plan()
  let c = standing_at(1.5, 0.9)
  assert character.try_sit(c, plan, "helm_main", True) == Error("occupied")
}

pub fn try_sit_occupied_beats_too_far_test() {
  let plan = console_plan()
  // BOTH occupied and out of range: the reply must be `occupied`.
  let c = standing_at(6.5, 0.5)
  assert character.try_sit(c, plan, "helm_main", True) == Error("occupied")
}

pub fn try_sit_already_seated_test() {
  let plan = console_plan()
  let c = Character(..standing_at(1.5, 0.5), seat: Some("helm_main"))
  assert character.try_sit(c, plan, "cargo_main", False)
    == Error("already_seated")
}

pub fn stand_leaves_seat_in_place_test() {
  let c = Character(..standing_at(1.5, 0.5), seat: Some("helm_main"))
  let assert Ok(standing) = character.stand(c)
  assert standing.seat == None
  assert standing.x == 1.5
  assert standing.y == 0.5
}

pub fn stand_not_seated_test() {
  let c = standing_at(1.5, 0.5)
  assert character.stand(c) == Error("not_seated")
}

pub fn stand_clears_stale_move_input_test() {
  let plan = console_plan()
  let c =
    Character(..standing_at(1.5, 0.5), seat: Some("helm_main"))
    |> character.set_move(1.0, 0.0)
  let assert Ok(standing) = character.stand(c)
  assert standing.move_dx == 0.0
  assert standing.move_dy == 0.0
  let after = character.step(standing, plan)
  assert after.x == standing.x
  assert after.y == standing.y
}

pub fn sit_clears_stale_move_input_test() {
  let plan = console_plan()
  let c = standing_at(1.5, 0.9) |> character.set_move(0.0, -1.0)
  let assert Ok(seated) = character.try_sit(c, plan, "helm_main", False)
  assert seated.move_dx == 0.0
  assert seated.move_dy == 0.0
}

pub fn seated_at_kind_matches_console_kind_test() {
  let plan = console_plan()
  let c = Character(..char_at(1, 1, character.Aboard), seat: Some("helm_main"))
  assert character.seated_at_kind(c, plan, "helm")
  assert !character.seated_at_kind(c, plan, "broker")
  let assert Ok(standing) = character.stand(c)
  assert !character.seated_at_kind(standing, plan, "helm")
}

/// A character at a fixed test position with a given place.
fn char_at(id: Int, ship_id: Int, place: character.Place) -> Character {
  Character(
    id: id,
    name: "t",
    ship_id: ship_id,
    place: place,
    x: 1.5,
    y: 0.5,
    deck: 0,
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
