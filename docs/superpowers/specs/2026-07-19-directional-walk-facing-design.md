# 4-axis directional walk facing (#34)

**Date:** 2026-07-19
**Issue:** #34 — Walk animation: add left/right/up facing directions (only front-on looks right)
**Follow-up to:** #21 / PR #25 (front-on walk cycle)

## Problem

Characters have a single front-facing (south) 22×34 sprite. The walk cycle from
#21 bakes a front-view gait by slicing that one sprite. The runtime's only sense
of direction is a **horizontal mirror** (`Vector2(facing, 1.0)` in
`interior_view.gd`), so a character walking left/right still stares at the camera
while sliding sideways, and walking up (away) looks identical to walking down.

A flipped front sprite is still a front sprite — that is exactly the "goofy"
sideways look the issue reports. Fixing it needs genuinely new viewpoints (side
profile, back view), not more slicing of the front art.

## Scope

- **In:** 4-axis facing — down (front, existing), up (back), left/right (side,
  mirrored). Applies to the player and all three crew variants.
- **Out (deferred):** full 8-axis / diagonal-specific art. Diagonals resolve to
  the nearest of the four via dominant-axis selection. If 4-axis proves
  insufficient in playtest, 8-axis is a later ticket.

## Why this is tractable

The base sprites are **procedurally drawn**, not hand-pixeled:
`tools/artspike/characters.py` composes each character from a tiny vocabulary of
rounded rects and circles (`rrect`, `circle`) — ~10 primitives: two thigh rects,
two boot rects, two arm rects, a torso rect + chest-badge highlight, and a head
of a hair circle behind a skin/face circle (face-on-top = looking at camera).

New views are new parametric functions in the same style, not new art files to
draw by hand.

## Design

### 1. Art — `tools/artspike/characters.py`

Two new view functions, exported per character alongside the untouched front
`<name>.png`:

- **`character_back_svg`** → `<name>_back.png`. The front silhouette **minus the
  face**: draw only the hair cap (no skin/face circle) and drop the chest-badge
  highlight. Legs / arms / torso identical to front. Same 22×34 cell.
- **`character_side_svg`** → `<name>_side.png`. A true profile facing **right**
  (the runtime mirrors it for left): narrower torso, a single near-side arm, a
  thin hair-cap head with the face nub on the right edge, and the two legs
  authored at **slightly different x** so a vertical split still separates
  near-leg from far-leg (needed by the baker, §2). Same 22×34 cell.

The contact sheet in `main()` grows to show all three views × four characters so
the profile can be eyeballed at 1× and 3×.

### 2. Baker — `tools/character_walk_baker.gd`

Produces three sheets per character, all **5 cells** (idle + 4-frame cycle) so
runtime cell indexing stays uniform (`SHEET_CELLS = 5`):

- **Front** `<name>_walk.png` — unchanged (existing slicing + pose table).
- **Back** `<name>_back_walk.png` — reuses the front slicing constants and pose
  table verbatim (identical topology: legs lift/tuck, arms swing contralateral);
  only the source image changes to `<name>_back.png`.
- **Side** `<name>_side_walk.png` — its **own** slice constants (near-leg /
  far-leg by vertical split, single arm region) and a **scissor pose table**:
  legs swing fore/aft on x (front leg forward while back leg trails, then pass,
  then reverse), the near-arm swings opposite-phase, plus a subtle body bob. This
  is the natural side gait and reads better than the front's lift-and-tuck.

Baker structure (slice regions → per-pose part offsets → composite → sheet +
preview) is unchanged; this adds a second slice/pose profile and two extra output
passes. Tunables stay as top-of-file constants.

### 3. Runtime — `interior_view.gd` `_draw_characters`

Replace the ±1 horizontal `_facing` scalar with a **4-way facing** (down / up /
left / right):

- **Selection:** from the per-frame movement delta's **dominant axis**
  (`|dx|` vs `|dy|`), gated by `FACE_EPS` so sub-pixel jitter never turns the
  body.
- **Hysteresis:** only switch facing when the new dominant component clearly
  beats the other axis (`dominant > HYST_RATIO * other`, `HYST_RATIO` a new
  top-of-file constant); otherwise hold the previous facing. Prevents diagonal
  movement from strobing between two sheets.
- **Sheet map:** down → `_walk`, up → `_back_walk`, left/right → `_side_walk`
  with a horizontal flip for left (reuse the existing `draw_set_transform` flip).
  Front and back are not flipped.
- **Idle:** cell 0 of the sheet matching the last facing, so a stopped character
  keeps facing where they were headed. Seated → front (`_walk`) idle.
- Coast logic (`MOVE_COAST_MS`) and per-id phase offset are unchanged.
- **Fallback chain** if a directional sheet is missing: directional → front
  `_walk` → static `<name>.png`. Keeps the render path safe if art regeneration
  lags.

No `AssetLibrary` change: it auto-loads every PNG in `assets/characters/` keyed
by filename, so the new sheets are available via `character("<name>_back_walk")`
etc. with no loader edits.

### 4. Testing / verification

All serverless, run in this isolated worktree — zero devserver contention.

- **Art:** extend `tools/artspike/test_composer.py` to assert each new view
  exports at 22×34, is non-empty (has opaque pixels), and differs from the front
  view (so a silent no-op regression is caught).
- **Baker:** run headless
  (`godot --headless --path client --script res://tools/character_walk_baker.gd`),
  eyeball `sheet_characters.png` and the per-sheet `_sheet.png` previews. Queue
  the contact sheet for human review (path/link) — non-blocking per review
  cadence.
- **Runtime:** extend `tools/interior_walk_probe.tscn` / its script to drive one
  character N/S/E/W and confirm sheet selection, mirroring, and the idle-facing
  hold render correctly through the real `interior_view` path.

## Risks

- **Side profile legibility at 22px** is the one real craft-risk. Mitigated by
  iterating the profile on the contact sheet *before* wiring runtime, with a
  human eyeball check at the first decent pass.
- **4-axis insufficiency:** if flipping between side and front on near-diagonal
  paths still reads oddly despite hysteresis, 8-axis art is the escalation — a
  separate ticket, not this one.

## Out of scope

- 8-axis / diagonal-specific sprites.
- Hand-drawn (non-procedural) character art.
- Any change to movement, networking, or collision — this is render-only.
