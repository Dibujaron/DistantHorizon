import dh_server/deckplan
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/list
import gleam/option

// A 2x2-tile hull: a fixed corridor row on top, a two-tile bay below whose
// tiles carry centre marker "B"; the corridor tile above the bay's right
// half leaves its south edge OPEN so a module can put a door there.
//
// The corridor carries the two markers every resolved class needs: a helm
// console (the wall glyph "h" on tile (0,0)'s east side) and a docking port
// ("q" at tile (1,0)) whose north door faces void off the top of the grid.
const hull_doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 96.0,
  \"provides\": { \"power\": 10 },
  \"requires\": { \"engine\": 1 },
  \"slots\": [ { \"marker\": \"B\", \"id\": \"bay\", \"name\": \"Bay\" } ],
  \"mounts\": [ { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" } ],
  \"cargo\": { \"capacity\": 7, \"handling\": \"breakbulk\" },
  \"decks\": [ { \"name\": \"Main\", \"grid\": [
    \"####=#\",
    \"# h q#\",
    \"#### #\",
    \"#### #\",
    \"#B  B#\",
    \"######\"
  ] } ]
}"

// The same hull with the corridor's helm glyph removed. A resolved class MUST
// carry a helm console, so on this hull the console can only come from a
// module — which is exactly the engine's headline promise under test.
const hull_no_helm_doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 96.0,
  \"provides\": { \"power\": 10 },
  \"requires\": { \"engine\": 1 },
  \"slots\": [ { \"marker\": \"B\", \"id\": \"bay\", \"name\": \"Bay\" } ],
  \"mounts\": [ { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" } ],
  \"cargo\": { \"capacity\": 7, \"handling\": \"breakbulk\" },
  \"decks\": [ { \"name\": \"Main\", \"grid\": [
    \"####=#\",
    \"#   q#\",
    \"#### #\",
    \"#### #\",
    \"#B  B#\",
    \"######\"
  ] } ]
}"

fn a_hull() -> hull.Hull {
  let assert Ok(h) = hull.decode(hull_doc)
  h
}

