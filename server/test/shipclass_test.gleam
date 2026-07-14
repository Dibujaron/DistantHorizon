import dh_server/shipclass.{Console, Grid}
import gleam/json
import gleam/list

pub fn load_bundled_sparrow_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  assert c.schema == 1
  assert c.id == "sparrow"
  assert c.grid == Grid(width: 10, height: 6)
  assert list.length(c.walkable) == 6
  assert list.length(c.rooms) == 4
  assert list.length(c.consoles) == 2
  assert c.spawn_tile == #(5, 4)
}

pub fn decode_encode_round_trips_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  let text = shipclass.encode(c) |> json.to_string
  let assert Ok(c2) = shipclass.decode(text)
  assert c == c2
}

pub fn helm_console_is_helm_main_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  let assert Ok(console) = shipclass.helm_console(c)
  assert console == Console(id: "helm_main", kind: "helm", x: 1, y: 2)
}

pub fn find_console_unknown_is_error_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  assert shipclass.find_console(c, "nope") == Error(Nil)
}

pub fn is_walkable_true_for_interior_tile_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  // Row 2: ".########." -> x=1..8 walkable.
  assert shipclass.is_walkable(c, 1, 2)
  assert shipclass.is_walkable(c, 8, 2)
}

pub fn is_walkable_false_for_hull_tile_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  assert !shipclass.is_walkable(c, 0, 2)
  assert !shipclass.is_walkable(c, 9, 2)
  assert !shipclass.is_walkable(c, 5, 0)
}

pub fn is_walkable_false_out_of_bounds_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  assert !shipclass.is_walkable(c, -1, 2)
  assert !shipclass.is_walkable(c, 10, 2)
  assert !shipclass.is_walkable(c, 5, -1)
  assert !shipclass.is_walkable(c, 5, 6)
}

/// A minimal valid class, for hand-crafting single-field violations without
/// depending on the bundled sparrow doc's exact layout.
fn valid_doc() -> String {
  "{\"schema\":1,\"id\":\"tiny\",\"name\":\"Tiny\","
  <> "\"grid\":{\"width\":3,\"height\":2},"
  <> "\"walkable\":[\"###\",\"###\"],"
  <> "\"rooms\":[],"
  <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
  <> "\"spawn_tile\":[1,1]}"
}

pub fn decode_valid_minimal_doc_test() {
  assert shipclass.decode(valid_doc()) |> is_ok
}

pub fn decode_rejects_row_count_mismatching_height_test() {
  let bad =
    "{\"schema\":1,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,0]}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_row_length_mismatching_width_test() {
  let bad =
    "{\"schema\":1,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"##\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,0]}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_console_off_walkable_tile_test() {
  let bad =
    "{\"schema\":1,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\".##\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":0,\"y\":1}],"
    <> "\"spawn_tile\":[1,1]}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_spawn_tile_off_walkable_tile_test() {
  let bad =
    "{\"schema\":1,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\".##\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":1}],"
    <> "\"spawn_tile\":[0,1]}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_missing_helm_console_test() {
  let bad =
    "{\"schema\":1,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"cargo_main\",\"kind\":\"cargo\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,1]}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_garbage_test() {
  assert shipclass.decode("not json") |> is_error
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
