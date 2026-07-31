# M4 Iteration 2b: The Sparrow and the Goldfinch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author two new hulls — a small single-deck Sparrow and a double-decked Goldfinch passenger liner — against the module rules iteration 2a finished, and find out which of those rules were design and which were the Mockingbird's shape in disguise.

**Architecture:** Pure content plus the small data changes that content forces. Three engine parts under a per-manufacturer naming grammar replace the two on disk; the Mockingbird gains the three engine mounts her art has always had; then two hull documents and their modules, with `rijay.cabin.standard` gaining twelve Goldfinch targets rather than the Goldfinch gaining a cabin file. No engine code changes are expected — if a task needs one, that is the anti-overfit test firing and it must be reported, not quietly worked around.

**Tech Stack:** Gleam (Erlang target) server, gleeunit, JSON data validated by jesse schemas, Python/pytest protocol harness.

**Spec:** `docs/superpowers/specs/2026-07-31-m4-iteration2b-sparrow-goldfinch-design.md`

## Global Constraints

- **Baseline: 337 Gleam tests, 29 harness tests**, on `main` at `b24d626`. Every task ends green.
- **Run `gleam test` in the FOREGROUND and wait for the result.** Do not background it and report before you have the output.
- A **pre-commit hook runs `gleam format --check`**: run `cd server; gleam format src test` before committing, then re-stage.
- If `gleam` is not on PATH: `PATH="$HOME/scoop/shims:$PATH"` (bash) or `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"` (PowerShell).
- **The Mockingbird's deck must not change.** `server/test/fixtures/mockingbird_authored.json` and `default_loadout_reproduces_the_authored_deck_test` remain the arbiter. Task 2 changes her *parts and reactor*, never her *rows*.
- **No engine/source changes are in scope.** Only `server/parts/`, `server/shipclasses/`, `server/modules/`, `server/schemas/`, tests, `harness/`, and docs.
- **No exterior art.** Nothing under `client/assets/ships/` is created. Both hulls are reviewed by walking them via `DH_SHIP_CLASS`.
- Builds and tests warning-clean; test output pristine.
- `python tools/slotmap.py <hull.json> [--structure <resolved.json>]` paints slot regions. Use it after every slot-digit edit.

## Deck-plan facts you must have straight

Getting these wrong is the single most likely cause of a failing task.

- **Every tile is a 3×3 character block.** Tile `(x, y)` occupies rows `3y..3y+2`, columns `3x..3x+2`.
- Centre is `(3y+1, 3x+1)`. N edge `(3y, 3x+1)`. S edge `(3y+2, 3x+1)`. W edge `(3y+1, 3x)`. E edge `(3y+1, 3x+2)`.
- **NE corner `(3y, 3x+2)` is the colour digit. SW corner `(3y+2, 3x)` is the slot digit.** NW and SE are cosmetic.
- **A stamp never overwrites SW** (hull-owned). It *does* overwrite NE (a module owns its colour).
- **Centre glyphs:** `' '`=floor, `.`=void, `x`=stairs, `Q`=dock port, `s`=spawn, and the decor set `r e d p f l t g`. `p`=cargo pallet is the unit hold capacity is counted in.
- **Consoles are EDGE fixtures, not centre glyphs:** `h`=helm, `c`=cargo, `b`=broker, alongside `v`=viewscreen, `w`=window, `d`=bunk. Other edges: `' '`=open, `#`=wall, `=`=door. A centre `d` is a floor bed; an edge `d` is a wall bunk.
- **A fit whose resolved plan has no helm fails** with `invalid_resolved_plan`. Every hull's cockpit module must draw an `h` on an edge.
- **A `Q` tile's outward normal is the edge whose door (`=`) faces void.** Get this wrong and mooring breaks.
- **Hold capacity is derived from pallet tiles** in the *stamped* plan. `hull.cargo.capacity` is only a fallback used when the stamped plan draws no pallets at all (`hull.gleam:56`).
- **Perimeter rule** (`docs/deckplan-format.md`, "Slots"): author the hull side of a slot perimeter **open**, and draw that perimeter's walls and doors on the slot side, in the module. Both new hulls are drawn from scratch and must obey it from the first row.
- **The slot digit is a single hex character, so a hull can carry at most 16 slots.** The Goldfinch is deliberately drawn to 15. If you need a 16th, stop and report it.

## File structure

**PR 1 — groundwork and the Sparrow**

| file | responsibility |
|---|---|
| `server/parts/rijay_engine_stork_240c2.json` | medium Rijay engine (replaces `rijay_engine_stock.json`) |
| `server/parts/rijay_engine_wren_90b.json` | **new** small Rijay engine |
| `server/parts/consol_engine_co17f_2.json` | Consolidated patch engine (replaces `rijay_engine_consol_patch.json`) |
| `server/shipclasses/mockingbird.json` | three mounts, reactor 25, new part ids |
| `server/test/fixtures/mockingbird_authored.json` | golden fixture — mounts/parts only, **rows untouched** |
| `server/shipclasses/sparrow.json` | **new** hull: 1 deck, 2 slots, 3 `s` mounts |
| `server/modules/rijay/cockpit_sparrow.json` | **new** |
| `server/modules/rijay/bay_packet.json` | **new** |
| `server/modules/rijay/bay_ranger.json` | **new** |
| `server/test/parts_test.gleam` | new ids, the `power` refusal |
| `server/test/sparrow_test.gleam` | **new** |
| `server/test/sim_test.gleam` | refused-refit case back to `tag_deficit:power` |
| `server/test/protocol_test.gleam` | new part ids in wire fixtures |
| `harness/fixtures/test_fixture.json`, `harness/test_m4_refit.py` | new part id |
| `docs/deckplan-format.md`, `docs/modules.md` | stale console prose; naming grammar |

**PR 2 — the Goldfinch**

| file | responsibility |
|---|---|
| `server/shipclasses/goldfinch.json` | **new** hull: 3 decks, 15 slots, mixed-size mounts |
| `server/modules/rijay/cabin_standard.json` | **+12 Goldfinch targets**, no new file |
| `server/modules/goldfinch/cockpit_stock.json` | **new** |
| `server/modules/goldfinch/galley_stock.json` | **new** |
| `server/modules/goldfinch/hold_breakbulk.json` | **new** |
| `server/test/goldfinch_test.gleam` | **new**, incl. the anti-overfit assertion |
| `docs/lore.md`, `DESIGN.md`, `docs/modules.md` | Finch → Goldfinch; findings |

