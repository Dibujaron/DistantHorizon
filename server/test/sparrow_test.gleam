import dh_server/deckplan
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/list
import gleam/option

/// One deck, no stairs, no mezzanine. Every deck-linking rule we have was
/// written against a three-deck ship; she is the first hull that has none.
pub fn she_is_a_single_deck_hull_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  assert h.id == "sparrow"
  assert list.length(h.decks) == 1
  assert list.length(h.slots) == 3
}

/// The fore slot ships EMPTY: `docs/lore.md` is explicit that she has no bed
/// unless you fit one, so `default_loadout` names only `cockpit` and `bay`.
/// She already carried the first unfitted MOUNT on any hull (`engine_center`);
/// this makes her the first with an unfitted SLOT, which nothing else on disk
/// exercises. The hull's own floor stands where the module would have gone.
pub fn she_resolves_with_the_fore_slot_empty_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let lo = loadout.default_for(h)
  assert list.length(lo.modules) == 2
  let assert Ok(_) = loadout.resolve(glyphs.default(), h, modules, parts, lo)
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
  assert fit.class.cargo_capacity == 6
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
        #("cockpit", "rijay.cockpit.solo_3x1"),
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
        #("cockpit", "rijay.cockpit.solo_3x1"),
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

/// The fore bay is a genuine refit decision and the power budget is what makes
/// it one. She provides 12: cockpit 2 + packet 1 leaves 9, which is exactly
/// three Wrens. Fitting the bunk spends one of those, so a bunk and a third
/// engine cannot coexist — speed or a place to sleep, never both.
pub fn the_fore_bunk_fits_beside_two_engines_but_not_three_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let with_bunk = [
    #("cockpit", "rijay.cockpit.solo_3x1"),
    #("bay", "rijay.bay.packet"),
    #("fore", "rijay.fore.bunk"),
  ]
  // Two engines: cockpit 2 + packet 1 + bunk 1 + engines 6 = 10 of 12.
  let liveaboard =
    loadout.Loadout(hull: "sparrow", modules: with_bunk, parts: [
      #("engine_port", "rijay.engine.wren_90b"),
      #("engine_stbd", "rijay.engine.wren_90b"),
    ])
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, modules, parts, liveaboard)
  // The positive half of the corridor guarantee: with the fore bunk actually
  // fitted, (2,2) must come out of the bake as plain hull floor, in no slot,
  // with open north and south edges. If `stamp` is ever refactored to fold
  // over a patch's full tile extent and skip only a void tile's centre
  // character, a fore module could still wall this tile off and seal the
  // helm from the hold — and every other test here would stay green.
  let assert Ok(corridor_deck) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(corridor) = deckplan.cell_at_xy(corridor_deck, 2, 2)
  assert corridor.tile == deckplan.Floor
  assert corridor.slot == option.None
  assert !deckplan.edge_blocks(corridor_deck, 2, 2, deckplan.N)
  assert !deckplan.edge_blocks(corridor_deck, 2, 2, deckplan.S)
  // Three engines: 2 + 1 + 1 + 9 = 13 of 12. Refused.
  let greedy =
    loadout.Loadout(..liveaboard, parts: [
      #("engine_port", "rijay.engine.wren_90b"),
      #("engine_center", "rijay.engine.wren_90b"),
      #("engine_stbd", "rijay.engine.wren_90b"),
    ])
  let assert Error(e) =
    loadout.resolve(glyphs.default(), h, modules, parts, greedy)
  assert e == "tag_deficit:power"
}

/// Her spine is hull, not slot. The fore row's centre tile carries no slot
/// digit, so `check_bounds` refuses any fore module whose overlay puts a
/// non-void centre glyph there — the corridor between cockpit and hold cannot
/// be paved by a refit, and the refusal is a CONTENT error naming the file at
/// fault. This is the single-deck equivalent of the stairs invariants: nothing
/// does reachability analysis, so the geometry has to be unbuildable rather
/// than merely discouraged.
pub fn a_fore_module_may_not_pave_the_corridor_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  // Differs from the shipped bunk only in the middle tile's centre glyph: a
  // floor space rather than void. That one character is the one `is_void`
  // reads, so the stamp claims a tile the hull never offered.
  let assert Ok(trespasser) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"test.fore.greedy\", \"hull\": \"sparrow\",
         \"slot\": \"fore\", \"name\": \"Greedy\", \"mass\": 1.0,
         \"requires\": {},
         \"patches\": [ { \"deck\": 0, \"x\": 1, \"y\": 2,
           \"grid\": [\"###...###\", \"#d=   =e#\", \" # ... # \"] } ] }",
    )
  let modules = dict.insert(modules, trespasser.id, trespasser)
  let lo =
    loadout.Loadout(..loadout.default_for(h), modules: [
      #("cockpit", "rijay.cockpit.solo_3x1"),
      #("bay", "rijay.bay.packet"),
      #("fore", "test.fore.greedy"),
    ])
  let assert Error(e) = loadout.resolve(glyphs.default(), h, modules, parts, lo)
  assert e == "out_of_slot_bounds:test.fore.greedy"
}
