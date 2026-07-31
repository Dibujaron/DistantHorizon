import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
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

/// Her stock fit resolves, draws its pallets, and puts a helm on the wire.
pub fn her_default_loadout_resolves_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, modules, parts, loadout.default_for(h))
  // Capacity is DERIVED from the packet locker's pallet tiles, never from
  // the hull's fallback of 2. `hull.gleam` calls the hull-side one
  // `fallback_capacity`; the resolved one on `ShipClass` is `cargo_capacity`.
  assert fit.class.cargo_capacity == 5
}

/// Range or speed, not both. The third engine and the endurance package each
/// fit alone and refuse together — a real refit decision expressed entirely
/// in numbers the validator already understands.
pub fn the_third_engine_and_the_ranger_package_cannot_both_fit_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let three = [
    #("engine_port", "rijay.engine.wren_90b"),
    #("engine_center", "rijay.engine.wren_90b"),
    #("engine_stbd", "rijay.engine.wren_90b"),
  ]
  // Speed build: cockpit 2 + packet 1 + engines 9 = 12 of 12. Exactly fits.
  let speed =
    loadout.Loadout(
      hull: "sparrow",
      modules: [
        #("cockpit", "rijay.cockpit.sparrow"),
        #("bay", "rijay.bay.packet"),
      ],
      parts: three,
    )
  let assert Ok(_) = loadout.resolve(glyphs.default(), h, modules, parts, speed)
  // Range build on two engines: 2 + 2 + 6 = 10 of 12. Fits.
  let range =
    loadout.Loadout(
      hull: "sparrow",
      modules: [
        #("cockpit", "rijay.cockpit.sparrow"),
        #("bay", "rijay.bay.ranger"),
      ],
      parts: [
        #("engine_port", "rijay.engine.wren_90b"),
        #("engine_stbd", "rijay.engine.wren_90b"),
      ],
    )
  let assert Ok(_) = loadout.resolve(glyphs.default(), h, modules, parts, range)
  // Both at once: 2 + 2 + 9 = 13 of 12. Refused.
  let greedy = loadout.Loadout(..range, parts: three)
  let assert Error(e) =
    loadout.resolve(glyphs.default(), h, modules, parts, greedy)
  assert e == "tag_deficit:power"
}

/// Her mounts are `s`. Both Mockingbird engines are `m`, so the size rule
/// finally has shipped content to bite on.
pub fn a_medium_engine_does_not_fit_her_small_mount_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let lo =
    loadout.Loadout(..loadout.default_for(h), parts: [
      #("engine_port", "rijay.engine.stork_240c2"),
    ])
  let assert Error(e) = loadout.resolve(glyphs.default(), h, modules, parts, lo)
  assert e == "mount_too_small:engine_port"
}
