# Slot Markers in the Tile Centre — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a hull's deck plan readable by eye — move slot membership from the tile's SW corner to its centre, encoded as an uppercase letter, and free the lowercase namespace entirely for "what a tile is".

**Architecture:** A three-step migration so every task ends green: teach the parser the new encoding alongside the old, convert every document, then delete the old encoding. `Q` becomes `q` first, in its own task, so the whole uppercase range is available. Slot membership stops surviving the module bake — that is intentional and safe, because the hull document is always loaded and tile coordinates index the hull grid and the resolved plan identically.

**Tech Stack:** Gleam (Erlang target) server, gleeunit, JSON data validated by jesse schemas, Python/pytest protocol harness, `tools/slotmap.py`.

## Why

A slot digit lives in the tile's SW corner, which is column `3x` — the tile's *west* column. A port cabin's outboard skin is also on its west edge, so its digit and its wall share a column; a starboard cabin's skin is on its east edge (`3x+2`) while its digit is still at `3x`. Identical rule, mirrored geometry, so a symmetric ship reads lopsided in the raw JSON. The centre column (`3x+1`) is the only position that is the same for a tile and its mirror image.

Hex digits cannot go in the centre: `d`, `e` and `f` are live centre glyphs (floor bed, seat, decor), and the Goldfinch already uses `e` for her galley and `f` for her hold. Uppercase letters collide with nothing once `Q` moves to `q`.

The resulting invariant, which is the point of the whole change:

> **Lowercase says what a tile *is*. Uppercase says which slot it *belongs to*.**

It also lifts the per-hull slot ceiling from 16 to 26.

## Global Constraints

- **Baseline:** the head of `feat/m4-iteration2b` *after* the stair-offset commit lands. **Task 0 records the exact test counts**; every later task ends green against them.
- **Run `gleam test` in the FOREGROUND with `timeout: 600000`** and wait for the result. Do not background it. The harness suite takes ~3 minutes; give it a long timeout too.
- A **pre-commit hook runs `gleam format --check`**: run `cd server; gleam format src test` before committing, then re-stage.
- If `gleam` is not on PATH: `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"` (PowerShell) or `PATH="$HOME/scoop/shims:$PATH"` (bash).
- **No deck row may change its shape.** This migration moves a character from one position in a tile block to another. Every hull's walls, doors, floors and voids stay exactly where they are. `default_loadout_reproduces_the_authored_deck_test` is the arbiter for the Mockingbird.
- **No module document changes.** Modules reference slot *ids*, never digits. If a task appears to need a module edit, stop and report it.
- Builds and tests warning-clean; test output pristine.
- `python tools/slotmap.py <hull.json>` paints slot regions. Use it after every data conversion.

## Deck-plan facts you must have straight

- **Every tile is a 3×3 character block.** Tile `(x, y)` occupies rows `3y..3y+2`, columns `3x..3x+2`.
- Centre `(3y+1, 3x+1)`. N edge `(3y, 3x+1)`. S edge `(3y+2, 3x+1)`. W edge `(3y+1, 3x)`. E edge `(3y+1, 3x+2)`.
- **NE corner `(3y, 3x+2)` is the colour digit — hex, and it is NOT changing.** SW corner `(3y+2, 3x)` is today's slot digit.
- When a cell has no slot, `deckplan.gleam`'s serialiser renders SW as `corner(s, w)` — a derived wall-junction character. So SW is not spare space; freeing it makes wall corners render consistently everywhere instead of being punched out by digits.
- The bake **splices text and re-parses**. Nothing serialises a hull and reads it back, so markers need not survive a round trip through `loadout.stamp` — but the parse→serialise path at `deckplan.gleam:~825` must still round-trip an *unstamped* hull, or composites break.
- Current centre glyphs: `' ' . x Q s r e d p f l t g`. Current edge glyphs: `' ' # = v w h c b d`.

## File structure

