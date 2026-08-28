# Sparrow Layout Revision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every dead tile from the Sparrow by deleting her aft row and promoting her forward corridor row into a third slot, `fore`, whose centre tile is deliberately excluded so the hull keeps its spine.

**Architecture:** Three changes to authored data, no engine changes. (1) The hull grid loses its aft interior row and gains an aft cap on the dock row. (2) The forward row's two flanking tiles get slot digit `3`; the centre tile stays unslotted hull. (3) A new optional module `rijay.fore.bunk` occupies the two flanking tiles and declares its centre column `void`, which `loadout.check_bounds` already enforces — a fore module that paves the corridor is refused with `out_of_slot_bounds`.

**Tech Stack:** Gleam/OTP server (`server/`), gleeunit tests, pytest protocol harness (`harness/`), JSON deck-plan documents.

**Spec:** `docs/superpowers/specs/2026-07-31-m4-iteration2b-sparrow-goldfinch-design.md` (the Sparrow section, lines 140-194). This plan revises the layout that spec shipped; the spec's stated intent — "her slots are shaped so weapons land later without rework" — is the reason the fore slot is not named `cabin`.

## Design decisions (from the 2026-08-28 walkthrough)

These were settled by walking the shipped hull in-engine and are the *why* behind each task:

- **No dead space.** She is the smallest hull; 12 of her 18 interior tiles could never be
  furnished, because only tiles carrying a slot digit can ever receive a module. That is what
  made her read as "a little square with nothing in it".
- **The aft row goes.** Boarding becomes the dock row itself. You step through a hatch onto a
  `Q` tile and are one tile from the hold's aft door.
- **The forward row becomes a slot, not more hold.** Keeping the hold at 3x2 preserves the
  packet-vs-ranger either/or exactly as specified and tested, and gives her a second refit
  axis instead of one all-or-nothing decision. Merging it into a 3x3 hold would leave the
  cheapest hull in the game — the one a new player refits first, in the milestone that builds
  the refit loop — with exactly one choice on board.
- **The slot is named for the space, not its occupant.** `cockpit` and `bay` are space-names;
  `fore` joins them. Naming it `cabin` would bake "only a bed goes here" into every
  `default_loadout` on disk, the same mistake as hull-namespacing module ids
  (see `docs/modules.md`'s module-id grammar).
- **The centre tile is excluded from the slot.** This is enforcement, not convention:
  `loadout.gleam:277-323` (`check_bounds`) requires every non-void overlay cell to land on a
  hull cell carrying one of the target's claimed slot digits, and `stamp`/`patch_tiles`
  (`loadout.gleam:327-342`, `374-383`) skip a patch tile whose centre glyph is void
  *entirely, all four edges included*. So a fore module cannot touch the corridor tile's
  floor **or** its walls. A slot is an arbitrary set of tiles, never required to be a
  rectangle.
- **Nothing is lost by excluding it.** The corridor's endpoints are pinned by the cockpit's
  aft door and the hold's fore door, both drawn on the centre column by modules in *other*
  slots. In a single-row gap there is no north or south to shift a corridor into.
- **The fore slot ships empty.** `docs/lore.md` is explicit that she has no bed unless you fit
  one. `rijay.fore.bunk` is an option, never a default.
- **`dock_standoff` stays 8.0.** `world.moored_position` (`world.gleam:278-298`) offsets the
  ship's centre along the *berth normal*. She moors side-on (`dock_port_orientation: 90.0`,
  ports on her port and starboard sides), so the normal runs along her width axis, which this
  change does not touch. Shortening her length does not move her along that axis.

## Global Constraints

- **Formatting is CI-enforced.** `gleam format --check src test` must pass. Run
  `gleam format src test` before every commit. The repo's pre-commit hook (`.githooks/`)
  blocks unformatted staged `server/**/*.gleam`.
