# Decorated interiors — pass 1 (issues #28, #29)

_Design doc, 2026-07-19._

## Goal

Let ship and station interiors be **decorated and coloured**, not just laid out
functionally. This is the first, focused pass: the enabling data pipeline plus
the simple single-sprite tiles that exercise it end-to-end. The neighbour-aware
and rule-bearing tiles (fountain merge, flowerbed→trees, hydroponic garden,
up/down hatchway art, wall-mounted bunk beds) are **out of scope — deferred to
#36**.

Two tickets, one feature:

- **#28 (pass 1)** — aesthetic tiles: rug, seat, bed (floor); window (wall);
  plus the cargo pallet. Screen is the existing `v` viewscreen.
- **#29** — per-tile colour: NE-corner hex digit `0`–`f` → a 16-colour palette,
  applied as a tint over greyscale base sprites.

## Vocabulary (LANDED — additive, fallback-safe)

Already in `server/glyphs.json` + mirrored in `glyphs.default()` (kept in sync by
`glyphs_test`), so authors can build against it immediately. Unknown glyphs still
fall back to walkable floor, so nothing typed is ever a parse error. These do not
yet render distinctly — that is the work below; today they draw as plain
floor/wall.

Center glyphs (all `floor` kind — walkability unchanged):

| glyph | id | sprite | colour? |
|---|---|---|---|
| `r` | rug | `rug` | yes |
| `e` | seat | `seat` | yes |
| `d` | bed | `bed` | yes |
| `p` | cargo_pallet | `cargo_pallet` | no |

Edge glyph (wall fixture — blocks like a wall, carries art):

| glyph | id | sprite |
|---|---|---|
| `w` | window | `window` |

`v` (viewscreen) is unchanged and now serves as the single wall-screen glyph
(bridge viewscreen or a domestic TV — no separate `t`).

`server/colors.json` (LANDED): a 16-entry palette, array index = the NE-corner
digit (`0`–`9`, then `a`–`f`), in Minecraft dye order (white→black). Sprites are
greyscale and multiplied by the slot colour, so any hex can be retuned without
re-authoring maps.

## Architecture — the one grid of cells

### The problem

The server does not forward authored rows; it **reconstructs** them with
`deck_to_rows` before sending, and that reconstruction only knows `.`/` `/`x`
centres and regenerates corners from edges. So an aesthetic centre glyph
collapses to plain floor and an NE-corner colour digit is discarded before the
client ever sees it. Both wire paths (flying ship via `shipclass.encode`, docked
composite via `encode_space`) go through it.

### The change

Carry decoration + colour **per cell**, in one data structure, rather than as
extra grids stitched by index. `composite.gleam` already works in cell units
internally (`Cell = #(Tile, edges)`, rotated/composed then split back into
parallel `tiles`/`edges` by `grid_from_cells`), so this direction removes friction
rather than adding it.

**Server (`deckplan.gleam`)** — replace `DeckGrid`'s parallel `tiles` +
`edges` lists with one grid of a record:

```gleam
pub type Cell {
  Cell(
    tile: Tile,                       // Void | Floor | Stairs — walkability, unchanged
    edges: #(Edge, Edge, Edge, Edge), // n, e, s, w — unchanged
    decor: Option(String),            // centre decoration glyph, None = bare floor
    color: Option(Int),               // 0-15 from the NE corner, None = uncoloured
  )
}
```

- `tile_at` / `edges_at` / `edge_in` / `is_walkable` become accessors over
  `cells` — same logic, same results, only field access moves. Collision and
  stairs code is untouched in behaviour.
- `parse_deck_with` fills `decor` from the centre glyph (any glyph whose spec is
  `Floor`-kind, is not a console/dock/spawn/stairs, and carries a sprite → its
  glyph char) and `color` from the NE corner (hex `0`–`f` → 0-15, else `None`).