| file | responsibility |
|---|---|
| `server/glyphs.json` | `Q` → `q`; the registry that defines both namespaces |
| `server/src/dh_server/glyphs.gleam` | any hardcoded `Q` |
| `server/src/dh_server/deckplan.gleam` | `Cell.slot` type, centre parse, marker parse, serialiser |
| `server/src/dh_server/hull.gleam` | `Slot` record, decoder, `validate` (uniqueness + range) |
| `server/src/dh_server/loadout.gleam` | `check_bounds` comparison |
| `server/src/dh_server/composite.gleam` | `slot: None` construction sites |
| `server/src/dh_server/stationclass.gleam` | station dock-port glyph |
| `server/schemas/hull.schema.json` | `digit` → `marker` |
| `server/shipclasses/{mockingbird,sparrow,goldfinch}.json` | grids + `slots` tables |
| `server/stationclasses/{highport,ring}.json` | `Q` → `q` |
| `server/test/fixtures/mockingbird_authored.json` | golden fixture |
| `server/test/fixtures/dock_testbed_hulls/`, `refit_testbed_hulls/`, `dock_testbed_stationclasses/` | testbed fixtures |
| `harness/deckplan.py`, `harness/fixtures/test_fixture.json` | the Python parser twin and its hull |
| `tools/slotmap.py` | renders slot regions |
| `docs/deckplan-format.md`, `docs/modules.md` | the format doc and the 16-slot finding |

---

### Task 0: Record the baseline

**Files:** none (measurement only).

**Interfaces:**
- Produces: the exact Gleam and harness test counts every later task must match.

- [ ] **Step 1: Run both suites and record the numbers**

Run: `cd server; gleam test` (foreground, `timeout: 600000`)
Run: `cd harness; python -m pytest -v`

Write both counts into your report. Every later task ends green at these numbers plus whatever tests it adds.

- [ ] **Step 2: Confirm the working tree is clean**

Run: `git status --short`
Expected: empty. If not, stop and report — this migration must start from a clean tree.

---

### Task 1: `Q` becomes `q`

The dock-port glyph is the only uppercase character in either namespace. It has to move before uppercase can mean "slot".

**Files:**
- Modify: `server/glyphs.json`, `server/src/dh_server/glyphs.gleam` (if it hardcodes `Q`)
- Modify: every grid containing a dock port — `server/shipclasses/*.json`, `server/stationclasses/{highport,ring}.json`, `server/test/fixtures/mockingbird_authored.json`, `server/test/fixtures/dock_testbed_hulls/dock_testbed.json`, `server/test/fixtures/dock_testbed_stationclasses/dock_testbed.json`, `server/test/fixtures/refit_testbed_hulls/refit_testbed.json`, `harness/fixtures/test_fixture.json`
- Modify: Gleam tests with inline grids — `server/test/{deckplan,loadout,shipclass,world,glyphs}_test.gleam`
- Modify: `harness/deckplan.py` if it names the glyph
- Modify: `docs/deckplan-format.md`, `docs/modules.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `q` is the dock-port centre glyph; `A`-`Z` are all unused.

- [ ] **Step 1: Write the failing test**

In `server/test/glyphs_test.gleam`:

```gleam
/// The dock port is lowercase like every other glyph that says what a tile
/// IS. Uppercase is reserved wholesale for slot membership — see
/// `docs/deckplan-format.md`. `Q` was the one exception and it is gone.
pub fn the_dock_port_glyph_is_lowercase_test() {
  let reg = glyphs.default()
  assert glyphs.center(reg, "q").tile == glyphs.Dock
  assert glyphs.center(reg, "Q").tile != glyphs.Dock
}
```

Read the real `glyphs.center` signature and the real name of the dock tile variant before writing this — `Dock` is a guess. Match what `glyphs.gleam` actually exports.

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — `q` is not a registered centre glyph.

- [ ] **Step 3: Rename the glyph in the registry**

In `server/glyphs.json`, change the dock-port entry's `glyph` from `"Q"` to `"q"`. Change nothing else about it.

- [ ] **Step 4: Rewrite every grid**

**Do this with a script, not by hand.** For each file listed above, replace `Q` with `q` **only inside deck/station grid row arrays** — never in prose, ids, or names. Write the script to load the JSON, walk to the grid arrays, and translate only those strings; do not run a blind text substitution over the file.

Then grep the whole repo for a surviving `Q` inside a grid row and report the result.

- [ ] **Step 5: Update the harness twin and the docs**

`harness/deckplan.py` — if it names `Q` anywhere, change it. Read the file; do not assume.
`docs/deckplan-format.md` and `docs/modules.md` — update the glyph key and any prose naming `Q`.

- [ ] **Step 6: Run both suites**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green at Task 0's counts + 1 Gleam test.

- [ ] **Step 7: Commit**

```bash
cd server; gleam format src test
git add server harness tools docs
git commit -m "refactor(deckplan): the dock port becomes q, freeing uppercase for slots (#M4)"
```

---

### Task 2: Teach the parser centre markers, alongside SW digits

Transitional: both encodings work. No data changes yet, so the whole suite stays green on unconverted documents.

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam`, `server/src/dh_server/hull.gleam`
- Modify: `harness/deckplan.py`
- Test: `server/test/deckplan_test.gleam`, `server/test/hull_test.gleam`