fn a_hull_without_a_helm() -> hull.Hull {
  let assert Ok(h) = hull.decode(hull_no_helm_doc)
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

fn engine_registry() -> dict.Dict(String, part.Part) {
  dict.from_list([#("test.engine", an_engine())])
}

fn registries(
  mods: List(module.Module),
) -> #(dict.Dict(String, module.Module), dict.Dict(String, part.Part)) {
  let by_id = dict.from_list(list.map(mods, fn(m) { #(m.id, m) }))
  #(by_id, engine_registry())
}

fn fit_on(h: hull.Hull, mods: List(module.Module), lo: loadout.Loadout) {
  let #(m, p) = registries(mods)
  loadout.resolve(glyphs.default(), h, m, p, lo)
}

fn fit_of(mods: List(module.Module), lo: loadout.Loadout) {
  fit_on(a_hull(), mods, lo)
}

fn bay_loadout(module_id: String) -> loadout.Loadout {
  loadout.Loadout(hull: "testhull", modules: [#("bay", module_id)], parts: [
    #("engine_center", "test.engine"),
  ])
}

pub fn a_module_supplies_its_own_wall_console_test() {
  // THE promise the module engine exists to keep: install a cockpit and the
  // helm console exists because the glyph does. `h` is an EDGE glyph — a
  // wall-mounted console operated from the floor tile it faces — so this only
  // works if the stamp writes the tile's edge characters, not just its centre.
  //
  // The hull here has no helm of its own, and a resolved class without one is
  // rejected, so the console cannot leak in from anywhere but the module.
  let cockpit =
    a_module("m.cockpit", "0.0", "{}", "[\"###\", \"# h\", \"###\"]")
  let bare = a_module("m.bare", "0.0", "{}", "[\"   \", \"   \", \"   \"]")
  let h = a_hull_without_a_helm()

  let assert Ok(fit) = fit_on(h, [cockpit, bare], bay_loadout("m.cockpit"))
  let assert Ok(helm) = deckplan.find_console_of_kind(fit.class.plan, "helm")
  // Derived from the stamped map, at the bay tile whose east wall it is.
  assert helm.deck == 0
  assert #(helm.x, helm.y) == #(0, 1)

  // The control: the same hull and the same slot, a module that draws nothing,
  // and the class no longer has a helm at all.
  let assert Error(e) = fit_on(h, [cockpit, bare], bay_loadout("m.bare"))
  assert e == "invalid_resolved_plan:no console of kind \"helm\""
}

pub fn the_stamp_writes_edges_in_the_right_orientation_test() {
  // An ASYMMETRIC patch: a door on the NORTH edge only, walls elsewhere. A
  // symmetric fixture could not catch a transposed row/column in the block
  // copy — north sits at (row 0, col 1) and west at (row 1, col 0), so
  // swapping them would put this door on the west wall instead.
  let m = a_module("m.door", "0.0", "{}", "[\"#=#\", \"# #\", \"###\"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.door"))
  let assert Ok(g) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(c) = deckplan.cell_at_xy(g, 0, 1)
  // The hull authored this tile as #(Wall, Open, Wall, Wall); the module now
  // owns all four sides of it.
  assert c.edges
    == #(deckplan.Door, deckplan.Wall, deckplan.Wall, deckplan.Wall)
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

/// The NE colour corner and the slot marker are asymmetric in who owns them
/// post-stamp — but no longer in the way the old name of this test claimed.
/// The marker moved into the CENTRE (M4), which is one of the eight cells a
/// stamp DOES overwrite, so it does NOT survive being fitted: this is
/// intended (docs/deckplan-format.md, "Slots") — a hull document is always
/// loaded alongside a resolved plan, and tile coordinates index both grids
/// identically, so slot membership is read off the hull, never the fit.
pub fn the_module_owns_the_ne_color_and_the_hull_document_owns_the_slot_marker_test() {
  // The patch writes "4" into its NE corner and leaves its own centre a
  // pallet; the hull's bay tile has no colour digit and carries slot marker
  // "B" on its OWN document, not on the stamped one.
  let m = a_module("m.p", "0.0", "{}", "[\"  4\", \" p \", \"   \"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.p"))
  let assert Ok(g) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(c) = deckplan.cell_at_xy(g, 0, 1)
  // NE corner is module-owned: a module repaints the bay it is installed in.
  assert c.color == option.Some(4)
  // The centre marker does NOT survive the stamp: the module's patch owns
  // the centre like any other non-SW cell, and this one draws a pallet.
  assert c.slot == option.None
  // Slot membership is still authoritative on the hull document itself.
  let assert Ok(bare) = deckplan.from_rows(glyphs.default(), a_hull().decks)
  let assert Ok(hull_deck) = deckplan.deck_at(bare, 0)
  let assert Ok(hull_cell) = deckplan.cell_at_xy(hull_deck, 0, 1)
  assert hull_cell.slot == option.Some("B")
}

pub fn derived_capacity_follows_the_stamp_test() {
  // The hull authors a distinctive fallback of 7, so "derived from the stamp"
  // and "fell back to the hull" are told apart by the number itself.
  let empty = a_module("m.empty", "0.0", "{}", "[\"   \", \"   \", \"   \"]")
  let pallets =
    a_module("m.pallets", "0.0", "{}", "[\"      \", \" p  p \", \"      \"]")
  let assert Ok(a) = fit_of([empty, pallets], bay_loadout("m.empty"))
  let assert Ok(b) = fit_of([empty, pallets], bay_loadout("m.pallets"))
  // Nothing on the stamped map draws a pallet, so the hull's fallback stands.
  assert a.class.cargo_capacity == 7
  // Two pallets drawn by the module beat the fallback outright.
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

pub fn a_loadout_for_another_hull_is_rejected_test() {
  // The first thing `resolve` checks: this loadout names a hull that is not
  // the one it is being resolved against, so nothing else about it matters.
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let lo =
    loadout.Loadout(hull: "otherhull", modules: [#("bay", "m.p")], parts: [
      #("engine_center", "test.engine"),
    ])
  let assert Error(e) = fit_of([m], lo)
  assert e == "loadout_wrong_hull:otherhull"
}

pub fn a_module_in_the_wrong_slot_is_rejected_test() {
  // The module declares this hull, but declares itself a HOLD module; the
  // loadout tries to install it in the bay. Distinct from
  // `slot_not_on_hull` — the slot exists, it is just not this module's.
  let assert Ok(m) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"m.hold\", \"hull\": \"testhull\",
         \"slot\": \"hold\", \"name\": \"M\",
         \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 1,
                          \"grid\": [\"   \", \" p \", \"   \"] } ] }",
    )
  let assert Error(e) = fit_of([m], bay_loadout("m.hold"))
  assert e == "module_not_drawn_for_slot:m.hold"
}

pub fn an_unknown_mount_and_an_unknown_part_are_rejected_test() {
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let #(mods, parts) = registries([m])
  // The hull's only mount is `engine_center`.
  let bad_mount =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [
      #("nose", "test.engine"),
    ])
  let assert Error(a) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, bad_mount)
  assert a == "mount_not_on_hull:nose"

  let bad_part =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [
      #("engine_center", "test.nope"),
    ])
  let assert Error(b) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, bad_part)
  assert b == "unknown_part:test.nope"
}