- **Slot digits are a single hex character in the tile's SW corner**, mirroring the NE colour
  digit. The Sparrow's are `1` = `cockpit`, `2` = `bay`, and new `3` = `fore`. (The
  slot-marker refactor in `docs/superpowers/plans/2026-08-01-slot-markers-in-the-tile-centre.md`
  will move these to the tile centre later; do not anticipate it here.)
- **A stamp never overwrites the SW corner** (hull-owned) but does overwrite everything else
  in the tile, the NE colour digit and all four edges included.
- **Module id grammar:** `<manufacturer>.<kind>.<model>`. The id names who built it, not which
  hull uses it.
- **Tiles are 1m.** Deck grids are 3 characters per tile in both axes: tile `(tx, ty)` owns
  rows `3ty..3ty+2` and columns `3tx..3tx+2`, with its centre glyph at `(3ty+1, 3tx+1)` and
  its SW corner at `(3ty+2, 3tx)`.
- **Running the server test suite:** from `server/`, with
  `export PATH="$USERPROFILE/scoop/shims:$PATH"`, run `gleam test`. It spawns real sim servers
  and takes several minutes; run it in the background and wait, do not assume a hang.
- **Never commit to `main`.** All code lands as a PR for review. Docs-only `.md` commits may go
  direct.

---

### Task 1: Revise the hull grid

Delete the dead aft interior row, cap the dock row, and mark the forward row's two flanking
tiles as slot `fore` while leaving its centre tile unslotted.

**Files:**
- Modify: `server/shipclasses/sparrow.json` (the `decks[0].grid` array and the `slots` array)
- Test: `server/test/sparrow_test.gleam`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a hull with `slots` of length 3, the third being
  `{ "digit": 3, "id": "fore", "name": "Fore bay" }`. Task 2's module targets slot id
  `"fore"` on hull id `"sparrow"` and stamps at `deck: 0, x: 1, y: 2`.

- [ ] **Step 1: Update the failing test first**

In `server/test/sparrow_test.gleam`, change the slot-count assertion in
`she_is_a_single_deck_hull_test` and add a new test directly beneath it:

```gleam
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `server/`: `gleam test`

Expected: `she_is_a_single_deck_hull_test` fails on the slot count (2, not 3).
`she_resolves_with_the_fore_slot_empty_test` passes already — it is a
characterisation guard, and that is fine; it must still pass at the end.

- [ ] **Step 3: Rewrite the hull grid**

In `server/shipclasses/sparrow.json`, replace the entire `decks[0].grid` array with the
21-row grid below. Two changes from the old 24-row grid: row 8 gains the `3` slot digits at
columns 3 and 9, and the old rows 17-20 (`"               "` plus the aft interior row and its
cap) collapse into a single cap row so the dock row is now the sternmost interior row.

```json
      "grid": [
        "               ",
        " .  .  .  .  . ",
        "               ",
        "   #########   ",
        " . #       # . ",
        "   1  1  1     ",
        "               ",
        " . #       # . ",
        "   3     3     ",
        "               ",
        " . #       # . ",
        "   2  2  2     ",
        "               ",
        " . #       # . ",
        "   2  2  2     ",
        "               ",
        " . =Q     Q= . ",
        "   #########   ",
        "               ",
        " .  .  .  .  . ",
        "               "
      ]
```

Every row is exactly 15 characters. Verify that before moving on — a short row silently
shifts every tile east of the truncation.

Reading it as tiles: `ty=1` cockpit (digit `1`), `ty=2` the fore row — tiles `(1,2)` and
`(3,2)` carry digit `3`, tile `(2,2)` carries nothing and stays hull — `ty=3` and `ty=4` the
hold (digit `2`), `ty=5` the dock row with both `Q` ports, capped to the south.

Note row 8: `"   3     3     "` puts `3` at columns 3 and 9 (the SW corners of tiles `(1,2)`
and `(3,2)`) and leaves column 6 — tile `(2,2)`'s SW corner — blank. That blank is the whole
mechanism.

- [ ] **Step 4: Add the fore slot**

In the same file, extend the `slots` array:

```json
  "slots": [
    { "digit": 1, "id": "cockpit", "name": "Cockpit" },
    { "digit": 2, "id": "bay",     "name": "Pod bay" },
    { "digit": 3, "id": "fore",    "name": "Fore bay" }
  ],
