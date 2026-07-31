import dh_server/hull
import gleam/list

/// One deck, no stairs, no mezzanine. Every deck-linking rule we have was
/// written against a three-deck ship; she is the first hull that has none.
pub fn she_is_a_single_deck_hull_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  assert h.id == "sparrow"
  assert list.length(h.decks) == 1
  assert list.length(h.slots) == 2
}

/// Two engines shipped of three mounts. `engine_center` is the first unfitted
/// mount on any hull, and pooled `requires: {engine: 1}` satisfied by 2 >= 1
/// has never been exercised by content either.
pub fn she_has_three_small_mounts_and_ships_two_engines_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  assert list.length(h.mounts) == 3
  assert list.all(h.mounts, fn(m) { m.size == "s" })
  assert h.default_parts
    == [
      #("engine_port", "rijay.engine.wren_90b"),
      #("engine_stbd", "rijay.engine.wren_90b"),
    ]
}
