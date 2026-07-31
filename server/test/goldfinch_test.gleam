import dh_server/hull
import gleam/list
import gleam/string

/// Two passenger decks plus the mezzanine that carries her dock ports: the
/// A380 reading of "two rows of windows on the sides".
pub fn she_is_a_double_decker_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  assert h.id == "goldfinch"
  assert list.length(h.decks) == 3
}

/// Twelve identical 1x2 cabins, and fifteen slots total — one below the
/// sixteen a single hex slot digit can express.
pub fn she_carries_twelve_cabins_in_fifteen_slots_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  assert list.length(h.slots) == 15
  let cabins =
    list.filter(h.slots, fn(s) { string.starts_with(s.id, "cabin_") })
  assert list.length(cabins) == 12
}

/// The first hull to mix mount sizes: a medium on the stern, smalls on struts.
pub fn her_mounts_mix_sizes_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(centre) = hull.mount_by_id(h, "engine_center")
  assert centre.size == "m"
  let assert Ok(port) = hull.mount_by_id(h, "engine_port")
  assert port.size == "s"
}
