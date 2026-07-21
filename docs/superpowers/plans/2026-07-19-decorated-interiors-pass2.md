# Decorated Interiors — Pass 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the pass-2 interior tiles — neighbour-aware decor (fountain, flowerbed, table, hydroponic), up/down hatchway art, wall-mounted consoles, the wall-bunk rule tile — plus first-crack greyscale sprites, all on top of the pass-1 decor+colour pipeline.

**Architecture:** New glyphs are additive registry entries (`server/glyphs.json` + `glyphs.default()`), fallback-safe. Neighbour-aware rendering is **client-only** and **deterministic** (a pure `interior_hash(deck_id,x,y)` + a same-deck `neighbor_mask`), so the server stays authoritative on walkability and no new wire data is needed. Wall consoles/bunks reuse the existing edge-fixture render path; the one server change is an optional `console` field on edge glyphs, from which the console-interaction records derive. Sprites are individual greyscale PNGs auto-loaded from `client/assets/interior/`, multiplied by the tile's palette colour at draw.

**Tech Stack:** Gleam (server, gleeunit tests via `gleam test` in `server/`), GDScript / Godot 4 (client), Python pytest + screenshot drivers in `harness/` for client-side verification. Design: `docs/superpowers/specs/2026-07-19-decorated-interiors-pass2-design.md`.

## Global Constraints

- **Additive & fallback-safe:** unknown centre glyph → walkable `floor`; unknown edge glyph → generic blocking `fixture`. Never a parse error. Old maps keep working.
- **`glyphs.default()` MUST stay byte-identical to `server/glyphs.json`** — `server/test/glyphs_test.gleam` asserts this; every registry edit touches both.
- **Determinism:** any per-tile rendering variation is a pure function of `(deck identity, x, y)` only. NEVER `Time`, `randi()`, `RandomNumberGenerator`, load order, or dict iteration order. Must be byte-identical across relogs.
- **No walkability/collision/pathing/docking/wire-schema changes** beyond the single `edge.console` registry field (Task 8). New floor glyphs are plain `floor`; new edge glyphs block like walls.
- **Graceful degradation:** every render addition falls back to the current look when its sprite is missing (pass-1 rule).
- **Tile geometry:** `TILE_PIXELS = 64.0`, wall strip `WALL_PX = 14.0` (`client/scripts/interior_view.gd`). Sprites are authored greyscale (shading in the sprite), tinted by `draw_texture_rect(..., modulate)`.
- **Godot gotcha:** Godot caches compiled `class_name` scripts; after adding a new `class_name` or `.tscn`, a stale `.godot/` cache can shadow it. If a probe/scene fails to find a new class, delete `client/.godot/global_script_class_cache.cfg` (or `client/.godot/`) and relaunch. Run godot with scoop shims on PATH (`client/run.bat` sets `%USERPROFILE%\scoop\shims`).
- **Commit after every task** (frequent commits). Branch: `feat/decorated-interiors-pass2`.

---

## File map

**Server (Gleam):**
- `server/glyphs.json`, `server/schemas/glyphs.schema.json` — new glyph entries; `edge.console` field.
- `server/src/dh_server/glyphs.gleam` — `EdgeSpec.console`, decoder/encoder/`default()`, `edge_console_kind` accessor.
- `server/src/dh_server/deckplan.gleam` — console derivation also scans edges (`scan_markers`).
- `server/test/glyphs_test.gleam`, `server/test/deckplan_test.gleam` — new cases.
- `server/shipclasses/mockingbird.json`, `server/stationclasses/*.json` — map migration (wall consoles).

**Client (GDScript):**
- `client/scripts/interior_neighbors.gd` (**new**, `class_name InteriorNeighbors`) — `interior_hash`, `neighbor_mask`, autotile helpers.
- `client/scripts/interior_view.gd` — `_draw_stairs` pass; neighbour-aware branch in `_draw_decor`; seat-facing; stop centre-drawing wall consoles.
- `client/scripts/glyph_registry.gd` — ingest `edge.console`.
- `client/tools/interior_selftest.gd` + `.tscn` (**new**) — headless assert runner for pure logic.
- `client/tools/interior_render_probe.gd` — extend inline deck to exercise pass-2 tiles.
- `client/assets/interior/*.png` — first-crack sprites.
- `tools/gen_interior_sprites.py` (**new**) — greyscale placeholder-PNG generator.

**Docs:**
- `docs/deckplan-format.md` — new glyphs, wall-console authoring, the bunk convention.

---

## Verification commands (referenced throughout)

- **Server unit tests:** from `server/`: `gleam test` — runs all gleeunit tests. Expected tail: `... tests, 0 failures`.
- **Client pure-logic self-test (headless):** `godot --path client --headless res://tools/interior_selftest.tscn --quit-after 240` — the scene prints `SELFTEST: PASS` / `SELFTEST: FAIL: <msg>` and sets exit code 0/1. (Scoop shims on PATH.)
- **Client visible probe (PNG):** `DH_SHOT=<abs>/probe.png godot --path client res://tools/interior_render_probe.tscn` — windowed; saves a screenshot after ~0.3 s then quits. Drop `--headless` to see pixels; keep it to just prove the draw path runs error-free.
- **Full-hull screenshots:** `python harness/shot_m35_interior.py` (writes `harness/out/m35_int_*.png`).
- **Client integration regression:** `python -m pytest harness/test_m2_interior.py harness/test_m31_stitched.py -q` — must stay green (walkability/prediction unchanged).

---

## Task 1: Sprite generator + pass-1 placeholder art (E-scaffold)

Make the probe show *real* sprites immediately, and give every later task a way to drop art. First-crack art is crude greyscale on purpose; the author retunes by replacing PNGs.

