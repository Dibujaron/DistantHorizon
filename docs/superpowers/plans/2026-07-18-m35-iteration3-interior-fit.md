# M3.5 Iteration 3: Interior-Fits-Hull + Split-Level Decks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the walkable interior actually fit inside its hull's exterior sprite (ship inside the Mockingbird, concourse inside the station bar), with the Mockingbird's lore-correct split-level interior, plus the round-10 quick fixes (Classic logo reused verbatim, view-cone dropped, bigger characters, centered airlock picto).

**Architecture:** Deck plans gain a per-tile deck alphabet (`.#LU2B`) so one 2D grid can host stacked floors; the walker sim gains a `deck` state that the alphabet drives; the client renders only the active deck. Interiors anchor to hull sprites via new `interior` fit metadata (`px_per_tile`, `origin_px`) in each export's meta.json: InteriorView draws pooled exterior-sprite backdrops (show_behind_parent) scaled `TILE_PIXELS / px_per_tile` at each hull's composite tile offset, while WorldView (dimmed beneath) zooms to the matched world scale and suppresses the hull you're inside. The station sprite is redesigned so its terminal bar IS the concourse footprint, pads aligned to berth tiles.

**Tech Stack:** Gleam (server), GDScript/Godot 4.7 (client), Python/PIL/resvg (art pipeline), pytest + gleeunit + screenshot harness.

## Global Constraints

- Walk-sim math must mirror bit-for-bit between `character.gleam` and `ship_class_data.gd` (existing project rule).
- Typed boundaries: wire data parsed into named types at the edge (no dict plumbing).
- `px_per_tile = 3` for ALL hulls this milestone (Mockingbird 21×45 px = 7×15 tiles; concourse 34×6 = 102×18 px inside the station bar).
- Deck alphabet: `.` void · `#` generic single floor (any deck) · `L` lower only · `U` upper only · `2` two stacked floors (no vertical connection) · `B` between-level (single floor connecting both decks).
- Deck rules: `walkable_for(deck, ch)`: `.`→no; `#`,`B`,`2`→yes; `L`→deck==lower; `U`→deck==upper. After a move, deck becomes lower/upper if the CENTER tile is `L`/`U`, else unchanged.
- Consoles must sit ≥ 2 tiles from any tile of the opposite deck (sit stays distance-only).
- View-cone: default OFF (V toggles it for debug); code kept for the post-fit revisit.
- The ship class is renamed sparrow → mockingbird (id `mockingbird`, name `Mockingbird`); the lore Sparrow is a single-seat fighter and is NOT this hull.
- Byte-identity regression for `manufacturers.build_sheet()` must keep passing.
- Do not touch the user's uncommitted `docs/lore.md` edits.

---

### Task 1: Logo reverted to the Classic sprite

**Files:**
- Create: `tools/artspike/classic_logo.png` (vendored copy of `../DistantHorizonClassic/client/sprites/logo/logo_big_trans.png`, 512×512)
- Rewrite: `tools/artspike/logo.py` (cell-map drawing code goes away)
- Regenerate: `client/assets/ui/logo.png` (256px), `client/icon.png` (64px)