```

Leave `default_loadout`, `mass`, `provides`, `requires`, `mounts`, `cargo`,
`dock_port_orientation` and `dock_standoff` untouched. `dock_standoff` stays `8.0` for the
reason recorded in the design decisions above.

- [ ] **Step 5: Run the tests to verify they pass**

Run from `server/`: `gleam test`

Expected: PASS, including the pre-existing `her_default_loadout_resolves_test`
(`cargo_capacity == 6`), `the_third_engine_and_the_ranger_package_cannot_both_fit_test`
(the power arithmetic is unchanged: cockpit 2 + packet 1 + three engines 9 = 12 of 12), and
`a_medium_engine_does_not_fit_her_small_mount_test`.

If `her_default_loadout_resolves_test` fails on capacity, a grid row is the wrong length and
the hold's pallets have shifted off their tiles.

- [ ] **Step 6: Eyeball the carve**

Run from the repo root: `python tools/slotmap.py server/shipclasses/sparrow.json`

Expected: three slot regions. `cockpit` and `bay` unchanged in shape; `fore` showing as two
separate single tiles with a gap between them. If `fore` renders as a contiguous 3-wide band,
column 6 of row 8 is not blank.

- [ ] **Step 7: Commit**

```bash
git add server/shipclasses/sparrow.json server/test/sparrow_test.gleam
git commit -m "feat(m4): give the sparrow a fore slot and drop her dead aft row (#M4)"
```

---

### Task 2: The fore bunk, and proof the corridor is protected

Ship one optional fore module, and pin the corridor-protection rule against the real hull with
a module that tries to break it.

**Files:**
- Create: `server/modules/rijay/fore_bunk.json`
- Test: `server/test/sparrow_test.gleam`

**Interfaces:**
- Consumes: hull `sparrow` with slot id `"fore"` (digit `3`) on tiles `(1,2)` and `(3,2)`,
  from Task 1.
- Produces: module id `rijay.fore.bunk`, mass `1.0`, `provides: { berths: 1 }`,
  `requires: { power: 1 }`. Task 3 fits it by that exact id.

- [ ] **Step 1: Write the failing tests**

Add to `server/test/sparrow_test.gleam`. The second test needs `gleam/dict`, so add
`import gleam/dict` to the import block at the top of the file, keeping the imports
alphabetically ordered (it goes after `import dh_server/part` and before `import gleam/list`).

```gleam
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
  let assert Ok(_) =
    loadout.resolve(glyphs.default(), h, modules, parts, liveaboard)
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
  // Identical to the shipped bunk except for ONE character: the centre glyph
  // of the middle tile is a floor space rather than void, so the stamp claims
  // a tile the hull never offered.
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `server/`: `gleam test`

Expected: `the_fore_bunk_fits_beside_two_engines_but_not_three_test` fails with
`unknown_module:rijay.fore.bunk`. `a_fore_module_may_not_pave_the_corridor_test` should already
PASS — it depends only on Task 1's hull and the existing `check_bounds`. If it fails with
anything other than the expected error, stop: the corridor is not actually protected and the
rest of this plan rests on it.

- [ ] **Step 3: Write the module document**

Create `server/modules/rijay/fore_bunk.json`:

```json
{
  "schema": 1,
  "id": "rijay.fore.bunk",
  "name": "Watch bunk",
  "mass": 1.0,
  "provides": { "berths": 1 },
  "requires": { "power": 1 },
  "targets": [
    {
      "hull": "sparrow",
      "slots": ["fore"],
      "patches": [
        {
          "deck": 0, "x": 1, "y": 2,
          "grid": [
            "###...###",
            "#d=...=e#",
            " # ... # "
          ]
        }
      ]
    }
  ]
}
```

