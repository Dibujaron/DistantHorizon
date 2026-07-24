import dh_server/deckplan
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/list
import gleam/option

// A 2x2-tile hull: a fixed corridor row on top, a two-tile slot-1 bay below.
// The bay's tiles carry SW digit "1"; the corridor tile above the bay's right
// half leaves its south edge OPEN so a module can put a door there.
//
// The corridor carries the two markers every resolved class needs: a helm
// console (the wall glyph "h" on tile (0,0)'s east side) and a docking port
// ("Q" at tile (1,0)) whose north door faces void off the top of the grid.
const hull_doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 96.0,
  \"provides\": { \"power\": 10 },
  \"requires\": { \"engine\": 1 },
  \"slots\": [ { \"digit\": 1, \"id\": \"bay\", \"name\": \"Bay\" } ],
  \"mounts\": [ { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" } ],
  \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" },
  \"decks\": [ { \"name\": \"Main\", \"grid\": [
    \"####=#\",
    \"# h Q#\",
    \"#### #\",
    \"#### #\",
    \"#    #\",
    \"1##1##\"
  ] } ]
}"

fn a_hull() -> hull.Hull {
  let assert Ok(h) = hull.decode(hull_doc)
  h
}

fn a_module(
  id: String,
  mass: String,
  requires: String,
  grid: String,
) -> module.Module {
  let assert Ok(m) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"" <> id <> "\", \"hull\": \"testhull\",
         \"slot\": \"bay\", \"name\": \"M\", \"mass\": " <> mass <> ",
         \"requires\": " <> requires <> ",
         \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 1, \"grid\": " <> grid <> " } ] }",
    )
  m
}

fn an_engine() -> part.Part {
  let assert Ok(p) =
    part.decode(
      "{ \"schema\": 1, \"id\": \"test.engine\", \"name\": \"E\",
         \"kind\": \"engine\", \"size\": \"m\", \"mass\": 24.0,
         \"provides\": { \"engine\": 1 }, \"requires\": { \"power\": 3 },
         \"thrust\": 4800.0, \"torque\": 21600.0 }",
    )
  p
}

fn registries(
  mods: List(module.Module),
) -> #(dict.Dict(String, module.Module), dict.Dict(String, part.Part)) {
  let by_id = dict.from_list(list.map(mods, fn(m) { #(m.id, m) }))
  #(by_id, dict.from_list([#("test.engine", an_engine())]))
}

fn fit_of(mods: List(module.Module), lo: loadout.Loadout) {
  let #(m, p) = registries(mods)
  loadout.resolve(glyphs.default(), a_hull(), m, p, lo)
}

fn bay_loadout(module_id: String) -> loadout.Loadout {
  loadout.Loadout(hull: "testhull", modules: [#("bay", module_id)], parts: [
    #("engine_center", "test.engine"),
  ])
}

pub fn void_cells_pass_through_test() {
  // A patch whose left tile is void and right tile is a pallet: the hull's
  // left bay tile survives untouched, the right one becomes a pallet.
  let m =
    a_module("m.void", "0.0", "{}", "[\"      \", \" .  p \", \"      \"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.void"))
  let assert Ok(g) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(left) = deckplan.cell_at_xy(g, 0, 1)
  let assert Ok(right) = deckplan.cell_at_xy(g, 1, 1)
  // Floor, not Void: the void patch cell did not overwrite the hull's tile.
  // (Checking `decor` alone would not catch a broken passthrough — a stamped
  // void centre has no decor either.)
  assert left.tile == deckplan.Floor
  assert left.decor == option.None
  assert right.decor == option.Some("p")
}

pub fn default_for_is_the_hulls_authored_loadout_test() {
  let assert Ok(h) =
    hull.decode(
      "{ \"schema\": 3, \"id\": \"testhull\", \"name\": \"T\", \"mass\": 1.0,
         \"default_loadout\": { \"modules\": { \"bay\": \"m.p\" },
                                \"parts\": { \"engine_center\": \"test.engine\" } },
         \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
         \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }",
    )
  assert loadout.default_for(h)
    == loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [
      #("engine_center", "test.engine"),
    ])
}

