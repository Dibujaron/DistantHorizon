# M4 Iteration 2: Portable Modules and the Mockingbird Re-carve

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one module document serve many `(hull, slot)` placements, let a module claim several adjacent slots, and re-carve the Mockingbird so her rooms are slots — five standard cabins served by a single `rijay.cabin.standard` document, a central payload bay, a crew commons, and a modular engine room.

**Architecture:** A module document gains a list of **targets**, each naming a hull, the slot(s) it claims there, and its own hand-drawn overlay. Nothing about the authored-overlay bet changes — every target is still drawn by hand against one specific hull's coordinates. What changes is file organisation: one document per *concept* instead of one per *placement*. The validator stays a per-cell slot-digit check with no geometry.

**Tech Stack:** Gleam (Erlang target) server, gleeunit, JSON data validated by jesse schemas, Python/pytest protocol harness.

## Why this before the Sparrow and Finch

The Mockingbird alone wants five 1×2 crew cabins of identical size, shape and layout. Under the current one-`(hull, slot)`-per-document rule that is five near-identical files, and the Sparrow and Finch will each want more. Authoring two new hulls against a rule we already know is wrong means reworking them immediately after. So the rule changes first, the Mockingbird proves it, and the new hulls are authored once, correctly.

This restores what `docs/modules.md` originally specified — "a module lists the `(hull, slot)` pairs it is drawn for and carries a separate overlay per pair" — which the iteration-1 implementation simplified away, after which the doc was amended to match the code rather than the reverse.

## Global Constraints

- **Free placement is refused.** A module is never positioned at runtime. Every overlay is authored at a fixed origin against a known hull, which is what guarantees its doors line up. Placement would mean coordinates in the loadout, overlap detection and fit checks — the shape-matching problem per-hull overlays exist to delete.
- **The validator never does geometry.** It stays `sum(provides) >= sum(requires)` pooled per tag, plus: each slot claimed by at most one module; every non-void overlay cell lands on a tile carrying one of that module's claimed slot digits; mount kind matches and mount size >= part size.
- **Void cell = passthrough; any other cell overwrites**, except the SW corner (the slot digit), which is hull-owned.
- **A wall belongs to a module when the slot covers the tiles on both sides of it.** Each tile owns its own half, so spanning a divider hands the whole wall over. This is the mechanism the re-carve uses to make partitions movable.
- **The Mockingbird's deck must not change.** Her default loadout must still resolve to the frozen pre-M4 map, tile for tile. `server/test/fixtures/mockingbird_authored.json` and `default_loadout_reproduces_the_authored_deck_test` remain the arbiter, unchanged.
- **Every task ends with a green `gleam test`.** Run it in the **foreground** and wait — do not background it and report before you have the result.
- A **pre-commit hook runs `gleam format --check`**: run `cd server; gleam format src test` before committing, then re-stage.
- Builds and tests warning-clean; test output pristine.
- If `gleam` is not on PATH, prefix with `PATH="$HOME/scoop/shims:$PATH"` (bash) or run `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"` first (PowerShell).
- Baseline at plan time: **327 Gleam tests, 29 harness tests**, on branch `feat/m4-modules` (worktree `.claude/worktrees/m4-modules`). Work continues on a branch off that.
- `python tools/slotmap.py <hull.json> [--structure <resolved.json>]` renders a hull's slot regions. Use it constantly during the re-carve.

## Scope

**In:** module targets, multi-slot targets, the Mockingbird re-carve to ten slots, `rijay.cabin.standard` serving all five cabin slots, schema and doc updates.

**Out, and deliberately so:** the Sparrow and Finch hulls (their own plan, once these rules are final); exterior part layering, hull mount geometry and per-ship `hull` on the snapshot (iteration 2b); the refit loop — shipyard stations, a refit console, catalogs, wallet charges (iteration 3).

## The target slot layout

Ten slots. Upper deck tile coordinates, `(x, y)`:

| slot | tiles | region |
|---|---|---|
| `cockpit` | x6-7, y3-4 | 4 — unchanged |
| `cabin_fore_a` | x6, y5-6 | 2 |
| `cabin_fore_b` | x6, y7-8 | 2 |
| `crew_commons` | x5-8, y9-11 | 12 |
| `cabin_mess` | x4, y10-11 | 2 — the cabin off the crew commons, fixed hull today |
| `payload` | x3-10 y12-14, x3-7 y15-17, x9-10 y15-17 | 45 — the large common plus every aft passenger cabin |
| `cabin_engineer` | x4, y18-19 | 2 — opens only into the engine room |
| `engineering` | x5-7, y18-19 | 6 — fixed hull today |
| `cabin_aft_stbd` | x9, y18-19 | 2 |
| `hold` (deck 2) | unchanged | 74 |