How to read the grid. It is 3 tiles wide by 1 tall, stamped with its north-west tile on hull
tile `(1, 2)`. Within each row, tile `px` owns characters `3px` (west edge), `3px+1` (centre)
and `3px+2` (east edge).

- Middle column is `...` on every row: the centre glyph of tile `px=1` is void, so
  `patch_tiles` drops that tile and `stamp` never writes any of its nine characters. The
  corridor stays exactly as the hull authored it. The dots on the edge rows are cosmetic —
  the tile is already skipped — but they make the passthrough obvious to a reader.
- Port tile (`px=0`): `#` hull skin to the west, `d` floor bed at the centre, `=` a door on
  its east edge opening onto the corridor.
- Starboard tile (`px=2`): `=` a door on its west edge, `e` seat at the centre, `#` hull skin
  to the east.
- Row 0 is solid wall to the north (the cockpit is enclosed by its own module anyway); row 2
  is wall to the south, and its characters at columns 0, 3 and 6 sit on SW corners, which the
  stamp never writes — the hull's `3` digits survive regardless of what is written there.
  Blanks there match the convention in `bay_packet.json` and `cockpit_solo_3x1.json`.

Use `d` and `e` exactly: they are the registered centre glyphs for a floor bed and a seat
(`server/glyphs.json`). A wall-mounted bunk is the same letter on an *edge*, which is a
blocking fixture — putting `d` on an edge here would wall off the tile it decorates.

- [ ] **Step 4: Run the tests to verify they pass**

Run from `server/`: `gleam test`

Expected: PASS, all tests including both new ones.

- [ ] **Step 5: Format and commit**

```bash
cd server && gleam format src test && cd ..
git add server/modules/rijay/fore_bunk.json server/test/sparrow_test.gleam
git commit -m "feat(m4): a watch bunk for the sparrow's fore bay, corridor protected (#M4)"
```

---

### Task 3: Re-walk her, and update the harness's account of her stern

The harness walk test drives a character the length of the Sparrow. Its route is unchanged by
this revision, but its prose describes a stern that no longer exists.