pub fn two_parts_on_one_mount_are_rejected_test() {
  // The mount half of `duplicate_slot`: naming the same mount twice is a
  // malformed loadout, not a silent last-one-wins.
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let lo =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [
      #("engine_center", "test.engine"),
      #("engine_center", "test.engine"),
    ])
  let assert Error(e) = fit_of([m], lo)
  assert e == "duplicate_mount:engine_center"
}

pub fn a_part_of_the_wrong_kind_is_rejected_test() {
  // A gun on an engine mount. It is small enough to fit — the refusal is
  // about KIND, which is checked before size.
  let assert Ok(gun) =
    part.decode(
      "{ \"schema\": 1, \"id\": \"test.gun\", \"name\": \"G\",
         \"kind\": \"gun\", \"size\": \"s\", \"mass\": 1.0,
         \"provides\": { \"engine\": 1 } }",
    )
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let #(mods, _) = registries([m])
  let lo =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [
      #("engine_center", "test.gun"),
    ])
  let assert Error(e) =
    loadout.resolve(
      glyphs.default(),
      a_hull(),
      mods,
      dict.from_list([#("test.gun", gun)]),
      lo,
    )
  assert e == "mount_wrong_kind:engine_center"
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

pub fn a_patch_running_off_the_grid_is_rejected_test() {
  // Distinct from the wrong-slot case: the right-hand tile of this two-tile
  // patch lands at x=2 on a two-tile-wide deck, so there is no cell to check
  // its slot marker against at all.
  let assert Ok(m) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"m.overhang\", \"hull\": \"testhull\",
         \"slot\": \"bay\", \"name\": \"M\",
         \"patches\": [ { \"deck\": 0, \"x\": 1, \"y\": 1,
                          \"grid\": [\"      \", \" p  p \", \"      \"] } ] }",
    )
  let assert Error(e) = fit_of([m], bay_loadout("m.overhang"))
  assert e == "out_of_slot_bounds:m.overhang"
}

pub fn a_massless_fit_is_rejected_test() {
  // Nothing forbids a negative module mass, and hull 96 + module -120 +
  // engine 24 cancels exactly — flight numbers would divide by zero.
  let ballast =
    a_module("m.antimass", "-120.0", "{}", "[\"   \", \" p \", \"   \"]")
  let assert Error(e) = fit_of([ballast], bay_loadout("m.antimass"))
  assert e == "zero_mass"
}

// ------------------------------------------------------- content errors --
//
// These three reasons mean a DATA FILE is malformed, not that the player asked
// for an illegal fit (see the `resolve` doc comment). They are pinned by exact
// string so they cannot quietly drift into the player-facing refusal
// vocabulary.

pub fn a_hull_mount_with_a_junk_size_is_a_content_error_test() {
  let assert Ok(h) =
    hull.decode(
      "{ \"schema\": 3, \"id\": \"testhull\", \"name\": \"T\", \"mass\": 96.0,
         \"mounts\": [ { \"id\": \"engine_center\", \"kind\": \"engine\",
                         \"size\": \"xl\" } ],
         \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
         \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }",
    )
  let lo =
    loadout.Loadout(hull: "testhull", modules: [], parts: [
      #("engine_center", "test.engine"),
    ])
  let #(mods, parts) = registries([])
  let assert Error(e) = loadout.resolve(glyphs.default(), h, mods, parts, lo)
  assert e == "mount_bad_size:engine_center"
}

