# Decorated interiors — pass 2 (issue #36)

_Design doc, 2026-07-19._

## Goal

Pass 1 (#28/#29, merged) built the enabling pipeline: per-`Cell` `decor` +
`color` flowing author → server → wire → client, plus the simple single-sprite
tiles (rug, seat, bed, pallet, window) and the 16-colour multiply-tint palette.

Pass 2 adds the tiles that each layer a **distinct new mechanic** on top of that
pipeline, plus first-crack sprite art so the whole thing is finally _visible_:

- **Neighbour-aware floor tiles** whose render reads their neighbours —
  deterministically (fountain, flowerbed, table, hydroponic garden).
- **Stair/hatchway art** derived from the vertically-adjacent deck.
- **A rule-bearing wall tile** (wall-mounted bunk) — the first placement whose
  legality depends on what is under/beside it.
- **Wall-mounted consoles** — consoles attach to a wall over a seat instead of
  being a floor tile.
- **Sprites in general** — first cracks at greyscale art for pass-1 and pass-2
  tiles, iterated on the render probe.

### Review model

The issue frames these as separate reviewed changes. Per the author's
preference, they are built as **internal slices (A–E below) but batched into a
single branch and one review** — one review per iteration, not five. This spec
is the cohesive whole; the slices are build order.

### What this pass does NOT change

Walkability, collision, prediction, docking, and the wire schema stay as pass 1
left them. Every new floor glyph is walkable `floor`-kind; every new wall glyph
blocks exactly like a wall. All rendering additions degrade gracefully to the
current look when art is missing (the pass-1 rule). No new wire fields except
the one `console`-on-edge registry field in slice C, which rides the existing
`welcome` glyph registry.

---

## Shared foundations

### F1 · Additive glyph vocabulary

All new glyphs are **additive and fallback-safe**: an unknown glyph is still
walkable floor (centre) or a generic wall-fixture (edge), so nothing typed is a
parse error, and old maps keep working. New entries go in `server/glyphs.json`,
are mirrored in `glyphs.default()` (kept byte-identical by `glyphs_test`), and
reach the client on the `welcome` message it already parses.

Glyph letters are the tunable lever — the author may veto any of these; they are
one-line edits in `glyphs.json` with no code impact.

New **centre** glyphs (all `floor` kind — walkable, honour NE-corner colour):

| glyph | id | sprite | slice |
|---|---|---|---|
| `f` | fountain | `fountain` | B |
| `l` | flowerbed | `flowerbed` | B |
| `g` | hydroponic garden | `hydroponic` | B |
| `t` | table | `table` | B |

New **edge** glyphs (block like a wall, carry art via the fixture path). Console
letters reuse their centre mnemonic on the edge — position disambiguates, exactly
as the glyph schema already documents:

| glyph | id | kind | console | slice |
|---|---|---|---|---|
| `h` | helm_console (wall) | fixture | helm | C |
| `c` | cargo_console (wall) | fixture | cargo | C |
| `b` | broker_console (wall) | fixture | broker | C |
| `d` | bunk (wall bed) | fixture | — | D |

In slice C the console glyphs `h`/`c`/`b` **move from centres to edges** (and are
removed from `centers`). `d` on a centre stays a floor bed; `d` on an edge is a
wall bunk — the same centre/edge overload the schema already sanctions.

### F2 · Determinism contract (neighbour-aware rendering)

Neighbour-aware tiles read their neighbours to choose a sprite, but the result
**must be identical every time the same map loads** — fountains, flowerbeds and
trees must not reshuffle on relog. Rules:

- Any per-tile variation (which plant, tree-or-not, decorative jitter) is a pure
  function of a **hash of stable inputs only**: `(deck identity, x, y)`. Never
  `Time`, `randi()`, `RandomNumberGenerator`, load order, or iteration order.
- The hash is one small pure helper, `interior_hash(deck_id, x, y) -> int`
  (client GDScript), implemented as an explicit integer mix (FNV-1a-style) so it
  is provably load-order-independent and unit-testable, rather than relying on
  engine `hash()` semantics.
- "Deck identity" is the deck's stable name/index within the plan; it varies the
  pattern between decks so two identical layouts don't look cloned, without
  introducing run-to-run variation.

This contract is the acceptance test for slice B: parse → render twice → byte
scenes identical; and `interior_hash` has direct unit tests.

### F3 · Sprite / art workflow

Sprites are individual greyscale PNGs in `client/assets/interior/`, auto-loaded
by `AssetLibrary` and keyed by the registry `sprite` id. Dropping a correctly
named PNG makes a tile render with **zero code change**; a missing one falls back
to today's placeholder. Art is authored greyscale and multiplied by the tile's
palette colour at draw time (the pass-1 tint model — no shader, just
`draw_texture_rect`'s modulate arg).

The iteration loop is the render probe
(`client/tools/interior_render_probe.gd`): author a tiny decorated deck inline in
`_ready()`, run windowed with `DH_SHOT=<path>` to capture a PNG, look, tweak.
First cracks are mine; final art is the author's to retune by replacing PNGs.

---

## Slice A · Hatchway up/down art

**Problem.** A `stairs` (`x`) tile renders as plain floor. It should read as an
up-hatchway vs a down-hatchway.

**Approach — pure client render.** `ShipClassData.stairs_target(deck, x, y)` is
already available client-side (mirrors the server, void-skipping scan included).
Direction is `target vs view_deck`: `target > view_deck` ⇒ leads **down**,
`target < view_deck` ⇒ leads **up**. A stair can connect both ways
(down wins the tie in `stairs_target`); to show both, also probe the opposite
direction with the same void-skip rule and pick a combined sprite when both
connect.

Add a `_draw_stairs(origin)` pass in `interior_view.gd`, inserted between
`_draw_floor` and `_draw_structure`, that for each visible `STAIRS` tile picks
one of `stairs_up` / `stairs_down` / `stairs_updown` and draws it (honouring the
tile colour, like decor). Register those sprite ids on the `stairs` centre entry;
graceful fallback to plain floor when art is absent.

Server: unchanged. (No new wire data — the client already has every deck.)

---

## Slice B · Neighbour-aware decor

The flagship. A small shared client module plus four tiles that use it.

### B0 · The neighbour module (`interior_neighbors.gd` or helpers on the view)

Two pure primitives, both client-side, both deterministic:

- `neighbor_mask(deck, x, y, glyph) -> int` — a 4-bit N/E/S/W bitmask of which
  orthogonal neighbours carry the **same** decor glyph. This drives merge /
  autotiling: a run of same-type tiles renders as one shape by selecting an
  edge/centre/corner sprite piece from the mask.
- `interior_hash(deck_id, x, y) -> int` (F2) — deterministic per-tile variation.

Optionally an 8-bit mask (incl. diagonals) if corner pieces need it; start with 4
and extend only if a tile demands it (YAGNI).

### B1 · Fountain (`f`) — merge

Adjacent fountain tiles render as **one larger fountain**. `neighbor_mask` picks
the sprite piece (isolated basin / edge / interior / corner) so a 2×2 of `f`
reads as a single pool rather than four basins. Deterministic; no thresholds.
Proof tile for the module.

### B2 · Flowerbed (`l`) — plants, trees when combined

Renders aesthetic plants; **renders trees when enough tiles are combined**. A
flowerbed cell that is "interior" to a large bed (≥ `TREE_NEIGHBORS` same-type
orthogonal neighbours, default 3) becomes a candidate tree; whether it actually
shows a tree, and which plant/tree variant otherwise, is chosen from
`interior_hash` so it is scattered but stable. `TREE_NEIGHBORS` and the tree
density are named constants (levers).

### B3 · Table (`t`) — merge + seat rotation

Adjacent tables merge like fountains (`neighbor_mask`). Additionally, a **seat
(`e`) orthogonally adjacent to a table renders rotated to face the table** — the
seat's draw picks a facing from the direction of the neighbouring `t`. This is
the one cross-glyph interaction (seat reads table neighbour); still deterministic
(if a seat borders two tables, pick by a fixed dir priority, e.g. N,E,S,W).
Requires the seat sprite to have (or be rotatable into) a facing — handled by
rotating the greyscale sprite at draw.

### B4 · Hydroponic garden (`g`) — aesthetic + hook

Renders like a planted bed (may reuse the flowerbed machinery with its own
sprites). **Aesthetic only** this pass; leave an explicit hook for fresh-food
production later: a documented `// TODO(#food)` seam and, if cheap, a
registry-level marker so a future system can find hydroponic tiles without a
render change. No mechanic, no wire, no capacity today.

**Server for all of B:** none. The four glyphs are registry entries with sprites;
`is_decor` already routes them onto the `Cell` and through `deck_to_rows`. All
merge/variation logic is client render only — the server stays authoritative on
walkability (all four are plain floor).

---

## Slice C · Wall-mounted consoles

**Goal.** Consoles attach to a wall over a seat, rather than being a floor tile.
Not all consoles need a seat (brokers stand).

**Model.** Console glyphs become **edge fixtures**. `EdgeSpec` gains an optional
`console: Option(String)` (schema `edge.console`, mirroring `center.console`).
An edge fixture whose spec carries a console kind:

1. **Renders on the wall** via the existing fixture path (`_fixture_tex` /
   `_draw_edge_wall`) — the console sprite (`console_helm`, …) draws on the wall
   strip, exactly like a window. No new client render path.
2. **Derives a `Console` interaction record** at the floor tile it faces. Server
   derivation (`derive_markers` / `scan_markers`) additionally scans each tile's
   four edges; a console-bearing fixture on a floor tile emits
   `Console(kind, deck, x, y)` at that floor tile. The derived record keeps its
   current shape and namespaced id, so `find_console_of_kind`, helm binding
   (`shipclass`, `sim`), and broker lookup (`world`) are **unchanged**.

The wall the console mounts on is the fixture edge; the operating tile is the
walkable floor cell that owns that edge. A seat (`e`) authored on that floor tile
is the "seat over which the console mounts"; a seatless broker is just the
fixture with no `e`.

**Client.** `_draw_consoles` stops centre-drawing the wall-mounted kinds
(helm/cargo/broker) — their art now comes from the wall fixture — but keeps
drawing `dock` (the `Q` airlock pictogram, still a centre tile) and keeps the
interaction/binding untouched. `GlyphRegistry` edge ingestion learns the edge
`console` field so `sprite_for_console`/derivation resolve.

**`Q` docking port stays a centre floor tile** — it is a genuine boarding/airlock
tile you stand on, not a wall desk. Only helm/cargo/broker move.

**Migration.** Re-author existing maps (`mockingbird.json`, station classes) to
mount `h`/`c`/`b` on the appropriate wall edge with a seat on the operating
floor tile, replacing the old centre glyph. This is the invasive part and is
verified by: existing helm/cargo/broker still derive to the same floor tiles;
sim/dock tests stay green.

---

## Slice D · Wall-mounted bunk (rule-bearing tile)

A wall-mounted bunk is an **edge fixture** `d` (wall bunk), distinct from centre
`d` (floor bed). It renders a bunk on the wall strip (fixture path) and blocks
like a wall.

**The rule.** A bunk may only mount over a **floor bed (`d` centre)** or **another
wall bunk** (to stack bunks). In this pass the rule is an **authoring
convention**, documented in `deckplan-format.md`; there is no builder yet.
Enforcement — rejecting an illegally placed bunk — is #24, and this glyph is the
forcing function for how #24 validates placement-constrained tiles. Rendering is
deterministic (stacked bunks read as a stack via a small vertical `neighbor_mask`
on the bunk edge / underlying bed).

Server: parses `d`-edge as a fixture (already the fallback behaviour); the only
addition is the registry entry + doc. No walkability change (fixture blocks).

---

## Slice E · First-crack sprites

Take first cracks at greyscale 64px PNGs (14px wall strip for fixtures), dropped
into `client/assets/interior/`, for the tiles that currently fall back:

- Pass-1 leftovers: `rug`, `seat`, `bed`, `cargo_pallet`, `window`, `viewscreen`.
- Pass-2: `fountain` (+ merge pieces), `flowerbed` / plant / `tree`,
  `hydroponic`, `table` (+ merge pieces), `stairs_up` / `stairs_down` /
  `stairs_updown`, wall-console art if the existing `console_*` needs a wall
  variant, `bunk`.

Merge tiles that need multiple pieces (fountain, table) key their pieces off the
`neighbor_mask` value — either separate sprite ids (`fountain_edge_n`, …) or one
sheet sliced by the module; separate ids are simpler and fit the one-PNG-per-id
convention, so prefer that.

These are **first cracks generated procedurally** (a small greyscale-PNG
generator script, committed under `tools/`), deliberately crude, so every
mechanic is visible on the probe. Final art is the author's lever: replace any
PNG in place. I hand over the probe + the sprite-id list and let the author
retune, matching the established visual-tuning workflow.

---

## Cross-cutting

### Wire / back-compat
- Only new registry field: `edge.console` (slice C), forwarded on `welcome` with
  the rest of the registry; older behaviour when absent.
- Derived `consoles` wire array keeps its shape and ids; the composite
  (`composite.gleam`) carries decor/edges through rotation as it already does, so
  new decor and wall consoles survive docking for free.
- `glyphs.default()` stays byte-identical to `glyphs.json` (`glyphs_test`).

### Testing
- **Determinism (B):** `interior_hash` unit tests; render-twice parity for a
  decorated deck. Merge masks: unit-test `neighbor_mask` on hand-built grids.
- **Hatchway (A):** direction derivation from `stairs_target` on up/down/both
  fixtures (client-side test or probe-verified).
- **Console migration (C):** `deckplan_test` — a map with wall-mounted `h`/`c`/`b`
  derives the same `Console` kinds/floor tiles as the old centre form;
  round-trip (`parse` → `deck_to_rows` → `parse`) preserves edge consoles;
  sim/dock tests stay green.
- **Glyph sync:** `glyphs_test` stays green after every registry edit.
- **Bunk (D):** parses as a blocking fixture; convention documented (no
  enforcement test — that's #24).
- **Visible check:** probe screenshots per mechanic (the "in a way I can see"
  requirement), plus a full-hull capture of the migrated Mockingbird.

### Non-goals (explicitly out)
- Builder enforcement of the bunk rule (→ #24).
- Fresh-food production from hydroponics (hook only).
- Door-size-to-load, or any pallet/cargo change (pass-1 territory).
- Any walkability/collision/pathing change.

---

## Build order (internal slices → one batched review)

1. **E-scaffold** — the greyscale-PNG generator + placeholder art for pass-1
   leftovers, so the probe shows _something_ real immediately.
2. **A · Hatchway art** — smallest, self-contained; establishes the
   render-from-neighbour-deck pattern.
3. **B · Neighbour-aware decor** — the module (B0) then fountain (B1, proof),
   flowerbed (B2), table (B3), hydroponic (B4).
4. **C · Wall-mounted consoles** — the invasive model change + map migration.
5. **D · Bunk rule tile** — the rule-bearing edge glyph + doc.
6. **E-final** — first-crack sprites for every pass-2 tile; probe captures.

Each slice keeps tests green and the app runnable; they land on one branch and
go to review together once the whole iteration is coherent.