pub fn stamp_preserves_the_hull_slot_digit_test() {
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.p"))
  let assert Ok(g) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(c) = deckplan.cell_at_xy(g, 0, 1)
  // SW corner is hull-owned: the tile is still in slot 1 after the stamp.
  assert c.slot == option.Some(1)
}

pub fn derived_capacity_follows_the_stamp_test() {
  let empty = a_module("m.empty", "0.0", "{}", "[\"   \", \"   \", \"   \"]")
  let pallets =
    a_module("m.pallets", "0.0", "{}", "[\"      \", \" p  p \", \"      \"]")
  let assert Ok(a) = fit_of([empty, pallets], bay_loadout("m.empty"))
  let assert Ok(b) = fit_of([empty, pallets], bay_loadout("m.pallets"))
  assert a.class.cargo_capacity == 0
  assert b.class.cargo_capacity == 2
}

pub fn flight_is_thrust_over_total_mass_test() {
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.p"))
  // hull 96 + module 0 + engine 24 = 120; 4800/120 = 40, 21600/120 = 180.
  assert fit.mass == 120.0
  assert fit.class.flight.accel == 40.0
  assert fit.class.flight.turn_rate == 180.0
}

pub fn heavier_module_is_slower_test() {
  let light = a_module("m.light", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let heavy = a_module("m.heavy", "40.0", "{}", "[\"   \", \" p \", \"   \"]")
  let assert Ok(a) = fit_of([light, heavy], bay_loadout("m.light"))
  let assert Ok(b) = fit_of([light, heavy], bay_loadout("m.heavy"))
  assert b.class.flight.accel <. a.class.flight.accel
}

pub fn out_of_slot_bounds_is_rejected_test() {
  // y=0 is the fixed corridor row, not slot 1.
  let assert Ok(m) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"m.trespass\", \"hull\": \"testhull\",
         \"slot\": \"bay\", \"name\": \"M\",
         \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 0, \"grid\": [\"   \", \" p \", \"   \"] } ] }",
    )
  let assert Error(e) = fit_of([m], bay_loadout("m.trespass"))
  assert e == "out_of_slot_bounds:m.trespass"
}

pub fn tag_deficit_is_rejected_test() {
  let hog =
    a_module("m.hog", "0.0", "{ \"power\": 99 }", "[\"   \", \" p \", \"   \"]")
  let assert Error(e) = fit_of([hog], bay_loadout("m.hog"))
  assert e == "tag_deficit:power"
}

pub fn missing_engine_is_rejected_test() {
  // The hull requires {"engine": 1} and nothing provides it.
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let bare =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [])
  let #(mods, parts) = registries([m])
  let assert Error(e) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, bare)
  assert e == "tag_deficit:engine"
}

pub fn unknown_slot_and_module_are_rejected_test() {
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let #(mods, parts) = registries([m])
  let bad_slot =
    loadout.Loadout(hull: "testhull", modules: [#("nope", "m.p")], parts: [])
  let assert Error(a) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, bad_slot)
  assert a == "slot_not_on_hull:nope"
  let bad_module =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.nope")], parts: [])
  let assert Error(b) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, bad_module)
  assert b == "unknown_module:m.nope"
}

pub fn two_modules_in_one_slot_are_rejected_test() {
  let a = a_module("m.a", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let b = a_module("m.b", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let lo =
    loadout.Loadout(
      hull: "testhull",
      modules: [#("bay", "m.a"), #("bay", "m.b")],
      parts: [#("engine_center", "test.engine")],
    )
  let assert Error(e) = fit_of([a, b], lo)
  assert e == "duplicate_slot:bay"
}

pub fn oversized_part_is_rejected_test() {
  let assert Ok(big) =
    part.decode(
      "{ \"schema\": 1, \"id\": \"test.bigengine\", \"name\": \"E\",
         \"kind\": \"engine\", \"size\": \"l\", \"mass\": 1.0,
         \"provides\": { \"engine\": 1 }, \"thrust\": 1.0, \"torque\": 1.0 }",
    )
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let #(mods, _) = registries([m])
  let parts = dict.from_list([#("test.bigengine", big)])
  let lo =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [
      #("engine_center", "test.bigengine"),
    ])
  let assert Error(e) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, lo)
  assert e == "mount_too_small:engine_center"
}