Stays fixed hull: the cockpit passage (x7, y5-8), the x8 corridor at y15-17 running from the commons down into engineering, the aft junction at x8 y18-19, both stairwells, the whole Mezzanine with its `Q` ports, and the hull skin.

The five cabins are identical 1×2 rooms. That is the point: one `rijay.cabin.standard` document targets all five.

---

### Task 1: A module document carries targets

**Files:**
- Modify: `server/src/dh_server/module.gleam`
- Modify: `server/src/dh_server/loadout.gleam` (`lookup_modules`, `check_bounds`, `stamp_all`, `total_mass`)
- Test: `server/test/module_test.gleam`, `server/test/loadout_test.gleam`

**Interfaces:**
- Produces: `module.Target(hull: String, slot: String, patches: List(Patch))` and `module.Module(schema, id, name, mass, provides, requires, targets: List(Target))` — the `hull`, `slot` and `patches` fields move off `Module` and onto `Target`.
- Produces: `module.target_for(m: Module, hull: String, slot: String) -> Result(Target, Nil)`
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to `server/test/module_test.gleam`:

```gleam
/// One document, several placements. This is the whole point of the change:
/// five identical 1x2 cabins are one concept, not five files.
pub fn a_module_targets_many_hulls_and_slots_test() {
  let doc =
    "{ \"schema\": 1, \"id\": \"rijay.cabin.standard\", \"name\": \"Cabin\",
       \"mass\": 3.0, \"provides\": { \"berths\": 1 },
       \"targets\": [
         { \"hull\": \"mockingbird\", \"slot\": \"cabin_fore_a\",
           \"patches\": [ { \"deck\": 0, \"x\": 6, \"y\": 5,
                            \"grid\": [\"###\", \"#d#\", \"###\"] } ] },
         { \"hull\": \"mockingbird\", \"slot\": \"cabin_fore_b\",
           \"patches\": [ { \"deck\": 0, \"x\": 6, \"y\": 7,
                            \"grid\": [\"###\", \"#d#\", \"###\"] } ] },
         { \"hull\": \"sparrow\", \"slot\": \"cabin\",
           \"patches\": [ { \"deck\": 0, \"x\": 2, \"y\": 2,
                            \"grid\": [\"###\", \"#d#\", \"###\"] } ] }
       ] }"
  let assert Ok(m) = module.decode(doc)
  assert list.length(m.targets) == 3
  let assert Ok(t) = module.target_for(m, "mockingbird", "cabin_fore_b")
  let assert [p] = t.patches
  assert p.y == 7
  assert module.target_for(m, "finch", "cabin") == Error(Nil)
  assert module.target_for(m, "mockingbird", "nope") == Error(Nil)
}

/// The flat single-target spelling stays legal — a module that exists in one
/// place on one hull should not have to write a one-element list.
pub fn the_flat_spelling_decodes_as_one_target_test() {
  let doc =
    "{ \"schema\": 1, \"id\": \"a\", \"name\": \"A\", \"mass\": 1.0,
       \"hull\": \"mockingbird\", \"slot\": \"hold\",
       \"patches\": [ { \"deck\": 2, \"x\": 3, \"y\": 10,
                        \"grid\": [\"###\", \"#p#\", \"###\"] } ] }"
  let assert Ok(m) = module.decode(doc)
  let assert [t] = m.targets
  assert t.hull == "mockingbird"
  assert t.slot == "hold"
  assert list.length(t.patches) == 1
}

pub fn a_module_with_no_targets_is_rejected_test() {
  let assert Error(_) =
    module.decode("{ \"schema\": 1, \"id\": \"a\", \"name\": \"A\" }")
}

pub fn duplicate_targets_are_rejected_test() {
  let doc =
    "{ \"schema\": 1, \"id\": \"a\", \"name\": \"A\",
       \"targets\": [
         { \"hull\": \"h\", \"slot\": \"s\", \"patches\": [] },
         { \"hull\": \"h\", \"slot\": \"s\", \"patches\": [] } ] }"
  let assert Error(_) = module.decode(doc)
}
```

Add `import gleam/list` to that file if it is not already there.

- [ ] **Step 2: Run to verify they fail**

Run: `cd server; gleam test`
Expected: compile error — `Module` has no field `targets`, `module.Target` does not exist.

