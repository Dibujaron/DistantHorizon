# Decorated Interiors — Pass 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry per-tile decoration + colour from author → server → wire → client so interiors render decorated (rug/seat/bed/window, tinted from a 16-colour palette) and cargo pallets derive breakbulk capacity.

**Architecture:** Replace the server `DeckGrid`'s parallel `tiles`/`edges` lists with a single grid of a `Cell` record that also carries `decor` (centre decoration glyph) and `color` (NE-corner 0–15). The wire re-serialiser (`deck_to_rows`) round-trips both losslessly; the client (which already re-parses raw rows) mirrors the `Cell` and renders a decor pass with a greyscale-multiply tint. The palette rides the `welcome` message like the glyph registry.

**Tech Stack:** Gleam (server, `gleam test`), GDScript/Godot 4 (client), Python pytest harness (`harness/`).

## Global Constraints

- Deck-plan format v3 (`docs/deckplan-format.md`): every tile is a 3×3 char block; centre = tile identity, four edge-mids = edges, four corners cosmetic. The **NE corner** (block-local row 0, col 2) now encodes colour.
- Walkability/collision behaviour MUST stay byte-identical (client prediction mirrors server). The refactor changes field access only, never collision logic.
- Glyph vocabulary is DATA: `server/glyphs.json` mirrored by `glyphs.default()`, kept equal by `glyphs_test`. Already landed: centres `r`/`e`/`d`/`p`, edge `w`; `server/colors.json` holds the 16-colour palette (index = digit `0`–`f`, Minecraft dye order).
- Colour model: base sprites greyscale, rendered `MODULATE`-multiplied by the slot colour. Uncoloured (blank/`#`/non-hex NE corner) = untinted.
- Server ignores palette hex values (transport only), exactly as it ignores `sprite`.
- `gleam format src test` must pass (CI checks `--check`). Commit after every green task.
- Shared working tree: another instance edits `client/assets/characters/*` — do NOT touch character art; do NOT switch git branches without asking the user.

---