---

# PR 1 — Groundwork and the Sparrow

### Task 1: The engine parts and their naming grammar

**Files:**
- Create: `server/parts/rijay_engine_stork_240c2.json`, `server/parts/rijay_engine_wren_90b.json`, `server/parts/consol_engine_co17f_2.json`
- Delete: `server/parts/rijay_engine_stock.json`, `server/parts/rijay_engine_consol_patch.json`
- Test: `server/test/parts_test.gleam`

**Interfaces:**
- Produces: part ids `rijay.engine.stork_240c2` (m), `rijay.engine.wren_90b` (s), `consol.engine.co17f_2` (m). Every later task uses these names.
- Consumes: nothing.

Naming grammar, for the docstring and for every future part: **Rijay Drive Yards** name an engine as they name a hull — a bird — then its thrust class in units of ten, then a block designation. Engine birds are distinct from hull birds so the namespaces never collide. **Consolidated Orbital** get a fleet-standard alphanumeric and no bird; a part number is all a part gets from the Company. `rijay.engine.consol_patch` was namespaced to the wrong manufacturer entirely — Consolidated Orbital is its own house in `docs/lore.md` and the whole point of the starter Mockingbird is that her centre engine is foreign to the hull.

- [ ] **Step 1: Write the failing test**

Replace the id assertions at the top of `server/test/parts_test.gleam` (currently lines 18-21, asserting `rijay.engine.consol_patch` and `rijay.engine.stock`) with:

```gleam
/// Part ids name the manufacturer that BUILT the part. The Consol patch
/// engine is a Consolidated Orbital part fitted to a Rijay hull, and filing
/// it under `rijay.` erased the joke the starter Mockingbird is built on.
pub fn shipped_engine_parts_load_test() {
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(patch) = dict.get(parts, "consol.engine.co17f_2")
  assert patch.kind == "engine"
  assert patch.size == "m"
  assert patch.mass == 8.0
  let assert Ok(stork) = dict.get(parts, "rijay.engine.stork_240c2")
  assert stork.size == "m"
  assert stork.mass == 12.0
  // The Sparrow's engine, and the first size-`s` part on disk. Until now
  // every shipped part was `m`, so `mount size >= part size` had never once
  // been exercised by content.
  let assert Ok(wren) = dict.get(parts, "rijay.engine.wren_90b")
  assert wren.size == "s"
  assert wren.mass == 4.0
  assert dict.get(parts, "rijay.engine.stock") == Error(Nil)
  assert dict.get(parts, "rijay.engine.consol_patch") == Error(Nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — `consol.engine.co17f_2` not found.

- [ ] **Step 3: Create the three part documents**

`server/parts/rijay_engine_stork_240c2.json`:

```json
{
  "schema": 1,
  "id": "rijay.engine.stork_240c2",
  "name": "Rijay Stork 240-C2",
  "kind": "engine",
  "size": "m",
  "mass": 12.0,
  "provides": { "engine": 1 },
  "requires": { "power": 4 },
  "thrust": 2400.0,
  "torque": 7000.0,
  "sprite": "engine_rijay"
}
```

`server/parts/rijay_engine_wren_90b.json`:

```json
{
  "schema": 1,
  "id": "rijay.engine.wren_90b",
  "name": "Rijay Wren 90-B",
  "kind": "engine",
  "size": "s",
  "mass": 4.0,
  "provides": { "engine": 1 },
  "requires": { "power": 3 },
  "thrust": 900.0,
  "torque": 3000.0,
  "sprite": "engine_rijay_small"
}
```

`server/parts/consol_engine_co17f_2.json`:

```json
{
  "schema": 1,
  "id": "consol.engine.co17f_2",
  "name": "Consolidated CO-17F Block 2",
  "kind": "engine",
  "size": "m",
  "mass": 8.0,
  "provides": { "engine": 1 },
  "requires": { "power": 3 },
  "thrust": 1700.0,
  "torque": 7500.0,
  "sprite": "engine_consol"
}
```

Note the Consol part is deliberately the odd one out: **less thrust than the Rijay original it displaced, but more torque.** It is a fleet part shoved into a hole it was not drawn for and it should read that way in the numbers.

Thrust and torque across all three are roughly a third of their pre-2b values, because those were authored against a one-mount hull and were therefore implicitly "the whole ship's push".

Delete `server/parts/rijay_engine_stock.json` and `server/parts/rijay_engine_consol_patch.json`.

- [ ] **Step 4: Update every other reference to the old ids**

These files name the old ids and will fail to compile or resolve otherwise:

- `server/parts_test.gleam:53` — `#("engine_center", "rijay.engine.stock")` → `"rijay.engine.stork_240c2"`
- `server/test/protocol_test.gleam:460,464,486,494` — `rijay.engine.stock` → `rijay.engine.stork_240c2`
- `server/test/sim_test.gleam:1045` — `const default_parts = [#("engine_center", "rijay.engine.consol_patch")]` → `consol.engine.co17f_2` (Task 2 rewrites this line again for the three mounts; change the id now so the suite stays green between tasks)
- `server/shipclasses/mockingbird.json:258` and `server/test/fixtures/mockingbird_authored.json:233` → `consol.engine.co17f_2`
- `harness/fixtures/test_fixture.json:35` → `consol.engine.co17f_2`
- `harness/test_m4_refit.py:14,33` — `ENGINE_PART = "consol.engine.co17f_2"` and the docstring
- `docs/modules.md:342` — the worked example

- [ ] **Step 5: Run both suites**

Run: `cd server; gleam test`
Expected: PASS, 337 tests.

Run: `cd harness; python -m pytest -v`
Expected: 29 passed, 2 deselected.

- [ ] **Step 6: Commit**

```bash
cd server; gleam format src test
git add server/parts server/test server/shipclasses harness docs/modules.md
git commit -m "refactor(parts): per-manufacturer engine naming; the Consol patch leaves the rijay namespace (#M4)"
```