**Interfaces:**
- Consumes: Task 1's freed uppercase range.
- Produces: `Cell.slot: Option(String)` holding an uppercase letter; `hull.Slot(marker: String, id: String, name: String)`; hull documents may use `marker` or `digit`.

**The type change is the crux.** `Cell.slot` is `Option(Int)` today (`deckplan.gleam:63`) and `hull.Slot` carries `digit: Int` (`hull.gleam:27`). Both become the letter as a `String`. A hull authored with `digit: 3` decodes to `marker: "D"` — index 0 is `"A"`, so digit `n` maps to the `n`-th uppercase letter — and its SW digits still parse. This keeps `check_bounds` comparing one type.

- [ ] **Step 1: Write the failing tests**

In `server/test/deckplan_test.gleam`:

```gleam
/// A slot marker is an uppercase letter in the tile CENTRE. It reads as
/// plain floor, because a slot tile is always floor the module will draw on.
pub fn an_uppercase_centre_is_floor_and_records_its_slot_test() {
  let reg = glyphs.default()
  let assert Ok(g) =
    deckplan.parse_deck_with(reg, "t", ["###", "#B#", "###"])
  let assert Ok(cell) = deckplan.cell_at_xy(g, 0, 0)
  assert cell.tile == deckplan.Floor
  assert cell.slot == Some("B")
  assert cell.decor == None
}

/// The old SW-corner hex digit still parses while documents are migrating.
pub fn an_sw_hex_digit_still_records_its_slot_test() {
  let reg = glyphs.default()
  let assert Ok(g) =
    deckplan.parse_deck_with(reg, "t", ["###", "# #", "2##"])
  let assert Ok(cell) = deckplan.cell_at_xy(g, 0, 0)
  assert cell.slot == Some("C")
}
```

