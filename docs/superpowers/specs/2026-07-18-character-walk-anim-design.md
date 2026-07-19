# Character walk animation (ticket #21)

**Status:** approved (design discussed live 2026-07-18).
**Branch/worktree:** `feat/character-walk-anim` in `../DH-walkanim` (isolated from the
active `feat/deckplan-v3` session; standalone scene so we never contend for the devserver).

## Problem

Characters don't animate while walking on foot. Attempt 1 wobbled the single static
sprite in place — "insane-looking." Ticket #21 is explicit: this **requires animation
frames**, not an in-place transform.

We have exactly one static, front-facing 22×34 pixel sprite per character
(`player.png`, `crew_0..2.png`). Not directional — always front-facing, flipped
horizontally for left/right movement. Rendered in immediate mode in
`interior_view.gd::_draw_characters` via `draw_texture_rect`. Assets load at runtime
(`Image.load_from_file`; tree is `.gdignore`'d, no import pass).

## Approach: procedural cutout → baked frames

Slice the existing art into pieces and drive a real walk cycle, then bake it to a
sprite-sheet PNG. No hand-drawn pixel art; reuses the art we have; produces genuine
"animation frames" that the ticket asks for.

### Slice map (verified against pixels)

```
rows 0–23   body   (head + torso + arms)          full width
rows 24–33  legs   split at centerline:
              leg_L = x <= 10
              leg_R = x >= 11
```

The legs are one solid dark block with no pre-drawn gap; splitting down the centerline
and moving each half independently reads as stepping. Seam sits under the torso, so it
never tears. Same map works for all four sprites (shared silhouette).

### Walk cycle — 4 frames, front view

Small moves (±1–2px is large at this scale):

- **F0 step-A:** left leg planted, right leg lifted (up ~2px, tucked inward ~1px), body dy 0
- **F1 pass:**   both legs neutral, body bob up 1px
- **F2 step-B:** mirror of F0
- **F3 pass:**   both legs neutral, body bob up 1px
- **idle:**      neutral rest pose (≈ the original sprite)

Exact offsets (lift / tuck / bob / pad) are tuned live against a contact sheet, not
guessed once. All params live at the top of the baker script.

### Bake

Pure `Image` compositing (headless, no viewport) → per-character horizontal
sprite-sheet PNG (`player_walk.png`, `crew_N_walk.png`) into `assets/characters`, plus
an upscaled contact sheet for eyeballing. Deterministic; no rig at runtime.

## Components

1. **`character_walk_baker.gd`** — headless SceneTree script: load PNG, slice,
   composite N frames, save spritesheet + contact sheet. The tuning harness and the
   asset generator, one file.
2. **`character_anim_lab.tscn` + `.gd`** — standalone scene, `AnimatedSprite2D`
   playing the baked cycle at game scale on a plain background; user-runnable without
   the devserver. The interactive deliverable.
3. **`interior_view.gd` integration** — minimal: generalize the existing
   `_last_char_x` facing tracking to "moved this frame?", pick walk vs. idle, swap
   `draw_texture_rect` → `draw_texture_rect_region` selecting the current frame's
   sub-rect by walk phase (phase from accumulated time). Crew animate for free.
   **Fallback:** if a `_walk` sheet is missing, keep the current single-frame draw.

## Verification

Iterate on the contact sheet headless until the cycle reads as walking. Then run the
standalone lab scene and screenshot the live loop. Only after it looks right does the
integration touch `interior_view.gd`. No devserver contention at any point.

## Out of scope

- Directional (4/8-way) sprites — figure stays front-facing.
- Run cycle, turn animations, per-crew unique gaits.
- Hand-authored pixel art (approach B, rejected).
```