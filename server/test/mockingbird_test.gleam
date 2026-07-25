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

pub fn default_flight_matches_the_pre_m4_constants_test() {
  let fit = resolved_default()
  assert fit.class.flight.accel == 40.0
  assert fit.class.flight.turn_rate == 180.0
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

pub fn every_shipped_module_resolves_in_its_slot_test() {
  let reg = glyphs.default()
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let base = loadout.default_for(h)
  // Each shipped module, installed alone in its own slot over the default fit,
  // must resolve — the cheapest guard against a patch drifting off its slot.
  dict.to_list(mods)
  |> list.each(fn(entry) {
    let #(id, m) = entry
    let swapped =
      loadout.Loadout(
        ..base,
        modules: list.map(base.modules, fn(e) {
          case e.0 == m.slot {
            True -> #(m.slot, id)
            False -> e
          }
        }),
      )
    let assert Ok(_) = loadout.resolve(reg, h, mods, parts, swapped)
  })
}