**Steps:**
- [ ] Copy the Classic sprite into `tools/artspike/classic_logo.png`.
- [ ] Rewrite `logo.py`: load the vendored sprite, `Image.LANCZOS`-downscale? NO — it is chunky pixel art authored at 512 with large uniform cells; use NEAREST to 256 and 64 (verify no aliasing artifacts by eyeballing the output; if 512 isn't an integer multiple of a clean cell size, inspect and pick BOX instead).
- [ ] Run `cd tools\artspike; python logo.py`, eyeball both outputs.
- [ ] Commit.

### Task 2: Server deck model (deckplan + character + composite + wire)

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam` (alphabet, `Deck` type, `char_at`, `deck_of_char`, `walkable_for`, validate)
- Modify: `server/src/dh_server/character.gleam` (deck field, per-deck collision, deck update in step/sit)
- Modify: `server/src/dh_server/composite.gleam` (preserve source chars when stitching)
- Modify: `server/src/dh_server/protocol.gleam` (deck on walkers characters + space `you`; `concourse` offset block on space)
- Modify: `server/src/dh_server/sim.gleam` (spawn deck from helm tile; wherever Character is constructed)
- Modify: `server/schemas/ship_class.schema.json`, `server/schemas/world.schema.json` (row pattern `^[.#LU2B]+$`, optional room `deck`)
- Test: `server/test/deckplan_test.gleam`, `server/test/composite_test.gleam` (or wherever composite tests live), `server/test/character_test.gleam`

**Interfaces (produced, exact):**
```gleam
pub type Deck { Lower Upper }
pub fn deck_to_string(d: Deck) -> String        // "lower" | "upper"
pub fn char_at(plan: DeckPlan, x: Int, y: Int) -> String   // "." out of bounds
pub fn walkable_for(plan: DeckPlan, deck: Deck, x: Int, y: Int) -> Bool
pub fn deck_after(plan: DeckPlan, deck: Deck, x: Float, y: Float) -> Deck  // center-tile rule
// Character gains: deck: Deck ; step/try_sit take it into account.
```
Wire: `walkers.characters[*].deck` and `space.you.deck` are `"lower"|"upper"`; `space.concourse` is `{"dx":N,"dy":N}` for station spaces, `null` for ship spaces.

**Steps:**
- [ ] TDD in `deckplan_test.gleam`: `is_walkable` true for `#LU2B`, false for `.`; `walkable_for(Lower)` false on `U`, true on `L2B#`; `validate` rejects a row containing `X`.
- [ ] Implement in deckplan.gleam. `is_walkable` = `char_at != "."`.
- [ ] TDD in character tests: a walker with deck Lower cannot step onto a `U` tile; stepping onto `L` from `B` sets deck Lower; on `2` deck persists.
- [ ] Implement: `circle_walkable(plan, deck, cx, cy)`; `step` updates deck via `deck_after` post-move; `try_sit` sets deck from the console tile char when `L`/`U`. `can_stand_at` gains deck.
- [ ] Composite test: stitching a ship whose rows use `LU2B` preserves those chars in the composite rows (not flattened to `#`).
- [ ] Implement: `compose_walkable` emits the claiming source's char.
- [ ] Protocol: add deck to `encode_character` and `you`; add `concourse` to `encode_space` (new params threaded from sim's Composite: dx/dy, or Nil for ship spaces). Fix all call sites.
- [ ] sim.gleam: every `character.Character(...)` construction gains `deck:` — login helm seat derives from helm tile char (`U` → Upper); crew transfer keeps prior deck; despawn-void checks use the walker's deck.
- [ ] Update schemas.
- [ ] `cd server; gleam test` green. Commit.

### Task 3: Mockingbird ship class (rename + split-level plan)

**Files:**
- Create: `server/classes/mockingbird.json`
- Delete: `server/classes/sparrow.json`
- Modify: default class path (grep `sparrow` in `server/src` + `harness/`)
- Test: `server/test/shipclass_test.gleam` fixtures

**The plan document (7×10 grid, nose up, ppt 3 against the 21×45 sprite; grid covers sprite px rows 0–30, drums hang below):**
```json
{
  "schema": 2, "id": "mockingbird", "name": "Mockingbird",
  "grid": {"width": 7, "height": 10},
  "walkable": [
    ".......",
    "...U...",
    "...U...",
    "..UUU..",
    "..UUU..",
    "..222..",
    "..222..",
    "..LLL..",
    "..LLL..",
    "..BBB.."
  ],
  "rooms": [
    {"id": "cockpit",  "name": "Cockpit",       "x": 3, "y": 1, "w": 1, "h": 2, "deck": "upper"},
    {"id": "quarters", "name": "Crew Quarters", "x": 2, "y": 3, "w": 3, "h": 2, "deck": "upper"},
    {"id": "mess",     "name": "Mess",          "x": 2, "y": 5, "w": 3, "h": 2, "deck": "upper"},
    {"id": "hold",     "name": "Main Hold",     "x": 2, "y": 5, "w": 3, "h": 4, "deck": "lower"},
    {"id": "dock",     "name": "Docking Deck",  "x": 2, "y": 9, "w": 3, "h": 1}
  ],
  "consoles": [
    {"id": "helm_main",  "kind": "helm",  "x": 3, "y": 1},
    {"id": "cargo_main", "kind": "cargo", "x": 3, "y": 8}
  ],
  "spawn_tile": [3, 9],
  "cargo": {"capacity": 40, "handling": "breakbulk"}
}
```
(Room `deck` is rendering metadata; deckplan decoder must tolerate+carry it — add optional field to Room with default `""`.)

**Steps:**
- [ ] Add optional `deck` to Room (decode default "", encode only the plain fields plus deck when non-empty — keep encode/decode round-trip).
- [ ] Write the class file; update every `sparrow` reference (server default path, gleam tests, harness expectations like walk routes — harness handled in Task 7).
- [ ] `gleam test` green; boot server once and confirm `loaded ship class "mockingbird"`. Commit.

### Task 4: Art pipeline — interior fit meta + station redesign

**Files:**
- Modify: `tools/artspike/composer.py` (ExportSpec gains `interior: dict | None = None`; export_ship writes it into meta.json verbatim)
- Modify: `tools/artspike/stations.py` (full redesign: horizontal terminal bar top-aligned to the 34×6 concourse, ring below)
- Test: `tools/artspike/test_composer.py`
- Regenerate: `client/assets/ships/*`, `client/assets/stations/*`

**Mockingbird spec:** `interior={"px_per_tile": 3, "origin_px": [0, 0]}` (grid (0,0) = sprite top-left; test asserts px_w==21, px_h==45 so the fit can't silently drift).

**Station geometry (model units, 1 tile = 7.5 u, px_per_unit = 0.4 → 3 px/tile):**
- Concourse grid (34×6 = 255×45 u) occupies the terminal bar: bar rect x −127.5..127.5, y −150..−105 (grid origin at (−127.5, −150)).
- Berth pads: 18-u-wide raised pads centered at x = −127.5 + (b+0.5)·7.5 for b ∈ {6,16,26}, on the bar's TOP edge (rows 0–1 of the grid, y −150..−135).
- Berth anchors (space-mode ship parking) at (pad_x, −150 − 11.25) — the moored Mockingbird's sprite center: ship grid origin is 9 tiles above the berth row, sprite center 22.5 px below sprite top ⇒ 4.5 px (11.25 u) above the concourse top edge.
- Ring Ø ~200 u hangs below: hub dome, 4 spokes, portholes — reuse existing part vocabulary; crane gantries become vertical booms above the outer pads for the crane variant; keep PHE palette.
- `interior={"px_per_tile": 3, "origin_px": [ox, oy]}` where (ox,oy) is the grid origin in exported-png px — compute from the export frame after building once, then PIN the numbers in the spec and assert them in the test.

**Steps:**
- [ ] TDD: ExportSpec with `interior` lands in meta.json; mockingbird meta has interior block and px 21×45.
- [ ] Implement composer change (one field + one meta line).
- [ ] Redesign `station_hull` per geometry above; TDD alignment: for each berth b, `meta["anchors"][i]["x_px"] == interior.origin_px[0] + (b + 0.5) * 3` (±0.5 px).
- [ ] `python composer.py`, `python stations.py` (from tools/artspike) to regenerate; eyeball `sheet_stations.png`.
- [ ] pytest green (`cd tools/artspike; python -m pytest -q`). Commit.

### Task 5: Client — decks, backdrops, matched zoom, quick fixes

**Files:**
- Modify: `client/scripts/ship_class_data.gd` (alphabet, `deck_at`, `walkable_for`, Room.deck, `step_walk` deck-aware returning `{pos, deck}`)
- Modify: `client/scripts/character_state.gd` (`deck: String`)
- Modify: `client/scripts/space_data.gd` (`concourse_dx/dy: int`, `has_concourse: bool`, you_deck)
- Modify: `client/scripts/interior_view.gd` (view-deck filtering everywhere; backdrop child sprites; CHAR_SIZE 27×42; picto centered in berth tile; `view_cone_enabled = false` default)
- Modify: `client/scripts/main.gd` (own-deck prediction + reconcile; backdrop specs; matched world zoom + geometric lerp through the transition; suppression ids to WorldView)
- Modify: `client/scripts/world_view.gd` (`interior_mode`, `suppress_station_id`, `suppress_ship_id` params: hide that hull + all labels/dock rings/orbits in interior mode)
- Modify: `client/scripts/asset_library.gd` (SpriteSet.interior_fit() -> Dictionary)

**Key mirrors (must match Gleam exactly):**
```gdscript
static func walkable_for(cls: ShipClassData, deck: String, tx: int, ty: int) -> bool:
    var ch := cls.char_at(tx, ty)
    if ch == ".": return false
    if ch == "L": return deck == "lower"
    if ch == "U": return deck == "upper"
    return true   # "#", "B", "2"

static func deck_after(cls: ShipClassData, deck: String, x: float, y: float) -> String:
    var ch := cls.char_at(int(floor(x)), int(floor(y)))
    if ch == "L": return "lower"
    if ch == "U": return "upper"
    return deck
```
`step_walk(cls, deck, x, y, dx, dy, delta)` — per-axis circle test with `walkable_for`, then `deck_after` on the final center.

**Backdrops (InteriorView):** main passes `Array[BackdropSpec]` (inner class: `kind: String` "ship"/"station", `asset: String` e.g. "mockingbird"/"ring_3berth_crane", `tile_origin: Vector2`). InteriorView pools child Sprite2Ds (`show_behind_parent = true`, NEAREST, the SpriteSet material so livery masks apply), `scale = TILE_PIXELS / ppt`, `position = origin_screen + (tile_origin - origin_px/ppt + px_size/(2*ppt)) * TILE_PIXELS` (Sprite2D is center-anchored). Station backdrop first, ship backdrops after.

**Deck-filtered rendering:** `view_deck` = own character's deck. Floor drawn iff `char in "#B" or char == "2" or (char == "L" and view_deck == "lower") or (char == "U" and view_deck == "upper")`. Bulkheads/berth hazards use the same visibility for the neighbor test. Room labels honor Room.deck ("" = both). Characters hidden when their tile is `2` with a different deck, or their tile is single-deck of the other deck.

**Matched zoom (main.gd):** interior world zoom = `TILE_PIXELS / (ppt * units_per_px)` where units_per_px is `SHIP_WORLD_UNITS_PER_PX` aboard, or `STATION_SPAN_FACTOR * dock_radius / station_px_w` docked. Blend geometrically with the user zoom across the view transition: `zoom = exp(lerp(log(user), log(matched), eased_interior_weight))`.

**Steps:**
- [ ] ship_class_data/character_state/space_data typed changes (+ parse the new wire fields).
- [ ] main.gd prediction: track `_predicted_deck`, seed from `space.you_deck` / walkers reconcile; pass deck into step_walk.
- [ ] interior_view deck filtering + backdrops + char size + picto center + cone default off.
- [ ] world_view suppression + interior_mode.
- [ ] main.gd zoom + suppression wiring.
- [ ] Parse check: `godot --path client --headless --quit` clean (rebuild class cache first: `godot --path client --headless --editor --quit`). Commit.

### Task 6: Server walkers deck ↔ client roundtrip check

**Steps:**
- [ ] Boot server + client via the automation harness smoke test (`cd harness; python -m pytest test_automation_smoke.py -q` — adjust route coords for the new plan as needed, see Task 7).
- [ ] Fix whatever the roundtrip shakes out. Commit.

### Task 7: Harness drivers + visual iteration loop

**Files:**
- Modify: `harness/shot_m35_interior.py` (new walk route: helm (3,1) upper → stand → walk south through quarters/mess to `B` row (3,9) → cross to berth/concourse), `harness/test_automation_smoke.py` route constants if they encode the old sparrow layout, any `"sparrow"` string expectations.
- Re-run: all three shot drivers; eyeball against the feedback list:
  - tiles fit INSIDE the station bar / ship sprite (the headline fix)
  - planet/station no longer floating at wrong scale behind the interior
  - split-level: hold visible on lower deck, mess on upper, docking deck from both
  - characters a touch bigger; airlock picto centered; Classic logo on the menu
- [ ] Iterate on visual defects (expect 2–3 loops). Commit each meaningful fix.

### Task 8: Ship it

- [ ] `gleam test`, artspike pytest, godot parse check — all green.
- [ ] Commit, push to `m3.5-vibe-pass` (PR #9).
- [ ] Artifact round 10 (same URL, prepend section), PR comment, memory update (deck alphabet canon, interior-fit meta contract, cone dropped-not-deleted).

## Self-Review Notes

- Spec coverage: logo revert (T1), cone drop (T5), scale unification (T4+T5), mockingbird interior per lore incl. split-level (T2+T3), station fit (T4), character size (T5), airlock picto (T5), welds already good (no task). "Zoom out → exterior" continuous morphing explicitly deferred; the sit/stand transition plus matched zoom covers the current loop.
- Type consistency: deck strings "lower"/"upper" on the wire and in GDScript; Gleam `Deck` type internal only.
- Risk log: composite `berth_blocked` unchanged (chars only carried through); prediction mirror is the highest-risk step — Task 6 exists to shake it out live.
