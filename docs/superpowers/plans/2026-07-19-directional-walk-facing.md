# 4-axis Directional Walk Facing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Characters turn to face their direction of travel — front (down), back (up), and side (left/right) — instead of always facing the camera.

**Architecture:** Add two procedurally-drawn views (back, side) to the existing character generator, bake a walk sheet for each alongside the front sheet, and pick the sheet at draw time by the dominant movement axis with hysteresis. Render-only: no movement, networking, or collision changes.

**Tech Stack:** Python + PIL + resvg (`tools/artspike`) for the source sprites; GDScript headless `Image` compositing for the baker; GDScript `CanvasItem` draw calls in `interior_view.gd` for the runtime.

## Global Constraints

- Character source cells are **22×34 px**; walk sheets are **5 cells** wide (`SHEET_CELLS = 5`): cell 0 idle, cells 1–4 the cycle. Every new sheet keeps this shape.
- Art is **procedural** (`rrect`/`circle` SVG primitives) — no hand-drawn PNGs.
- The four characters are exactly `player`, `crew_0`, `crew_1`, `crew_2`.
- This change is **render-only** — do not touch movement, networking, collision, or seating logic beyond reading `is_seated()`.
- All verification runs **serverless** in the isolated worktree — never against the running devserver.
- Side art is authored facing **right**; the runtime mirrors it for left.

---

### Task 1: Back and side source sprites

Add two view functions to the generator and export them per character. Back = front minus the face. Side = a new right-facing profile whose legs are authored adjacent (split at x=11) so the baker can scissor them.

**Files:**
- Modify: `tools/artspike/characters.py`
- Test: `tools/artspike/test_composer.py` (extend `test_characters_export`)

**Interfaces:**
- Consumes: `rrect(x, y, w, h, r, fill, stroke, sw)`, `circle(cx, cy, r, fill, stroke, sw)` from `shipforge`; `rasterize(fragment, (minx,miny,w,h), ss)` from `composer`; existing `_shade(hex, k)`, `INK`, `BOOT`, `CHARACTERS`.
- Produces: `character_back_svg(suit, skin, hair) -> str`, `character_side_svg(suit, skin, hair) -> str`; `export_characters(out_dir)` now also writes `<name>_back.png` and `<name>_side.png` (each 22×34, transparent bg).

- [ ] **Step 1: Extend the export test to require the two new views**

In `tools/artspike/test_composer.py`, replace `test_characters_export` (lines ~215-223) with:

```python
def test_characters_export(tmp_path):
    from characters import CHARACTERS, export_characters
    export_characters(tmp_path)
    from PIL import Image
    import numpy as np
    for name, _ in CHARACTERS:
        for suffix in ("", "_back", "_side"):
            img = Image.open(tmp_path / f"{name}{suffix}.png")
            assert img.size == (22, 34)
            assert img.getpixel((0, 0))[3] == 0        # transparent background
            assert np.asarray(img)[..., 3].max() > 0   # not a blank cell
        front = np.asarray(Image.open(tmp_path / f"{name}.png"))
        for suffix in ("_back", "_side"):
            view = np.asarray(Image.open(tmp_path / f"{name}{suffix}.png"))
            assert not np.array_equal(front, view)     # a real turn, not a copy
    assert {n for n, _ in CHARACTERS} == {"player", "crew_0", "crew_1", "crew_2"}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python -m pytest tools/artspike/test_composer.py::test_characters_export -q`
Expected: FAIL — `export_characters` does not write `_back`/`_side` files yet (FileNotFoundError).

- [ ] **Step 3: Add the two view functions**

In `tools/artspike/characters.py`, after `character_svg` (line ~47), add:

```python
def character_back_svg(suit, skin, hair):
    dark = _shade(suit)
    s = ""
    # legs + boots (identical topology to the front view)
    s += rrect(6.5, 23, 4, 8, 1, dark, stroke=INK, sw=1)
    s += rrect(11.5, 23, 4, 8, 1, dark, stroke=INK, sw=1)
    s += rrect(5.5, 30, 5, 3.5, 1, BOOT, stroke=INK, sw=1)
    s += rrect(11.5, 30, 5, 3.5, 1, BOOT, stroke=INK, sw=1)
    # arms
    s += rrect(2.8, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    s += rrect(16, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    # torso — no chest badge on the back
    s += rrect(5, 12.5, 12, 11.5, 3, suit, stroke=INK, sw=1)
    # head: back of the skull is all hair, no face; a nape shadow at the collar
    s += circle(11, 7.4, 5.3, hair, stroke=INK, sw=1)
    s += f'<rect x="9" y="12" width="4" height="1.5" fill="{_shade(hair, 0.7)}"/>'
    return s


def character_side_svg(suit, skin, hair):
    """Profile facing RIGHT. The runtime mirrors it for left. Legs are authored
    adjacent (split at x=11) so the baker separates near/far leg with a vertical
    cut and scissors them fore/aft. Boots stay within their half of the split so
    the cut never tears a foot."""
    dark = _shade(suit)
    deep = _shade(suit, 0.6)          # far-side limbs read darker
    s = ""
    # back (far) leg — left of the split; front (near) leg — right of it
    s += rrect(7.0, 23, 3.5, 8, 1, deep, stroke=INK, sw=1)      # back leg  (x 7.0-10.5)
    s += rrect(6.5, 30, 4.0, 3.5, 1, _shade(BOOT, 0.7), stroke=INK, sw=1)  # back boot (x 6.5-10.5)
    s += rrect(11.0, 23, 3.5, 8, 1, dark, stroke=INK, sw=1)     # front leg (x 11-14.5)
    s += rrect(11.0, 30, 5.0, 3.5, 1, BOOT, stroke=INK, sw=1)   # front boot toe-forward (x 11-16)
    # torso — narrower than the front (seen edge-on)
    s += rrect(6.5, 12.5, 8, 11.5, 3, suit, stroke=INK, sw=1)
    # single near arm over the torso (the far arm is hidden behind it)
    s += rrect(8.5, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    # head: hair cap at the back (left), face pushed to the forward (right) edge
    s += circle(9.5, 7.0, 5.2, hair, stroke=INK, sw=1)
    s += circle(12.0, 8.4, 3.6, skin, stroke=INK, sw=1)
    s += f'<rect x="14.2" y="8.0" width="1.3" height="1.6" fill="{skin}"/>'  # nose nub
    return s
```

- [ ] **Step 4: Export the new views**

In `export_characters` (line ~59), replace the loop body so all three views are written:

```python
def export_characters(out_dir):
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    views = {"": character_svg, "_back": character_back_svg, "_side": character_side_svg}
    for name, (suit, skin, hair) in CHARACTERS:
        for suffix, fn in views.items():
            rgba = rasterize(fn(suit, skin, hair), (0, 0, 22, 34), ss=1)
            Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8),
                            "RGBA").save(out / f"{name}{suffix}.png")
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `python -m pytest tools/artspike/test_composer.py::test_characters_export -q`
Expected: PASS.

- [ ] **Step 6: Regenerate the shipped source sprites + contact sheet**

Extend `main()` (line ~68) so the contact sheet shows all three views. Replace the contact-sheet block with:

```python
def main():
    root = pathlib.Path(__file__).parents[2]
    export_characters(root / "client" / "assets" / "characters")
    print("exported", len(CHARACTERS), "characters x 3 views")
    # contact sheet: front / back / side per character, 1x and 3x
    views = [character_svg, character_back_svg, character_side_svg]
    cell, gap = 22, 6
    cols = len(views)
    sheet = Image.new(
        "RGBA",
        (len(CHARACTERS) * (cols * (cell + gap) + gap),
         cell + 34 * 3 + 36), (10, 13, 19, 255))
    for i, (name, (suit, skin, hair)) in enumerate(CHARACTERS):
        ox = 12 + i * (cols * (cell + gap) + gap)
        for j, fn in enumerate(views):
            rgba = rasterize(fn(suit, skin, hair), (0, 0, 22, 34), ss=1)
            img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA")
            sheet.alpha_composite(img, (ox + j * (cell + gap), 12))
            sheet.alpha_composite(img.resize((66, 102), Image.NEAREST),
                                  (ox + j * (cell + gap), 58))
    out = pathlib.Path(__file__).parent / "sheet_characters.png"
    sheet.convert("RGB").save(out)
    print("wrote", out)
```

Run: `python tools/artspike/characters.py`
Expected: prints `exported 4 characters x 3 views` and `wrote .../sheet_characters.png`; `client/assets/characters/` now contains `<name>_back.png` and `<name>_side.png` for all four characters.

- [ ] **Step 7: Commit**

```bash
git add tools/artspike/characters.py tools/artspike/test_composer.py \
        tools/artspike/sheet_characters.png client/assets/characters/