Confirm `parse_deck_with`'s real signature and `deckplan.Floor`'s real name before writing — read the module. Digit `2` maps to `"C"` because `0 -> "A"`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd server; gleam test`
Expected: FAIL — `cell.slot` is an `Int`, and `"B"` in a centre parses as an unregistered glyph.

- [ ] **Step 3: Change the types and the parse**

In `deckplan.gleam`:
- `Cell.slot` becomes `option.Option(String)`.
- Add a `parse_slot_marker(ch) -> Option(String)` returning `Some(ch)` for a single `A`-`Z` grapheme, `None` otherwise.
- In the cell constructor (`~line 145-154`): `slot` becomes "centre marker if present, else the SW hex digit converted to a letter". Keep `parse_hex_digit` for the NE colour corner — **the colour encoding does not change.**
- `parse_center` must return `Floor` for an `A`-`Z` centre, and `parse_decor` must return `None` for one. Both read the same character (`:145` and `:152`), so both need the case.
- The serialiser (`~line 825`): the centre becomes `decor` if `Some`, else the marker if `Some`, else `center_glyph(tile)`. `sw` becomes unconditionally `corner(s, w)`. This keeps an unstamped hull round-tripping.

In `hull.gleam`:
- `Slot` carries `marker: String`.
- The decoder accepts either `marker` (a string) or `digit` (an int, converted). Keep both for now.
- `validate` checks marker uniqueness and that each is a single `A`-`Z` character.

- [ ] **Step 4: Teach the harness twin**

`harness/deckplan.py` models tile-centre voidness. An uppercase centre must read as **walkable floor**, exactly like a space. Read the file and make the minimal change; add a comment saying why uppercase appears in a centre.

- [ ] **Step 5: Run both suites**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green — every shipped document still uses SW digits and still works.

- [ ] **Step 6: Commit**

```bash
cd server; gleam format src test
git add server harness
git commit -m "feat(deckplan): slot markers as uppercase letters in the tile centre (#M4)"
```

---

### Task 2.5: A slot tile may not be void

**Added mid-execution.** Task 2 discovered that the centre encoding cannot express slot membership for a *void* tile — the centre holds either `.` or a marker, never both — and that ten tiles across two testbed fixtures rely on exactly that. Reading the module payloads showed it is a real capability, not fixture sloppiness: a module drawing a non-void centre over a void hull tile **grows the ship's footprint**, and because a void patch cell is passthrough, that is the *only* way a refit can change a hull's outline.

**The human partner's ruling: refits do not change a ship's internal outline.** Exterior silhouette may still change with mounts and sprites — that is 2c's exterior layering, not this. So the capability goes, and a slot tile must be floor.

(If a growable hull is ever genuinely wanted, the escape hatch the human named is to move the *void-or-not* designation to the SW corner and keep the marker in the centre — the inverse of today. Do not build that now.)

**Files:**
- Modify: `server/src/dh_server/hull.gleam` (validation)
- Modify: `server/test/fixtures/dock_testbed_hulls/dock_testbed.json`, `server/test/fixtures/refit_testbed_hulls/refit_testbed.json`
- Modify: `server/test/fixtures/dock_testbed_modules/wide.json`, `server/test/fixtures/refit_testbed_modules/{empty,muster}.json` as needed
- Modify: `server/test/sim_test.gleam` (the two composite regression tests)
- Modify: `docs/deckplan-format.md`

**Interfaces:**
- Consumes: Task 2's `hull.Slot(marker: String)`.
- Produces: the guarantee Task 3's conversion script depends on — every slot tile's centre is blank.

- [ ] **Step 1: Write the failing test**

In `server/test/hull_test.gleam`, following the style of the existing rejection tests there:

```gleam
/// A slot tile is interior the module redecorates, never hull the module
/// conjures. A refit may change what a room contains and how it is walled;
/// it may not change the ship's outline, because a void patch cell is
/// passthrough and so growth would be one-way and unremovable.
pub fn a_void_slot_tile_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"digit\": 1, \"id\": \"a\", \"name\": \"A\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"#.#\", \"1##\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}
```

Confirm `hull.decode`'s real error-string style and match it.

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — the document decodes fine today.

- [ ] **Step 3: Add the rule**

In `hull.gleam`'s `validate`, reject any hull with a tile that carries a slot marker and a void centre. Name the offending slot and tile in the error.

- [ ] **Step 4: Redraw the two testbed hulls**

Make every slot tile's centre blank instead of `.` in `dock_testbed.json` and `refit_testbed.json`. **Row lengths must not change.** These hulls are now their full size unfitted.

- [ ] **Step 5: Rework the two composite regression tests**

`server/test/sim_test.gleam` (~1329-1385) has `refit_that_would_break_the_composite_is_refused_test` and `a_dock_that_would_break_the_composite_is_refused_test`. Both currently work by fitting a module that plates over void — `wide.json` "plates over her fore and aft rows", `muster.json` "floors the tile that the resulting docking tube would have to run through".

Those mechanisms are gone. **Rework them to break the composite by walling instead of by growing** — a module owns its tiles' edges, so a module that walls off the tile the docking tube must run through should still trigger the same refusal. Adjust the fixture modules as needed.

**If the refusal turns out to be unreachable once outlines are fixed, STOP and report it** — do not delete the tests. That would mean `berth_blocked` has become unreachable through content, which is a real finding about the validator and the human partner's call to make.

- [ ] **Step 6: Document the rule**

In `docs/deckplan-format.md`'s "Slots" section: a slot tile may not be void. A refit changes what a room *is*, never where the ship *ends*. Note the reason — a void patch cell is passthrough, so growth could never be undone — and that exterior silhouette is a separate concern.

- [ ] **Step 7: Run both suites and commit**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green.

```bash
cd server; gleam format src test
git add server docs
git commit -m "feat(deckplan): a slot tile may not be void; refits don't change a hull's outline (#M4)"
```

---

### Task 3: Convert every document

**Files:**
- Modify: `server/schemas/hull.schema.json`
- Modify: `server/shipclasses/{mockingbird,sparrow,goldfinch}.json`
- Modify: `server/test/fixtures/mockingbird_authored.json`, `server/test/fixtures/dock_testbed_hulls/dock_testbed.json`, `server/test/fixtures/refit_testbed_hulls/refit_testbed.json`
- Modify: `harness/fixtures/test_fixture.json`
- Modify: Gleam tests carrying inline grids with SW digits

**Interfaces:**
- Consumes: Task 2's dual-encoding parser.
- Produces: every shipped document uses `marker` and centre letters.

- [ ] **Step 1: Write the conversion script**

Write a throwaway script (scratch directory, not committed) that, for one hull document:
1. reads each slot's `digit`, maps it to its letter (`0 -> "A"`), and rewrites the `slots` entry as `{"marker": "A", "id": ..., "name": ...}`;
2. for every deck grid, for every tile whose SW corner `(3y+2, 3x)` is a hex digit: clear that position back to the wall-junction character the serialiser would derive (a space where there is no wall) and write the letter into the centre `(3y+1, 3x+1)`;
3. asserts the tile's centre was a space before overwriting — **if it was not, stop and report**, because that tile had authored content and the assumption behind this whole change is wrong.

Row lengths must not change. Verify with a script.

- [ ] **Step 2: Convert and verify one hull first**

Convert `server/shipclasses/sparrow.json` — she is the smallest. Run:

Run: `python tools/slotmap.py server/shipclasses/sparrow.json`
Expected: the same regions as before the conversion. Compare against a copy of the output taken before you started.

- [ ] **Step 3: Convert the rest**

Convert the remaining hulls and fixtures. **`server/test/fixtures/mockingbird_authored.json` is a resolved fixture** — check whether it carries slot digits at all before touching it, and say so in your report.

Then update the SW digits in any Gleam test's inline grids.

- [ ] **Step 4: Update the schema**

In `server/schemas/hull.schema.json`, the slot object's `digit` becomes:

```json
    "marker": {
      "type": "string",
      "pattern": "^[A-Z]$",
      "description": "The uppercase letter hull tiles carry in their CENTRE to join this slot. Uppercase means slot membership; lowercase says what a tile is."
    }
