//// The carve's arbiter: the Mockingbird's DEFAULT LOADOUT must resolve to the
//// exact deck she had before M4 split her into a hull plus five modules.
//// `test/fixtures/mockingbird_authored.json` is that frozen pre-M4 map; every
//// tile, edge, decor glyph and colour of the resolved plan is compared against
//// it. Modules are per-hull authored overlays precisely so a refit never turns
//// her hand-authored interior into snapped-together boxes — this test is what
//// makes that promise checkable.

import dh_server/deckplan
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/float
import gleam/list
import gleam/option
import simplifile

fn resolved_default() -> loadout.Fit {
  let reg = glyphs.default()
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(reg, h, mods, parts, loadout.default_for(h))
  fit
}

/// The frozen pre-M4 authored map, parsed. The carve is only correct if the
/// default loadout reproduces it tile for tile.
fn authored_plan() -> deckplan.DeckPlan {
  let assert Ok(text) =
    simplifile.read("test/fixtures/mockingbird_authored.json")
  let assert Ok(h) = hull.decode(text)
  let assert Ok(plan) = deckplan.from_rows(glyphs.default(), h.decks)
  plan
}

/// Slot digits are new structure the frozen map does not have, so compare with
/// them stripped — everything else (tile kind, all four edges, decor, colour,
/// consoles, spawn) must match exactly.
fn strip_slots(plan: deckplan.DeckPlan) -> deckplan.DeckPlan {
  deckplan.DeckPlan(
    ..plan,
    decks: list.map(plan.decks, fn(g) {
      deckplan.DeckGrid(
        ..g,
        cells: list.map(g.cells, fn(row) {
          list.map(row, fn(c) { deckplan.Cell(..c, slot: option.None) })
        }),
      )
    }),
  )
}

pub fn default_loadout_reproduces_the_authored_deck_test() {
  assert strip_slots(resolved_default().class.plan)
    == strip_slots(authored_plan())
}

pub fn default_capacity_is_still_sixty_test() {
  assert resolved_default().class.cargo_capacity == 60
}

pub fn default_flight_derives_from_hull_and_module_masses_test() {
  let fit = resolved_default()
  assert float.loosely_equals(
    fit.class.flight.accel,
    42.76315789473684,
    tolerating: 0.001,
  )
  assert float.loosely_equals(
    fit.class.flight.turn_rate,
    141.44736842105263,
    tolerating: 0.001,
  )
}

pub fn swapping_the_hold_for_a_tank_drops_capacity_test() {
  let reg = glyphs.default()
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let base = loadout.default_for(h)
  let swapped =
    loadout.Loadout(
      ..base,
      modules: list.map(base.modules, fn(entry) {
        case entry.0 == "hold" {
          True -> #("hold", "mockingbird.hold.tank")
          False -> entry
        }
      }),
    )
  let assert Ok(fit) = loadout.resolve(reg, h, mods, parts, swapped)
  assert fit.class.cargo_capacity < 60
}

/// The point of module targets: one document furnishes every cabin on the
/// ship. If this ever needs a second file, the change did not work.
pub fn one_cabin_document_serves_every_cabin_slot_test() {
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(cabin) = dict.get(mods, "rijay.cabin.standard")
  let slots =
    list.filter_map(cabin.targets, fn(t) {
      case t.hull == "mockingbird" {
        True -> Ok(t.slots)
        False -> Error(Nil)
      }
    })
    |> list.flatten
  assert list.length(slots) == 5
  // And the default loadout actually installs it in all five.
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let installed =
    list.filter(loadout.default_for(h).modules, fn(e) {
      e.1 == "rijay.cabin.standard"
    })
  assert list.length(installed) == 5
}

pub fn every_shipped_module_resolves_in_its_slot_test() {
  let reg = glyphs.default()
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let base = loadout.default_for(h)
  // Every shipped module's mockingbird target, installed alone in its own slot
  // over the default fit, must resolve — the cheapest guard against a patch
  // drifting off its slot. A module with several targets on this hull (a
  // standard cabin stamped into five different bays, say) has to prove every
  // one of them, not just the first — otherwise four of five placements would
  // drift unnoticed. Filtered to this hull: a module is authored per (hull,
  // slot) target, so a Sparrow or Finch module arriving later would otherwise
  // fail here as `module_not_drawn_for_slot` rather than being skipped.
  dict.to_list(mods)
  |> list.flat_map(fn(entry) {
    let #(id, m) = entry
    list.filter(m.targets, fn(t) { t.hull == "mockingbird" })
    |> list.map(fn(t) { #(id, t) })
  })
  |> list.each(fn(entry) {
    let #(id, target) = entry
    // Every module shipped today claims exactly one slot per target, so
    // installing it under the first (only) one is enough to prove the
    // target's patch lands in bounds.
    let assert [slot_id, ..] = target.slots
    let swapped =
      loadout.Loadout(
        ..base,
        modules: list.map(base.modules, fn(e) {
          case e.0 == slot_id {
            True -> #(slot_id, id)
            False -> e
          }
        }),
      )
    // `list.map` only REPLACES: a module whose slot has no default entry
    // would leave the loadout identical to the default, and the resolve
    // below would pass without ever installing the module under test.
    assert list.contains(swapped.modules, #(slot_id, id))
    let assert Ok(_) = loadout.resolve(reg, h, mods, parts, swapped)
  })
}

/// Her art has three nozzle anchors and always has. The default loadout is
/// now the lore verbatim: "a Consol center engine shoved between two Rijay
/// originals".
pub fn she_flies_on_three_engines_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  assert list.length(h.mounts) == 3
  // `hull.sorted_pairs` orders a decoded loadout by id, not JSON key order —
  // alphabetically, that's centre, port, stbd.
  assert h.default_parts
    == [
      #("engine_center", "consol.engine.co17f_2"),
      #("engine_port", "rijay.engine.stork_240c2"),
      #("engine_stbd", "rijay.engine.stork_240c2"),
    ]
}

/// Zero headroom, and now it bites: you cannot fix the Company's patch
/// without first fixing what feeds it. This is the "putting it right" early
/// game enforced by the validator rather than by narration, and it is the
/// only `tag_deficit:power` reachable through shipped content.
pub fn upgrading_the_centre_engine_overdraws_her_reactor_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let stock = loadout.default_for(h)
  // Swap the cheap Consol Mule for a proper Rijay Stork: draw 26 vs 25.
  let greedy =
    loadout.Loadout(..stock, parts: [
      #("engine_port", "rijay.engine.stork_240c2"),
      #("engine_center", "rijay.engine.stork_240c2"),
      #("engine_stbd", "rijay.engine.stork_240c2"),
    ])
  let assert Error(e) =
    loadout.resolve(glyphs.default(), h, modules, parts, greedy)
  assert e == "tag_deficit:power"
  // ...and the stock fit sits at exactly zero headroom.
  let assert Ok(_) = loadout.resolve(glyphs.default(), h, modules, parts, stock)
}