### Task 1: Server — `DeckGrid` → grid of `Cell` (behaviour-preserving refactor)

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam`
- Modify: `server/src/dh_server/composite.gleam`
- Test: `server/test/deckplan_test.gleam`, `server/test/composite_test.gleam` (existing — must stay green)

**Interfaces:**
- Produces: `pub type Cell { Cell(tile: Tile, edges: #(Edge, Edge, Edge, Edge), decor: Option(String), color: Option(Int)) }`; `DeckGrid(..., cells: List(List(Cell)))` replacing `tiles` + `edges`. Accessors `tile_at`, `edges_at`, `edge_in`, `is_walkable`, `edge_blocks` keep their current signatures and behaviour.
- Consumes: `glyphs.Registry` (unchanged).

- [ ] **Step 1: Introduce the `Cell` type and swap the `DeckGrid` fields**

In `deckplan.gleam`, replace the `DeckGrid` definition and add `Cell`:

```gleam
pub type Cell {
  Cell(
    tile: Tile,
    edges: #(Edge, Edge, Edge, Edge),
    decor: Option(String),
    color: Option(Int),
  )
}

pub type DeckGrid {
  DeckGrid(
    name: String,
    width: Int,
    height: Int,
    cells: List(List(Cell)),
  )
}
```

- [ ] **Step 2: Rebuild construction in `parse_deck_with`**

Replace the separate `tiles`/`edges` list-comprehensions with one `cells` grid. `decor`/`color` are `None` for now (Task 2 fills them):

```gleam
  let cells =
    list.map(range(0, height), fn(y) {
      list.map(range(0, width), fn(x) {
        Cell(
          tile: parse_center(reg, cell_at(cells_g, 3 * y + 1, 3 * x + 1)),
          edges: #(
            parse_edge(reg, cell_at(cells_g, 3 * y, 3 * x + 1)),
            parse_edge(reg, cell_at(cells_g, 3 * y + 1, 3 * x + 2)),
            parse_edge(reg, cell_at(cells_g, 3 * y + 2, 3 * x + 1)),
            parse_edge(reg, cell_at(cells_g, 3 * y + 1, 3 * x)),
          ),
          decor: None,
          color: None,
        )
      })
    })
  Ok(DeckGrid(name: name, width: width, height: height, cells: cells))
```

(Rename the local `let cells = list.map(rows, string.to_graphemes)` to `cells_g` to avoid shadowing.)

- [ ] **Step 3: Update the accessors to read from `cells`**

`tile_at` and `edges_at` index into `cells` and project the field:

```gleam
pub fn tile_at(g: DeckGrid, x: Int, y: Int) -> Tile {
  case cell_of(g, x, y) {
    Ok(c) -> c.tile
    Error(Nil) -> Void
  }
}

pub fn edges_at(g: DeckGrid, x: Int, y: Int) -> Result(#(Edge, Edge, Edge, Edge), Nil) {
  case cell_of(g, x, y) {
    Ok(c) -> Ok(c.edges)
    Error(Nil) -> Error(Nil)
  }
}

fn cell_of(g: DeckGrid, x: Int, y: Int) -> Result(Cell, Nil) {
  case in_bounds(g, x, y) {
    False -> Error(Nil)
    True ->
      case list.drop(g.cells, y) |> list.first {
        Error(Nil) -> Error(Nil)
        Ok(row) -> list.drop(row, x) |> list.first
      }
  }
}
```

`is_walkable`, `edge_in`, `edge_blocks`, `stairs_target`, `scan_stairs` are unchanged — they already call `tile_at`/`edges_at`. `empty_grid` becomes `DeckGrid(name, 0, 0, [])`.

- [ ] **Step 4: Update `deck_to_rows` / `tile_block` to read cells**

`tile_block` already calls `edges_at`/`tile_at`; leave its body. It stays valid. No color emission yet (Task 2).

- [ ] **Step 5: Update `composite.gleam` to the new `Cell`**

`composite` has its own local `Cell = #(Tile, edges)` tuple and `grid_from_cells`. Point them at the deckplan record:
- Its `cell(g, x, y)` helper returns `deckplan.Cell` now (read `deckplan.tile_at` + `deckplan.edges_at`, wrap with `decor: None, color: None`).
- `grid_from_cells(name, w, h, cells)` builds `DeckGrid(name, w, h, cells)` directly (the rows are already `deckplan.Cell`); delete the `tiles:`/`edges:` split.
- `rotate_ccw_grid` / `compose` / `lift` shuffle whole `Cell`s; when they build an edge-rotated cell, construct `Cell(tile:, edges:, decor:, color:)` carrying the source cell's `decor`/`color` unchanged.
- `carve_tile` sets a cell's `tile` to `Floor` via `Cell(..c, tile: Floor)`.
- `mooring_grid` fallback `DeckGrid(name: "", width: 0, height: 0, cells: [])`.
- Update the import line to include `Cell` if referenced by name.

- [ ] **Step 6: Run the server test suite**

Run: `cd server && gleam format src test && gleam test`
Expected: `227 passed, no failures` (walkability, round-trip, composite, stairs all green — behaviour unchanged).

- [ ] **Step 7: Commit**

```bash
cd /c/Users/dibuj/dev/DistantHorizon
git add server/src/dh_server/deckplan.gleam server/src/dh_server/composite.gleam
git commit -m "refactor(deckplan): DeckGrid as one grid of Cell records"
```

---

### Task 2: Server — parse + emit decor & colour (lossless round-trip)

**Files:**
- Modify: `server/src/dh_server/glyphs.gleam` (decor predicate)
- Modify: `server/src/dh_server/deckplan.gleam` (fill + emit `decor`/`color`)
- Test: `server/test/glyphs_test.gleam`, `server/test/deckplan_test.gleam`

**Interfaces:**
- Produces: `glyphs.is_decor(reg: Registry, glyph: String) -> Bool`; `deckplan` fills `Cell.decor` (the centre glyph char, when it is a decor glyph) and `Cell.color` (0–15). `deck_to_rows` re-emits both.
- Consumes: `Cell` from Task 1.

- [ ] **Step 1: Write the failing test for the decor predicate**

In `glyphs_test.gleam`:

```gleam
pub fn is_decor_test() {
  let reg = glyphs.default()
  assert glyphs.is_decor(reg, "r") == True
  // seat, bed, pallet are decor; plain floor / stairs / console / dock / spawn are not
  assert glyphs.is_decor(reg, "d") == True
  assert glyphs.is_decor(reg, "p") == True
  assert glyphs.is_decor(reg, " ") == False
  assert glyphs.is_decor(reg, "x") == False
  assert glyphs.is_decor(reg, "h") == False
  assert glyphs.is_decor(reg, "Q") == False
  assert glyphs.is_decor(reg, "s") == False
}
```

- [ ] **Step 2: Run it — expect failure**

Run: `cd server && gleam test 2>&1 | grep -i "is_decor\|error"`
Expected: compile/assert failure (`is_decor` undefined).

- [ ] **Step 3: Implement `is_decor`**

In `glyphs.gleam`. A decor glyph is a floor-kind centre that is not a console/dock/spawn/stairs and carries a sprite:

```gleam
/// Whether a centre glyph is a decorative floor tile (rug/seat/bed/pallet …):
/// Floor-kind, not a console/dock/spawn, and carrying a client sprite. These
/// are preserved per-cell and rendered as art, unlike bare floor.
pub fn is_decor(reg: Registry, glyph: String) -> Bool {
  let spec = center(reg, glyph)
  spec.tile == Floor
  && spec.console == None
  && !spec.dock
  && !spec.spawn
  && spec.sprite != None
}
```

- [ ] **Step 4: Run — expect pass**

Run: `cd server && gleam test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Write the failing round-trip + parse tests**

In `deckplan_test.gleam` (a 1×1 deck: centre `d` bed with NE colour `a` = 10):

```gleam
pub fn decor_and_color_parse_test() {
  // 3x3 block: NE corner (row0 col2) = "a"; centre (row1 col1) = "d" (bed).
  let rows = ["#=a", " d ", "###"]
  let assert Ok(g) = deckplan.parse_deck("t", rows)
  let assert Ok(c) = deckplan_cell(g, 0, 0)
  assert c.decor == option.Some("d")
  assert c.color == option.Some(10)
  assert c.tile == deckplan.Floor
}

pub fn decor_color_roundtrip_test() {
  let rows = ["#=a", " d ", "###"]
  let assert Ok(g) = deckplan.parse_deck("t", rows)
  let assert Ok(g2) = deckplan.parse_deck("t", deckplan.deck_to_rows(g))
  assert g2.cells == g.cells
}

pub fn blank_ne_corner_is_uncolored_test() {
  let rows = ["# #", " r ", "###"]
  let assert Ok(g) = deckplan.parse_deck("t", rows)
  let assert Ok(c) = deckplan_cell(g, 0, 0)
  assert c.color == option.None
  assert c.decor == option.Some("r")
}
```

Add a tiny test accessor (or use an exposed one). Expose `pub fn cell_at_xy(g, x, y) -> Result(Cell, Nil)` in `deckplan.gleam` (rename `cell_of` to public `cell_at_xy`) and call it as `deckplan.cell_at_xy` in the test instead of `deckplan_cell`.

- [ ] **Step 6: Run — expect failure**

Run: `cd server && gleam test 2>&1 | grep -i "decor\|color\|roundtrip"`
Expected: assert failures (`decor`/`color` are `None`; no `cell_at_xy`).

- [ ] **Step 7: Fill `decor`/`color` in `parse_deck_with`**

Add helpers and set the fields in the `Cell(...)` built in Task 1 Step 2:

```gleam
fn parse_decor(reg: glyphs.Registry, ch: String) -> Option(String) {
  case glyphs.is_decor(reg, ch) {
    True -> Some(ch)
    False -> None
  }
}

/// The NE corner encodes colour as a single hex digit 0-f -> 0-15; anything
/// else (blank, "#", junk) is uncoloured.
fn parse_color(ch: String) -> Option(Int) {
  case int.base_parse(ch, 16) {
    Ok(n) if n >= 0 && n <= 15 -> Some(n)
    _ -> None
  }
}
```

In the cell builder: `decor: parse_decor(reg, cell_at(cells_g, 3 * y + 1, 3 * x + 1))`, and `color: parse_color(cell_at(cells_g, 3 * y, 3 * x + 2))` (row `3y`, col `3x+2` = NE corner). Make `cell_of` public as `cell_at_xy`.

- [ ] **Step 8: Emit `decor` + `color` in `deck_to_rows`**

In `tile_block`, use the cell's decor for the centre and its colour for the NE corner:

```gleam
fn tile_block(g: DeckGrid, x: Int, y: Int) -> #(String, String, String) {
  let assert Ok(cell) = cell_at_xy(g, x, y)
  let #(n, e, s, w) = cell.edges
  let c = case cell.decor {
    Some(glyph) -> glyph
    None -> center_glyph(cell.tile)
  }
  let ne = case cell.color {
    Some(v) -> int.to_base16_digit(v)   // see Step 9
    None -> corner(n, e)
  }
  let top = corner(n, w) <> edge_glyph(n) <> ne
  let mid = edge_glyph(w) <> c <> edge_glyph(e)
  let bot = corner(s, w) <> edge_glyph(s) <> corner(s, e)
  #(top, mid, bot)
}
```

- [ ] **Step 9: Add the hex-digit emitter**

`gleam/int` has no lowercase single-digit helper; add a local one:

```gleam
fn int.to_base16_digit(v: Int) -> String {  // define as `to_hex_digit`
  case v {
    0 -> "0"  1 -> "1"  2 -> "2"  3 -> "3"  4 -> "4"  5 -> "5"
    6 -> "6"  7 -> "7"  8 -> "8"  9 -> "9"  10 -> "a"  11 -> "b"
    12 -> "c"  13 -> "d"  14 -> "e"  15 -> "f"  _ -> " "
  }
}
```

(Write it as a normal `fn to_hex_digit(v: Int) -> String` with one `case` arm per line; call `to_hex_digit(v)` in Step 8.)

- [ ] **Step 10: Run — expect pass**

Run: `cd server && gleam format src test && gleam test 2>&1 | tail -3`
Expected: all pass (new decor/color/round-trip tests + the existing 227).

- [ ] **Step 11: Commit**

```bash
git add server/src/dh_server/glyphs.gleam server/src/dh_server/deckplan.gleam server/test/glyphs_test.gleam server/test/deckplan_test.gleam
git commit -m "feat(deckplan): parse + round-trip per-cell decor and NE-corner colour"
```

---

### Task 3: Server — palette module + forward on `welcome`

**Files:**
- Create: `server/src/dh_server/palette.gleam`
- Create: `server/test/palette_test.gleam`
- Modify: `server/src/dh_server/protocol.gleam` (welcome), `server/src/dh_server/server.gleam` (thread param), `server/src/dh_server.gleam` (load)

**Interfaces:**
- Produces: `palette.Palette`; `palette.load(path) -> Result(Palette, String)`; `palette.default() -> Palette`; `palette.encode(Palette) -> Json`. `protocol.encode_welcome(..., palette: palette.Palette)` gains a trailing `palette` arg and emits `#("palette", palette.encode(palette))`.
- Consumes: `server/colors.json` (landed).

- [ ] **Step 1: Write `palette_test`**

```gleam
import dh_server/palette

pub fn loads_shipped_palette_test() {
  let assert Ok(_) = palette.load("colors.json")
}

pub fn default_matches_shipped_file_test() {
  let assert Ok(loaded) = palette.load("colors.json")
  assert loaded == palette.default()
}

pub fn sixteen_entries_test() {
  assert palette.count(palette.default()) == 16
}
```

- [ ] **Step 2: Run — expect failure**

Run: `cd server && gleam test 2>&1 | grep -i palette`
Expected: module not found.

- [ ] **Step 3: Implement `palette.gleam`**

Mirror `glyphs.gleam`'s load/default/encode shape. `Palette` wraps a `List(String)` of 16 hex strings (order = slot):

```gleam
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type Entry {
  Entry(name: String, hex: String)
}

pub type Palette {
  Palette(entries: List(Entry))
}

pub fn count(p: Palette) -> Int {
  list.length(p.entries)
}

pub fn load(path: String) -> Result(Palette, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) { "failed to read palette " <> path <> ": " <> string.inspect(e) }),
  )
  json.parse(text, palette_decoder())
  |> result.map_error(fn(e) { "invalid palette: " <> string.inspect(e) })
}

fn palette_decoder() -> decode.Decoder(Palette) {
  use entries <- decode.field("palette", decode.list(entry_decoder()))
  decode.success(Palette(entries: entries))
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use name <- decode.field("name", decode.string)
  use hex <- decode.field("hex", decode.string)
  decode.success(Entry(name: name, hex: hex))
}

/// Forwarded on `welcome` as a flat array of hex strings, index = slot digit.
pub fn encode(p: Palette) -> Json {
  json.array(p.entries, fn(e) { json.string(e.hex) })
}
```

`default()`: return `Palette([Entry("white", "#F9FFFE"), … , Entry("black", "#1D1D21")])` — all 16 entries copied verbatim from `server/colors.json` in order.

- [ ] **Step 4: Run — expect pass**

Run: `cd server && gleam test 2>&1 | grep -i palette`
Expected: 3 palette tests pass.

- [ ] **Step 5: Thread the palette into `welcome`**

- `protocol.encode_welcome`: add trailing param `palette: palette.Palette` and add `#("palette", palette.encode(palette))` to the object (import `dh_server/palette`).
- `server.gleam`: the 4 functions carrying `registry: glyphs.Registry` (`start`, `route`, and the two inner handlers) gain a parallel `palette: palette.Palette` param; pass it through to the `encode_welcome` call site.
- `dh_server.gleam` `main`: after loading the glyph registry, load the palette the same way:

```gleam
  let colors_path = case envoy.get("DH_COLORS") {
    Ok(path) -> path
    Error(Nil) -> "colors.json"
  }
  let color_palette = case palette.load(colors_path) {
    Ok(p) -> p
    Error(err) -> {
      io.println("WARNING: colors: " <> err <> "; using built-in palette")
      palette.default()
    }
  }
```

Pass `color_palette` into `server.start(sim_subject, world, class, registry, color_palette, authenticator)`.

- [ ] **Step 6: Update `protocol_test` welcome call**

Any test calling `encode_welcome` needs the new arg. Add `palette.default()` at the call site(s). Run: `cd server && gleam test 2>&1 | grep -i "welcome\|palette"` then fix.

- [ ] **Step 7: Run full suite + format**

Run: `cd server && gleam format src test && gleam test 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add server/src/dh_server/palette.gleam server/test/palette_test.gleam server/src/dh_server/protocol.gleam server/src/dh_server/server.gleam server/src/dh_server.gleam
git commit -m "feat(server): load colors.json and forward the palette on welcome"
```

---

### Task 4: Server — breakbulk capacity derived from pallet count

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam` (pallet counter)
- Modify: `server/src/dh_server/shipclass.gleam` (derive)
- Test: `server/test/deckplan_test.gleam`, `server/test/shipclass_test.gleam`

**Interfaces:**
- Produces: `deckplan.pallet_count(plan: DeckPlan, reg: glyphs.Registry) -> Int`. `shipclass` sets `cargo_capacity` to the pallet count when > 0, else the authored value.
- Consumes: `Cell.decor`, `glyphs.center(reg, glyph).id`.

- [ ] **Step 1: Write the failing `pallet_count` test**

In `deckplan_test.gleam` — a 2×1 deck with two `p` pallet tiles:

```gleam
pub fn pallet_count_test() {
  let rows = ["######", " p  p ", "######"]
  let assert Ok(g) = deckplan.parse_deck("hold", rows)
  let plan = deckplan.DeckPlan(decks: [g], consoles: [], spawn_deck: 0, spawn_tile: #(0, 0))
  assert deckplan.pallet_count(plan, glyphs.default()) == 2
}
```

- [ ] **Step 2: Run — expect failure** — Run: `cd server && gleam test 2>&1 | grep -i pallet` → undefined.

- [ ] **Step 3: Implement `pallet_count`**

```gleam
/// Count of cargo-pallet tiles across every deck — the derived breakbulk
/// hold capacity ("the map is the single source of truth"). A pallet is a
/// cell whose decor glyph maps to the `cargo_pallet` id in the registry.
pub fn pallet_count(plan: DeckPlan, reg: glyphs.Registry) -> Int {
  list.fold(plan.decks, 0, fn(total, g) {
    list.fold(g.cells, total, fn(t, row) {
      list.fold(row, t, fn(n, c) {
        case c.decor {
          Some(glyph) ->
            case glyphs.center(reg, glyph).id == "cargo_pallet" {
              True -> n + 1
              False -> n
            }
          None -> n
        }
      })
    })
  })
}
```

- [ ] **Step 4: Run — expect pass** — Run: `cd server && gleam test 2>&1 | grep -i pallet` → passes.

- [ ] **Step 5: Write the failing shipclass derivation test**

In `shipclass_test.gleam`, decode a minimal class whose single deck has 3 pallet tiles and `cargo.capacity` authored as 0; assert the derived capacity is 3. Model the JSON on existing `shipclass_test` fixtures (a `decks` array with one deck grid, `cargo`, `dock_port_orientation`). Assert `class.cargo_capacity == 3`.

- [ ] **Step 6: Run — expect failure** (still the authored 0).

- [ ] **Step 7: Derive in `shipclass`**

In the shipclass decoder, after the `DeckPlan` and authored `#(capacity, handling)` are in scope, compute:

```gleam
  let derived = deckplan.pallet_count(plan, reg)
  let effective_capacity = case derived > 0 {
    True -> derived
    False -> capacity
  }
```

Use `effective_capacity` for `cargo_capacity`. (The shipclass decoder already threads `reg`; if not in that scope, pass it — it is available in `decode_with`/`load_with`.)

- [ ] **Step 8: Run full suite + format** — `cd server && gleam format src test && gleam test 2>&1 | tail -3` → all pass.

- [ ] **Step 9: Commit**

```bash
git add server/src/dh_server/deckplan.gleam server/src/dh_server/shipclass.gleam server/test/deckplan_test.gleam server/test/shipclass_test.gleam
git commit -m "feat(shipclass): derive breakbulk capacity from cargo-pallet tiles"
```

---

### Task 5: Client — `Deck` mirrors `Cell`; parse decor + colour

**Files:**
- Modify: `client/scripts/ship_class_data.gd`
- Create: `client/tools/interior_parse_probe.gd` (headless parse assertions)
- Test: headless Godot run of the probe

**Interfaces:**
- Produces: `ShipClassData.Deck` stores `cells` (each an inner `Cell` with `tile: int`, `edges: Array` `[n,e,s,w]`, `decor: String` (`""`=none), `color: int` (`-1`=none)). Accessors `tile_at`/`edges_at`/`edge_in`/`is_walkable` unchanged in signature. New: `Deck.decor_at(tx, ty) -> String`, `Deck.color_at(tx, ty) -> int`; `ShipClassData.decor_at(deck, tx, ty)`, `ShipClassData.color_at(deck, tx, ty)`.
- Consumes: raw `grid` rows from the wire (already received).

- [ ] **Step 1: Refactor `Deck` to hold `cells`**

In `ship_class_data.gd`, add an inner `Cell` class and replace `tiles`/`edges` with `cells` (keep the `fixtures` dict as-is for edge fixture chars). Mirror the server's parse:
- centre → `Tile` (unchanged mapping) and, when the glyph is a decor glyph, `decor` = the centre char. The client can't see the server registry synchronously here, but it CAN ask `NetworkClient.glyphs` (set at welcome). Store `decor` = centre char whenever it is non-blank and not one of the structural centres (`.`/`x`) and not a console/spawn glyph per the registry; simplest robust rule mirroring the server: `decor = ch` when `NetworkClient.glyphs.is_decor(ch)` (add that helper in Task 6) — until Task 6 lands, store `decor = ch` for any centre char whose registry sprite is non-empty and is not a console. To avoid a Task ordering trap, implement `GlyphRegistry.is_decor(glyph)` in THIS task too (it only needs the welcome data). See Step 2.
- NE corner (row `3*ty`, col `3*tx+2`) → `color` = hex value 0–15 or `-1`.

```gdscript
class Cell:
    var tile: int
    var edges: Array          # [n, e, s, w] of Edge
    var decor: String = ""    # centre decoration glyph, "" = none
    var color: int = -1       # 0-15 from NE corner, -1 = uncoloured
```

Build `cells[ty][tx]` in `from_grid`; rewrite `tile_at`, `edges_at`, `edge_in`, `is_walkable` to read `cells`.

- [ ] **Step 2: Colour + decor parse helpers**

```gdscript
static func _parse_color(ch: String) -> int:
    var v := ("0x" + ch).hex_to_int() if ch.length() == 1 and \
        "0123456789abcdefABCDEF".contains(ch) else -1
    return v if v >= 0 and v <= 15 else -1
```

For decor, in `from_grid`, set `cell.decor = ch` when `ch != " " and ch != "." and ch != "x"` and the registry marks it decor. Use `NetworkClient.glyphs.is_decor(ch)` (helper added in Task 6 Step 2); guard for a null registry (fall back to `false`) so tests without a welcome still parse geometry.

- [ ] **Step 3: Add public accessors**

```gdscript
func decor_at(deck: int, tx: int, ty: int) -> String:
    var g := get_deck(deck)
    return "" if g == null else g.decor_at(tx, ty)

func color_at(deck: int, tx: int, ty: int) -> int:
    var g := get_deck(deck)
    return -1 if g == null else g.color_at(tx, ty)
```

(and the `Deck.decor_at`/`Deck.color_at` reading `cells`.)

- [ ] **Step 4: Write the headless parse probe**

`client/tools/interior_parse_probe.gd` — a `SceneTree` script that builds a `ShipClassData` from a decorated deck and asserts:

```gdscript
extends SceneTree
## Headless parse probe: godot --path client --headless --script res://tools/interior_parse_probe.gd
func _init() -> void:
    var cls := ShipClassData.from_dict({
        "id": "t", "name": "T",
        "decks": [{ "name": "d", "grid": ["#=a", " d ", "###"] }],
    })
    var ok := true
    ok = ok and cls.is_walkable(0, 0, 0)
    ok = ok and cls.decor_at(0, 0, 0) == "d"
    ok = ok and cls.color_at(0, 0, 0) == 10
    print("[parse_probe] ", "PASS" if ok else "FAIL")
    quit(0 if ok else 1)
```

(Decor assertion needs the registry; the probe has no welcome. Either set `NetworkClient.glyphs` from `glyphs.json` in the probe, or assert only geometry+color here and cover decor via the harness integration test in Task 7. Prefer: load the registry in the probe — `NetworkClient.glyphs = GlyphRegistry.from_dict(JSON.parse_string(FileAccess.get_file_as_string("res://../server/glyphs.json")))` — so decor asserts too.)

- [ ] **Step 5: Run the probe**

Run: `godot --path client --headless --script res://tools/interior_parse_probe.gd`
Expected: `[parse_probe] PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add client/scripts/ship_class_data.gd client/tools/interior_parse_probe.gd
git commit -m "feat(client): Deck as cells; parse decor + NE-corner colour"
```

---

### Task 6: Client — palette + glyph→sprite lookup at welcome

**Files:**
- Modify: `client/scripts/glyph_registry.gd` (`is_decor`, `sprite_for_glyph`)
- Create: `client/scripts/palette.gd`
- Modify: `client/scripts/network_client.gd` (parse `palette` from welcome)

**Interfaces:**
- Produces: `GlyphRegistry.is_decor(glyph: String) -> bool`; `GlyphRegistry.sprite_for_glyph(glyph: String) -> String`; `Palette.from_dict(data) -> Palette`, `Palette.color(slot: int) -> Color`; `NetworkClient.palette: Palette` (static, set at welcome next to `NetworkClient.glyphs`).
- Consumes: welcome `glyphs` (per-entry `glyph`+`sprite`+role flags) and `palette` (array of hex strings).

- [ ] **Step 1: `GlyphRegistry.sprite_for_glyph` + `sprite_by_glyph`**

In `glyph_registry.gd` `from_dict`, while ingesting centres AND edges, also build `sprite_by_glyph[glyph] = sprite` and record role flags per glyph (`console`, `dock`, `spawn`, `tile`) so `is_decor` can be answered:

```gdscript
var sprite_by_glyph: Dictionary = {}   # glyph char -> sprite id
var _decor_glyphs: Dictionary = {}     # glyph char -> true

func sprite_for_glyph(glyph: String) -> String:
    return str(sprite_by_glyph.get(glyph, ""))

func is_decor(glyph: String) -> bool:
    return _decor_glyphs.has(glyph)
```

Populate `_decor_glyphs[glyph] = true` for a centre entry whose `tile == "floor"`, `console == null`, `dock`/`spawn` falsey, and `sprite != null` (mirror of the server predicate).

- [ ] **Step 2: `palette.gd`**

```gdscript
class_name Palette
extends RefCounted
var colors: Array[Color] = []

static func from_dict(data: Variant) -> Palette:
    var p := Palette.new()
    if data is Array:
        for hex: Variant in data:
            p.colors.append(Color(str(hex)))
    return p

## Slot 0-15 -> Color; white for an out-of-range slot (safe default).
func color(slot: int) -> Color:
    if slot < 0 or slot >= colors.size():
        return Color.WHITE
    return colors[slot]
```

- [ ] **Step 3: Parse palette at welcome**

In `network_client.gd`, where `glyphs` is parsed from the welcome message, add:

```gdscript
NetworkClient.palette = Palette.from_dict(msg.get("palette", []))
```

and declare the static `static var palette: Palette` next to `static var glyphs`.

- [ ] **Step 4: Verify parse (extend the probe)**

Extend `interior_parse_probe.gd` to build a `Palette` from the shipped `colors.json` and assert `Color`-parse works:

```gdscript
    var raw = JSON.parse_string(FileAccess.get_file_as_string("res://../server/colors.json"))
    var hexes: Array = []
    for e in raw["palette"]: hexes.append(e["hex"])
    var pal := Palette.from_dict(hexes)
    ok = ok and pal.colors.size() == 16
    ok = ok and pal.color(15).is_equal_approx(Color("#1D1D21"))
```

Run: `godot --path client --headless --script res://tools/interior_parse_probe.gd` → `PASS`.

- [ ] **Step 5: Commit**

```bash
git add client/scripts/glyph_registry.gd client/scripts/palette.gd client/scripts/network_client.gd client/tools/interior_parse_probe.gd
git commit -m "feat(client): parse palette + glyph->sprite lookup at welcome"
```

---

### Task 7: Client — render decor pass (tinted, with placeholder) + fixture sprites

**Files:**
- Modify: `client/scripts/interior_view.gd`
- Modify: `harness/test_m2_interior.py` (or new `harness/test_decor.py`) + a shot script
- Test: Python harness screenshot + visual check via `run` skill

**Interfaces:**
- Consumes: `ShipClassData.decor_at`/`color_at`, `NetworkClient.glyphs.sprite_for_glyph`, `NetworkClient.palette.color`.

- [ ] **Step 1: Add a decor pass to `_draw`**

Insert `_draw_decor(origin)` between `_draw_floor` and `_draw_consoles` in `_draw()`. For each visible floor tile with a decor glyph, draw its sprite tinted by the tile's colour, or a tinted placeholder swatch if the sprite art is missing (so authored decor is visible NOW, before art exists):

```gdscript
func _draw_decor(origin: Vector2) -> void:
    var reg: GlyphRegistry = NetworkClient.glyphs
    if reg == null:
        return
    for ty in _grid_h():
        for tx in _grid_w():
            if not _vis(tx, ty):
                continue
            var glyph := ship_class.decor_at(view_deck, tx, ty)
            if glyph == "":
                continue
            var slot := ship_class.color_at(view_deck, tx, ty)
            var tint := NetworkClient.palette.color(slot) if slot >= 0 \
                and NetworkClient.palette != null else Color.WHITE
            var pos := _tile_to_screen(Vector2(tx, ty), origin)
            var sprite_id := reg.sprite_for_glyph(glyph)
            var tex: Texture2D = _lib.interior(sprite_id) if sprite_id != "" else null
            if tex != null:
                draw_texture_rect(tex, Rect2(pos, Vector2(TILE_PIXELS, TILE_PIXELS)), false, tint)
            else:
                # Placeholder until decor art exists: a centred tinted swatch.
                var m := TILE_PIXELS * 0.22
                draw_rect(Rect2(pos + Vector2(m, m), Vector2(TILE_PIXELS - 2 * m, TILE_PIXELS - 2 * m)),
                    tint if slot >= 0 else Color(0.6, 0.6, 0.65), true)
```

- [ ] **Step 2: Draw edge-fixture sprites in `_draw_structure`**

Where a boundary is a `FIXTURE` (window `w`, viewscreen `v`), draw the fixture's sprite on the wall strip instead of a plain plate. Look up the fixture char from the `fixtures` dict (already populated) → `reg.sprite_for_glyph(char)` → `_lib.interior(id)`; fall back to the plain wall texture when the sprite is missing (today's look). Keep collision unchanged (fixtures still block).

- [ ] **Step 3: Visual check via the run skill**

Author a scratch deck with a rug/seat/bed of different colours and a window, launch the client against the dev server, and confirm the tinted swatches appear on the right tiles in the right colours, walls/doors unchanged, walkability intact. (Use the `run` skill / `harness` shot pattern — e.g. copy `harness/shot_m35_interior.py` to drive a decorated hull and save a PNG, then inspect it.)

Run: `cd harness && python shot_m35_interior.py` (or the new decor shot). Expected: PNG shows coloured decor swatches; no errors in console.

- [ ] **Step 4: Harness regression**

Run: `cd harness && pytest test_m2_interior.py test_m31_stitched.py -q`
Expected: pass (decor pass does not disturb walk/interior behaviour).

- [ ] **Step 5: Commit**

```bash
git add client/scripts/interior_view.gd harness/
git commit -m "feat(client): render tinted decor pass + wall-fixture sprites"
```

---

### Task 8: Docs — deck-plan format: colour corner, new glyphs, derived capacity

**Files:**
- Modify: `docs/deckplan-format.md`

- [ ] **Step 1: Update the corners note**

In the "Core idea" / glyph-key sections, change "The four corners are cosmetic" to document that the **NE corner** encodes colour (`0`–`f` → the 16-slot palette in `server/colors.json`; blank/`#`/other = uncoloured); NW/SW/SE remain cosmetic hull-weld corners.

- [ ] **Step 2: Note the new glyphs + palette**

Add rug `r`, seat `e`, bed `d`, cargo-pallet `p`, window `w` to the prose glyph rationale (the registry stays the SoT). Note `v` viewscreen now covers any wall screen. Add a short "Colour" subsection pointing at `server/colors.json` and the greyscale-multiply tint. Note breakbulk `capacity` derives from the number of `p` pallet tiles (authored `cargo.capacity` is the fallback when none are placed).

- [ ] **Step 3: Commit**

```bash
git add docs/deckplan-format.md
git commit -m "docs(deckplan): NE-corner colour, pass-1 decor glyphs, derived capacity"
```

---

## Self-Review

**Spec coverage:**
- Per-cell decor+color transport → Tasks 1, 2 (server), 5 (client). ✓
- Lossless round-trip → Task 2 Step 5. ✓
- Palette in colors.json, wire-forwarded, greyscale-multiply tint → Tasks 3 (server), 6 (client parse), 7 (render). ✓
- Simple tiles rug/seat/bed/window + `v` screen → vocabulary landed; rendered in Task 7. ✓
- Cargo pallet + derived breakbulk capacity → Task 4. ✓
- Walkability untouched → Task 1 is behaviour-preserving; verified by the existing 227 tests staying green. ✓
- Uncoloured default, non-hex NE handling → Task 2 (`parse_color`), Task 5 (`_parse_color`). ✓
- Graceful missing-sprite fallback (+ placeholder swatch for visibility) → Task 7 Step 1–2. ✓
- Docs → Task 8. ✓
- Non-goals (#36) → not planned here. ✓

**Placeholder scan:** No "TBD/handle edge cases" — every code step shows code; test steps show assertions. The one hex-emitter step names the helper explicitly.

**Type consistency:** `Cell(tile, edges, decor, color)` used identically across Tasks 1/2/4 (server) and mirrored as GDScript `Cell` (Task 5). `pallet_count(plan, reg)` defined in Task 4 Step 3 and called in Task 4 Step 7. `is_decor` defined server-side (Task 2) and client-side (`GlyphRegistry.is_decor`, Task 6, used in Task 5 with a null-guard). `sprite_for_glyph` defined Task 6, used Task 7. `Palette.color(slot)` defined Task 6, used Task 7.

**Ordering note:** Task 5 uses `GlyphRegistry.is_decor` which is formally added in Task 6; Task 5 Step 2 calls it with a null-guard and Task 5's probe loads the registry itself, so implement `is_decor` in whichever of Tasks 5/6 lands first (it only needs welcome data). If executing strictly in order, add `is_decor` during Task 5.
