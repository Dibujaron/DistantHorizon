# M3.5 PR 3 — On-Foot Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the interior read as a place: generated deck/concourse tile art with
bulkhead edges, Semiotic-Standard signage (hazard stripes, stencil berth digits,
pictograms), FTL-scale character sprites, THE WINDOW (the live system view visible
through the hull voids), and a toggleable view-cone prototype.

**Architecture:** Interior stays immediate-mode (`interior_view.gd` `_draw`) but textured:
tiles/decals/characters come from two new artspike generators (`tiles.py`,
`characters.py`) exported to `client/assets/{interior,characters}/` and loaded through
`AssetLibrary`. Void tiles stop painting VOID_COLOR; instead main.gd keeps WorldView
visible (dimmed) beneath InteriorView in INTERIOR mode, so space — station traffic,
planets, parallax — shows through everywhere the deck plan isn't. The view-cone is a
cached tile-LOS dim overlay toggled with V.

**Tech Stack:** Python (resvg vector tiles through the PR 1 rasterize path), Godot 4.7
gl_compatibility, GDScript. Verification via a new interior screenshot driver.

## Global Constraints

- Branch `m3.5-vibe-pass`, stacked. Tiles are 64 px (`TILE_PIXELS`); character collision
  radius is 0.3 tiles — sprites read against that, not replace it.
- Interior art is hand-authored-style: NO normal maps, never sun-lit (interiors aren't
  in the suns' cull mask — everything in InteriorView keeps default light_mask but the
  suns only cull-mask ships, and InteriorView draws above WorldView anyway).
- Concourse tone: transactional, a little alienating; grid lines die, plate seams live
  in the texture. Signage is the cheap vibe: hazard stripes, stencil digits, pictograms
  (Ron Cobb Semiotic Standard as reference — simple white geometric icons).
- Characters: FTL-honest upright mini-people, ~22×34 px, one player variant + 3 crew
  variants; "no generic NPC" arrives later (M6-ish variation axes) — this is the
  minimum cast for the vibe pass.
- The window is a LAYER decision in main.gd (world view stays visible dimmed), not a
  copy of the space renderer. The view-cone overlay is toggleable (V) and defaults OFF.
- Don't block on eyeball review: publish round 7, queue verdicts.

---

### Task 1: Tile + signage generator (`tools/artspike/tiles.py`)

**Files:**
- Create: `tools/artspike/tiles.py`
- Test: `tools/artspike/test_composer.py` (append)
- Output (committed): `client/assets/interior/*.png` + `client/assets/interior/meta.json`