**Files:**
- Modify: `harness/test_m4_sparrow_walk.py` (module docstring and the test's docstring)

**Interfaces:**
- Consumes: the revised hull from Task 1. The walk still runs helm → `dock0`, and `dock0` is
  still tile `(1, 5)`; the BFS route `(2,1) → (2,2) → (2,3) → (2,4) → (2,5) → (1,5)` is
  unchanged because only the row *aft* of the dock row was removed.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Run the harness test unchanged, to confirm the route survived**

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
cd harness
python -m pytest test_m4_sparrow_walk.py -v
```

Expected: PASS. The test is coordinate-independent — it looks `dock0` up via `console_tile`
rather than hardcoding it — so a pass here means the cockpit's exit door, the corridor, both
of the hold's doors and the dock row's floor all still resolve as intended.

If it FAILS with a stall rather than a missing route, suspect the BFS tie-break: paths down
the middle column and down the port column are the same length, the port column is not
actually walkable (the hold's north edge carries the `c` cargo console, a blocking fixture),
and `walk.py` models tile-centre voidness only with no edge model. That tie predates this
change, but this is where it would surface.

- [ ] **Step 2: Correct the docstrings**

In `harness/test_m4_sparrow_walk.py`, the module docstring's first paragraph currently ends
"to a dock port one tile short of her stern cap." Replace that clause with "to a dock port on
her sternmost row, hard against her stern cap." In the test function's docstring, replace
"walk to a dock port (the stern, barring the last tile-and-a-bit of aft corridor before the
hull cap)" with "walk to a dock port (the stern itself — her dock row is now her sternmost
interior row)."

Leave every assertion and the explanation of why the walk is a single BFS run untouched; that
reasoning is still exactly right and is the most valuable prose in the file.

- [ ] **Step 3: Re-run the harness test**

```powershell
cd harness
python -m pytest test_m4_sparrow_walk.py -v
```

Expected: PASS.

- [ ] **Step 4: Run the full server suite once more**

Run from `server/`: `gleam test`

Expected: PASS. Run it in the background; it takes several minutes.

- [ ] **Step 5: Walk her in the engine**

```bash
cd server && DH_SHIP_CLASS=shipclasses/sparrow.json gleam run
```

and in a second shell:

```bash
godot --path "<repo>/client" -- --username=<you> --password=dev
```

Confirm by eye: no dead row aft of the dock ports; the fore row reads as two small spaces
flanking a corridor; you can walk bow to stern without stopping. She will still wear the
Mockingbird's interior backdrop — exterior art and per-ship hull art are 2c, not this plan.

- [ ] **Step 6: Commit**

```bash
git add harness/test_m4_sparrow_walk.py
git commit -m "docs(m4): the sparrow's dock row is her stern now (#M4)"
```

---

### Task 4: Record the rule that makes this work

The reusable lesson is not about the Sparrow: it is that a slot is an arbitrary set of tiles,
and that excluding a tile is the enforceable way to reserve a corridor through a slot.

**Files:**
- Modify: `docs/deckplan-format.md` (the slot-digit section)
- Modify: `docs/modules.md` (the Sparrow's slot table, and the authoring rules)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Document the non-rectangular slot rule**

In `docs/deckplan-format.md`, in the section describing the SW-corner slot digit, add:

```markdown
A slot is an arbitrary SET of tiles, never required to be a rectangle or even to be
contiguous. Only tiles carrying the digit belong to the slot, and `loadout.check_bounds`
refuses any module whose overlay puts a non-void centre glyph on a tile that carries a
different digit or none at all (`out_of_slot_bounds`).

This makes tile exclusion the way to reserve structure that runs *through* a slot. Leave the
SW corner of a corridor tile blank and no module fitted to the surrounding slot can touch that
tile — not its floor, and not its walls either, because `stamp` skips a patch tile with a void
centre glyph in full, all nine characters. The Sparrow's fore bay is the shipped example: two
flanking tiles carry digit `3`, the tile between them carries nothing, and her spine survives
every possible refit rather than depending on each module author remembering to leave a gap.
Prefer this to a convention whenever a route must survive refit — nothing in the validator
does reachability analysis, so unbuildable beats discouraged.
```

- [ ] **Step 2: Update the Sparrow's entry**

In `docs/modules.md`, update the Sparrow's slot table to three slots — `cockpit`, `fore`
(tiles `(1,2)` and `(3,2)` only), `bay` — and add `rijay.fore.bunk` to the module list with
mass `1.0`, `provides: berths 1`, `requires: power 1`. Note that the fore slot ships empty by
default and that a bunk and a third engine cannot both be fitted, since her reactor provides
12 and cockpit 2 + packet 1 + bunk 1 + three Wrens 9 is 13.

Where the file records slot naming, add: slot ids name the SPACE, not the expected occupant —
`fore`, not `cabin` — for the same reason module ids name their manufacturer rather than a
hull: a name that encodes an assumption is expensive to undo once it is written into every
`default_loadout` on disk.

- [ ] **Step 3: Commit**

```bash
git add docs/deckplan-format.md docs/modules.md
git commit -m "docs(m4): a slot is a set of tiles, so exclude one to keep a corridor (#M4)"
```

---

## Follow-ups this plan deliberately does not do

- **Exterior art and hull proportions.** She is shorter now; her sprite does not exist yet.
  2c owns the art pipeline and per-ship `hull` on the snapshot.
- **Weapons.** The fore bay is shaped for them and nothing more. No weapon tags, mounts or
  modules exist, and inventing them here would be authoring bookkeeping for a system that does
  not exist — the same call the 2b spec made about `fuel` and `berths`.
- **The slot-marker refactor.** Adding a third slot digit makes the Sparrow one more hull the
  refactor in `docs/superpowers/plans/2026-08-01-slot-markers-in-the-tile-centre.md` will have
  to migrate. That is a known and accepted cost; it is three tiles.