- `deck_to_rows` re-emits `decor` at the centre and `color` at the NE corner, so
  the round-trip is lossless (corners for non-coloured tiles keep today's
  `#`/blank hull weld). `composite` carries `decor`/`color` through rotation and
  mooring for free because they ride on the `Cell`.

**Client (`ship_class_data.gd`)** — mirror it: the `Deck` inner class stores one
`cells` array of a `Cell` (tile, edges, decor, color); `tile_at`/`edge_in`/etc.
read from it. Because the client already re-parses the raw rows, **no new wire
fields are needed** — it reads the centre decor glyph and the NE-corner colour
straight from the grid it already receives.

**Palette on the wire** — the server loads `colors.json` at startup (built-in
default fallback, mirroring `glyphs`) and forwards it on the `welcome` message
next to `glyphs`. The server ignores the hex values (transport only). The client
parses it once at welcome into a 16-entry colour table.

## Colour rendering

- Authoring: NE corner of a tile's 3×3 block = one hex digit `0`–`f`. Blank,
  `#`, or any non-hex char = uncoloured.
- Tint model: base sprites are greyscale (carrying their own shading); render =
  `MODULATE` (multiply) by `palette[slot]`. One base sprite → all 16 colours,
  shading preserved.
- Uncoloured: drawn untinted (greyscale as authored) in pass 1. Per-glyph
  default colours can come later.
- Which tiles honour colour: rug, seat, bed. Window and pallet ignore it.

## Tile rendering (`interior_view.gd`)

- New decor pass: for each visible floor tile whose cell has a `decor` glyph,
  look up its sprite id via the glyph registry (the path consoles already use)
  and draw it, multiplied by the cell's palette colour.
- Edge fixtures (`w` window, `v` viewscreen): draw the fixture's sprite on the
  wall strip instead of a plain plate.
- Graceful degradation: a missing sprite falls back to today's look (plain
  floor / plain wall), so the render pass ships before the decor **art** exists.
  Decor sprite art is a separate task and is not on this pass's critical path.

## Cargo pallet → derived breakbulk capacity

A hull's **breakbulk** capacity becomes the count of `p` cargo-pallet tiles
across its decks — the same "map is the single source of truth" derivation used
for consoles and berths, rather than a hand-authored number.

- `shipclass.gleam`: when pallet tiles are present, `cargo.capacity` is derived
  from their count; the authored `capacity` remains a fallback for hulls with no
  pallet tiles (back-compat). `handling` stays authored.
- Pallet tiles are walkable floor in pass 1; the pallet also renders via the
  decor pass (its sprite). Door-size-to-load is **not** enforced (explicitly out
  of scope).

## Non-goals (deferred to #36)

Fountain merge, flowerbed→trees, hydroponic garden, up/down hatchway art, and the
wall-mounted bunk-bed placement rule — each adds a distinct new mechanic
(deterministic neighbour rendering, placement constraints) and gets its own
reviewed change.

## Testing

- **Parity**: server `deckplan` and client `ship_class_data` parse the same rows
  to the same cells; existing collision/prediction tests must stay green
  (walkability logic is unchanged).
- **Lossless round-trip**: `parse_deck` → `deck_to_rows` → `parse_deck`
  preserves decor + colour (new `deckplan_test` cases), alongside the existing
  centre/edge round-trip.
- **Colour parse**: NE hex `0`–`f` → 0-15; blank / `#` / junk → `None`.
- **Capacity derivation**: a deck with N pallet tiles yields capacity N; a hull
  with none falls back to the authored value.
- **`glyphs_test`**: `default()` stays equal to `glyphs.json` (already green).
- Composite: decor/colour survive rotation + mooring into the composite frame.

## Open confirmations (author to veto)

1. Pallet is **walkable** floor (vs. a blocking obstacle) for pass 1.
2. Breakbulk `capacity` is **derived** from pallet count (vs. staying a
   hand-authored number).