```

Move `digit` out of `required` and into nothing — delete it. Update the object's `description`, which currently names the SW corner.

- [ ] **Step 5: Run both suites**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green, including `default_loadout_reproduces_the_authored_deck_test`.

- [ ] **Step 6: Commit**

```bash
cd server; gleam format src test
git add server harness
git commit -m "refactor(hulls): slot markers move to the tile centre (#M4)"
```

---

### Task 4: Delete the SW-digit encoding

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam`, `server/src/dh_server/hull.gleam`
- Test: `server/test/hull_test.gleam`, `server/test/deckplan_test.gleam`

**Interfaces:**
- Consumes: Task 3's converted documents.
- Produces: one encoding, and a 26-slot ceiling.

- [ ] **Step 1: Write the failing tests**

```gleam
/// One encoding. A hex digit in the SW corner is just a corner character now.
pub fn an_sw_digit_no_longer_marks_a_slot_test() {
  let reg = glyphs.default()
  let assert Ok(g) =
    deckplan.parse_deck_with(reg, "t", ["###", "# #", "2##"])
  let assert Ok(cell) = deckplan.cell_at_xy(g, 0, 0)
  assert cell.slot == None
}

/// Twenty-six letters, so twenty-six slots. The old ceiling was sixteen
/// because a slot was one hex digit in a corner.
pub fn a_hull_may_carry_twenty_six_slots_test() {
  let markers =
    string.to_graphemes("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    |> list.map(fn(m) {
      "{ \"marker\": \"" <> m <> "\", \"id\": \"s" <> m <> "\", \"name\": \"S\" }"
    })
    |> string.join(", ")
  let doc =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [" <> markers <> "],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Ok(h) = hull.decode(doc)
  assert list.length(h.slots) == 26
}

/// A marker is one uppercase letter. Lowercase is the other namespace
/// entirely, and a digit is no longer a slot at all.
pub fn a_non_letter_marker_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"marker\": \"a\", \"id\": \"a\", \"name\": \"A\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}
```