---

### Task 2: The Mockingbird's three engines

`client/assets/ships/mockingbird/meta.json` carries **three** `nozzle` anchors, evenly spaced across the stern; the hull document declares one mount. The art and the data have disagreed since iteration 1, and 2c binds mounts to exactly those anchors.

**Files:**
- Modify: `server/shipclasses/mockingbird.json` (`mounts`, `provides.power`, `default_loadout.parts`)
- Modify: `server/test/fixtures/mockingbird_authored.json` (`mounts`, `default_loadout.parts` — **not the deck rows**)
- Modify: `server/test/sim_test.gleam:1045`
- Test: `server/test/mockingbird_test.gleam`

**Interfaces:**
- Consumes: the three part ids from Task 1.
- Produces: mount ids `engine_port`, `engine_center`, `engine_stbd` on the Mockingbird, all `kind: engine`, `size: m`.

- [ ] **Step 1: Write the failing tests**

Append to `server/test/mockingbird_test.gleam`:

```gleam
/// Her art has three nozzle anchors and always has. The default loadout is
/// now the lore verbatim: "a Consol center engine shoved between two Rijay
/// originals".
pub fn she_flies_on_three_engines_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  assert list.length(h.mounts) == 3
  assert h.default_parts
    == [
      #("engine_port", "rijay.engine.stork_240c2"),
      #("engine_center", "consol.engine.co17f_2"),
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
```

Add whichever of `gleam/list`, `dh_server/part`, `dh_server/module`, `dh_server/glyphs`, `dh_server/loadout` imports the file lacks. Match the existing `loadout.resolve` argument order in that file — do not guess it.

- [ ] **Step 2: Run to verify they fail**

Run: `cd server; gleam test`
Expected: FAIL — `list.length(h.mounts) == 3` is false (it is 1).

- [ ] **Step 3: Give her three mounts and a bigger reactor**

In `server/shipclasses/mockingbird.json`, replace the `mounts` line:

```json
  "mounts": [
    { "id": "engine_port",   "kind": "engine", "size": "m" },
    { "id": "engine_center", "kind": "engine", "size": "m" },
    { "id": "engine_stbd",   "kind": "engine", "size": "m" }
  ],
```

Replace `default_loadout.parts`:

```json
    "parts": {
      "engine_port":   "rijay.engine.stork_240c2",
      "engine_center": "consol.engine.co17f_2",
      "engine_stbd":   "rijay.engine.stork_240c2"
    }
```

Change `"provides": { "power": 18 }` to `"provides": { "power": 25 }`.

**The arithmetic, because the exact number is the point.** Her modules draw 14. Three engines draw 4 + 3 + 4 = 11. Total 25, against a reactor providing 25 — zero headroom. Swap the centre Mule for a Stork and the draw becomes 26 → `tag_deficit:power`.

Resulting flight figures: mass 73 + 47 + 12 + 8 + 12 = 152.0; thrust 6500 → 42.8 u/s²; torque 21500 → 141.4 deg/s. Close to the pre-2b 39.06 and 171.9. These are placeholders and the goal is coherence, not tuning.

- [ ] **Step 4: Mirror the mounts into the golden fixture**

In `server/test/fixtures/mockingbird_authored.json`, apply the same `mounts` and `default_loadout.parts` edits (lines 232-233). **Do not touch a single deck row.** The fixture's job is to prove her map is unchanged.

- [ ] **Step 5: Point `sim_test` at the three mounts, and take back its `power` case**

`server/test/sim_test.gleam:1045`:

```gleam
const default_parts = [
  #("engine_port", "rijay.engine.stork_240c2"),
  #("engine_center", "consol.engine.co17f_2"),
  #("engine_stbd", "rijay.engine.stork_240c2"),
]
```

Then find the refused-refit case that iteration 2a retargeted to `tag_deficit:engine` (grep `tag_deficit` in that file). Iteration 2a's re-carve made `power` unreachable through shipped content, so the case was forced onto `engine`. It is reachable again: change that case to request three Storks and assert `tag_deficit:power`, and update its comment to say so.

- [ ] **Step 6: Run both suites**

Run: `cd server; gleam test`
Expected: PASS — **including `default_loadout_reproduces_the_authored_deck_test`**. If that one fails you edited a deck row; revert the fixture's rows and redo Step 4.

Run: `cd harness; python -m pytest -v`
Expected: 29 passed, 2 deselected.

- [ ] **Step 7: Commit**

```bash
cd server; gleam format src test
git add server/shipclasses server/test
git commit -m "feat(mockingbird): three engine mounts, matching her art; a Stork centre overdraws her reactor (#M4)"
```

---

### Task 3: The Sparrow hull

> The Toyota Corolla of space fighters. Definitely a single-seat vehicle. Does not contain a bed by default. Basically just a small central cylindrical pod with a cockpit in front, with an engine strapped to either side at the back. Two engines instead of three (by default); upgradeable to three. — `docs/lore.md`

**Constant-width pod. No bulge** — she is a small Mockingbird in her cockpit and her engines and nowhere else.

**Files:**
- Create: `server/shipclasses/sparrow.json`
- Test: `server/test/sparrow_test.gleam`

**Interfaces:**
- Consumes: `rijay.engine.wren_90b` from Task 1.
- Produces: hull id `sparrow`; slot ids `cockpit` (digit 1) and `bay` (digit 2); mount ids `engine_port`, `engine_center`, `engine_stbd`, all `size: s`.

- [ ] **Step 1: Write the failing test**

Create `server/test/sparrow_test.gleam`:

```gleam
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — `shipclasses/sparrow.json` does not exist.

- [ ] **Step 3: Author the hull**

Create `server/shipclasses/sparrow.json`. The deck is **5 tiles wide × 8 tall = 15 columns × 24 rows**. Interior runs `x1..x3`, `y1..y6`; `x0`, `x4`, `y0` and `y7` are void margin.

Layout: cockpit slot at `y1` (`x1-3`, digit `1`); fixed passage at `y2`; bay slot at `y3-4` (`x1-3`, digit `2`); dock vestibule at `y5` with a `Q` on each beam; fixed aft section at `y6`.

**Every row below is exactly 15 characters.** Count them.

```json
{
  "schema": 3,
  "id": "sparrow",
  "name": "Sparrow",
  "decks": [
    {
      "name": "Main",
      "grid": [
        "               ",
        " .  .  .  .  . ",
        "               ",
        "   #########   ",
        " . #       # . ",
        "   1  1  1     ",
        "               ",
        " . #       # . ",
        "               ",
        "               ",
        " . #       # . ",
        "   2  2  2     ",
        "               ",
        " . #       # . ",
        "   2  2  2     ",
        "               ",
        " . =Q     Q= . ",
        "               ",
        "               ",
        " . #       # . ",
        "   #########   ",
        "               ",
        " .  .  .  .  . ",
        "               "
      ]
    }
  ],
  "mass": 12.0,
  "provides": { "power": 12 },
  "requires": { "engine": 1 },
  "mounts": [
    { "id": "engine_port",   "kind": "engine", "size": "s" },
    { "id": "engine_center", "kind": "engine", "size": "s" },
    { "id": "engine_stbd",   "kind": "engine", "size": "s" }
  ],
  "slots": [
    { "digit": 1, "id": "cockpit", "name": "Cockpit" },
    { "digit": 2, "id": "bay",     "name": "Pod bay" }
  ],
  "default_loadout": {
    "modules": {
      "cockpit": "rijay.cockpit.sparrow",
      "bay":     "rijay.bay.packet"
    },
    "parts": {
      "engine_port": "rijay.engine.wren_90b",
      "engine_stbd": "rijay.engine.wren_90b"
    }
  },
  "cargo": {
    "capacity": 2,
    "handling": "breakbulk"
  },
  "dock_port_orientation": 90.0,
  "dock_standoff": 8.0
}
```

Things to check by eye before moving on:

- **Slot digits** are the SW corners on rows 5 (`1` at cols 3, 6, 9) and 11 and 14 (`2` at cols 3, 6, 9).
- **The dock ports face outward.** Row 16 is `" . =Q     Q= . "`. The port `Q` sits at column 4 with a `=` on its **W** edge (column 3) and void at `x0`; the starboard `Q` sits at column 10 with a `=` on its **E** edge (column 11) and void at `x4`. That is what makes their outward normals port and starboard. Symmetric, deliberately — a door on one side only reads as a work van.
- **Slot perimeters are open on the hull side.** Rows 5, 6, 8, 9, 11, 12, 14 and 15 carry no `#` at the N/S edge positions. The cockpit and bay modules draw those walls and doors themselves.
- **`engine_center` is absent from `default_loadout.parts`.** That is the lore's third-engine upgrade, left unfitted.
- `cargo.capacity: 2` is a **fallback**, used only if a fit draws no pallets at all. The packet locker's pallets are the real number.

- [ ] **Step 4: Verify the slot map**

Run: `python tools/slotmap.py server/shipclasses/sparrow.json`
Expected: digit `1` painted across three tiles in one row near the bow; digit `2` painted across a 3×2 block amidships; everything else unpainted.

If the painted regions do not match, fix the SW corners before writing any module — a module drawn against wrong digits fails as `out_of_slot_bounds` and is very hard to localise.

- [ ] **Step 5: Run the suite**

Run: `cd server; gleam test`
Expected: the two new tests PASS. The default loadout does not resolve yet — its modules do not exist — so do not add a resolve test here; Task 4 adds it.

- [ ] **Step 6: Commit**

```bash
cd server; gleam format src test
git add server/shipclasses/sparrow.json server/test/sparrow_test.gleam
git commit -m "feat(sparrow): a single-deck hull, two slots, three small mounts (#M4)"
```

---

### Task 4: The Sparrow's modules

**Files:**
- Create: `server/modules/rijay/cockpit_sparrow.json`, `server/modules/rijay/bay_packet.json`, `server/modules/rijay/bay_ranger.json`
- Test: `server/test/sparrow_test.gleam`

**Interfaces:**
- Consumes: hull `sparrow`, slots `cockpit` and `bay` (Task 3).
- Produces: module ids `rijay.cockpit.sparrow`, `rijay.bay.packet`, `rijay.bay.ranger`.

Filed under `rijay/` rather than `sparrow/` because they are manufacturer parts, the same reason `rijay.cabin.standard` is.

- [ ] **Step 1: Write the failing tests**

Append to `server/test/sparrow_test.gleam`:

```gleam
/// Her stock fit resolves, draws its pallets, and puts a helm on the wire.
pub fn her_default_loadout_resolves_test() {
  let assert Ok(h) = hull.load("shipclasses/sparrow.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, modules, parts, loadout.default_for(h))
  // Capacity is DERIVED from the packet locker's pallet tiles, never from
  // the hull's fallback of 2. Confirm the field's real name on the resolved
  // shipclass before writing this line — `hull.gleam` calls the hull-side
  // one `fallback_capacity`, and the resolved one is a different field.
  assert fit.class.capacity == 5
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
    loadout.Loadout(hull: "sparrow", modules: [
      #("cockpit", "rijay.cockpit.sparrow"),
      #("bay", "rijay.bay.packet"),
    ], parts: three)
  let assert Ok(_) = loadout.resolve(glyphs.default(), h, modules, parts, speed)
  // Range build on two engines: 2 + 2 + 6 = 10 of 12. Fits.
  let range =
    loadout.Loadout(hull: "sparrow", modules: [
      #("cockpit", "rijay.cockpit.sparrow"),
      #("bay", "rijay.bay.ranger"),
    ], parts: [
      #("engine_port", "rijay.engine.wren_90b"),
      #("engine_stbd", "rijay.engine.wren_90b"),
    ])
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
```

Add the imports these need. Match the existing `loadout.resolve` argument order used elsewhere in the suite — do not guess it.

- [ ] **Step 2: Run to verify they fail**

Run: `cd server; gleam test`
Expected: FAIL — `unknown_module:rijay.cockpit.sparrow`.

- [ ] **Step 3: The cockpit**

`server/modules/rijay/cockpit_sparrow.json`. The patch origin is `x: 1, y: 1`, so its grid starts at hull row 3, column 3, and is **9 columns × 3 rows** — the three cockpit tiles and their own borders.