git commit -m "feat(art): back + side character views for directional walk (#34)"
```

---

### Task 2: Bake back and side walk sheets

Refactor the baker so it bakes any (source, slice-config, pose-table) combination, then bake three sheets per character: front (unchanged), back (front slicing + front poses), and side (leg-only slicing + a scissor pose table).

**Files:**
- Modify: `client/tools/character_walk_baker.gd`

**Interfaces:**
- Consumes: `<name>.png`, `<name>_back.png`, `<name>_side.png` from Task 1 (in `client/assets/characters/`).
- Produces: `<name>_walk.png` (unchanged), `<name>_back_walk.png`, `<name>_side_walk.png` — each a 5-cell horizontal strip.

- [ ] **Step 1: Add the side tunables and the two slice configs**

In `client/tools/character_walk_baker.gd`, after the existing tunable constants (after line ~30, `PREVIEW_SCALE`), add:

```gdscript
# --- side-profile scissor tunables ---
const SIDE_STRIDE := 2  ## px a side-view leg swings fore/aft
const SIDE_BOB := 1     ## px the body rises on a passing frame

# Slice profiles. A config with arm rects of zero width skips arm-cutting, so
# the arms ride with the body (the side view has one arm and no arm-swing yet).
const FRONT_CFG := {
	leg_top = LEG_TOP, split_x = SPLIT_X, arm_l = ARM_L, arm_r = ARM_R,
}
const SIDE_CFG := {
	leg_top = LEG_TOP, split_x = SPLIT_X,
	arm_l = Rect2i(0, 0, 0, 0), arm_r = Rect2i(0, 0, 0, 0),
}
```

- [ ] **Step 2: Add the side pose table**

After `_poses()` (line ~60), add:

```gdscript
# Side scissor: legL is the BACK leg, legR the FRONT leg (split at SPLIT_X).
# They swing on X (fore/aft) instead of lifting; the body bobs on the pass
# frames. Idle (0) matches the rest cell so start/stop never pops.
func _side_poses() -> Array[Dictionary]:
	return [
		{body = Vector2i.ZERO, legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i.ZERO, legL = Vector2i(-SIDE_STRIDE, 0), legR = Vector2i(SIDE_STRIDE, 0),
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i(0, -SIDE_BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i.ZERO, legL = Vector2i(SIDE_STRIDE, 0), legR = Vector2i(-SIDE_STRIDE, 0),
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
		{body = Vector2i(0, -SIDE_BOB), legL = Vector2i.ZERO, legR = Vector2i.ZERO,
			armL = Vector2i.ZERO, armR = Vector2i.ZERO},
	]
```

- [ ] **Step 3: Parameterize `_build_frames` by config + poses**

Replace `_build_frames(src)` (lines ~81-111) with a version that takes `cfg` and `poses` and only cuts arms when the config asks for them:

```gdscript
## Build one Image per frame from a slice config + pose table. Every frame is
## the same padded cell size so the sheet is a clean horizontal strip.
func _build_frames(src: Image, cfg: Dictionary, poses: Array) -> Array:
	var w := src.get_width()
	var h := src.get_height()
	var leg_top: int = cfg.leg_top
	var split_x: int = cfg.split_x
	var arm_l: Rect2i = cfg.arm_l
	var arm_r: Rect2i = cfg.arm_r
	var cut_arms := arm_l.size.x > 0 and arm_r.size.x > 0
	var cell_w := w + 2 * PAD_X
	var cell_h := h + PAD_TOP
	var body_rect := Rect2i(0, 0, w, leg_top)
	var legL_rect := Rect2i(0, leg_top, split_x, h - leg_top)
	var legR_rect := Rect2i(split_x, leg_top, w - split_x, h - leg_top)
	var body := src.get_region(body_rect)
	var arm_L := Image.new()
	var arm_R := Image.new()
	if cut_arms:
		# Carry the arms as their own pieces so they swing; leave the shoulders.
		arm_L = src.get_region(arm_l)
		arm_R = src.get_region(arm_r)
		_erase(body, arm_l)
		_erase(body, arm_r)
	var out := []
	for p in poses:
		var cell := Image.create(cell_w, cell_h, false, Image.FORMAT_RGBA8)
		var origin := Vector2i(PAD_X, PAD_TOP)
		cell.blend_rect(body, Rect2i(Vector2i.ZERO, body_rect.size), origin + p.body)
		cell.blend_rect(src, legL_rect, origin + legL_rect.position + p.legL)
		cell.blend_rect(src, legR_rect, origin + legR_rect.position + p.legR)
		if cut_arms:
			cell.blend_rect(arm_L, Rect2i(Vector2i.ZERO, arm_l.size),
				origin + arm_l.position + p.body + p.armL)
			cell.blend_rect(arm_R, Rect2i(Vector2i.ZERO, arm_r.size),
				origin + arm_r.position + p.body + p.armR)
		out.append(cell)
	return out
```

- [ ] **Step 4: Bake all three views per character**

Replace `_initialize()` (lines ~63-76) with a version that bakes front/back/side via a shared helper:

```gdscript
func _initialize() -> void:
	var root := ProjectSettings.globalize_path("res://assets/characters")
	for name in CHARACTERS:
		_bake_view(root, name, "", FRONT_CFG, _poses())
		_bake_view(root, name, "_back", FRONT_CFG, _poses())
		_bake_view(root, name, "_side", SIDE_CFG, _side_poses())
	quit()


## Load <name><suffix>.png, bake it, and write <name><suffix>_walk.png (+ preview).
func _bake_view(root: String, name: String, suffix: String,
		cfg: Dictionary, poses: Array) -> void:
	var src := Image.load_from_file(root + "/" + name + suffix + ".png")
	if src == null:
		push_error("baker: missing " + name + suffix)
		return
	src.convert(Image.FORMAT_RGBA8)
	var frames := _build_frames(src, cfg, poses)
	_save_sheet(frames, root + "/" + name + suffix + "_walk.png")
	_save_preview(frames, root + "/" + name + suffix + "_sheet.png")
	print("baked %s%s: %d frames, cell %dx%d" % [
		name, suffix, frames.size(), frames[0].get_width(), frames[0].get_height()])
```

- [ ] **Step 5: Run the baker headless**

Run: `godot --headless --path client --script res://tools/character_walk_baker.gd`
Expected: prints `baked player: …`, `baked player_back: …`, `baked player_side: …` (and the three crew), no errors. `client/assets/characters/` now has `<name>_back_walk.png` and `<name>_side_walk.png`, each a 5-cell strip, plus `_sheet.png` previews.

- [ ] **Step 6: Human eyeball checkpoint (art)**

Verify the side preview strips read as a walking profile and the back strips read as a back. Preview paths:
`client/assets/characters/player_side_sheet.png` and `player_back_sheet.png`.
Throw the user these paths for a look. If the profile needs work, the knobs are: side sprite geometry in `characters.py` (`character_side_svg`), and `SIDE_STRIDE` / `SIDE_BOB` in the baker. Re-run Task 1 Step 6 then Task 2 Step 5 after any tweak.

- [ ] **Step 7: Commit**

```bash
git add client/tools/character_walk_baker.gd client/assets/characters/
git commit -m "feat(art): bake back + side walk sheets (#34)"
```

---

### Task 3: 4-way facing in the runtime

Replace the ±1 horizontal-mirror facing with a four-way facing chosen by dominant movement axis (with hysteresis), and select front/back/side sheets accordingly. Side mirrors for left. Falls back to the front sheet, then the static sprite, if a directional sheet is missing.

**Files:**
- Modify: `client/scripts/interior_view.gd`

**Interfaces:**
- Consumes: sheet textures `<name>_walk`, `<name>_back_walk`, `<name>_side_walk` via `_lib.character(name)` (Task 2 output; auto-loaded by `AssetLibrary`).
- Produces: no new public interface — behavior change inside `_draw_characters`.

- [ ] **Step 1: Add the facing enum, hysteresis constant, and update the state comment**

In `client/scripts/interior_view.gd`, near the other constants (after `FACE_EPS`, line ~78), add:

```gdscript
## Movement must beat the cross-axis by this factor to change facing, so a
## near-diagonal path holds its current facing instead of strobing sheets.
const HYST_RATIO := 1.3
enum Facing { DOWN, UP, LEFT, RIGHT }
```

Change the `_facing` declaration comment (line ~117) from:

```gdscript
var _facing: Dictionary = {}        # character id -> -1.0 | 1.0
```

to:

```gdscript
var _facing: Dictionary = {}        # character id -> Facing enum
```

- [ ] **Step 2: Add a pure facing-selection helper**

Add this static helper (place it just above `_draw_characters`, line ~590) so the axis/hysteresis rule is readable and unit-reasoned in isolation:

```gdscript
## Pick a facing from this frame's movement delta. Sub-threshold movement or a
## near-diagonal (neither axis clearly dominant) holds the previous facing.
static func _facing_from_delta(dx: float, dy: float, prev: int) -> int:
	if abs(dx) < FACE_EPS and abs(dy) < FACE_EPS:
		return prev
	if abs(dx) > HYST_RATIO * abs(dy):
		return Facing.RIGHT if dx > 0.0 else Facing.LEFT
	if abs(dy) > HYST_RATIO * abs(dx):
		return Facing.DOWN if dy > 0.0 else Facing.UP
	return prev
```

- [ ] **Step 3: Load the directional sheets and select by facing**

In `_draw_characters`, replace the block from `var walk := _lib.character(base_name + "_walk")` (line ~610) through the facing computation and the `if walk != null:` sheet-draw branch (down to line ~645), with:

```gdscript
			var walk := _lib.character(base_name + "_walk")
			var back_walk := _lib.character(base_name + "_back_walk")
			var side_walk := _lib.character(base_name + "_side_walk")
			if tex != null:
				# Facing + walk state from how far the body moved since last frame.
				var last: Vector2 = _last_pos.get(character.id, character.position())
				var prev_facing: int = _facing.get(character.id, Facing.DOWN)
				var facing := _facing_from_delta(
					character.x - last.x, character.y - last.y, prev_facing)
				var now := Time.get_ticks_msec()
				if character.position().distance_to(last) > MOVE_EPS:
					_walk_until[character.id] = now + MOVE_COAST_MS
				var walking: bool = not character.is_seated() \
					and now < int(_walk_until.get(character.id, 0))
				if character.is_seated():
					facing = Facing.DOWN          # seated at a console: face front
				_facing[character.id] = facing
				_last_pos[character.id] = character.position()
				# Choose the sheet for this facing; side art is drawn facing right,
				# so LEFT flips it. Missing directional sheets fall back to front.
				var sheet := walk
				var flip := 1.0
				match facing:
					Facing.UP:
						if back_walk != null:
							sheet = back_walk
					Facing.RIGHT:
						if side_walk != null:
							sheet = side_walk
					Facing.LEFT:
						if side_walk != null:
							sheet = side_walk
						flip = -1.0
				# feet at the collision circle's bottom edge; flip mirrors the
				# side view for left-facing (or the front fallback, as before).
				draw_set_transform(screen_pos + Vector2(0, radius_px),
					0.0, Vector2(flip, 1.0))
				if sheet != null:
					# Play the baked cycle: idle = cell 0, walking = cells 1.. by
					# wall-clock phase (offset per id so crew don't march in step).
					# The sheet is padded, so scale each cell to keep the body the
					# same on-screen size CHAR_SIZE gives the native art.
					var cell_w := sheet.get_width() / SHEET_CELLS
					var cell_h := sheet.get_height()
					var draw_w := CHAR_SIZE.x * float(cell_w) / float(tex.get_width())
					var draw_h := CHAR_SIZE.y * float(cell_h) / float(tex.get_height())
					var frame := 0
					if walking:
						frame = 1 + (int(now / WALK_FRAME_MS) + character.id) \
							% (SHEET_CELLS - 1)
					draw_texture_rect_region(sheet,
						Rect2(Vector2(-draw_w * 0.5, -draw_h), Vector2(draw_w, draw_h)),
						Rect2(frame * cell_w, 0, cell_w, cell_h))
```

Leave the existing `else:` static-fallback branch (line ~646), the `draw_set_transform(Vector2.ZERO, ...)` reset, and the label drawing untouched.

- [ ] **Step 4: Verify the project loads without parse errors**

Run: `godot --headless --path client --check-only --script res://scripts/interior_view.gd`
Expected: no parse/compile errors reported. (If `--check-only` is unavailable in this Godot build, Step 5's probe run is the compile gate.)

- [ ] **Step 5: Commit**

```bash
git add client/scripts/interior_view.gd
git commit -m "feat(interior): 4-way directional walk facing with hysteresis (#34)"
```

---

### Task 4: Extend the probe harness and verify in-engine

Drive the real `interior_view` render path with a character moving through all four directions, capture shots, and confirm the correct sheet is selected and mirrored — serverless, no devserver contention.

**Files:**
- Modify: `client/tools/interior_walk_probe.gd`

**Interfaces:**
- Consumes: the runtime from Task 3 and the sheets from Task 2.
- Produces: nothing shipped — a verification harness.

- [ ] **Step 1: Drive all four facings**

In `client/tools/interior_walk_probe.gd`, replace the `_process` movement lines (the two `sin`-based assignments) with a box path for the own character and a vertical pace for the crew, so every facing is exercised:

```gdscript
	_t += delta
	# Own character walks a box (right -> up -> left -> down) so all four
	# facings render; crew paces north/south to exercise front<->back.
	var leg := fmod(_t * 0.6, 4.0)
	if leg < 1.0:
		_own.x = 4.0 + 4.0 * leg;      _own.y = 4.0
	elif leg < 2.0:
		_own.x = 8.0;                  _own.y = 4.0 - 2.0 * (leg - 1.0)
	elif leg < 3.0:
		_own.x = 8.0 - 4.0 * (leg - 2.0); _own.y = 2.0
	else:
		_own.x = 4.0;                  _own.y = 2.0 + 2.0 * (leg - 3.0)
	_crew.x = 8.0
	_crew.y = 3.0 + 2.0 * sin(_t * 0.7)
	_view.set_frame_data(_cls, [_own, _crew] as Array[CharacterState], 1,
		_own.position(), "upper", [] as Array[InteriorView.Backdrop])
	_maybe_shot()
```

- [ ] **Step 2: Capture a shot in each facing**

Run four shots at times landing in different box legs (the DH_SHOT capture fires once `_t >= 0.9`; re-run with the phase offset via the box period, or capture manually). Simplest: run the probe windowed and watch, or capture one shot per leg by adjusting the guard. For an automated pass, run:

```bash
DH_SHOT="$SCRATCH/probe_side.png"  godot --path client res://tools/interior_walk_probe.gd
```

(substitute your scratchpad path). Expected: `[probe] shot saved` prints and the PNG shows the own character mid-stride facing its travel direction.

- [ ] **Step 3: Human eyeball checkpoint (in-engine)**

Confirm in the captured shot(s): walking right shows the profile facing right; walking left shows it mirrored; walking up shows the back; walking down shows the front; a stopped character keeps its last facing. Throw the user the shot path(s). Knobs if anything's off: `HYST_RATIO` (strobing/late turns) in `interior_view.gd`; side art/`SIDE_STRIDE` for the profile itself (loops back to Task 1/2).

- [ ] **Step 4: Run the art test suite once more as a regression gate**

Run: `python -m pytest tools/artspike -q`
Expected: all pass (the extended `test_characters_export` included).

- [ ] **Step 5: Commit**

```bash
git add client/tools/interior_walk_probe.gd
git commit -m "test(interior): probe all four walk facings (#34)"
```

---

## Self-Review

**Spec coverage:**
- Back view (front-minus-face) → Task 1 (`character_back_svg`), Task 2 (back sheet).
- Side profile facing right, mirrored for left → Task 1 (`character_side_svg`), Task 2 (side sheet + scissor poses), Task 3 (LEFT flip).
- Legs authored separable by vertical split → Task 1 Step 3 (split at x=11, boots kept within halves), Task 2 (`SIDE_CFG` split, `_side_poses` scissor).
- Uniform 5-cell sheets → Task 2 (all pose tables are 5 entries; `SHEET_CELLS` unchanged).
- Dominant-axis facing + hysteresis → Task 3 (`_facing_from_delta`, `HYST_RATIO`).
- Idle keeps last facing; seated → front → Task 3 Step 3.
- Fallback chain directional → front → static → Task 3 Step 3 (`match` guards) + untouched `else` branch.
- No `AssetLibrary` change needed → confirmed; sheets auto-load by filename.
- Serverless verification → Task 4 (probe), Task 1/4 (pytest).

**Placeholder scan:** No TBD/TODO; every code step has complete code. Side-profile pixel values are concrete and runnable; tuning is an explicit checkpoint (Task 2 Step 6, Task 4 Step 3), not a gap.

**Type consistency:** `Facing` enum used consistently (`_facing_from_delta` returns int, stored/read as `Facing.*`). `_build_frames(src, cfg, poses)` signature matches all three call sites in `_bake_view`. `cfg` dict keys (`leg_top`, `split_x`, `arm_l`, `arm_r`) match between `FRONT_CFG`/`SIDE_CFG` and `_build_frames`. Sheet names (`_back_walk`, `_side_walk`) match between baker outputs and runtime `_lib.character(...)` reads.