These two go in `server/test/hull_test.gleam`, not `deckplan_test.gleam` — they follow the shape of the existing `duplicate_slot_digit_is_rejected_test` and `slot_digit_out_of_range_is_rejected_test` there, which this task retargets or deletes. Add whichever `gleam/string` and `gleam/list` imports the file lacks.

- [ ] **Step 2: Run to verify they fail**

Run: `cd server; gleam test`
Expected: FAIL — the SW digit still parses as a slot.

- [ ] **Step 3: Remove the old encoding**

- `deckplan.gleam`: drop the SW fallback from the cell constructor; `slot` reads the centre only. Leave `parse_hex_digit` in place — the NE colour corner still uses it.
- `hull.gleam`: drop `digit` from the decoder. `validate`'s range check becomes "single `A`-`Z` character"; its error strings should name markers, not digits.
- Delete or retarget any test that asserted the digit range 0-15.

- [ ] **Step 4: Run both suites and commit**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green.

```bash
cd server; gleam format src test
git add server
git commit -m "refactor(deckplan): drop the SW-corner slot digit; 26 slots per hull (#M4)"
```

---

### Task 5: Tooling and the docs the change rewrites

**Files:**
- Modify: `tools/slotmap.py`
- Modify: `docs/deckplan-format.md`, `docs/modules.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Update `tools/slotmap.py`**

It reads the SW corner and paints the digit into the tile centre so regions are legible. That is now what the raw file already does, so its bare-hull mode becomes close to an identity render. Read it and decide honestly what it should still do — its `--structure` mode (showing a fitted ship) is the valuable half and must keep working. Update its docstring, which describes the SW corner at length.

- [ ] **Step 2: Rewrite the format doc**

`docs/deckplan-format.md`: the "Slots" section describes the SW-corner hex digit. Replace it with the centre uppercase letter, and state the invariant plainly: **lowercase says what a tile is, uppercase says which slot it belongs to.** Note that the NE colour digit is still hex and unaffected, and that the SW corner is now an ordinary derived wall-junction character. Update the glyph key for `q`.

- [ ] **Step 3: Correct the 16-slot finding**

`docs/modules.md` records a 16-slot ceiling as a finding of M4 iteration 2b. It is now 26. **Do not delete the finding** — rewrite it to say the ceiling was sixteen because a slot was one hex digit in a corner, that this was found by drawing a second large hull, and that moving the marker to the centre as an uppercase letter both fixed the readability problem and lifted the ceiling to twenty-six. That history is the useful part.

Grep `docs/` for any other mention of the SW corner, slot digits, or the sixteen-slot limit.

- [ ] **Step 4: Run both suites and commit**

Run: `cd server; gleam test` then `cd harness; python -m pytest -v`
Expected: both green.

```bash
git add tools docs
git commit -m "docs(deckplan): slot markers are uppercase letters in the centre (#M4)"
```

---

## Definition of done

- `cd server; gleam test` and `cd harness; python -m pytest -v` both green at Task 0's counts plus the tests this plan adds.
- No deck row changed shape: every wall, door, floor and void sits exactly where it did. The Mockingbird's golden fixture test proves it for her.
- `q` is the dock port; no uppercase character means anything but slot membership.
- Every hull document reads symmetrically — a port tile and its starboard mirror carry their markers in the same column.
- One encoding: the SW corner is a derived wall-junction character again, and the NE colour digit is untouched.
- A hull may carry 26 slots, and `docs/modules.md` records why it used to be 16.