```json
{
  "schema": 1,
  "id": "rijay.cockpit.sparrow",
  "name": "Sparrow cockpit",
  "mass": 3.0,
  "provides": { "seats": 1 },
  "requires": { "power": 2 },
  "targets": [
    {
      "hull": "sparrow",
      "slots": ["cockpit"],
      "patches": [
        {
          "deck": 0, "x": 1, "y": 1,
          "grid": [
            "####h####",
            "w   e   w",
            " #  =  # "
          ]
        }
      ]
    }
  ]
}
```

Row by row: the `h` is the **helm console on the bow-facing N edge** of the centre tile — a console is an *edge fixture*, never a centre glyph, and without it the whole fit dies as `invalid_resolved_plan`. The `w`s are windows on the outboard skin. The `e` is the pilot's seat, and there is exactly one because she is a single-seater. The last row draws the cockpit's own S wall with a `=` door aft; the SW slot digits in that row are hull-owned and the stamp skips them, so what you write in those columns is ignored.

- [ ] **Step 4: The packet locker (default) and the ranger package**

`server/modules/rijay/bay_packet.json` — patch origin `x: 1, y: 3`, **9 columns × 6 rows**:

```json
{
  "schema": 1,
  "id": "rijay.bay.packet",
  "name": "Packet locker",
  "mass": 2.0,
  "requires": { "power": 1 },
  "targets": [
    {
      "hull": "sparrow",
      "slots": ["bay"],
      "patches": [
        {
          "deck": 0, "x": 1, "y": 3,
          "grid": [
            "#c##=####",
            "#p     p#",
            "         ",
            "         ",
            "#p  p  p#",
            " #  =  # "
          ]
        }
      ]
    }
  ]
}
```

Five `p` pallets, so her derived capacity is 5. The `c` is the **cargo console on the N edge** of the port tile — a hold module that forgets its `c` leaves the crew nowhere to work cargo. The `=` in the top row is the door forward to the passage, and the `=` in the bottom row is the door aft to the dock vestibule.

`server/modules/rijay/bay_ranger.json` — same origin and footprint:

```json
{
  "schema": 1,
  "id": "rijay.bay.ranger",
  "name": "Ranger endurance package",
  "mass": 4.0,
  "provides": { "berths": 1, "fuel": 8 },
  "requires": { "power": 2 },
  "targets": [
    {
      "hull": "sparrow",
      "slots": ["bay"],
      "patches": [
        {
          "deck": 0, "x": 1, "y": 3,
          "grid": [
            "####=####",
            "wd     ew",
            "         ",
            "         ",
            "#   t   #",
            " #  =  # "
          ]
        }
      ]
    }
  ]
}
```

A bed, a seat, a table and windows, and no pallets at all — which is how a fit with the ranger installed falls back to the hull's `cargo.capacity` of 2. Its `fuel: 8` is bookkeeping: **nothing in the game consumes fuel**, exactly as nothing consumes `berths`. Do not add a fuel mechanic.

The two are mutually exclusive for free, because a slot holds one module. That is the whole mechanism.

- [ ] **Step 5: Run the suite**

Run: `cd server; gleam test`
Expected: PASS, all four Sparrow tests included.

If `out_of_slot_bounds:<id>` appears, a patch cell landed on a tile whose SW digit is not the module's slot — re-run `tools/slotmap.py` and compare against the patch origin. If `invalid_resolved_plan` appears, the helm `h` is missing or you put it in a centre position.

- [ ] **Step 6: Walk her, then commit**

Run the server with `DH_SHIP_CLASS=server/shipclasses/sparrow.json` and walk the interior. This is the only human-eyeball check in PR 1 and it is worth doing: confirm the cockpit reads as a cockpit, both dock ports open outward, and nothing is unreachable.

```bash
cd server; gleam format src test
git add server/modules/rijay server/test/sparrow_test.gleam
git commit -m "feat(sparrow): cockpit, packet locker and ranger package; range or speed, not both (#M4)"
```

---

### Task 5: Schema coverage and the docs PR 1 owes

**Files:**
- Modify: `server/schemas/hull.schema.json`, `server/schemas/part.schema.json` (only if they reject the new documents)
- Modify: `docs/deckplan-format.md` (stale console prose)
- Modify: `docs/modules.md` (naming grammar, the Sparrow)

**Interfaces:**
- Consumes: everything in Tasks 1-4.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Confirm the schemas already accept the new documents**

`server/test/data_schema_test.gleam` validates every shipped document, so Task 4's green run already proved this — unless it failed, in which case the schema is what to fix. Read `server/schemas/hull.schema.json` and `part.schema.json` and confirm nothing pins `mounts` to a single entry, `size` to `"m"`, or the id pattern to a `rijay.` prefix. Fix only what actually rejects.

- [ ] **Step 2: Fix the stale console prose in `docs/deckplan-format.md`**

Its "Glyph key" section still lists `h`/`c`/`b` as **centre** glyphs carrying a `console` kind. That has been wrong since the pass-2 decor migration moved consoles to wall mounts: `server/glyphs.json` has no centre `h`, `c` or `b` at all, and all three are **edge fixtures** with a `console` kind. Correct the bullet so it says consoles are wall-mounted edge fixtures, and keep the existing note that a letter's meaning depends on whether it sits in the centre or on an edge — that part is still true and is exactly why `d` means a floor bed in the centre and a wall bunk on an edge.

- [ ] **Step 3: Record the naming grammar and the Sparrow in `docs/modules.md`**

- **Part naming:** `<manufacturer>.<kind>.<model>`. Rijay name engines after birds — distinct from the birds their hulls are named for — followed by a thrust class in units of ten and a block designation. Consolidated Orbital use a fleet-standard alphanumeric. **A part id names the manufacturer that built the part, not the hull it happens to be bolted to**; `rijay.engine.consol_patch` broke that and is now `consol.engine.co17f_2`.
- **The Mockingbird has three engine mounts**, matching the three nozzle anchors in her art, and her reactor covers them with exactly zero headroom, so upgrading her centre engine refuses for `power`.
- **The Sparrow**: one deck, two slots, three `s` mounts of which two ship filled. Note what she was the first shipped content to exercise — a single-deck hull, multiple mounts, an unfitted mount, and `mount size >= part size`.
- Update the worked part example at line 342 to the new id.