**Interfaces (all rendered at 64 px tile scale via `composer.rasterize`, ss=1 on a
64-unit frame — tiles are authored at final resolution):**
- `floor_0.png, floor_1.png, floor_2.png` (64×64): deck plating — near-black blue-gray
  base (#14161c-ish family), panel seam lines (INK at low alpha), occasional rivet dots
  / scuff variant. Must butt seamlessly (seams only at inset lines, edges clean).
- `wall_n.png` (64×14): bulkhead cap strip drawn along the TOP edge of a floor tile
  (light gray #3a3f4a face + darker #232833 inner shadow line). Client rotates it for
  E/S/W. `wall_corner.png` (14×14) for outer corners.
- `console_helm.png, console_cargo.png, console_broker.png` (44×44): kind-colored
  console readouts (blue helm / amber cargo / green broker screen glow on a dark desk
  block) — top-down desk + lit screen, no text.
- `hazard.png` (64×14): yellow/black diagonal stripe strip (45°, 8 px pitch, worn —
  2-3 notches knocked out).
- `digit_0.png … digit_9.png` (26×40): stencil numerals, white, built from rects with
  stencil gaps (7-segment-with-bridges look; NOT font-rendered — resvg text needs
  fonts, rect segments don't).
- `picto_airlock.png, picto_trade.png, picto_cargo.png, picto_helm.png` (40×40):
  white 2.5px-stroke geometric icons in a circle outline, Semiotic-Standard register:
  airlock = circle with inner door arc + two brackets; trade = two opposed arrows;
  cargo = crate (square + diagonal braces); helm = chevron over a dot.
- `meta.json`: `{"tile_px": 64, "wall_px": 14, "files": [...]}` (inventory only).
- Registry `TILE_SPRITES: list[(name, w, h, svg_fn)]`; `main()` renders each to
  `client/assets/interior/` (alpha preserved; floors opaque, decals transparent).

- [ ] **Step 1: Failing test** (append to test_composer.py):

```python
def test_tiles_export(tmp_path):
    from tiles import TILE_SPRITES, export_tiles
    export_tiles(tmp_path)
    import json
    meta = json.loads((tmp_path / "meta.json").read_text())
    assert meta["tile_px"] == 64
    names = {n for n, _, _, _ in TILE_SPRITES}
    assert {"floor_0", "floor_1", "floor_2", "wall_n", "hazard",
            "console_helm", "console_cargo", "console_broker",
            "picto_airlock", "picto_trade", "picto_cargo", "picto_helm"} <= names
    assert all((tmp_path / f"digit_{d}.png").exists() for d in range(10))
    from PIL import Image
    f = Image.open(tmp_path / "floor_0.png")
    assert f.size == (64, 64)
    assert f.getpixel((0, 0))[3] == 255          # floors are opaque
    d = Image.open(tmp_path / "digit_7.png")
    assert d.getpixel((0, 0))[3] == 0            # decals are transparent
```

- [ ] **Step 2:** Run → FAIL (no tiles module).
- [ ] **Step 3:** Implement `tiles.py` with small SVG-fragment functions per sprite
  (reuse `shipforge.rrect/line/poly` + `composer.rasterize` with a `(0, 0, w, h)`
  frame, ss=1), `export_tiles(out_dir)` writing PNGs + meta, `main()` targeting
  `client/assets/interior/`. Palette: floor #14161c/#1a1d25/#10131a bases, INK seams
  at 0.35 opacity, bulkhead #3a3f4a/#232833, hazard #d9a441/#101010, decals #e8ecf2
  at 0.9 opacity.
- [ ] **Step 4:** Run tests → PASS; run `python tools/artspike/tiles.py`; Read a
  contact sheet (add a tiny `sheet_tiles.png` compositing all sprites on one image
  in `main()`) and eyeball: plates read as deck not grid, hazard reads worn, digits
  stencil-read at 40 px, pictograms read at 40 px.
- [ ] **Step 5:** Commit `feat(art): interior tile + signage generator`.

---

### Task 2: Character sprite generator (`tools/artspike/characters.py`)

**Files:**
- Create: `tools/artspike/characters.py`
- Test: `tools/artspike/test_composer.py` (append)
- Output (committed): `client/assets/characters/{player,crew_0,crew_1,crew_2}.png` (22×34)

**Interfaces:**
- `character_svg(jumpsuit_rgb, skin_rgb, hair_rgb) -> str` — upright FTL-scale person:
  boots (2 dark 4×5 rects), jumpsuit body (rounded 12×14 torso + 4px legs), arms (2
  thin side rects, jumpsuit shade), head (7px circle, skin), hair cap (top arc),
  chest tab (2×3 lighter rect — the "badge"). INK outline 1px everywhere.
- `CHARACTERS = [("player", RIJ blue suit), ("crew_0", PHE orange), ("crew_1",
  #57755c green), ("crew_2", #7a6b8e mauve)]` with two skin tones and hair colors
  spread across them; `export_characters(out_dir)`; `main()` →
  `client/assets/characters/`.

- [ ] **Step 1: Failing test:**

```python
def test_characters_export(tmp_path):
    from characters import CHARACTERS, export_characters
    export_characters(tmp_path)
    from PIL import Image
    for name, _ in CHARACTERS:
        img = Image.open(tmp_path / f"{name}.png")
        assert img.size == (22, 34)
        assert img.getpixel((0, 0))[3] == 0      # transparent background
    assert {n for n, _ in CHARACTERS} == {"player", "crew_0", "crew_1", "crew_2"}
```

- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** tests PASS + eyeball a
  4-up contact sheet at 1×/3× (`sheet_characters.png`). **Step 5:** Commit
  `feat(art): FTL-scale character sprites (player + 3 crew)`.

---

### Task 3: AssetLibrary additions

**Files:**
- Modify: `client/scripts/asset_library.gd`

**Interfaces:**
- `func interior(name: String) -> Texture2D` — any `client/assets/interior/*.png` by
  basename ("floor_0", "hazard", "digit_3", "picto_airlock", …), loaded by directory
  scan like `_bodies`.
- `func character(name: String) -> Texture2D` — "player" | "crew_0" | "crew_1" | "crew_2".

- [ ] **Step 1:** Add `_interior`/`_characters` dicts + directory scans in `load_all`
  (same `DirAccess.get_files_at` loop as bodies) + the two accessors.
- [ ] **Step 2:** `godot --path client --headless --quit` → clean. Commit
  `feat(client): asset library loads interior + character art`.

---

### Task 4: InteriorView rework + THE WINDOW + view-cone

**Files:**
- Modify: `client/scripts/interior_view.gd` (major)
- Modify: `client/scripts/main.gd` (window layering in `_apply_transition_visuals` /
  `_snap_view_visuals`; V-key handling)
- Modify: `client/project.godot` (input action `toggle_viewcone`, physical V / keycode 86)

**The window (main.gd):** WorldView stays VISIBLE in INTERIOR mode, dimmed:
- `_apply_transition_visuals`: replace `_world_view.modulate.a = 1.0 - interior_alpha`
  + visible toggle with: alpha stays 1.0; `_world_view.modulate =
  Color(1,1,1).lerp(WINDOW_DIM, eased)` when transitioning to interior (reverse when
  leaving); `_world_view.visible = true` always. `const WINDOW_DIM := Color(0.42,
  0.47, 0.58)` (cool, dark — space through glass).
- `_snap_view_visuals`: same end states.
- InteriorView void tiles paint NOTHING (transparent), so the dimmed system view IS
  the window everywhere the plan isn't. Floors/walls are opaque textures and occlude.

**interior_view.gd rework (all in `_draw`, textures via one AssetLibrary loaded in
`_ready` — reuse `AssetLibrary.load_all()`? No: heavy. Add a lightweight static
`AssetLibrary.load_interior_only()`? NO — simplest: `_lib = AssetLibrary.load_all()`
once per view is fine, it's a handful of small files loaded at startup):**

- Floor: variant by `abs(hash(Vector2i(tx, ty))) % 3`; `draw_texture_rect(tex, rect,
  false)`. Keep room tint as a subtle overlay: `draw_rect(rect, tint * Color(1,1,1,
  0.10), true)` using the existing palette; drop `GRID_LINE_COLOR` entirely.
- Bulkheads: for each walkable tile, for each of 4 neighbors that is NOT walkable
  (or out of bounds), draw the wall strip on that edge: north = `draw_texture_rect
  (wall_n, Rect2(pos, Vector2(64, 14)))`; others via `draw_set_transform` rotation
  around the tile (E: rot PI/2 at pos+(64,0); S: rot PI at pos+(64,64); W: rot
  -PI/2 at pos+(0,64)), then `draw_set_transform(Vector2.ZERO)` reset.
- Consoles: `draw_texture(console_<kind>, center - Vector2(22, 22))`; fall back to the
  colored square if texture missing; keep the small kind label for now (UI pass owns
  its fate).
- Signage:
  - Rooms with id `berth_<n>`: stencil digit at room-rect center (`digit_<n%10>`),
    drawn under characters; `picto_airlock` at 0.5 alpha in the tile's top-left.
  - Hazard strips: on every walkable tile INSIDE a `berth_*` room, draw `hazard` along
    each edge bordering a walkable tile OUTSIDE the room (the pinch mouth gets striped).
  - Rooms named Concourse: `picto_trade` faded (0.35 alpha) on the floor by each broker
    console (offset one tile left if walkable, else on the console tile).
- Characters: sprite `player` for own id, `crew_<abs(id_hash) % 3>` for others; draw at
  `screen_pos + Vector2(-11, -24)` (feet at the collision circle's bottom: 34px tall,
  center-of-mass at ~y 22). Track `_facing: Dictionary` (id → -1|1) updated when x
  moves > 0.01 tile between frames; `draw_texture_rect(tex, rect, false)` with rect
  width negated... `draw_texture_rect_region` doesn't flip — use `draw_set_transform
  (screen_pos, 0, Vector2(facing, 1))` then draw at local offset, then reset. Name
  labels stay. Own-character label stays "you".
- View-cone (prototype, default off): main.gd flips `_interior_view.view_cone_enabled`
  on `toggle_viewcone` pressed. In InteriorView: when enabled, dim walkable tiles
  without LOS: recompute `_visible_tiles: Dictionary` only when own tile (floored)
  changes or plan id changes; LOS = Bresenham tile walk from own tile center to target
  tile center, blocked by non-walkable tiles (target tile itself allowed); overlay
  `draw_rect(rect, Color(0, 0, 0, 0.55))` on walkable-but-hidden tiles, drawn after
  floors/signage, before characters (hidden characters: skip drawing others entirely
  when their tile is hidden — that's the gameplay tease).

```gdscript
func _line_of_sight(from_tile: Vector2i, to_tile: Vector2i) -> bool:
	var x0 := from_tile.x; var y0 := from_tile.y
	var x1 := to_tile.x; var y1 := to_tile.y
	var dx := absi(x1 - x0); var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		if Vector2i(x0, y0) != from_tile and Vector2i(x0, y0) != to_tile \
				and not ship_class.is_walkable(x0, y0):
			return false
		if x0 == x1 and y0 == y1:
			return true
		var e2 := 2 * err
		if e2 >= dy: err += dy; x0 += sx
		if e2 <= dx: err += dx; y0 += sy
	return true
```

- [ ] **Step 1:** main.gd window layering + input action + view-cone toggle plumb.
- [ ] **Step 2:** interior_view.gd rework per above.
- [ ] **Step 3:** `godot --path client --headless --quit` → clean (editor cache pass
  first if new class_names appear — none should).
- [ ] **Step 4:** Commit `feat(client): on-foot layer - tiles, signage, characters, THE WINDOW, view-cone prototype`.

---

### Task 5: Live verification (`harness/shot_m35_interior.py`)

Mirror `shot_m35_space.py`'s boot; then:
1. Wait for login (seated at helm, station composite) → shot `m35_int_seated.png` —
   the deck + concourse with the dimmed system view through the voids (THE WINDOW).
2. E to stand → walk ashore (reuse the smoke test's helm_x+4 airlock walk +
   `_settle_x`) → shot `m35_int_concourse.png` — berth digits, hazard stripes,
   characters on the concourse.
3. `key("V")` press/release → shot `m35_int_viewcone.png` → V again (off).
4. SPACE undock (walk back to helm + E + … too long — instead relogin approach:
   skip; simplest flying-window shot: second driver run undocks while seated at
   login, then E-stands mid-flight) → shot `m35_int_flying.png` — the hold with
   stars/planet streaming past = the Awe frame.
   (Implementation: after the concourse shots, walk back to the helm column and
   `_settle_x` onto it, E to sit, SPACE to undock, thrust 2 s, E to stand, shot.)
5. Read every shot; eyeball: place-not-grid, window payoff, signage reads, sprites
   read at FTL scale, view-cone hides the far concourse.
6. Iterate constants (dim color, tint alphas, hazard pitch) from the eyeball; commit
   `feat(harness): interior screenshot driver`.

---

### Task 6: Publish round 7 + PR comment + verify

- [ ] `python -m pytest tools/artspike -q` green; `sheet_mfr.svg` regen unchanged;
  `godot --path client --headless --quit` clean.
- [ ] Artifact round 7 in place (same URL): interior shots + tile/character contact
  sheets; queue: tileset read, character sprites (new design language — flag hard),
  window dim level, view-cone keep/cut, signage density.
- [ ] Push; `gh pr comment 9` with the round-7 summary.

---

## Self-Review

- Scope: tileset ✓ T1/T4, characters ✓ T2/T4, signage ✓ T1/T4, window ✓ T4 (layering,
  not re-render) with flying + docked frames ✓ T5, view-cone prototype toggleable ✓ T4.
- Consistency: `AssetLibrary.interior/character` names match tiles.py/characters.py
  outputs; digit naming `digit_<n>` matches berth id parse `berth_<n>`.
- Placeholders: tile art directions are written as specs with exact palettes/sizes
  (they're art, iterated at eyeball time); all logic is full code or exact directives.