pub fn a_part_with_a_junk_size_is_a_content_error_test() {
  // `part.decode` rejects a bad size at load, so this arm is defence in depth
  // against a Part reaching the engine another way; build the record directly.
  let bad =
    part.Part(
      schema: 1,
      id: "test.badsize",
      name: "E",
      kind: "engine",
      size: "xl",
      mass: 1.0,
      provides: dict.from_list([#("engine", 1)]),
      requires: dict.new(),
      thrust: 1.0,
      torque: 1.0,
      sprite: option.None,
    )
  let lo =
    loadout.Loadout(hull: "testhull", modules: [], parts: [
      #("engine_center", "test.badsize"),
    ])
  let assert Error(e) =
    loadout.resolve(
      glyphs.default(),
      a_hull(),
      dict.new(),
      dict.from_list([#("test.badsize", bad)]),
      lo,
    )
  assert e == "part_bad_size:test.badsize"
}

pub fn a_hull_whose_own_rows_do_not_parse_is_a_content_error_test() {
  // `hull.decode` keeps deck grids as raw TEXT, so a malformed hull document
  // loads happily and only fails when `resolve` parses it — distinct from
  // `invalid_resolved_plan`, which is the same parse run on the STAMPED rows.
  // These rows are 4 characters wide, and a v3 tile is 3 characters.
  let assert Ok(h) =
    hull.decode(
      "{ \"schema\": 3, \"id\": \"testhull\", \"name\": \"T\", \"mass\": 1.0,
         \"decks\": [ { \"name\": \"M\", \"grid\": [\"####\", \"#  #\", \"####\"] } ],
         \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }",
    )
  let lo = loadout.Loadout(hull: "testhull", modules: [], parts: [])
  let assert Error(e) =
    loadout.resolve(glyphs.default(), h, dict.new(), dict.new(), lo)
  assert e
    == "invalid_hull_plan:deck \"M\" row length is not a positive multiple of 3"
}

pub fn a_patch_naming_a_deck_the_hull_lacks_is_a_content_error_test() {
  // The test hull has exactly one deck; this module patches deck 9.
  let assert Ok(m) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"m.deck9\", \"hull\": \"testhull\",
         \"slot\": \"bay\", \"name\": \"M\",
         \"patches\": [ { \"deck\": 9, \"x\": 0, \"y\": 1,
                          \"grid\": [\"   \", \" p \", \"   \"] } ] }",
    )
  let assert Error(e) = fit_of([m], bay_loadout("m.deck9"))
  assert e == "patch_bad_deck:m.deck9"
}

// ------------------------------------------------------ multi-slot targets --

// `hull_doc`'s bay, split into two adjacent single-tile slots so a module can
// be drawn to claim both at once. Only the centre markers differ.
const hull_two_slots_doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 96.0,
  \"provides\": { \"power\": 10 },
  \"requires\": { \"engine\": 1 },
  \"slots\": [ { \"marker\": \"B\", \"id\": \"bay_a\", \"name\": \"Bay A\" },
               { \"marker\": \"C\", \"id\": \"bay_b\", \"name\": \"Bay B\" } ],
  \"mounts\": [ { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" } ],
  \"cargo\": { \"capacity\": 7, \"handling\": \"breakbulk\" },
  \"decks\": [ { \"name\": \"Main\", \"grid\": [
    \"####=#\",
    \"# h q#\",
    \"#### #\",
    \"#### #\",
    \"#B  C#\",
    \"######\"
  ] } ]
}"

// Two tiles wide, claiming both slots with one overlay.
const wide_module_doc = "{
  \"schema\": 1, \"id\": \"m.wide\", \"name\": \"Wide bay\", \"mass\": 0.0,
  \"targets\": [ { \"hull\": \"testhull\", \"slots\": [\"bay_a\", \"bay_b\"],
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 1,
                     \"grid\": [\"      \", \" p  p \", \"      \"] } ] } ] }"