- [ ] **Step 4: Run both suites and commit**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green.

```bash
git add server/schemas docs
git commit -m "docs(m4): part naming grammar, the Sparrow, and consoles are edge fixtures (#M4)"
```

**PR 1 ends here.** Open it as "M4 iteration 2b, part 1: engine naming, the Mockingbird's three engines, and the Sparrow". Wait for review before starting Task 6 — the Sparrow's lessons are supposed to reach the Goldfinch before her decks are drawn.

---

# PR 2 — The Goldfinch

### Task 6: The Goldfinch hull

> Dedicated passenger carrier. Similar to the mockingbird, especially in cockpit and neck. Body is much slimmer than the mockingbird, with two rows of windows on the sides (something like an A380 but not as long). Single medium engine centrally mounted on the stern. Small engines mounted to the sides of the back, on struts. — `docs/lore.md`

**The A380 is a double-decker and "two rows of windows" is the second deck seen from outside.** That is the reading this hull is built on, and it is what makes "slimmer than the Mockingbird" and "carries far more passengers" hold together at once: the volume went vertical, not wide.

**Files:**
- Create: `server/shipclasses/goldfinch.json`
- Test: `server/test/goldfinch_test.gleam`

**Interfaces:**
- Consumes: `rijay.engine.stork_240c2` and `rijay.engine.wren_90b`.
- Produces: hull id `goldfinch`; 15 slots; mount ids `engine_center` (`m`), `engine_port` (`s`), `engine_stbd` (`s`).

**The slot table — fifteen, and fifteen is near a real ceiling.** A slot digit is one hex character, so **16 is the hard maximum for any hull** and she is drawn to 15 deliberately. If the drawing wants a 16th, stop and report it rather than working around it; that is a genuine finding about the format.

| digit | id | deck | region |
|---|---|---|---|
| 1 | `cockpit` | Upper | bow, `x1-3`, one row |
| 2-7 | `cabin_u_p_a`, `cabin_u_s_a`, `cabin_u_p_b`, `cabin_u_s_b`, `cabin_u_p_c`, `cabin_u_s_c` | Upper | six 1×2 cabins, port and starboard of the corridor |
| 8-d | `cabin_l_p_a`, `cabin_l_s_a`, `cabin_l_p_b`, `cabin_l_s_b`, `cabin_l_p_c`, `cabin_l_s_c` | Lower | six more, same pattern |
| e | `galley` | Lower | forward of the lower cabins |
| f | `hold` | Lower | aft |

`p` = port, `s` = starboard, `a`/`b`/`c` = fore to aft. Twelve cabins, all the identical 1×2 shape.

- [ ] **Step 1: Write the failing test**

Create `server/test/goldfinch_test.gleam`:

```gleam
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — `shipclasses/goldfinch.json` does not exist.

- [ ] **Step 3: Author the three decks**

Create `server/shipclasses/goldfinch.json`. Each deck is **5 tiles wide × 14 tall = 15 columns × 42 rows**, the same beam as the Sparrow — she is slim. Interior runs `x1..x3`; `x0` and `x4` are void margin.

The cross-section is the whole design: **`x1` = port cabin, `x2` = corridor, `x3` = starboard cabin.** Every cabin is one column wide and two rows tall, so each pair of rows is one port cabin and one starboard cabin facing each other across the corridor.

**Upper deck** (`y0` and `y13` void margin):

| y | content | slot digits (SW of `x1`, `x3`) |
|---|---|---|
| 1 | cockpit, `x1-3` | `1` on all three |
| 2 | neck passage, fixed hull | none |
| 3-4 | cabins fore | `2` at `x1`, `3` at `x3` |
| 5-6 | cabins middle | `4` at `x1`, `5` at `x3` |
| 7-8 | cabins aft | `6` at `x1`, `7` at `x3` |
| 9 | stair landing, `x` at `x2`, fixed hull | none |
| 10-12 | aft structure, fixed hull | none |

**Mezzanine**: void everywhere except one band carrying the dock ports, drawn exactly on the Mockingbird's pattern (`server/shipclasses/mockingbird.json`, Mezzanine deck, grid rows 61-66 — read them and copy the shape). A stairs tile `x` at `x2` vertically aligned with the Upper and Lower landings, a `Q` at `x1` with a `=` on its **W** edge and void beyond, and a `Q` at `x3` with a `=` on its **E** edge and void beyond.

**Lower deck**, laid out explicitly so the cabin patch origins in Task 7 are unambiguous:

| y | content | slot digits (SW of `x1`, `x3`) |
|---|---|---|
| 1-2 | `galley`, `x1-3` | `e` on all six tiles |
| 3-4 | cabins fore | `8` at `x1`, `9` at `x3` |
| 5-6 | cabins middle | `a` at `x1`, `b` at `x3` |
| 7-8 | cabins aft | `c` at `x1`, `d` at `x3` |
| 9 | stair landing, `x` at `x2`, fixed hull | none |
| 10-12 | `hold`, `x1-3` | `f` on all nine tiles |

The cabin rows are at the same `y` on both decks — 3, 5 and 7 — so the twelve targets differ only in `deck` and `x` beyond their slot ids.

Rules that must hold in every row you draw, and the reason each one exists:

1. **Slot perimeters are open on the hull side.** A cabin's walls, its door onto the corridor and its window are drawn by `rijay.cabin.standard`, never by the hull. The hull draws only its own skin and the corridor.
2. **The corridor at `x2` is fixed hull** and runs unbroken from the cockpit passage to the aft structure on both cabin decks. This is what guarantees connectivity without anyone analysing it.
3. **Stairs must be vertically aligned** across Upper, Mezzanine and Lower — a stairs tile connects to the tile at the same `(x, y)` on the adjacent deck.
4. **Both `Q` tiles' doors face void**, port to port and starboard to starboard. Symmetric.

Hull metadata:

```json
  "mass": 90.0,
  "provides": { "power": 34 },
  "requires": { "engine": 1 },
  "mounts": [
    { "id": "engine_center", "kind": "engine", "size": "m" },
    { "id": "engine_port",   "kind": "engine", "size": "s" },
    { "id": "engine_stbd",   "kind": "engine", "size": "s" }
  ],
  "cargo": { "capacity": 4, "handling": "breakbulk" },
  "dock_port_orientation": 90.0,
  "dock_standoff": 16.0