- [ ] **Step 3: Reshape `Module`**

In `module.gleam`, replace the `Module` type with:

```gleam
/// One placement of a module: the hull it is drawn for, the slot it claims
/// there, and the overlay drawn against that hull's coordinates.
///
/// A module is still never portable *as a drawing* — every target is
/// hand-authored against one specific hull, which is what guarantees its doors
/// line up. What a target list buys is that one CONCEPT (a standard cabin, a
/// medbay) is one document, however many places it fits.
pub type Target {
  Target(hull: String, slot: String, patches: List(Patch))
}

pub type Module {
  Module(
    schema: Int,
    id: String,
    name: String,
    mass: Float,
    provides: Dict(String, Int),
    requires: Dict(String, Int),
    targets: List(Target),
  )
}

/// This module's overlay for one `(hull, slot)` placement, or `Error(Nil)` if
/// it is not drawn for that pair.
pub fn target_for(
  m: Module,
  hull_id: String,
  slot_id: String,
) -> Result(Target, Nil) {
  list.find(m.targets, fn(t) { t.hull == hull_id && t.slot == slot_id })
}
```

Replace `module_decoder`'s `hull`/`slot`/`patches` fields with a targets decoder that accepts both spellings:

```gleam
fn module_decoder() -> decode.Decoder(Module) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use mass <- decode.optional_field("mass", 0.0, hull.number_decoder())
  use provides <- decode.optional_field(
    "provides",
    dict.new(),
    hull.tags_decoder(),
  )
  use requires <- decode.optional_field(
    "requires",
    dict.new(),
    hull.tags_decoder(),
  )
  use targets <- decode.optional_field(
    "targets",
    [],
    decode.list(target_decoder()),
  )
  // The flat spelling — top-level `hull`/`slot`/`patches` — is shorthand for a
  // single target, so a module that exists in exactly one place on one hull
  // does not have to write a one-element list. `targets` is canonical.
  use flat_hull <- decode.optional_field("hull", "", decode.string)
  use flat_slot <- decode.optional_field("slot", "", decode.string)
  use flat_patches <- decode.optional_field(
    "patches",
    [],
    decode.list(patch_decoder()),
  )
  let all = case targets, flat_hull, flat_slot {
    [], "", _ | [], _, "" -> []
    [], h, s -> [Target(hull: h, slot: s, patches: flat_patches)]
    ts, _, _ -> ts
  }
  decode.success(Module(
    schema: schema,
    id: id,
    name: name,
    mass: mass,
    provides: provides,
    requires: requires,
    targets: all,
  ))
}

fn target_decoder() -> decode.Decoder(Target) {
  use hull_id <- decode.field("hull", decode.string)
  use slot <- decode.field("slot", decode.string)
  use patches <- decode.optional_field(
    "patches",
    [],
    decode.list(patch_decoder()),
  )
  decode.success(Target(hull: hull_id, slot: slot, patches: patches))
}
```

Extend `validate` to require at least one target, reject duplicate `(hull, slot)` pairs, and run the existing patch-shape checks over every target's patches:

```gleam
fn validate(m: Module) -> Result(Module, String) {
  use <- guard(
    m.targets != [],
    "module \"" <> m.id <> "\" has no targets: it names no (hull, slot) pair",
  )
  let pairs = list.map(m.targets, fn(t) { t.hull <> "/" <> t.slot })
  use <- guard(
    list.length(list.unique(pairs)) == list.length(pairs),
    "module \"" <> m.id <> "\" targets the same (hull, slot) pair twice",
  )
  list.try_fold(m.targets, m, fn(_, t) {
    list.try_fold(t.patches, m, fn(_, p) { validate_patch(m, p) })
  })
}
```

Move the existing per-patch shape checks into `validate_patch(m, p)` unchanged, and add the local `guard` helper if `module.gleam` does not already have one (copy the shape from `loadout.gleam`).

- [ ] **Step 4: Thread targets through `loadout.gleam`**

`lookup_modules` currently checks `m.hull` and `m.slot`. Replace those two guards with a target lookup, and carry the target forward so later stages use its patches:

```gleam
fn lookup_modules(
  h: Hull,
  modules: Dict(String, Module),
  lo: Loadout,
) -> Result(List(#(Slot, Module, module.Target)), String) {
  list.try_fold(lo.modules, [], fn(acc: List(#(Slot, Module, module.Target)), entry) {
    let #(slot_id, module_id) = entry
    use slot <- result.try(
      hull.slot_by_id(h, slot_id)
      |> result.replace_error("slot_not_on_hull:" <> slot_id),
    )
    use <- guard(
      !list.any(acc, fn(a) { { a.0 }.id == slot_id }),
      "duplicate_slot:" <> slot_id,
    )
    use m <- result.try(
      dict.get(modules, module_id)
      |> result.replace_error("unknown_module:" <> module_id),
    )
    // One reason, not two: a module that is not drawn for this hull and this
    // slot has no overlay to stamp, and the player cannot tell the difference
    // between "wrong hull" and "wrong slot" anyway.
    use target <- result.try(
      module.target_for(m, h.id, slot_id)
      |> result.replace_error("module_not_drawn_for_slot:" <> module_id),
    )
    Ok(list.append(acc, [#(slot, m, target)]))
  })
}
```

Update `check_bounds`, `stamp_all` and `total_mass` to take `List(#(Slot, Module, Target))` and read patches from the target rather than the module. Their logic is otherwise unchanged.

Note the reason-string change: `module_wrong_hull` and `module_wrong_slot` are replaced by `module_not_drawn_for_slot`. Update the vocabulary lists in `loadout.resolve`'s docstring and `protocol.gleam`'s wire block, and any test asserting the old strings.

- [ ] **Step 5: Convert the shipped modules (mechanical)**

The nine documents under `server/modules/` and the two test fixtures under `server/test/fixtures/modules_*` use the flat spelling, which still decodes — so **no content change is required by this task.** Confirm that by running the suite; the Mockingbird golden must pass untouched.

- [ ] **Step 6: Run the suite**

Run: `cd server; gleam test`
Expected: PASS, whole suite, including `default_loadout_reproduces_the_authored_deck_test`.

- [ ] **Step 7: Commit**

```bash
cd server; gleam format src test
git add server/src server/test
git commit -m "feat(modules): a module document carries targets, not one (hull, slot) (#M4)"
```

---

### Task 2: A target may claim several adjacent slots

**Files:**
- Modify: `server/src/dh_server/module.gleam` (`Target`)
- Modify: `server/src/dh_server/loadout.gleam` (`lookup_modules`, `check_bounds`)
- Test: `server/test/module_test.gleam`, `server/test/loadout_test.gleam`

**Interfaces:**
- Consumes: `module.Target` from Task 1.
- Produces: `Target(hull: String, slots: List(String), patches: List(Patch))` — `slot` becomes `slots`; `module.target_for` matches when `slots` contains the id.

- [ ] **Step 1: Write the failing tests**

Append to `server/test/loadout_test.gleam`. It needs a hull whose bay is split
into two adjacent single-tile slots, so add these fixtures alongside the
existing `hull_doc`:

```gleam
// `hull_doc`'s bay, split into two adjacent single-tile slots so a module can
// be drawn to claim both at once. Only the SW digits differ.
const hull_two_slots_doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 96.0,
  \"provides\": { \"power\": 10 },
  \"requires\": { \"engine\": 1 },
  \"slots\": [ { \"digit\": 1, \"id\": \"bay_a\", \"name\": \"Bay A\" },
               { \"digit\": 2, \"id\": \"bay_b\", \"name\": \"Bay B\" } ],
  \"mounts\": [ { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" } ],
  \"cargo\": { \"capacity\": 7, \"handling\": \"breakbulk\" },
  \"decks\": [ { \"name\": \"Main\", \"grid\": [
    \"####=#\",
    \"# h Q#\",
    \"#### #\",
    \"#### #\",
    \"#    #\",
    \"1##2##\"
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
```

`engine_registry()` is a one-line helper returning the file's existing
`test.engine` part in a `Dict`; extract it from the current `registries` helper
if one does not already exist.

- [ ] **Step 2: Run to verify they fail**

Run: `cd server; gleam test`
Expected: FAIL — `slots` is not a field of `Target`.

- [ ] **Step 3: Implement**

Change `Target`'s `slot: String` to `slots: List(String)`, require it non-empty in `validate`, and match in `target_for` with `list.contains(t.slots, slot_id)`. The flat spelling's `slot` becomes a one-element list.

In `lookup_modules`, occupancy becomes the target's whole slot set: keep a running list of claimed slot ids, error `duplicate_slot:<id>` if any of the target's slots is already claimed, and record them all. In `check_bounds`, a cell is in bounds when its digit is any of the target's slots' digits:

```gleam
let digits =
  list.filter_map(target.slots, fn(id) {
    hull.slot_by_id(h, id) |> result.map(fn(s) { s.digit })
  })
// ... case list.contains(digits, digit) — where `digit` is the cell's slot
```

`check_bounds` now needs the `Hull` to resolve slot ids to digits; thread it through from `resolve`.

- [ ] **Step 4: Run the suite**

Run: `cd server; gleam test`
Expected: PASS, whole suite.

- [ ] **Step 5: Commit**

```bash
cd server; gleam format src test
git add server/src server/test
git commit -m "feat(modules): a target may claim several adjacent slots (#M4)"
```

---

### Task 3: Re-carve the Mockingbird into ten slots

The content task, and the risky one. Carve **one slot at a time**, running the golden test after each — a single failing comparison across three decks is very hard to localise.

**Files:**
- Modify: `server/shipclasses/mockingbird.json`
- Rewrite: `server/modules/mockingbird/*.json`
- Test: `server/test/mockingbird_test.gleam`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: the ten slots in "The target slot layout" above, and module ids `mockingbird.payload.passenger`, `mockingbird.commons.crew`, `mockingbird.engineering.stock`, plus the existing `mockingbird.cockpit.stock` and `mockingbird.hold.breakbulk` / `.tank` re-slotted.

- [ ] **Step 1: Mark the new slot digits**

Assign digits 1-a per the layout table and write them into each tile's SW corner (row `3y+2`, column `3x`). Replace the `slots` table wholesale. Verify with `python tools/slotmap.py server/shipclasses/mockingbird.json --structure server/test/fixtures/mockingbird_authored.json` before touching any module — the painted regions must match the table exactly.

- [ ] **Step 2: Empty the newly-modular regions**

`engineering` (x5-7 y18-19) and `cabin_mess` (x4 y10-11) are fixed hull today: strip their furniture and interior partitions out of the hull so their modules can supply them. The regions that were already slots keep their hull-side state.

Where a divider now has slot tiles on **both** sides — the partitions between the aft passenger cabins, and the wall between the large common and those cabins, all inside `payload` — remove it from the hull entirely and let the payload module draw it. That is the change that makes those walls movable.

- [ ] **Step 3: Author the payload module**

`server/modules/mockingbird/payload_passenger.json`, one target on `payload`, drawing exactly what the frozen map has across x3-10 y12-14 and the aft cabins: the passenger common's tables and seats, every cabin partition, every cabin's furniture and doors. Mass 14.0, `provides: {"passengers": 6}`, `requires: {"power": 3}`.

- [ ] **Step 4: Author the crew commons and engineering modules**

- `commons_crew.json` — target `crew_commons`, drawing x5-8 y9-11 as today. Mass 4.0, `provides: {"galley": 1}`, `requires: {"power": 1}`.
- `engineering_stock.json` — target `engineering`, drawing x5-7 y18-19 as today. Mass 6.0, `provides: {"engine_bay": 1}`, `requires: {"power": 2}`.

- [ ] **Step 5: Re-slot the cockpit and hold modules**

`cockpit_stock.json` and both hold modules keep their content; only their target's `slot` id changes if the layout renamed it. The hold is unchanged.

- [ ] **Step 6: Delete the superseded modules**

`forward_crew_cabins.json`, `forward_crew_passenger.json`, `aft_crew_cabins.json` and `commons_mess.json` are replaced by the cabin document (Task 4) and the payload module. Remove them and their `default_loadout` entries.

- [ ] **Step 7: Run the golden test after every slot, and the harness at the end**

Run: `cd server; gleam test` after each slot's module lands.
Expected: `default_loadout_reproduces_the_authored_deck_test` PASSES throughout.

Then: `cd harness; python -m pytest -v` — expected 29 passed, 2 deselected.

A failure is almost always one of: a slot digit missing from a tile the module writes into (`out_of_slot_bounds`), a hull tile that kept decor the module also draws, or a divider removed from the hull that no module redraws.

- [ ] **Step 8: Commit**

```bash
cd server; gleam format src test
git add server/shipclasses server/modules server/test
git commit -m "feat(mockingbird): re-carve into ten slots — rooms, not furniture outlines (#M4)"
```

---

### Task 4: One cabin document for all five cabin slots

The payoff. Five identical 1×2 rooms, one file.

**Files:**
- Create: `server/modules/rijay/cabin_standard.json`
- Modify: `server/shipclasses/mockingbird.json` (`default_loadout`)
- Test: `server/test/mockingbird_test.gleam`