**Files:**
- Create: `tools/gen_interior_sprites.py`
- Create: `client/assets/interior/rug.png`, `seat.png`, `bed.png`, `cargo_pallet.png`, `window.png`, `viewscreen.png` (generated)
- Reference: `client/assets/interior/meta.json` (tile_px=64, wall_px=14)

**Interfaces:**
- Produces: correctly-named 64×64 (fixtures 64×14) greyscale PNGs keyed by registry `sprite` id; auto-loaded by `AssetLibrary`. No code consumes the generator at runtime.

- [ ] **Step 1: Write the generator.** `tools/gen_interior_sprites.py` uses only the stdlib (`zlib`, `struct`) to emit greyscale PNGs — no Pillow dependency (matches the repo's no-extra-deps posture). Provide one function per sprite drawing simple shapes into a `bytearray` of 8-bit grey + alpha, and a `write_png(path, w, h, pixels)` helper. Include: `rug` (rounded rect w/ border), `seat` (chair: back bar + cushion), `bed` (mattress + pillow band), `cargo_pallet` (crate + slats), `window` (64×14 pane w/ mullion), `viewscreen` (64×14 dark screen + frame). Keep them light-grey (so palette multiply reads) with darker shading lines.

```python
#!/usr/bin/env python3
"""Generate first-crack greyscale interior sprites (stdlib-only PNG writer).
Run: python tools/gen_interior_sprites.py [outdir]
Default outdir: client/assets/interior
Art is intentionally crude; replace any PNG in place to retune (issue #36)."""
import sys, zlib, struct
from pathlib import Path

def write_png(path, w, h, px):  # px: list of (r,g,b,a) rows-major, len w*h
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: none
        for x in range(w):
            r, g, b, a = px[y * w + x]
            raw += bytes((r, g, b, a))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    Path(path).write_bytes(png)

def blank(w, h, base=(0, 0, 0, 0)):
    return [base] * (w * h)

def rect(px, w, x0, y0, x1, y1, col):
    for y in range(max(0, y0), min(len(px)//w, y1)):
        for x in range(max(0, x0), min(w, x1)):
            px[y * w + x] = col

G = lambda v, a=255: (v, v, v, a)

def sprite_rug(w=64, h=64):
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(200)); rect(px, w, 10, 10, 54, 54, G(150)); return w, h, px
def sprite_seat(w=64, h=64):
    px = blank(w, h); rect(px, w, 16, 40, 48, 54, G(190)); rect(px, w, 16, 14, 22, 54, G(150)); return w, h, px
def sprite_bed(w=64, h=64):
    px = blank(w, h); rect(px, w, 8, 12, 56, 56, G(200)); rect(px, w, 12, 16, 52, 26, G(230)); return w, h, px
def sprite_cargo_pallet(w=64, h=64):
    px = blank(w, h); rect(px, w, 10, 10, 54, 54, G(170))
    for gx in range(10, 54, 8): rect(px, w, gx, 10, gx + 2, 54, G(120))
    return w, h, px
def sprite_window(w=64, h=14):
    px = blank(w, h); rect(px, w, 2, 2, 62, 12, G(210)); rect(px, w, 30, 2, 34, 12, G(120)); return w, h, px
def sprite_viewscreen(w=64, h=14):
    px = blank(w, h); rect(px, w, 2, 2, 62, 12, G(70)); rect(px, w, 2, 2, 62, 4, G(140)); return w, h, px

SPRITES = {"rug": sprite_rug, "seat": sprite_seat, "bed": sprite_bed,
           "cargo_pallet": sprite_cargo_pallet, "window": sprite_window,
           "viewscreen": sprite_viewscreen}

def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("client/assets/interior")
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in SPRITES.items():
        w, h, px = fn(); write_png(out / f"{name}.png", w, h, px)
        print(f"wrote {name}.png ({w}x{h})")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it.** `python tools/gen_interior_sprites.py` — Expected: prints `wrote rug.png (64x64)` … `wrote viewscreen.png (64x14)`; six PNGs now in `client/assets/interior/`.

- [ ] **Step 3: Verify they load & render.** `DH_SHOT=<abs>/scratch/probe1.png godot --path client res://tools/interior_render_probe.tscn`. Open `probe1.png`: the probe's `bed`/`cargo_pallet`/`window` tiles now show art instead of the tinted-swatch/plain-wall placeholder. (If nothing changed, confirm `AssetLibrary` scanned the dir — filenames must exactly match the `sprite` ids.)

- [ ] **Step 4: Commit.**
```bash
git add tools/gen_interior_sprites.py client/assets/interior/*.png
git commit -m "feat(interior): stdlib greyscale sprite generator + pass-1 placeholder art (#36)"
```

---

## Task 2: Deterministic neighbour module + headless self-test (F2 / B0)

The shared machinery for all neighbour-aware tiles. Pure, deterministic, unit-tested via a headless scene (no GDScript unit framework exists, so we assert in-engine and exit 0/1 — the probe pattern).

**Files:**
- Create: `client/scripts/interior_neighbors.gd` (`class_name InteriorNeighbors`)
- Create: `client/tools/interior_selftest.gd`, `client/tools/interior_selftest.tscn`

**Interfaces:**
- Produces:
  - `InteriorNeighbors.interior_hash(deck_id: int, x: int, y: int) -> int` — 31-bit non-negative, FNV-1a mix; pure.
  - `InteriorNeighbors.mask4(deck, x, y, glyph: String) -> int` — 4-bit N=1,E=2,S=4,W=8 of orthogonal neighbours whose `decor_at` equals `glyph`. `deck` is a `ShipClassData.Deck`.
  - `InteriorNeighbors.chance(hash: int, num: int, den: int) -> bool` — deterministic fraction test from a hash.

- [ ] **Step 1: Write the module.**
```gdscript
class_name InteriorNeighbors
## Deterministic, load-order-independent helpers for neighbour-aware interior
## rendering (issue #36). Variation MUST derive only from (deck_id, x, y) — never
## Time/RNG/iteration order — so fountains, flowerbeds and trees never reshuffle
## on relog.

const N := 1
const E := 2
const S := 4
const W := 8

## FNV-1a over the three ints. Pure; returns a non-negative 31-bit int.
static func interior_hash(deck_id: int, x: int, y: int) -> int:
	var h := 2166136261
	for v in [deck_id, x, y]:
		# fold 32 bits of v, byte by byte
		for shift in [0, 8, 16, 24]:
			h = (h ^ ((v >> shift) & 0xff)) & 0xffffffff
			h = (h * 16777619) & 0xffffffff
	return h & 0x7fffffff

## Bitmask (N|E|S|W) of orthogonal neighbours whose decor glyph == `glyph`.
static func mask4(deck, x: int, y: int, glyph: String) -> int:
	var m := 0
	if deck.decor_at(x, y - 1) == glyph: m |= N
	if deck.decor_at(x + 1, y) == glyph: m |= E
	if deck.decor_at(x, y + 1) == glyph: m |= S
	if deck.decor_at(x - 1, y) == glyph: m |= W
	return m

## Deterministic "num/den" chance from a precomputed hash.
static func chance(hash: int, num: int, den: int) -> bool:
	return (hash % den) < num
```
(Confirm `Deck.decor_at(x,y)` exists and returns `""` off-grid — `ship_class_data.gd`. It does.)

- [ ] **Step 2: Write the self-test scene.** `interior_selftest.gd`:
```gdscript
extends Node
## Headless assert runner for pure interior logic (issue #36). Prints
## `SELFTEST: PASS` or `SELFTEST: FAIL: <msg>` and quits with code 0/1.
## Run: godot --path client --headless res://tools/interior_selftest.tscn --quit-after 240

var _fail := ""

func _check(cond: bool, msg: String) -> void:
	if not cond and _fail == "": _fail = msg

func _ready() -> void:
	# Determinism: same inputs -> same hash across calls.
	var a := InteriorNeighbors.interior_hash(0, 3, 7)
	var b := InteriorNeighbors.interior_hash(0, 3, 7)
	_check(a == b, "hash not stable")
	_check(a >= 0, "hash negative")
	# Sensitivity: differing inputs mostly differ.
	_check(InteriorNeighbors.interior_hash(0, 3, 7) != InteriorNeighbors.interior_hash(1, 3, 7), "deck_id ignored")
	_check(InteriorNeighbors.interior_hash(0, 3, 7) != InteriorNeighbors.interior_hash(0, 4, 7), "x ignored")
	# Golden values pin the mix so a refactor can't silently change patterns.
	_check(InteriorNeighbors.interior_hash(0, 0, 0) == _GOLD_000, "golden 0,0,0 changed: got %d" % InteriorNeighbors.interior_hash(0, 0, 0))
	# mask4 on a hand-built 3x3 of fountains around centre (1,1).
	var deck := _mask_fixture()
	_check(InteriorNeighbors.mask4(deck, 1, 1, "f") == (InteriorNeighbors.N|InteriorNeighbors.E|InteriorNeighbors.S|InteriorNeighbors.W), "mask centre")
	_check(InteriorNeighbors.mask4(deck, 0, 0, "f") == (InteriorNeighbors.E|InteriorNeighbors.S), "mask corner")
	if _fail == "":
		print("SELFTEST: PASS")
		get_tree().quit(0)
	else:
		print("SELFTEST: FAIL: ", _fail)
		get_tree().quit(1)

const _GOLD_000 := 0  # placeholder; set in Step 4 from the first real run

func _mask_fixture():
	# 3x3 all-fountain deck via ShipClassData.Deck.from_grid.
	var rows := PackedStringArray()
	for _i in range(9):
		rows.append("f  f  f  ")  # each 3-wide tile block, centre glyph 'f'
	return ShipClassData.Deck.from_grid("mask", rows, NetworkClient.glyphs)
```
Wire the `.tscn`: one `Node` with `interior_selftest.gd` attached. NOTE the mask fixture needs `NetworkClient.glyphs` to know `f` is decor — either stub a minimal `GlyphRegistry` in `_ready()` before `_mask_fixture()` (mirror `interior_render_probe.gd:23-61`), or build a `Deck` and set decor directly. Prefer stubbing the registry with `f` as a decor centre so `decor_at` returns `"f"`.

- [ ] **Step 3: Run it — expect FAIL (golden unset).** `godot --path client --headless res://tools/interior_selftest.tscn --quit-after 240`. Expected: `SELFTEST: FAIL: golden 0,0,0 changed: got <NNN>`. Record `<NNN>`.

- [ ] **Step 4: Set the golden and re-run — expect PASS.** Set `const _GOLD_000 := <NNN>`. Re-run. Expected: `SELFTEST: PASS`, exit 0.

- [ ] **Step 5: Commit.**
```bash
git add client/scripts/interior_neighbors.gd client/tools/interior_selftest.gd client/tools/interior_selftest.tscn
git commit -m "feat(interior): deterministic neighbour hash + mask module w/ headless selftest (#36)"
```

---

## Task 3: Hatchway up/down art (Slice A)

Render `stairs` tiles as up- vs down- vs both-hatchways, derived from the vertically-adjacent deck. Client-only.

**Files:**
- Modify: `client/scripts/interior_view.gd` (add `_draw_stairs`, call it in `_draw` between floor and structure, ~`:158-170`)
- Modify: `server/glyphs.json` + `glyphs.default()` — add `stairs_up`/`stairs_down`/`stairs_updown` sprite ids to the `stairs` entry's doc (the client picks by direction, so add a comment; no schema change — `sprite` is a single field, so instead the client maps direction→id itself; see Step 1)
- Create: `client/assets/interior/stairs_up.png`, `stairs_down.png`, `stairs_updown.png` (extend `gen_interior_sprites.py`)
- Modify: `client/tools/interior_render_probe.gd` (add a stacked-stairs case)

**Interfaces:**
- Consumes: `ShipClassData.stairs_target(deck, x, y) -> int` (existing, client-side).
- Produces: `_draw_stairs(origin)` visual only.

- [ ] **Step 1: Add sprite generators + regen.** Extend `SPRITES` in `tools/gen_interior_sprites.py` with `stairs_up` (chevrons pointing up + rails), `stairs_down` (a dark shaft opening / down chevrons), `stairs_updown` (both). 64×64. Run `python tools/gen_interior_sprites.py`; confirm the three PNGs appear.

- [ ] **Step 2: Add the render pass.** In `interior_view.gd`, add a call `_draw_stairs(origin)` in `_draw()` right after `_draw_floor(origin)`. Direction logic (mirror the server rule; `target > view_deck` ⇒ down, `< ` ⇒ up; probe both directions for the "both" case using the same void-skip scan already at `:311-321`):
```gdscript
func _draw_stairs(origin: Vector2) -> void:
	var g := _deck()
	if g == null: return
	for ty in _grid_h():
		for tx in _grid_w():
			if not _vis(tx, ty): continue
			if g.tile_at(tx, ty) != ShipClassData.Tile.STAIRS: continue
			var down := ship_class.stairs_target(view_deck, tx, ty)  # deck+1-first
			var up := ship_class._scan_stairs(view_deck, -1, tx, ty)   # -1 = upward
			var has_down := down > view_deck
			var has_up := up != -1 and up < view_deck
			var name := "stairs_updown"
			if has_up and not has_down: name = "stairs_up"
			elif has_down and not has_up: name = "stairs_down"
			var tex: Texture2D = _lib.interior(name)
			if tex == null: continue  # graceful: plain floor already drawn
			var pos := _tile_to_screen(Vector2(tx, ty), origin)
			var slot := ship_class.color_at(view_deck, tx, ty)
			var tint := NetworkClient.palette.color(slot) if slot >= 0 and NetworkClient.palette != null else Color.WHITE
			draw_texture_rect(tex, Rect2(pos, Vector2(TILE_PIXELS, TILE_PIXELS)), false, tint)
```
Confirm `_scan_stairs`'s signature (`ship_class_data.gd:311`); if it's private/instance-scoped differently, add a tiny public `stairs_target_dir(deck, step, x, y)` helper mirroring it rather than reaching into `_scan_stairs`.

- [ ] **Step 3: Exercise it on the probe.** In `interior_render_probe.gd`, make a 2-deck plan where column (1,0) is `x` on both decks (so deck 0's stair leads down, deck 1's leads up). Capture `DH_SHOT` for each `view_deck`. Verify deck 0 shows `stairs_down` art and deck 1 shows `stairs_up`.

- [ ] **Step 4: Regression.** `python -m pytest harness/test_m2_interior.py -q` — Expected: green (stairs still walkable; only rendering changed).

- [ ] **Step 5: Commit.**
```bash
git add tools/gen_interior_sprites.py client/assets/interior/stairs_*.png client/scripts/interior_view.gd client/tools/interior_render_probe.gd
git commit -m "feat(interior): up/down hatchway art derived from adjacent deck (#36)"
```

---

## Task 4: Fountain merge (Slice B1)

First neighbour-aware decor tile; proves the module. Adjacent `f` tiles render as one pool.

**Files:**
- Modify: `server/glyphs.json` + `glyphs.default()` — add centre `f` → fountain.
- Modify: `server/test/glyphs_test.gleam` — keep default==file green (usually automatic; run to confirm).
- Modify: `client/scripts/interior_view.gd` — neighbour-aware branch in `_draw_decor`.
- Create: `client/assets/interior/fountain.png` + merge pieces `fountain_n/e/s/w/ns/ew/nesw/...` (or a single `fountain` + edge shading; start minimal).
- Modify: `tools/gen_interior_sprites.py`, `client/tools/interior_render_probe.gd`, `client/tools/interior_selftest.gd`.

**Interfaces:**
- Consumes: `InteriorNeighbors.mask4`.
- Produces: `_decor_sprite_id(glyph, mask, hash) -> String` (new helper routing merge/variant glyphs to a sprite id; plain glyphs return `reg.sprite_for_glyph(glyph)`).

- [ ] **Step 1: Add the glyph (server).** In `server/glyphs.json` `centers`, after `cargo_pallet`:
```json
{ "glyph": "f", "id": "fountain", "tile": "floor", "sprite": "fountain", "description": "Fountain (walkable floor); adjacent fountains render as one larger pool. Honours the NE-corner colour." }
```
Mirror the same `CenterSpec("fountain", Floor, None, False, False, Some("fountain"))` under `#("f", …)` in `glyphs.default()` (`glyphs.gleam`).

- [ ] **Step 2: Server test green.** From `server/`: `gleam test`. Expected: `glyphs_test` still passes (default==file), `... 0 failures`.

- [ ] **Step 3: Fountain pieces + selftest for the sprite router.** Add to `interior_selftest.gd` asserts for a pure `InteriorView._fountain_piece(mask)` mapping (16 masks → piece suffix). Since `_draw_decor` is instance code, put the pure mapping on `InteriorNeighbors` instead: `static func autotile_suffix(mask: int) -> String` returning e.g. `""` (isolated), `"_n"`, `"_ew"`, `"_nesw"`. Assert a few: `autotile_suffix(0) == ""`, `autotile_suffix(N|E|S|W) == "_nesw"`, `autotile_suffix(E|W) == "_ew"`. Run selftest → set any new golden → PASS.

- [ ] **Step 4: Neighbour-aware decor branch (client).** In `_draw_decor` (`interior_view.gd:308-331`), before the sprite lookup, route merge glyphs:
```gdscript
var sprite_id := ""
if glyph == "f":   # fountain: merge by neighbour mask
	var mask := InteriorNeighbors.mask4(_deck(), tx, ty, glyph)
	sprite_id = "fountain" + InteriorNeighbors.autotile_suffix(mask)
	if _lib.interior(sprite_id) == null:
		sprite_id = "fountain"  # fall back to the base piece if a suffix art is absent
else:
	sprite_id = reg.sprite_for_glyph(glyph)
```
Generate `fountain.png` (base pool) and at least `fountain_nesw.png` (seamless interior) in `gen_interior_sprites.py`; other suffixes fall back to base for now.

- [ ] **Step 5: See it.** Probe: author a 2×2 block of `f` tiles; `DH_SHOT`. Verify the 2×2 reads as one pool (interior tiles use the seamless piece), not four basins. Confirm relog-stability by capturing twice and diffing bytes (`fc` / `cmp`): identical.

- [ ] **Step 6: Commit.**
```bash
git add server/glyphs.json server/src/dh_server/glyphs.gleam client/scripts/interior_neighbors.gd client/scripts/interior_view.gd client/assets/interior/fountain*.png client/tools/interior_selftest.gd client/tools/interior_render_probe.gd
git commit -m "feat(interior): fountain tile with deterministic neighbour merge (#36)"
```

---

## Task 5: Flowerbed + trees (Slice B2)

`l` renders plants; interior cells of a large bed can become trees, chosen deterministically.

**Files:** `server/glyphs.json` + `glyphs.default()` (centre `l`); `client/scripts/interior_view.gd` (decor branch); `client/assets/interior/flowerbed.png`, `plant.png`, `tree.png`; `tools/gen_interior_sprites.py`; probe.

**Interfaces:**
- Consumes: `InteriorNeighbors.mask4`, `interior_hash`, `chance`.

- [ ] **Step 1: Add glyph `l`** (id `flowerbed`, sprite `flowerbed`) to `glyphs.json` + `default()`. Run `gleam test` → green.

- [ ] **Step 2: Sprites.** Add `flowerbed` (soil bed), `plant` (small sprig), `tree` (canopy) to the generator; regen.

- [ ] **Step 3: Decor branch + constants.** Extend `_draw_decor`'s router:
```gdscript
elif glyph == "l":   # flowerbed: plants, trees in the interior of a large bed
	var mask := InteriorNeighbors.mask4(_deck(), tx, ty, glyph)
	var neighbours := _popcount(mask)  # small helper: count set bits of 0..15
	var h := InteriorNeighbors.interior_hash(view_deck, tx, ty)
	if neighbours >= TREE_NEIGHBORS and InteriorNeighbors.chance(h, TREE_NUM, TREE_DEN):
		sprite_id = "tree"
	elif InteriorNeighbors.chance(h >> 3, 1, 2):
		sprite_id = "plant"
	else:
		sprite_id = "flowerbed"
```
Add near the top of the file: `const TREE_NEIGHBORS := 3`, `const TREE_NUM := 1`, `const TREE_DEN := 3` (levers, documented as such). Add a `_popcount(m:int)->int` helper (or `InteriorNeighbors.popcount`).

- [ ] **Step 4: Determinism assert.** In `interior_selftest.gd`, assert that for a fixed `(deck,x,y)` the tree/plant decision is stable across two calls and that a corner cell (`neighbours < 3`) never yields `tree`. Run selftest → PASS.

- [ ] **Step 5: See it.** Probe: a 4×4 `l` field; capture twice, diff bytes → identical; visually a few trees scattered in the interior, edges are plants/beds.

- [ ] **Step 6: Commit.**
```bash
git add server/glyphs.json server/src/dh_server/glyphs.gleam client/scripts/interior_view.gd client/scripts/interior_neighbors.gd client/assets/interior/flowerbed.png client/assets/interior/plant.png client/assets/interior/tree.png tools/gen_interior_sprites.py client/tools/interior_selftest.gd client/tools/interior_render_probe.gd
git commit -m "feat(interior): flowerbed w/ deterministic trees when combined (#36)"
```

---

## Task 6: Table merge + seat rotation (Slice B3)

`t` merges like fountains; a `seat` (`e`) adjacent to a table renders rotated to face it.

**Files:** `server/glyphs.json` + `default()` (centre `t`); `client/scripts/interior_view.gd` (decor branch: table autotile + seat facing); `client/assets/interior/table.png` (+ suffixes); generator; probe.

**Interfaces:**
- Consumes: `mask4`, `autotile_suffix`.
- Produces: seat-facing derivation reading table neighbours (tie-break dir priority N,E,S,W).

- [ ] **Step 1: Add glyph `t`** (id `table`, sprite `table`); `gleam test` green. Generate `table.png` (+ `table_nesw.png`).

- [ ] **Step 2: Table branch** in `_draw_decor` router: same shape as fountain (`"table" + autotile_suffix(mask4(...,"t"))`, fall back to base).

- [ ] **Step 3: Seat facing.** For `glyph == "e"`, before drawing, compute a facing from adjacent tables and rotate the sprite:
```gdscript
elif glyph == "e":   # seat: face an adjacent table if any (deterministic priority N,E,S,W)
	sprite_id = "seat"
	var g := _deck()
	var face := -1  # 0=N,1=E,2=S,3=W
	if g.decor_at(tx, ty - 1) == "t": face = 0
	elif g.decor_at(tx + 1, ty) == "t": face = 1
	elif g.decor_at(tx, ty + 1) == "t": face = 2
	elif g.decor_at(tx - 1, ty) == "t": face = 3
	# draw seat rotated by face*90°; if no table, face stays -1 → unrotated
```
Because `_draw_decor` currently uses `draw_texture_rect` (axis-aligned), add a `_draw_decor_rotated(tex, pos, quarter_turns, tint)` helper using `draw_set_transform`/`draw_texture` about the tile centre, and use it for seats (quarter_turns = face, or 0 when face<0). Leave all other decor on the existing `draw_texture_rect` path.

- [ ] **Step 4: Determinism assert.** Selftest: a seat with tables on two sides picks the priority winner (N over E); a seat with no table → face -1. Run → PASS.

- [ ] **Step 5: See it.** Probe: a `t` run with `e` seats around it; verify seats visibly turn toward the table; capture twice → byte-identical.

- [ ] **Step 6: Commit.**
```bash
git add -A
git commit -m "feat(interior): table merge + seats rotate toward adjacent tables (#36)"
```

---

## Task 7: Hydroponic garden (Slice B4)

Aesthetic planted tile reusing flowerbed machinery, with an explicit food-production hook and no mechanic.

**Files:** `server/glyphs.json` + `default()` (centre `g`); `client/scripts/interior_view.gd` (decor branch — reuse flowerbed logic w/ hydroponic sprites); `client/assets/interior/hydroponic.png`, `hydro_plant.png`; generator; probe; `docs/deckplan-format.md`.

- [ ] **Step 1: Add glyph `g`** (id `hydroponic`, sprite `hydroponic`); `gleam test` green. In the `glyphs.json` description, note the future-food hook so the seam is discoverable: `"… aesthetic for now; reserved for fresh-food production (#food)."`

- [ ] **Step 2: Sprites** `hydroponic` (trough/rack), `hydro_plant`; regen.

- [ ] **Step 3: Decor branch** for `glyph == "g"`: same neighbour/hash pattern as flowerbed but never trees — plants vs base only. Add a code hook: `# TODO(#food): hydroponic tiles are the future fresh-food source; a food system can enumerate 'g' decor cells without touching render.`

- [ ] **Step 4: See it + determinism** on probe (capture twice, diff). Document `g` in `docs/deckplan-format.md`.

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "feat(interior): hydroponic garden tile (aesthetic; food-production hook) (#36)"
```

---

## Task 8: Server — `edge.console` field + console glyphs on edges (Slice C, vocabulary)

Teach the registry that an edge fixture can carry a console kind. No derivation yet — just the data + round-trip.

**Files:**
- Modify: `server/schemas/glyphs.schema.json` (`edge.console`)
- Modify: `server/src/dh_server/glyphs.gleam` (`EdgeSpec.console`, decoder/encoder, `default()`, `edge_console_kind`)
- Modify: `server/glyphs.json` (move `h`/`c`/`b` to `edges` with `console`; remove from `centers`)
- Modify: `server/test/glyphs_test.gleam`

**Interfaces:**
- Produces: `glyphs.edge_console_kind(reg, glyph) -> Result(String, Nil)` (mirror of `console_kind` for edges); `EdgeSpec(id, kind, console: Option(String), sprite)`.

- [ ] **Step 1: Failing test.** In `glyphs_test.gleam`, add:
```gleam
pub fn edge_console_kind_test() {
  let reg = glyphs.default()
  assert glyphs.edge_console_kind(reg, "h") == Ok("helm")
  assert glyphs.edge_console_kind(reg, "b") == Ok("broker")
  assert glyphs.edge_console_kind(reg, "#") == Error(Nil)
}
```
- [ ] **Step 2: Run — fail.** `gleam test` → compile error / assert fail (`edge_console_kind` undefined, `h`/`b` not edges yet).

- [ ] **Step 3: Implement.**
  - `EdgeSpec`: add `console: Option(String)`. Update `edge_decoder` (`optional_field "console"`), `encode_edge` (nullable), and the `edge` fallback in `glyphs.edge` (`console: None`).
  - Add `pub fn edge_console_kind(reg, glyph) { option.to_result(edge(reg, glyph).console, Nil) }`.
  - `default()`: add edges `#("h", EdgeSpec("helm_console", Fixture, Some("helm"), Some("console_helm")))`, `c`→cargo, `b`→broker; **remove** the `h`/`c`/`b` centre entries.
  - `glyphs.json`: same edits (add three `edges` entries with `"kind":"fixture"`, `"console":…`, `"sprite":"console_…"`; delete the three `centers`).
  - `schemas/glyphs.schema.json`: add `"console": { "type": "string", "description": "Optional. Console kind mounted on this wall (e.g. 'helm'). The operating floor tile derives a console record." }` to `edge.properties`.
- [ ] **Step 4: Run — pass.** `gleam test` → `edge_console_kind_test` passes; `glyphs_test` default==file passes; `... 0 failures`.
- [ ] **Step 5: Commit.**
```bash
git add server/schemas/glyphs.schema.json server/src/dh_server/glyphs.gleam server/glyphs.json server/test/glyphs_test.gleam
git commit -m "feat(glyphs): edge fixtures can carry a console kind; move h/c/b to edges (#36)"
```

---

## Task 9: Server — derive consoles from edge fixtures (Slice C, derivation)

A console-bearing edge fixture on a floor tile yields a `Console` at that floor tile. Keep the record shape/ids so the sim is unchanged.

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam` (`scan_markers` also scans edges)
- Modify: `server/test/deckplan_test.gleam`

- [ ] **Step 1: Failing test.** Add to `deckplan_test.gleam` a small plan (built via `parse_deck`) with a wall-mounted `h` fixture on a floor tile's edge and assert the derived console:
```gleam
pub fn wall_console_derivation_test() {
  // 1x1-usable deck: floor tile at (1,1) with a helm fixture on its N edge.
  let rows = [
    "         ",
    " #h#     ",   // N-edge of tile (0,0)... (author exact 3x3 block; see deckplan-format)
    "         ",
  ]
  let assert Ok(g) = deckplan.parse_deck("t", rows)
  let plan = deckplan.DeckPlan([g], [], 0, #(0, 0))
  // derivation happens in decoder(); for a hand-built plan call the exposed
  // derive path or parse via decoder from JSON. Assert one helm console at the
  // floor tile owning that edge.
  ...
}
```
Author the exact rows against `docs/deckplan-format.md` (centre col `3x+1`, N edge row `3y`). Assert `find_console_of_kind(plan, "helm")` returns a console at the floor tile, kind `"helm"`. (If derivation is only reachable through `decoder`, drive the test through `deckplan.decoder` on a JSON deck instead of `parse_deck`.)

- [ ] **Step 2: Run — fail.** `gleam test` → no helm console derived (edges not scanned).

- [ ] **Step 3: Implement.** In `scan_markers` (`deckplan.gleam:571-596`), after the centre-glyph check, also inspect the tile's four edge glyphs; for each edge whose `glyphs.edge_console_kind` is `Ok(kind)`, and the centre tile is `Floor`, append `#(kind, deck, x, y)`. Guard against double-counting a fixture authored on both facing tiles (the double-wall model): only the tile whose own edge carries the glyph emits it (scan the raw edge char at this tile's N/E/S/W positions, not the neighbour's). Dock (`Q`) stays centre-derived — unchanged.

- [ ] **Step 4: Run — pass.** `gleam test` → `wall_console_derivation_test` passes; existing console/dock tests still green.

- [ ] **Step 5: Round-trip.** Add/confirm a `deck_to_rows` round-trip case that a wall console survives `parse → deck_to_rows → parse` (the edge glyph is re-emitted). Run `gleam test` → green.

- [ ] **Step 6: Commit.**
```bash
git add server/src/dh_server/deckplan.gleam server/test/deckplan_test.gleam
git commit -m "feat(deckplan): derive console records from wall-mounted edge fixtures (#36)"
```

---

## Task 10: Client — ingest edge consoles, render on the wall, stop centre-drawing (Slice C, client)

**Files:**
- Modify: `client/scripts/glyph_registry.gd` (ingest edge `console`)
- Modify: `client/scripts/interior_view.gd` (`_draw_consoles` skips wall kinds; wall fixture already renders console art via `_fixture_tex`)

- [ ] **Step 1: Registry ingest.** In `GlyphRegistry.from_dict`/`_ingest` (`glyph_registry.gd:33-60`), for edge entries with both `console` and `sprite`, register `console_sprite[kind] = sprite` (same as centres today) and ensure `sprite_by_glyph[glyph] = sprite` so `_fixture_tex` resolves the wall art. Confirm `is_decor` is unaffected (edges aren't decor).

- [ ] **Step 2: Wall art renders.** No new draw code needed — `_fixture_tex` (`interior_view.gd:408-421`) already maps an edge glyph → `sprite_for_glyph` → texture on the wall strip. Verify `console_helm.png` (exists) shows on the wall in the probe when an `h` edge is authored.

- [ ] **Step 3: Stop double-draw.** In `_draw_consoles` (`:540-566`), `continue` for `console.kind in ["helm","cargo","broker"]` (their art is now the wall fixture) while keeping `dock` and keeping the interaction/binding. Keep a coloured-square fallback ONLY if the wall sprite is absent (optional; simplest is to just skip).

- [ ] **Step 4: Probe.** Author a floor tile with an `h` on its wall edge + a seat `e` in front. Capture: helm art on the wall, seat on the floor, no centred helm square. `DH_SHOT` diff twice → identical.

- [ ] **Step 5: Commit.**
```bash
git add client/scripts/glyph_registry.gd client/scripts/interior_view.gd client/tools/interior_render_probe.gd
git commit -m "feat(interior): render wall-mounted consoles on the wall strip (#36)"
```

---

## Task 11: Migrate maps to wall-mounted consoles (Slice C, migration)

Re-author existing maps so `h`/`c`/`b` are wall fixtures with a seat on the operating floor tile. This is the behavioural-parity gate.

**Files:**
- Modify: `server/shipclasses/mockingbird.json`
- Modify: `server/stationclasses/*.json` (any with `h`/`c`/`b` centres)
- Verify: sim/dock behaviour unchanged.

- [ ] **Step 1: Inventory.** `grep -rn` the centre glyphs in every `server/shipclasses/*.json` and `server/stationclasses/*.json` to list every console to move (helm on Mockingbird Upper `#h  e#`; cargo on Lower `#c`; brokers on stations).

- [ ] **Step 2: Migrate Mockingbird.** For each console: place the console glyph on the wall edge adjacent to its seat (e.g. Upper helm: put `h` on the west or north wall of the seat tile, seat `e` on the floor). Keep the operating floor tile walkable. Preserve the airlock `Q` centres. Re-author the exact 3×3 blocks.

- [ ] **Step 3: Parity test.** `gleam test` — the plan-load tests derive helm/cargo consoles at the expected floor tiles. Add/adjust a Mockingbird-specific assertion if one exists; otherwise assert via `deckplan_test` that a migrated snippet derives the same kinds.

- [ ] **Step 4: Integration.** `python -m pytest harness/test_m2_interior.py harness/test_m31_stitched.py harness/test_m3_trade.py -q` — Expected green: login-at-helm, walking ashore, trade at broker all still work (console floor tiles unchanged → seating/binding unchanged).

- [ ] **Step 5: Visible check.** `python harness/shot_m35_interior.py`; inspect `harness/out/m35_int_seated.png` — helm now reads as a wall console with the pilot seated in front.

- [ ] **Step 6: Commit.**
```bash
git add server/shipclasses/mockingbird.json server/stationclasses/*.json
git commit -m "refactor(maps): mount helm/cargo/broker consoles on walls over seats (#36)"
```

---

## Task 12: Wall-mounted bunk rule tile (Slice D)

An edge `d` (wall bunk), distinct from centre `d` (floor bed). Convention-only placement rule, documented; render stacks deterministically.

**Files:** `server/glyphs.json` + `default()` (edge `d`); `server/schemas` (none — reuses fixture); `client/assets/interior/bunk.png`; `docs/deckplan-format.md`; probe.

- [ ] **Step 1: Add edge glyph `d`.** In `glyphs.json` `edges`: `{ "glyph": "d", "id": "bunk", "kind": "fixture", "sprite": "bunk", "description": "Wall-mounted bunk. Convention: may only mount over a floor bed (centre d) or another wall bunk (stacking). Enforcement is #24." }`. Mirror in `default()` as `#("d", EdgeSpec("bunk", Fixture, None, Some("bunk")))`. `gleam test` → green (default==file; `d` centre bed untouched).

- [ ] **Step 2: Sprite.** Add `bunk` (64×14 wall bunk: frame + mattress band) to the generator; regen.

- [ ] **Step 3: Render + stacking.** The bunk renders via `_fixture_tex` automatically. For a stacked look, optionally vary the bunk sprite by a small vertical mask (bunk over a `d` bed vs bunk over bunk) — start with the single `bunk.png` (YAGNI; note the stacking hook in a comment).

- [ ] **Step 4: Document the convention** in `docs/deckplan-format.md`: centre `d` = floor bed; edge `d` = wall bunk; legal only over a floor bed or another bunk; enforcement is #24.

- [ ] **Step 5: Probe.** Author a floor bed `d` with a wall bunk `d` on the wall above it; capture — reads as a bunk over a bed. Blocks like a wall (walk into it → blocked); confirm via existing collision (fixture blocks).

- [ ] **Step 6: Commit.**
```bash
git add server/glyphs.json server/src/dh_server/glyphs.gleam client/assets/interior/bunk.png docs/deckplan-format.md tools/gen_interior_sprites.py client/tools/interior_render_probe.gd
git commit -m "feat(interior): wall-mounted bunk rule tile (convention; enforcement #24) (#36)"
```

---

## Task 13: First-crack sprites for all pass-2 tiles + captures (Slice E-final)

Polish the generated art one pass (still crude but legible), regenerate everything, and capture per-mechanic screenshots so the whole zoo is visible.

**Files:** `tools/gen_interior_sprites.py` (refine shapes/shading), `client/assets/interior/*.png` (regen), `docs/superpowers/plans/…` (link captures), `harness/out/` (captures, gitignored).

- [ ] **Step 1: Refine** each generator sprite for legibility (consistent light-grey base ~180–210 so palette multiply reads; darker accents). Regen all.
- [ ] **Step 2: Full sweep capture.** Probe-capture each pass-2 tile (fountain 2×2, flowerbed field, table+seats, hydroponic, up/down stairs, wall console, bunk). Save under `harness/out/pass2_*.png`.
- [ ] **Step 3: Determinism sweep.** For each neighbour-aware capture, shoot twice and `cmp`/`fc` → byte-identical. `godot --path client --headless res://tools/interior_selftest.tscn --quit-after 240` → `SELFTEST: PASS`.
- [ ] **Step 4: Regression sweep.** `cd server && gleam test` → 0 failures; `python -m pytest harness/test_m2_interior.py harness/test_m31_stitched.py harness/test_m3_trade.py -q` → green.
- [ ] **Step 5: Hand-off note.** Add a short "retuning sprites" note to `docs/deckplan-format.md` (or the spec): edit `tools/gen_interior_sprites.py` or replace any `client/assets/interior/<sprite>.png`; the sprite-id list = registry `sprite` fields.
- [ ] **Step 6: Commit.**
```bash
git add tools/gen_interior_sprites.py client/assets/interior/*.png docs/deckplan-format.md
git commit -m "feat(interior): first-crack sprite pass for all pass-2 tiles (#36)"
```

---

## Final: batch review

After Task 13, the branch `feat/decorated-interiors-pass2` holds all slices. Open **one** PR referencing #36 with a summary of the mechanics and the probe/screenshot captures, per the batched-review model. Do not open per-slice PRs.

## Self-review notes (coverage vs spec)

- F1 vocabulary → Tasks 4,5,6,7,8,12. F2 determinism → Task 2 (+ asserts in 4,5,6,7). F3 sprites → Tasks 1,13.
- Slice A → Task 3. Slice B → Tasks 4–7 (module in 2). Slice C → Tasks 8–11. Slice D → Task 12. Slice E → Tasks 1,13.
- Non-goals honoured: no builder enforcement (bunk is convention, Task 12); hydroponic hook only (Task 7); no walkability/wire changes beyond `edge.console` (Task 8).
