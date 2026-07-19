import dh_server/deckplan
import dh_server/shipclass
import gleam/json
import gleam/list

pub fn load_bundled_mockingbird_test() {
  let assert Ok(c) = shipclass.load("shipclasses/mockingbird.json")
  assert c.schema == 3
  assert c.id == "mockingbird"
  // Three decks: Upper, Mezzanine, Lower.
  assert list.length(c.plan.decks) == 3
  // The docking port (`Q` glyph) derives a "dock" console.
  let assert Ok(_) = deckplan.find_console_of_kind(c.plan, "dock")
  let assert Ok(_) = shipclass.helm_console(c)
}

pub fn decode_encode_round_trips_test() {
  let assert Ok(c) = shipclass.load("shipclasses/mockingbird.json")
  let text = shipclass.encode(c) |> json.to_string
  let assert Ok(c2) = shipclass.decode(text)
  assert c == c2
}

pub fn helm_console_is_helm_main_test() {
  let assert Ok(c) = shipclass.load("shipclasses/mockingbird.json")
  let assert Ok(console) = shipclass.helm_console(c)
  assert console.id == "helm"
  assert console.kind == "helm"
}

pub fn find_console_unknown_is_error_test() {
  let assert Ok(c) = shipclass.load("shipclasses/mockingbird.json")
  assert deckplan.find_console(c.plan, "nope") == Error(Nil)
}

pub fn spawn_tile_is_walkable_test() {
  let assert Ok(c) = shipclass.load("shipclasses/mockingbird.json")
  let assert Ok(g) = deckplan.deck_at(c.plan, c.plan.spawn_deck)
  let #(sx, sy) = c.plan.spawn_tile
  assert deckplan.is_walkable(g, sx, sy)
}

/// A minimal valid schema-3 class, for hand-crafting single-field
/// violations without depending on the bundled hull's exact layout.
fn valid_doc() -> String {
  "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
  <> "\"decks\":[{\"name\":\"main\",\"grid\":"
  <> "[\"#########\",\"#       #\",\"#########\"]}],"
  <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"deck\":0,\"x\":1,\"y\":0}],"
  <> "\"spawn\":{\"deck\":0,\"tile\":[1,0]},"
  <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
}

pub fn decode_valid_minimal_doc_test() {
  assert shipclass.decode(valid_doc()) |> is_ok
}

pub fn decode_rejects_ragged_deck_rows_test() {
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"######\",\"# #\"]}],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"deck\":0,\"x\":0,\"y\":0}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[0,0]},"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_non_multiple_of_three_test() {
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"####\",\"#  #\",\"####\"]}],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"deck\":0,\"x\":0,\"y\":0}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[0,0]},"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_console_off_walkable_tile_test() {
  // Console on a void tile — the '.' centre is at col 4 (tile 1).
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"######\",\"#   . \",\"######\"]}],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"deck\":0,\"x\":1,\"y\":0}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[0,0]},"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_spawn_tile_off_walkable_tile_test() {
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"######\",\"#   . \",\"######\"]}],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"deck\":0,\"x\":0,\"y\":0}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[1,0]},"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_missing_helm_console_test() {
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"######\",\"#    #\",\"######\"]}],"
    <> "\"consoles\":[{\"id\":\"cargo_main\",\"kind\":\"cargo\",\"deck\":0,\"x\":1,\"y\":0}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[0,0]},"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_docking_port_without_void_facing_door_test() {
  // A Q docking port walled in on every side — no door faces void — is an
  // authoring error (the format requires the outer gangway door). Consoles
  // (helm + dock) derive from the 'h'/'Q' grid glyphs.
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"#########\",\"#   h  Q#\",\"#########\"]}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[0,0]},"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"breakbulk\"}}"
  assert shipclass.decode(bad) |> is_error
}

pub fn decode_rejects_garbage_test() {
  assert shipclass.decode("not json") |> is_error
}

pub fn decode_reads_cargo_block_test() {
  let assert Ok(c) = shipclass.load("shipclasses/mockingbird.json")
  assert c.cargo_capacity == 40
  assert c.handling == shipclass.BreakBulk
}

pub fn dock_standoff_reads_and_defaults_test() {
  // The bundled hull authors its standoff.
  let assert Ok(c) = shipclass.load("shipclasses/mockingbird.json")
  assert c.dock_standoff == 20.0
  // A class that omits dock_standoff falls back to the default.
  let assert Ok(d) = shipclass.decode(valid_doc())
  assert d.dock_standoff == shipclass.default_dock_standoff
}

pub fn decode_rejects_unknown_handling_test() {
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"######\",\"#    #\",\"######\"]}],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"deck\":0,\"x\":1,\"y\":0}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[0,0]},"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"antigrav\"}}"
  let assert Error(_) = shipclass.decode(bad)
}

pub fn decode_rejects_missing_cargo_block_test() {
  let bad =
    "{\"schema\":3,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"decks\":[{\"name\":\"main\",\"grid\":[\"######\",\"#    #\",\"######\"]}],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"deck\":0,\"x\":1,\"y\":0}],"
    <> "\"spawn\":{\"deck\":0,\"tile\":[0,0]}}"
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