- [ ] **Step 1: Write the failing test**

```gleam
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
```

- [ ] **Step 2: Author the document**

`server/modules/rijay/cabin_standard.json` — id `rijay.cabin.standard`, name "Standard cabin", mass 3.0, `provides: {"berths": 1}`, `requires: {"power": 1}`, with five targets on `mockingbird`: `cabin_fore_a` (x6 y5), `cabin_fore_b` (x6 y7), `cabin_mess` (x4 y10), `cabin_engineer` (x4 y18), `cabin_aft_stbd` (x9 y18). Each target's patch draws that cabin exactly as the frozen map has it — they differ in origin and in which wall carries the door and window, which is precisely why each is hand-drawn rather than generated.

Note the id is namespaced `rijay.` rather than `mockingbird.`: it is a manufacturer-level part, and the Sparrow and Finch will add targets to this same file.

- [ ] **Step 3: Point the default loadout at it**

Five `default_loadout.modules` entries, one per cabin slot, all `rijay.cabin.standard`.

- [ ] **Step 4: Run both suites**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green, golden included.

- [ ] **Step 5: Commit**

```bash
cd server; gleam format src test
git add server/modules server/shipclasses server/test
git commit -m "feat(content): one standard cabin document serves all five cabin slots (#M4)"
```

---

### Task 5: Schemas and documentation

**Files:**
- Modify: `server/schemas/module.schema.json`
- Modify: `docs/modules.md`
- Modify: `docs/deckplan-format.md`

- [ ] **Step 1: Extend the module schema**

Add `targets` (array of `{hull, slots, patches}`) alongside the existing flat spelling, with `additionalProperties: false` at every level and a description naming `module.gleam`'s decoder as the source of truth. Both spellings must validate; a document with neither must not. `server/test/data_schema_test.gleam` already validates every shipped module, so the new cabin document is covered once the schema accepts it.

- [ ] **Step 2: Restore and extend `docs/modules.md`**

- "Slots and mounts": a module document carries **targets**; each names a hull, the slot(s) it claims there, and its own overlay. Restore the original intent — one concept, many placements — and say plainly that the iteration-1 one-pair rule was an implementation simplification, not a design decision.
- Record that **free placement is refused** and why: a module's doors line up because a human drew them at a known position, and runtime placement would reintroduce shape-matching.
- Record that a target may claim **several adjacent slots**, and that this is how a larger room absorbs the one next door.
- Update the reason vocabulary: `module_wrong_hull` and `module_wrong_slot` are gone, replaced by `module_not_drawn_for_slot`.
- Describe the Mockingbird's ten slots and note that five are identical 1×2 cabins served by one document.

- [ ] **Step 3: Update `docs/deckplan-format.md`**

The Slots section records that the Mockingbird's corridor-side walls are permanent because she was carved from an existing map. That is still true for her *hull-owned* perimeters, but the re-carve moved every divider that sits between two slot tiles into its module. Correct the paragraph so it distinguishes the two cases rather than implying nothing on her can move.

- [ ] **Step 4: Run the suite and commit**

Run: `cd server; gleam test`
Expected: PASS.

```bash
git add server/schemas docs
git commit -m "docs(m4): module targets, refused placement, the ten-slot Mockingbird (#M4)"
```

---

## Definition of done

- `cd server; gleam test` and `cd harness; python -m pytest -v` both green.
- The Mockingbird's default loadout still resolves to her frozen pre-M4 deck, tile for tile.
- One `rijay.cabin.standard` document furnishes all five of her cabins, and a test fails if that ever needs a second file.
- A module can claim two adjacent slots; a slot can be claimed only once.
- `tools/slotmap.py` shows ten slots covering the rooms — cabins, crew commons, payload, engineering, cockpit, hold — with corridors, stairwells, the mezzanine and the hull skin fixed.

## What comes after

**Iteration 2b — the Sparrow and Finch.** Authored against these finished rules: perimeters open, cabin slots the standard 1×2 shape, and `rijay.cabin.standard` gaining targets rather than the hulls gaining bespoke cabin files. This is the anti-overfit test the whole design rests on, and it is worth its own plan once the rules stop moving.

**Iteration 2c — exterior part layering.** Hull mount geometry, standalone part sprite exports from `tools/artspike/composer.py`, client-side layering, per-ship `hull` on the snapshot. Orthogonal to everything above.

**Iteration 3 — the refit loop.** Shipyard stations, a refit console you walk to, per-station catalogs and prices, charging the wallet, the Godot refit UI.