// One tile, claiming only the right-hand slot.
const narrow_b_doc = "{
  \"schema\": 1, \"id\": \"m.narrow_b\", \"name\": \"Narrow\", \"mass\": 0.0,
  \"targets\": [ { \"hull\": \"testhull\", \"slots\": [\"bay_b\"],
    \"patches\": [ { \"deck\": 0, \"x\": 1, \"y\": 1,
                     \"grid\": [\"   \", \" p \", \"   \"] } ] } ] }"

// Claims only bay_a, but its overlay reaches into bay_b.
const escaping_module_doc = "{
  \"schema\": 1, \"id\": \"m.escape\", \"name\": \"Escape\", \"mass\": 0.0,
  \"targets\": [ { \"hull\": \"testhull\", \"slots\": [\"bay_a\"],
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 1,
                     \"grid\": [\"      \", \" p  p \", \"      \"] } ] } ] }"

// Claims bay_a plus a slot id that is not on the hull at all — a typo.
const typo_module_doc = "{
  \"schema\": 1, \"id\": \"m.typo\", \"name\": \"Typo\", \"mass\": 0.0,
  \"targets\": [ { \"hull\": \"testhull\", \"slots\": [\"bay_a\", \"nope\"],
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 1,
                     \"grid\": [\"      \", \" p  p \", \"      \"] } ] } ] }"

fn two_slot_fit(
  module_docs: List(String),
  lo: loadout.Loadout,
) -> Result(loadout.Fit, String) {
  let assert Ok(h) = hull.decode(hull_two_slots_doc)
  let mods =
    dict.from_list(
      list.map(module_docs, fn(doc) {
        let assert Ok(m) = module.decode(doc)
        #(m.id, m)
      }),
    )
  loadout.resolve(glyphs.default(), h, mods, engine_registry(), lo)
}

/// A module may claim several adjacent slots with one overlay — that is how a
/// bigger room absorbs the one next door. Naming it in the loadout under one
/// of its slots occupies all of them.
pub fn a_multi_slot_module_occupies_every_slot_it_claims_test() {
  let lo =
    loadout.Loadout(hull: "testhull", modules: [#("bay_a", "m.wide")], parts: [
      #("engine_center", "test.engine"),
    ])
  let assert Ok(fit) = two_slot_fit([wide_module_doc], lo)
  let assert Ok(g) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(left) = deckplan.cell_at_xy(g, 0, 1)
  let assert Ok(right) = deckplan.cell_at_xy(g, 1, 1)
  // The overlay landed in BOTH slots from a single loadout entry.
  assert left.decor == option.Some("p")
  assert right.decor == option.Some("p")
}

/// The slots a multi-slot module claims are not free for anything else.
pub fn another_module_cannot_claim_an_occupied_slot_test() {
  let lo =
    loadout.Loadout(
      hull: "testhull",
      modules: [#("bay_a", "m.wide"), #("bay_b", "m.narrow_b")],
      parts: [#("engine_center", "test.engine")],
    )
  let assert Error(e) = two_slot_fit([wide_module_doc, narrow_b_doc], lo)
  assert e == "duplicate_slot:bay_b"
}

/// Claiming one slot does not license writing into its neighbour.
pub fn a_multi_slot_patch_still_cannot_escape_its_slots_test() {
  let lo =
    loadout.Loadout(hull: "testhull", modules: [#("bay_a", "m.escape")], parts: [
      #("engine_center", "test.engine"),
    ])
  let assert Error(e) = two_slot_fit([escaping_module_doc], lo)
  assert e == "out_of_slot_bounds:m.escape"
}

/// A mistyped id in a multi-slot target's `slots` must be loud, not silently
/// dropped from the marker set it backs — but this is a CONTENT bug (the
/// module document is wrong), not a loadout refusal, so it gets its own
/// reason naming the module rather than reusing `slot_not_on_hull` (which
/// names a slot the player's loadout entry asked for).
pub fn a_typo_in_a_multi_slot_targets_slots_is_rejected_test() {
  let lo =
    loadout.Loadout(hull: "testhull", modules: [#("bay_a", "m.typo")], parts: [
      #("engine_center", "test.engine"),
    ])
  let assert Error(e) = two_slot_fit([typo_module_doc], lo)
  assert e == "target_slot_not_on_hull:m.typo"
}
