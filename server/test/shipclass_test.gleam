import dh_server/deckplan.{Console, Grid}
import dh_server/shipclass
import gleam/json
import gleam/list

pub fn load_bundled_mockingbird_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  assert c.schema == 2
  assert c.id == "mockingbird"
  assert c.plan.grid == Grid(width: 14, height: 22)
  assert list.length(c.plan.walkable) == 22
  assert list.length(c.plan.rooms) == 6
  assert list.length(c.plan.consoles) == 2
  // The spawn tile is the PORT docking dormer on the between-level ('B')
  // corridor at the waist — side ports, never the stern.
  assert c.plan.spawn_tile == #(5, 21)
  assert list.any(c.plan.rooms, fn(r) { r.id == "dock" })
  // Split-level metadata: the hold is a lower-deck room.
  let assert Ok(hold) = list.find(c.plan.rooms, fn(r) { r.id == "hold" })
  assert hold.deck == "lower"
}

pub fn decode_encode_round_trips_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  let text = shipclass.encode(c) |> json.to_string
  let assert Ok(c2) = shipclass.decode(text)
  assert c == c2
}

pub fn helm_console_is_helm_main_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  let assert Ok(console) = shipclass.helm_console(c)
  assert console == Console(id: "helm_main", kind: "helm", x: 6, y: 2)
}

pub fn find_console_unknown_is_error_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  assert deckplan.find_console(c.plan, "nope") == Error(Nil)
}

pub fn is_walkable_true_for_interior_tile_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  // Row 7: "...22222222..." -> x=3..10 walkable; row 21 corridor likewise.
  assert deckplan.is_walkable(c.plan, 3, 7)
  assert deckplan.is_walkable(c.plan, 10, 7)
  assert deckplan.is_walkable(c.plan, 5, 21)
}

pub fn is_walkable_false_for_hull_tile_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  assert !deckplan.is_walkable(c.plan, 2, 7)
  assert !deckplan.is_walkable(c.plan, 11, 7)
  assert !deckplan.is_walkable(c.plan, 6, 0)
}

pub fn is_walkable_false_out_of_bounds_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  assert !deckplan.is_walkable(c.plan, -1, 7)
  assert !deckplan.is_walkable(c.plan, 14, 7)
  assert !deckplan.is_walkable(c.plan, 6, -1)
  assert !deckplan.is_walkable(c.plan, 6, 22)
}

/// A minimal valid class, for hand-crafting single-field violations without
/// depending on the bundled sparrow doc's exact layout.
fn valid_doc() -> String {
  "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
  <> "\"grid\":{\"width\":3,\"height\":2},"
  <> "\"walkable\":[\"###\",\"###\"],"
  <> "\"rooms\":[],"
  <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
  <> "\"spawn_tile\":[1,1],"
  <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
}

pub fn decode_valid_minimal_doc_test() {
  assert shipclass.decode(valid_doc()) |> is_ok
}

pub fn decode_rejects_row_count_mismatching_height_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,0],"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_row_length_mismatching_width_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"##\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,0],"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_console_off_walkable_tile_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\".##\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":0,\"y\":1}],"
    <> "\"spawn_tile\":[1,1],"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_spawn_tile_off_walkable_tile_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\".##\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":1}],"
    <> "\"spawn_tile\":[0,1],"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_missing_helm_console_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"cargo_main\",\"kind\":\"cargo\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,1],"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_garbage_test() {
  assert shipclass.decode("not json") |> is_error
}

pub fn decode_reads_cargo_block_test() {
  let assert Ok(c) = shipclass.load("classes/mockingbird.json")
  assert c.cargo_capacity == 40
  assert c.handling == shipclass.BreakBulk
}

pub fn decode_rejects_unknown_handling_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,1],"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"antigrav\"}}"
  let assert Error(_) = shipclass.decode(bad)
}

pub fn decode_rejects_missing_cargo_block_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,1]}"
  let assert Error(_) = shipclass.decode(bad)
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Error(_) -> True
    Ok(_) -> False
  }
}