```

`default_loadout` installs `goldfinch.cockpit.stock` in `cockpit`, `rijay.cabin.standard` in **all twelve** cabin slots, `goldfinch.galley.stock` in `galley`, `goldfinch.hold.breakbulk` in `hold`, and all three engines: a Stork 240-C2 on `engine_center`, a Wren 90-B on each strut.

**The power budget:** twelve cabins at 1 each = 12, cockpit 2, galley 2, hold 1, engines 4 + 3 + 3 = 10. Total **27**, against `power: 34` — seven to spare. She is a liner, not a starter ship; her tension is mass and passengers, not amps. Per the lore a passenger transport needs less thrust overall, so her figures should land soft and heavy: mass 90 + modules + 20 of engine against 4200 thrust.

- [ ] **Step 4: Verify the slot map, deck by deck**

Run: `python tools/slotmap.py server/shipclasses/goldfinch.json`

Expected: digit `1` across three bow tiles; digits `2`-`7` as six 1×2 columns flanking an unpainted corridor on the Upper; `8`-`d` likewise on the Lower with `e` forward and `f` aft; the Mezzanine unpainted entirely.

**Do not proceed until this matches.** Twelve near-identical regions are exactly the case where a misplaced digit is invisible in the raw JSON and produces an `out_of_slot_bounds` you will spend an hour localising.

- [ ] **Step 5: Run the suite**

Run: `cd server; gleam test`
Expected: the three new tests PASS. Her default loadout does not resolve yet; Tasks 7 and 8 supply the modules.

- [ ] **Step 6: Commit**

```bash
cd server; gleam format src test
git add server/shipclasses/goldfinch.json server/test/goldfinch_test.gleam
git commit -m "feat(goldfinch): a double-decked liner, twelve cabin slots of one shape (#M4)"
```

---

### Task 7: One cabin document furnishes a hull it was never drawn for

**This is the task the whole design rests on.** If it needs a second cabin document, the rule iteration 2a shipped is wrong, and saying so is a successful outcome.

**Files:**
- Modify: `server/modules/rijay/cabin_standard.json` (**+12 targets, no new file**)
- Test: `server/test/goldfinch_test.gleam`

**Interfaces:**
- Consumes: the twelve `cabin_*` slots from Task 6.
- Produces: `rijay.cabin.standard` targeting two hulls.

- [ ] **Step 1: Write the failing test**

Append to `server/test/goldfinch_test.gleam`:

```gleam
/// The claim iteration 2a shipped and this iteration tests: one document,
/// many hulls. If the Goldfinch ever needs a cabin file of her own, this
/// fails and the rule was wrong.
pub fn one_cabin_document_serves_both_hulls_test() {
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(cabin) = dict.get(mods, "rijay.cabin.standard")
  let hulls = list.unique(list.map(cabin.targets, fn(t) { t.hull }))
  assert list.sort(hulls, string.compare) == ["goldfinch", "mockingbird"]
  let goldfinch_targets =
    list.filter(cabin.targets, fn(t) { t.hull == "goldfinch" })
  assert list.length(goldfinch_targets) == 12
  // And no second cabin document exists anywhere.
  let cabin_docs =
    dict.keys(mods) |> list.filter(fn(id) { string.contains(id, "cabin") })
  assert cabin_docs == ["rijay.cabin.standard"]
}

/// Her whole stock fit resolves: twelve cabins, a galley, a hold, three
/// engines of two different sizes.
pub fn her_default_loadout_resolves_test() {
  let assert Ok(h) = hull.load("shipclasses/goldfinch.json")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(_) =
    loadout.resolve(glyphs.default(), h, modules, parts, loadout.default_for(h))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — `rijay.cabin.standard` targets only `mockingbird`.

- [ ] **Step 3: Add twelve targets to the existing document**

Append twelve entries to the `targets` array in `server/modules/rijay/cabin_standard.json`. **Create no new file.** Each is:

```json
    {
      "hull": "goldfinch",
      "slots": ["cabin_u_p_a"],
      "patches": [
        {
          "deck": 0, "x": 1, "y": 3,
          "grid": [
            "###",
            "wd#",
            "#e#",
            "#e#",
            "# =",
            "###"
          ]
        }
      ]
    },
```

There are exactly **two distinct grids**, because the Goldfinch is a purpose-built liner rather than a hand-carved classic — her cabins are regular where the Mockingbird's five are all different. Port cabins take the grid above: window `w` on the **W** skin, wall bunk `d` above it, seats, and the door `=` on the **E** edge onto the corridor. Starboard cabins are its mirror — window on the **E** skin, door `=` on the **W** edge:

```json
          "grid": [
            "###",
            "#dw",
            "#e#",
            "#e#",
            "= #",
            "###"
          ]
```

The twelve differ **only in `deck`, `x`, `y` and the slot id**: `x: 1` for every port cabin and `x: 3` for every starboard one, `deck: 0` for the six Upper and `deck: 2` for the six Lower, and `y` = 3, 5, 7 fore to aft on the Upper and whatever the Lower's cabin block starts at.

That is the payoff stated as plainly as it goes — one concept, one document, twelve placements — and it only works because a target's patch is positioned by its own `x`/`y` rather than by the drawing.

- [ ] **Step 4: Run the suite**

Run: `cd server; gleam test`
Expected: `one_cabin_document_serves_both_hulls_test` PASSES.

`her_default_loadout_resolves_test` still fails on `unknown_module:goldfinch.cockpit.stock` — that is Task 8. Leave it failing and say so in the commit; do not stub the missing modules to make it green.

- [ ] **Step 5: Commit**

```bash
cd server; gleam format src test
git add server/modules/rijay/cabin_standard.json server/test/goldfinch_test.gleam
git commit -m "feat(goldfinch): twelve cabins from the one standard cabin document (#M4)"
```

---

### Task 8: The Goldfinch's own modules

**Files:**
- Create: `server/modules/goldfinch/cockpit_stock.json`, `server/modules/goldfinch/galley_stock.json`, `server/modules/goldfinch/hold_breakbulk.json`

**Interfaces:**
- Consumes: slots `cockpit`, `galley`, `hold` from Task 6.
- Produces: module ids `goldfinch.cockpit.stock`, `goldfinch.galley.stock`, `goldfinch.hold.breakbulk`.

Filed under `goldfinch/` rather than `rijay/` because each is drawn to one hull's specific geometry, the same reason `mockingbird.commons.crew` is.

- [ ] **Step 1: The cockpit**

`server/modules/goldfinch/cockpit_stock.json`, `mass: 4.0`, `provides: {"seats": 2}`, `requires: {"power": 2}`, one target on `goldfinch`/`cockpit`, patch at `deck: 0, x: 1, y: 1`, a 9×3 grid on the Sparrow cockpit's pattern:

```json
          "grid": [
            "####h####",
            "we  e  ew",
            " #  =  # "
          ]
```

Two seats — she is crewed, not single-seat — a helm `h` on the bow-facing N edge, windows outboard, and a door aft into the neck. **Without the `h` the entire fit dies as `invalid_resolved_plan`.**

- [ ] **Step 2: The galley**

`server/modules/goldfinch/galley_stock.json`, `mass: 5.0`, `provides: {"galley": 1}`, `requires: {"power": 2}`, one target on `goldfinch`/`galley`, patch covering `x1-3` across the galley's two rows on the Lower deck (`deck: 2`). Draw tables `t` and seats `e` — adjacent tables merge into one surface and nearby seats turn to face them, so a run of `t` with `e` alongside renders as a dining room with no further work. Model the layout on `server/modules/mockingbird/commons_crew.json`.

- [ ] **Step 3: The hold**

`server/modules/goldfinch/hold_breakbulk.json`, `mass: 6.0`, `requires: {"power": 1}`, one target on `goldfinch`/`hold`, patch covering the hold's three rows on the Lower deck. Draw a **cargo console `c` on an edge** — a hold module that forgets it leaves the crew nowhere to work cargo — and enough `p` pallets to be worth flying; her derived capacity is however many you draw, and the hull's `cargo.capacity: 4` is only the fallback for a fit that draws none.

- [ ] **Step 4: Run the suite**

Run: `cd server; gleam test`
Expected: PASS, `her_default_loadout_resolves_test` included.

If `tag_deficit:power` appears, recount against Task 6's budget: 12 cabins + cockpit 2 + galley 2 + hold 1 + engines 10 = 27 of 34.

- [ ] **Step 5: Walk her, then commit**

Run the server with `DH_SHIP_CLASS=server/shipclasses/goldfinch.json` and walk all three decks. Check the corridor runs unbroken bow to stern on both cabin decks, every cabin door opens onto it, the stairs connect Upper → Mezzanine → Lower, and both dock ports open outward.

```bash
cd server; gleam format src test
git add server/modules/goldfinch
git commit -m "feat(goldfinch): cockpit, galley and hold (#M4)"
```

---

### Task 9: The rename, the harness, and what 2b proved

**Files:**
- Modify: `docs/lore.md`, `DESIGN.md:526`, `docs/modules.md`
- Modify: `harness/` — a Sparrow walk case

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Finch → Goldfinch**

A finch is a tiny bird and this hull is Mockingbird-scale; the gold carries the luxury connotation a passenger liner wants. Rename in `docs/lore.md` (the "The Finch" entry under Rijay Drive Yards), `DESIGN.md:526` ("can be the Finch's engines"), and the four references in `docs/modules.md` (lines 10, 76, 162, 443). Keep the lore entry's body — only the name changes.

- [ ] **Step 2: Walk the Sparrow in the harness**

The pytest harness's walk driver has only ever seen multi-deck hulls. Add a case that points `DH_SHIP_CLASS` at `server/shipclasses/sparrow.json` and walks bow to stern, following the pattern of the existing fixture-hull tests in `harness/`. Read `harness/walk.py` and `harness/deckplan.py` first — the driver models tile-centre voidness only and has no edge model, which is a known limitation, so keep the path down the middle of the pod.

Run: `cd harness; python -m pytest -v`
Expected: 30 passed, 2 deselected.

- [ ] **Step 3: Record the findings in `docs/modules.md`**

Replace the "Iteration 2b is the Sparrow and Finch hulls" paragraph with what actually happened. Cover:

- The two hulls, what each was the first shipped content to exercise, and that `rijay.cabin.standard` now serves two hulls with twelve Goldfinch placements from two drawings.
- **The 16-slot ceiling.** A slot digit is one hex character, so no hull can carry more than sixteen slots. The Goldfinch sits at fifteen. This is a real limit of the format that only surfaced when a second hull was drawn, and it should be written down before someone designs a hull that needs twenty.
- **Anything that did not survive.** If a rule had to bend, say which and why, plainly. That is the finding this iteration existed to produce and it is worth more than a clean report.

- [ ] **Step 4: Run both suites and commit**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green.

```bash
git add docs DESIGN.md harness
git commit -m "docs(m4): the Goldfinch rename, and what the second and third hulls proved (#M4)"
```

**PR 2 ends here.** Open it as "M4 iteration 2b, part 2: the Goldfinch".

---

## Definition of done

- `cd server; gleam test` and `cd harness; python -m pytest -v` both green — 30 harness tests after Task 9.
- The Mockingbird flies on three engines matching her art, her deck unchanged tile for tile, her reactor at exactly zero headroom, and a Stork in her centre mount refusing for `power`.
- `sim_test`'s refused-refit case is back on `tag_deficit:power`.
- The Sparrow: one deck, two slots, three `s` mounts with two filled, symmetric dock ports, and range-or-speed enforced by the validator.
- The Goldfinch: two passenger decks of regular cabins, all twelve furnished by `rijay.cabin.standard`, with no bespoke cabin document anywhere.
- No part id names a manufacturer that did not build it.
- `docs/modules.md` records what 2b proved, what it disproved, and the 16-slot ceiling.
