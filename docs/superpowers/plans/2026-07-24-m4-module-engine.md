# M4 Module Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the server-side module engine from `docs/modules.md` — a hull registry, slot-marked deck plans, hand-authored module overlays, the resolved-plan bake, per-ship loadouts with pooled-tag validation, flight stats out of constants and into data, and a refit verb — with the Mockingbird as the only hull and her current deck reproduced exactly by her default loadout.

**Architecture:** A hull document (`server/shipclasses/*.json`) keeps its authored deck rows as *text*; a module (`server/modules/<hull>/<id>.json`) is a small ASCII patch drawn against that hull's coordinate space. Resolving a loadout **splices module character-blocks into the hull's rows** and re-runs the existing v3 parse-and-derive path, so consoles, spawn, docking ports and pallet-derived cargo capacity all fall out of the stamped map with no new derivation code. The output is an ordinary `ShipClass` — exactly what the sim, the composite and the wire already consume — so nothing downstream changes shape.

**Tech Stack:** Gleam (Erlang target) server, gleeunit tests, JSON data files validated by jesse schemas, Python/pytest protocol harness.

## Global Constraints

- Deck-plan format is **v3** (`docs/deckplan-format.md`): every tile is a 3×3 character block; the parser reads centre + four edge-mids + the **NE corner** (colour hex digit). This plan adds the **SW corner** (slot hex digit `0`–`f`). NW and SE stay cosmetic.
- **`void` cell = passthrough, non-void = overwrite** is the whole overlay rule (`docs/modules.md`). No DSL, no generative recipes.
- **The map is the single source of truth.** Consoles, the spawn/mooring tile, docking ports and breakbulk capacity are derived from glyphs — after the bake, from the *resolved* plan, never authored as numbers.
- **Loadout validation is one rule plus structural checks:** `sum(provides) ≥ sum(requires)` pooled per tag; ≤1 module per slot; every non-void overlay cell lands on a hull cell marked with that slot's digit; mount kind matches and mount size ≥ part size. **Never** reachability or geometry analysis.
- **The Mockingbird's deck does not change in this plan.** Her default loadout must resolve to today's authored map, tile for tile. A golden test enforces it.
- Angles are **degrees** everywhere (config, wire, sim); only `cos`/`sin` use radians.
- Gleam has no `list.range` in the pinned stdlib — every module that needs one defines the local `fn range(from, to)` helper already used in `deckplan.gleam` and `composite.gleam`.
- Run the server test suite from `server/`: `gleam test`. Run the harness from `harness/`: `python -m pytest <file> -v` (needs `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"` for `gleam`).
- Work happens on branch `feat/m4-modules` (worktree `.claude/worktrees/m4-modules`). Commit after every task.
- **Every task ends with a green `gleam test`.** The task order is built around this: the hull document keeps a temporary `shipclass.load` shim (Task 3) until the sim resolves fits (Task 7), and the Mockingbird is carved last (Task 8) so the carve runs against live machinery instead of hiding behind unwired code. A task that cannot leave the suite green is a task that needs splitting differently — say so rather than committing red.

## Scope

**In this plan (iteration 1 — the engine):** slot digits, hull/module/part documents and registries, the overlay stamp + resolved bake, per-ship loadouts, pooled-tag validation, flight stats from data, the `refit` wire verb and its pushes, the Mockingbird carved into hull + default modules, schema and doc updates.

**Deliberately deferred to iteration 2 (three hulls + exteriors):** the Sparrow and Finch hulls, hull **mount geometry** (sprite-space position/rotation of a mount), standalone exterior part sprite exports from `tools/artspike/composer.py`, client-side sprite layering, per-ship `hull` on the `snapshot` message, and the engineering-bay interior module (which needs a deliberate revision of the Mockingbird's stern).

**Deferred to iteration 3 (the refit loop):** shipyard stations, the refit console glyph, per-station part catalogs and prices, charging the wallet, and the Godot refit UI. This plan's `refit` verb is docked-only and free — iteration 3 layers the console-proximity, catalog and cost checks on top of it.

## File Structure

**New server modules:**
- `server/src/dh_server/hull.gleam` — the authored hull document (deck rows kept as text, slots, mounts, mass, tag provides, default loadout) plus the directory registry.
- `server/src/dh_server/module.gleam` — the authored interior-module document (patches) plus its registry.
- `server/src/dh_server/part.gleam` — the authored exterior-part document (kind/size/mass/flight) plus its registry.
- `server/src/dh_server/loadout.gleam` — `Loadout`, the overlay stamp, validation, and `resolve` → `Fit`.

**Modified server modules:**
- `deckplan.gleam` — SW slot digit on `Cell`; `from_rows` exposing the parse-and-derive path.
- `shipclass.gleam` — becomes the *resolved* class only: gains `Flight`, gains `from_plan`, loses file loading.
- `composite.gleam` — `Cell` construction sites gain `slot: None`.
- `ship.gleam` — `main_accel`/`turn_rate` constants deleted; `step` takes a `Flight`.
- `sim.gleam` — one shared `class` becomes per-ship `Fit`s; handles `Refit`.
- `protocol.gleam` — `refit` in, `refit_result` + `ship_fit` out; `flight` on the encoded class.
- `dh_server.gleam` — loads the three registries and picks the spawn hull.

**New data:**
- `server/shipclasses/mockingbird.json` — rewritten as a hull document (slot digits marked, slot regions emptied).
- `server/modules/mockingbird/*.json` — six modules (five default + alternates).
- `server/parts/*.json` — two engines.
- `server/schemas/module.schema.json`, `server/schemas/part.schema.json`.

---

### Task 1: Slot digit in the deck-plan parser

The SW corner of a tile block becomes the slot marker, mirroring the NE colour digit.

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam` (`Cell` at 52-59, `parse_deck_with` at 110-152, `parse_color` at 181-186, `tile_block` at 768-783)
- Modify: `server/src/dh_server/composite.gleam` (lines 409, 539)
- Test: `server/test/deckplan_test.gleam`
- Modify: `docs/deckplan-format.md`

**Interfaces:**
- Produces: `deckplan.Cell` gains field `slot: option.Option(Int)` (5th positional field, after `color`). Every `Cell(...)` construction in the codebase must supply it.

- [ ] **Step 1: Write the failing tests**

Append to `server/test/deckplan_test.gleam`:

```gleam
pub fn sw_corner_marks_slot_test() {
  // Two tiles: the left one in slot 1 (SW = "1"), the right one unmarked.
  let assert Ok(g) =
    deckplan.parse_deck("t", ["######", "#    #", "1##  #"])
  let assert Ok(a) = deckplan.cell_at_xy(g, 0, 0)
  let assert Ok(b) = deckplan.cell_at_xy(g, 1, 0)
  assert a.slot == option.Some(1)
  assert b.slot == option.None
}

pub fn sw_corner_accepts_high_hex_digits_test() {
  let assert Ok(g) = deckplan.parse_deck("t", ["###", "# #", "f##"])
  let assert Ok(c) = deckplan.cell_at_xy(g, 0, 0)
  assert c.slot == option.Some(15)
}

pub fn non_hex_sw_corner_is_no_slot_test() {
  let assert Ok(g) = deckplan.parse_deck("t", ["###", "# #", "###"])
  let assert Ok(c) = deckplan.cell_at_xy(g, 0, 0)
  assert c.slot == option.None
}

pub fn slot_digit_round_trips_through_rows_test() {
  let rows = ["###", "# #", "3##"]
  let assert Ok(g) = deckplan.parse_deck("t", rows)
  let assert Ok(g2) = deckplan.parse_deck("t", deckplan.deck_to_rows(g))
  assert deckplan.cell_at_xy(g, 0, 0) == deckplan.cell_at_xy(g2, 0, 0)
}
```

Add `import gleam/option` to the test file's imports if it is not already there.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server; gleam test`
Expected: compile error — `Cell` has no field `slot`.

- [ ] **Step 3: Add the field and parse it**

In `deckplan.gleam`, replace the `Cell` type (lines 52-59):

```gleam
/// One tile: what it IS at centre plus its four edges `#(n, e, s, w)`, an
/// optional decor glyph, an optional palette colour index, and (M4) the hull
/// SLOT this tile belongs to. Colour rides the NE corner, slot the SW corner
/// — see `docs/deckplan-format.md`.
pub type Cell {
  Cell(
    tile: Tile,
    edges: #(Edge, Edge, Edge, Edge),
    decor: option.Option(String),
    color: option.Option(Int),
    /// Slot membership: the SW-corner hex digit selecting one of the hull's
    /// slots (`docs/modules.md`), or `None` for fixed hull structure that no
    /// module may overwrite.
    slot: option.Option(Int),
  )
}
```

In `parse_deck_with`, add the field to the `Cell(...)` built at lines 138-148:

```gleam
          color: parse_hex_digit(cell_at(cells_g, 3 * y, 3 * x + 2)),
          slot: parse_hex_digit(cell_at(cells_g, 3 * y + 2, 3 * x)),
```

Replace `parse_color` (lines 178-186) with the shared helper — both corners use the same encoding:

```gleam
/// A corner hex digit 0-f -> 0-15; anything else (blank, "#", junk) is None.
/// Both the NE corner (colour) and the SW corner (slot) use this encoding.
fn parse_hex_digit(ch: String) -> option.Option(Int) {
  case int.base_parse(ch, 16) {
    Ok(n) if n >= 0 && n <= 15 -> Some(n)
    _ -> None
  }
}
```

In `tile_block` (lines 768-783), emit the SW digit so `deck_to_rows` stays an exact inverse:

```gleam
  let ne = case cell.color {
    Some(v) -> to_hex_digit(v)
    None -> corner(n, e)
  }
  let sw = case cell.slot {
    Some(v) -> to_hex_digit(v)
    None -> corner(s, w)
  }
  let top = corner(n, w) <> edge_glyph(n) <> ne
  let mid = edge_glyph(w) <> c <> edge_glyph(e)
  let bot = sw <> edge_glyph(s) <> corner(s, e)
```

- [ ] **Step 4: Fix the other `Cell` construction sites**

In `composite.gleam`, both bare-void cells (line 409 in `compose_level`, line 539 in `cell`) become:

```gleam
            Ok(Cell(
              tile: Void,
              edges: open_edges(),
              decor: None,
              color: None,
              slot: None,
            ))
```

- [ ] **Step 5: Run the whole server suite**

Run: `cd server; gleam test`
Expected: PASS, including the four new deckplan tests.

- [ ] **Step 6: Document the SW corner**

In `docs/deckplan-format.md`, in the "Core idea" section, change the sentence that reads "The four corners carry no collision data ... but the **NE corner** carries one more fact" so it names both data corners, and change the "**Corners**" bullet in the glyph key to read:

```markdown
- **Corners**: NW/SE are cosmetic — use `#` for a clean hull outline; the
  renderer auto-joins wall corners, so a blank corner between two walls still
  renders closed. **NE and SW are not cosmetic**: NE is the tile's colour digit
  (see "Colour" below) and SW is its slot digit (see "Slots" below). Corners
  never carry collision data and decor never changes walkability.
```

Add a new section after "Colour":

```markdown
### Slots

A tile's **SW corner** carries a hex digit `0`–`f` naming the hull **slot** the
tile belongs to — the modulable regions a refit may overwrite (`docs/modules.md`).
A blank, `#`, or any other non-hex character means "fixed hull structure": no
module may touch that tile. The hull's `slots` table maps each digit to a slot
id and human name. Slot regions are exactly as fluid as the hull author draws
them — following a taper, non-rectangular, whatever — and there is no rectangle
list anywhere.

A module rewrites its slot completely — including *both* halves of any wall
between two slot tiles, since both tiles are its own. The only edges it shares
with the hull are the slot's **perimeter**, where the neighbouring tile is fixed
structure. Two authoring rules follow, and neither is machine-checked:

- **Leave the slot perimeter open by default.** Each tile owns all four of its
  own walls and the collision rule ORs the two facing edges, so a module can put
  a wall (`#` on its half) or a door (`=` on its half) anywhere along an open
  perimeter — full freedom, no engine special case. A hull-side wall on the
  perimeter is therefore a *deliberate structural declaration*: "no module ever
  opens this", for a pressure bulkhead or a hold's fire wall. Draw one only
  where you mean it.
- **A stamp never overwrites the SW corner.** Slot regions are hull-owned, so
  the resolved plan still carries them and a second refit finds the same
  region.
```

- [ ] **Step 7: Commit**

```bash
git add server/src/dh_server/deckplan.gleam server/src/dh_server/composite.gleam server/test/deckplan_test.gleam docs/deckplan-format.md
git commit -m "feat(deckplan): SW-corner slot digit (#M4)"
```

---

### Task 2: `deckplan.from_rows` — the parse-and-derive path, off the decoder

The bake needs to parse *stamped* rows and re-derive consoles/spawn exactly as the JSON decoder does. Today that logic is trapped inside `decoder()`.

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam` (`decoder` at 522-550)
- Test: `server/test/deckplan_test.gleam`

**Interfaces:**
- Produces: `pub fn deckplan.from_rows(reg: glyphs.Registry, decks: List(#(String, List(String)))) -> Result(DeckPlan, String)`

- [ ] **Step 1: Write the failing test**

Append to `server/test/deckplan_test.gleam`:

```gleam
pub fn from_rows_derives_markers_like_the_decoder_test() {
  // A one-deck plan with a wall-mounted helm and a west-facing docking port.
  let rows = [
    "##########",
    "#h       #",
    "##########",
    "##########",
    "=Q       #",
    "##########",
  ]
  let assert Ok(plan) = deckplan.from_rows(glyphs.default(), [#("Main", rows)])
  let assert Ok(helm) = deckplan.find_console_of_kind(plan, "helm")
  assert helm.x == 0
  assert helm.y == 0
  let assert Ok(dock) = deckplan.find_console_of_kind(plan, "dock")
  assert dock.x == 0
  assert dock.y == 1
  // The west-facing port is the mooring/spawn tile.
  assert plan.spawn_tile == #(0, 1)
}

pub fn from_rows_rejects_a_ragged_deck_test() {
  let assert Error(_) =
    deckplan.from_rows(glyphs.default(), [#("Main", ["###", "# #"])])
}
```

Add `import dh_server/glyphs` to the test file's imports if it is not already there.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd server; gleam test`
Expected: compile error — `from_rows` is not defined.

- [ ] **Step 3: Extract the shared path**

In `deckplan.gleam`, add above `decoder`:

```gleam
/// Build a `DeckPlan` from named raw deck rows — the same parse-and-derive path
/// the JSON decoder runs, exposed so the module overlay bake
/// (`loadout.resolve`) can stamp rows and re-derive consoles, the spawn/mooring
/// tile and docking ports from the STAMPED map rather than the authored hull.
/// That is what keeps "the map is the single source of truth" true after a
/// refit: install a cockpit and the helm console appears because the glyph does.
pub fn from_rows(
  reg: glyphs.Registry,
  decks: List(#(String, List(String))),
) -> Result(DeckPlan, String) {
  use entries <- result.try(
    list.try_map(decks, fn(entry) {
      let #(name, rows) = entry
      case parse_deck_with(reg, name, rows) {
        Ok(g) -> Ok(#(g, rows))
        Error(e) -> Error(e)
      }
    }),
  )
  Ok(plan_from_entries(reg, entries))
}

/// Assemble a plan from already-parsed deck entries, deriving the console list
/// and spawn tile from the raw rows carried alongside each grid.
fn plan_from_entries(
  reg: glyphs.Registry,
  entries: List(#(DeckGrid, List(String))),
) -> DeckPlan {
  let decks = list.map(entries, fn(e) { e.0 })
  let #(consoles, #(spawn_deck, spawn_tile)) = derive_markers(reg, entries)
  DeckPlan(
    decks: decks,
    consoles: consoles,
    spawn_deck: spawn_deck,
    spawn_tile: spawn_tile,
  )
}
```

Add `import gleam/result` to `deckplan.gleam`'s imports.

Then rewrite the body of `decoder` (lines 522-550) to reuse it, keeping the wire overrides:

```gleam
pub fn decoder(reg: glyphs.Registry) -> decode.Decoder(DeckPlan) {
  use entries <- decode.field("decks", decode.list(deck_entry_decoder(reg)))
  use consoles_override <- decode.optional_field(
    "consoles",
    [],
    decode.list(console_decoder()),
  )
  use spawn_override <- decode.optional_field(
    "spawn",
    None,
    decode.optional(spawn_decoder()),
  )
  let derived = plan_from_entries(reg, entries)
  let consoles = case consoles_override {
    [] -> derived.consoles
    _ -> consoles_override
  }
  let #(spawn_deck, spawn_tile) = case spawn_override {
    Some(s) -> s
    None -> #(derived.spawn_deck, derived.spawn_tile)
  }
  decode.success(DeckPlan(
    decks: derived.decks,
    consoles: consoles,
    spawn_deck: spawn_deck,
    spawn_tile: spawn_tile,
  ))
}
```

- [ ] **Step 4: Run the tests**

Run: `cd server; gleam test`
Expected: PASS — the two new tests plus every existing deckplan/shipclass/composite test (the decoder path is unchanged in behaviour).

- [ ] **Step 5: Commit**

```bash
git add server/src/dh_server/deckplan.gleam server/test/deckplan_test.gleam
git commit -m "refactor(deckplan): expose from_rows for the module bake (#M4)"
```

---

### Task 3: The hull document and registry

`server/shipclasses/*.json` becomes a **hull** document: it keeps its deck rows as text (so a refit can re-stamp them), and adds slots, mounts, mass, tag provides and a default loadout. `ShipClass` stays what it is — the *resolved* plan — and gains flight stats.

**Files:**
- Create: `server/src/dh_server/hull.gleam`
- Modify: `server/src/dh_server/shipclass.gleam`
- Test: `server/test/hull_test.gleam`
- Modify: `server/test/shipclass_test.gleam`

**Interfaces:**
- Consumes: `deckplan.from_rows` (Task 2).
- Produces:
  - `hull.Hull`, `hull.Slot(digit: Int, id: String, name: String)`, `hull.Mount(id: String, kind: String, size: String)`
  - `hull.load(path: String) -> Result(Hull, String)`
  - `hull.load_all(dir: String) -> Result(dict.Dict(String, Hull), String)`
  - `hull.slot_by_id(h: Hull, id: String) -> Result(Slot, Nil)`
  - `hull.mount_by_id(h: Hull, id: String) -> Result(Mount, Nil)`
  - `shipclass.Flight(accel: Float, turn_rate: Float)`
  - `shipclass.from_plan(reg, id, name, schema, plan, fallback_capacity, handling, dock_port_orientation, dock_standoff, flight) -> Result(ShipClass, String)`
  - `shipclass.ShipClass` gains field `flight: Flight` (last positional field)

- [ ] **Step 1: Write the failing hull tests**

Create `server/test/hull_test.gleam`:

```gleam
import dh_server/hull
import gleam/dict

const doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 100.0,
  \"provides\": { \"power\": 10, \"engine_mount\": 1 },
  \"slots\": [
    { \"digit\": 1, \"id\": \"cockpit\", \"name\": \"Cockpit\" }
  ],
  \"mounts\": [
    { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" }
  ],
  \"default_loadout\": {
    \"modules\": { \"cockpit\": \"testhull.cockpit.stock\" },
    \"parts\": { \"engine_center\": \"test.engine\" }
  },
  \"decks\": [
    { \"name\": \"Main\", \"grid\": [\"###\", \"# #\", \"1##\"] }
  ],
  \"cargo\": { \"capacity\": 4, \"handling\": \"breakbulk\" }
}"

pub fn decode_hull_document_test() {
  let assert Ok(h) = hull.decode(doc)
  assert h.id == "testhull"
  assert h.mass == 100.0
  assert dict.get(h.provides, "power") == Ok(10)
  // Deck rows are kept as TEXT — the refit bake re-stamps them.
  assert h.decks == [#("Main", ["###", "# #", "1##"])]
  assert h.default_modules == [#("cockpit", "testhull.cockpit.stock")]
  assert h.default_parts == [#("engine_center", "test.engine")]
}

pub fn slot_lookup_test() {
  let assert Ok(h) = hull.decode(doc)
  let assert Ok(slot) = hull.slot_by_id(h, "cockpit")
  assert slot.digit == 1
  assert hull.slot_by_id(h, "nope") == Error(Nil)
}

pub fn mount_lookup_test() {
  let assert Ok(h) = hull.decode(doc)
  let assert Ok(mount) = hull.mount_by_id(h, "engine_center")
  assert mount.kind == "engine"
  assert mount.size == "m"
}

pub fn duplicate_slot_digit_is_rejected_test() {
  let bad =
    "{ \"schema\": 3, \"id\": \"h\", \"name\": \"H\", \"mass\": 1.0,
       \"slots\": [ { \"digit\": 1, \"id\": \"a\", \"name\": \"A\" },
                    { \"digit\": 1, \"id\": \"b\", \"name\": \"B\" } ],
       \"decks\": [ { \"name\": \"M\", \"grid\": [\"###\", \"# #\", \"###\"] } ],
       \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" } }"
  let assert Error(_) = hull.decode(bad)
}

pub fn load_all_indexes_by_id_test() {
  let assert Ok(hulls) = hull.load_all("shipclasses")
  let assert Ok(mb) = dict.get(hulls, "mockingbird")
  assert mb.name == "Mockingbird"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: compile error — module `dh_server/hull` does not exist.

- [ ] **Step 3: Write `hull.gleam`**

Create `server/src/dh_server/hull.gleam`:

```gleam
//// The authored HULL document (`server/shipclasses/*.json`, schema 3): a
//// hull's deck plan kept as raw 3x3 TEXT rows, the slot regions modules may
//// overlay, the exterior mount points parts hang on, its dry mass and the
//// capability tags it supplies for free, plus the default loadout it ships
//// with. See `docs/modules.md`.
////
//// A hull is not directly flyable: `loadout.resolve` stamps its default (or a
//// player's) modules into these rows and re-parses the result into a
//// `shipclass.ShipClass` — the resolved plan the sim, the composite and the
//// wire all speak. Rows are kept as text precisely so a refit can re-stamp
//// from the authored map rather than trying to un-stamp the previous fit.

import dh_server/shipclass.{type Handling}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// One modulable interior region. `digit` is the hex digit hull tiles carry in
/// their SW corner (`docs/deckplan-format.md`, "Slots"); `id` is what a module
/// names in its `slot` field.
pub type Slot {
  Slot(digit: Int, id: String, name: String)
}

/// One exterior attach point. `kind` gates what can hang there ("engine"),
/// `size` is the ordered scale `"s" | "m" | "l"` — a mount takes any part of
/// its kind up to its size. Mount GEOMETRY (sprite-space position/rotation)
/// lands with client-side part layering in M4 iteration 2; a mount is
/// currently a capability slot only.
pub type Mount {
  Mount(id: String, kind: String, size: String)
}

pub type Hull {
  Hull(
    schema: Int,
    id: String,
    name: String,
    /// Authored decks as `#(name, rows)` — raw 3x3 text, not parsed cells.
    decks: List(#(String, List(String))),
    slots: List(Slot),
    mounts: List(Mount),
    /// Dry structural mass. Total mass = this + every fitted module and part.
    mass: Float,
    /// Capability tags the bare hull supplies (its built-in reactor's `power`,
    /// for instance) — pooled with every module's and part's `provides`.
    provides: Dict(String, Int),
    /// Capability tags the bare hull demands — `{"engine": 1}` is how a hull
    /// says it will not fly without an engine mounted.
    requires: Dict(String, Int),
    /// Hold capacity used ONLY when the resolved plan draws no pallet tiles.
    fallback_capacity: Int,
    handling: Handling,
    dock_port_orientation: Float,
    dock_standoff: Float,
    /// slot id -> module id.
    default_modules: List(#(String, String)),
    /// mount id -> part id.
    default_parts: List(#(String, String)),
  )
}

/// Read and decode a hull document from a file.
pub fn load(path: String) -> Result(Hull, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read hull file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Every `*.json` in `dir`, indexed by hull id. A duplicate id is an error
/// rather than a silent last-one-wins.
pub fn load_all(dir: String) -> Result(Dict(String, Hull), String) {
  use names <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "failed to list hull directory " <> dir <> ": " <> string.inspect(err)
    }),
  )
  names
  |> list.filter(fn(n) { string.ends_with(n, ".json") })
  |> list.sort(string.compare)
  |> list.try_fold(dict.new(), fn(acc, name) {
    use h <- result.try(load(dir <> "/" <> name))
    case dict.has_key(acc, h.id) {
      True -> Error("duplicate hull id \"" <> h.id <> "\" in " <> dir)
      False -> Ok(dict.insert(acc, h.id, h))
    }
  })
}

/// Decode a hull document from JSON text.
pub fn decode(json_text: String) -> Result(Hull, String) {
  case json.parse(json_text, hull_decoder()) {
    Ok(h) -> validate(h)
    Error(err) -> Error("invalid hull document: " <> string.inspect(err))
  }
}

/// The slot with this id, or `Error(Nil)`.
pub fn slot_by_id(h: Hull, id: String) -> Result(Slot, Nil) {
  list.find(h.slots, fn(s) { s.id == id })
}

/// The mount with this id, or `Error(Nil)`.
pub fn mount_by_id(h: Hull, id: String) -> Result(Mount, Nil) {
  list.find(h.mounts, fn(m) { m.id == id })
}

fn validate(h: Hull) -> Result(Hull, String) {
  let digits = list.map(h.slots, fn(s) { s.digit })
  let ids = list.map(h.slots, fn(s) { s.id })
  case list.length(list.unique(digits)) == list.length(digits) {
    False -> Error("hull \"" <> h.id <> "\" has duplicate slot digits")
    True ->
      case list.length(list.unique(ids)) == list.length(ids) {
        False -> Error("hull \"" <> h.id <> "\" has duplicate slot ids")
        True ->
          case list.all(digits, fn(d) { d >= 0 && d <= 15 }) {
            False -> Error("hull \"" <> h.id <> "\" has a slot digit outside 0-15")
            True ->
              case h.mass >. 0.0 {
                False -> Error("hull \"" <> h.id <> "\" must have mass > 0")
                True -> Ok(h)
              }
          }
      }
  }
}

fn hull_decoder() -> decode.Decoder(Hull) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use decks <- decode.field("decks", decode.list(deck_decoder()))
  use slots <- decode.optional_field("slots", [], decode.list(slot_decoder()))
  use mounts <- decode.optional_field("mounts", [], decode.list(mount_decoder()))
  use mass <- decode.optional_field("mass", 100.0, decode.float)
  use provides <- decode.optional_field("provides", dict.new(), tags_decoder())
  use requires <- decode.optional_field("requires", dict.new(), tags_decoder())
  use cargo <- decode.field("cargo", cargo_decoder())
  use dock_port_orientation <- decode.optional_field(
    "dock_port_orientation",
    shipclass.default_dock_port_orientation_deg,
    decode.float,
  )
  use dock_standoff <- decode.optional_field(
    "dock_standoff",
    shipclass.default_dock_standoff,
    decode.float,
  )
  use loadout <- decode.optional_field(
    "default_loadout",
    #([], []),
    default_loadout_decoder(),
  )
  let #(capacity, handling) = cargo
  let #(default_modules, default_parts) = loadout
  decode.success(Hull(
    schema: schema,
    id: id,
    name: name,
    decks: decks,
    slots: slots,
    mounts: mounts,
    mass: mass,
    provides: provides,
    requires: requires,
    fallback_capacity: capacity,
    handling: handling,
    dock_port_orientation: dock_port_orientation,
    dock_standoff: dock_standoff,
    default_modules: default_modules,
    default_parts: default_parts,
  ))
}

fn deck_decoder() -> decode.Decoder(#(String, List(String))) {
  use name <- decode.field("name", decode.string)
  use grid <- decode.field("grid", decode.list(decode.string))
  decode.success(#(name, grid))
}

fn slot_decoder() -> decode.Decoder(Slot) {
  use digit <- decode.field("digit", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(Slot(digit: digit, id: id, name: name))
}

fn mount_decoder() -> decode.Decoder(Mount) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use size <- decode.field("size", decode.string)
  decode.success(Mount(id: id, kind: kind, size: size))
}

/// A `{tag: amount}` object. Tags are open strings the engine only compares
/// and sums, so new content invents new tags with zero code.
pub fn tags_decoder() -> decode.Decoder(Dict(String, Int)) {
  decode.dict(decode.string, decode.int)
}

fn cargo_decoder() -> decode.Decoder(#(Int, Handling)) {
  use capacity <- decode.field("capacity", decode.int)
  use handling <- decode.field("handling", shipclass.handling_decoder())
  decode.success(#(capacity, handling))
}

fn default_loadout_decoder() -> decode.Decoder(
  #(List(#(String, String)), List(#(String, String))),
) {
  use modules <- decode.optional_field(
    "modules",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use parts <- decode.optional_field(
    "parts",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  decode.success(#(sorted_pairs(modules), sorted_pairs(parts)))
}

/// A `Dict` in id order — JSON objects have no order, and a loadout that
/// stamps in a different order every boot would be a nightmare to debug.
fn sorted_pairs(d: Dict(String, String)) -> List(#(String, String)) {
  dict.to_list(d) |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// Unused-import guard: `int` is imported for future error formatting.
/// Delete this line and the `gleam/int` import if the compiler warns.
const _unused = 0
```

Note for the implementer: delete the trailing `_unused` const and the `gleam/int` import if the Gleam compiler reports them unused — the codebase builds warning-clean.

- [ ] **Step 4: Add `Flight` and `from_plan` to `shipclass.gleam`, make `handling_decoder` public**

In `server/src/dh_server/shipclass.gleam`:

Change the module doc comment's first paragraph to:

```gleam
//// A ship class is a hull's RESOLVED deck plan (schema 3) — what a specific
//// ship actually is once its loadout has been stamped onto its hull
//// (`loadout.resolve`, `docs/modules.md`) — plus the cargo characteristics M3
//// trading needs and the flight stats M4 moved out of `ship.gleam`'s
//// constants. The authored hull document lives in `hull.gleam`; this type is
//// the bake's OUTPUT, and the whole document is sent verbatim to clients as
//// `ship_class` in the `welcome` message, so `encode` round-trips exactly what
//// was resolved. Angles are degrees throughout.
```

Add the flight type above `ShipClass`:

```gleam
/// A resolved hull's flight performance, derived from the loadout: total
/// thrust and torque of the mounted engine parts divided by the fit's total
/// mass (`loadout.resolve`). These replaced `ship.main_accel` /
/// `ship.turn_rate`, which were global constants until M4.
pub type Flight {
  Flight(
    /// Acceleration at full thrust, u/s^2, along the ship's heading.
    accel: Float,
    /// Turn rate at full rotate input, DEGREES/s.
    turn_rate: Float,
  )
}
```

Add `flight: Flight` as the last field of `ShipClass`:

```gleam
    dock_standoff: Float,
    /// Flight performance derived from the fitted engine parts and the fit's
    /// total mass — data now, not constants.
    flight: Flight,
  )
}
```

**Keep `load` / `load_with` for now.** They are the path `dh_server` and `sim` still use, and this task must leave the suite green — Task 7 deletes them once every ship resolves through a fit. They just need a `Flight` to build a `ShipClass` with, so add above them:

```gleam
/// TEMPORARY (deleted in the sim-rewiring task): the pre-M4 global flight
/// constants, so the old `load` path keeps producing a flyable class while the
/// hull/loadout machinery lands around it. Real flight stats come from the
/// fitted engine parts (`loadout.resolve`).
const default_shim_flight = Flight(accel: 40.0, turn_rate: 180.0)
```

and pass `flight: default_shim_flight` in the `ShipClass(...)` that `ship_class_decoder` builds when no `flight` field is present (the `decode.optional_field` default below does exactly this).

Add the constructor:

```gleam
/// Build a resolved class from a baked plan. This is the bake's exit: the plan
/// has already been stamped and re-parsed, so consoles, the mooring tile and
/// the pallet-derived hold capacity all come from the RESOLVED map. Validates
/// the same invariants an authored class always had (geometry, void-facing
/// dock doors, a helm) — which is what makes a cockpit-less loadout illegal.
pub fn from_plan(
  reg: Registry,
  id: String,
  name: String,
  schema: Int,
  plan: DeckPlan,
  fallback_capacity: Int,
  handling: Handling,
  dock_port_orientation: Float,
  dock_standoff: Float,
  flight: Flight,
) -> Result(ShipClass, String) {
  let derived = deckplan.pallet_count(plan, reg)
  let capacity = case derived > 0 {
    True -> derived
    False -> fallback_capacity
  }
  validate(ShipClass(
    schema: schema,
    id: id,
    name: name,
    plan: plan,
    cargo_capacity: capacity,
    handling: handling,
    dock_port_orientation: dock_port_orientation,
    dock_standoff: dock_standoff,
    flight: flight,
  ))
}
```

Make the handling decoder public (hull decodes the same `cargo` block) by changing `fn handling_decoder()` to `pub fn handling_decoder()`.

Extend `encode` so the wire carries flight — append to the third list:

```gleam
      #("cargo", encode_cargo(class)),
      #("dock_port_orientation", json.float(class.dock_port_orientation)),
      #("dock_standoff", json.float(class.dock_standoff)),
      #(
        "flight",
        json.object([
          #("accel", json.float(class.flight.accel)),
          #("turn_rate", json.float(class.flight.turn_rate)),
        ]),
      ),
```

And in `ship_class_decoder`, decode it back (the round-trip test depends on it):

```gleam
  use flight <- decode.optional_field(
    "flight",
    default_shim_flight,
    flight_decoder(),
  )
```

with

```gleam
fn flight_decoder() -> decode.Decoder(Flight) {
  use accel <- decode.field("accel", decode.float)
  use turn_rate <- decode.field("turn_rate", decode.float)
  decode.success(Flight(accel: accel, turn_rate: turn_rate))
}
```

and pass `flight: flight` into the `ShipClass(...)` it builds.

- [ ] **Step 5: Add the `from_plan` tests**

`shipclass_test.gleam`'s existing cases keep working — the `load` shim is still there — so this step only ADDS coverage for the new constructor. Task 7 retrains the file once the shim goes. Append:

```gleam
pub fn from_plan_derives_capacity_from_pallets_test() {
  let reg = glyphs.default()
  let rows = [
    "#h#######",
    "#       #",
    "#########",
    "#########",
    "=Q     p#",
    "#########",
  ]
  let assert Ok(plan) = deckplan.from_rows(reg, [#("Main", rows)])
  let assert Ok(c) =
    shipclass.from_plan(
      reg,
      "testhull",
      "Test Hull",
      3,
      plan,
      7,
      shipclass.BreakBulk,
      90.0,
      20.0,
      shipclass.Flight(accel: 40.0, turn_rate: 180.0),
    )
  // The single `p` tile on the map beats the authored fallback of 7.
  assert c.cargo_capacity == 1
  assert c.flight.accel == 40.0
}

pub fn from_plan_requires_a_helm_test() {
  let reg = glyphs.default()
  let assert Ok(plan) =
    deckplan.from_rows(reg, [
      #("Main", ["#########", "#       #", "#########"]),
    ])
  let assert Error(e) =
    shipclass.from_plan(
      reg,
      "h",
      "H",
      3,
      plan,
      0,
      shipclass.BreakBulk,
      90.0,
      20.0,
      shipclass.Flight(accel: 1.0, turn_rate: 1.0),
    )
  // This is what makes a cockpit-less loadout illegal: the resolved map has to
  // carry a helm, and a module supplies it by drawing the glyph.
  assert e == "no console of kind \"helm\""
}
```

Add `import dh_server/glyphs` to the file if it is not already there.

- [ ] **Step 6: Run the tests**

Run: `cd server; gleam test`
Expected: PASS, whole suite — every `hull_test` case plus the untouched existing suites. Keeping the `load` shim is what buys that: `sim`, `dh_server` and `protocol` still compile against the same API they always used.

- [ ] **Step 7: Commit**

```bash
git add server/src/dh_server/hull.gleam server/src/dh_server/shipclass.gleam server/test/hull_test.gleam server/test/shipclass_test.gleam
git commit -m "feat(hull): authored hull document + registry; ShipClass gains flight (#M4)"
```

---

### Task 4: Module and part documents

**Files:**
- Create: `server/src/dh_server/module.gleam`
- Create: `server/src/dh_server/part.gleam`
- Test: `server/test/module_test.gleam`

**Interfaces:**
- Consumes: `hull.tags_decoder`.
- Produces:
  - `module.Patch(deck: Int, x: Int, y: Int, rows: List(String))`
  - `module.Module(schema, id, hull, slot, name, mass, provides, requires, patches)`
  - `module.load_all(dir: String) -> Result(dict.Dict(String, Module), String)` — walks one level of per-hull subdirectories
  - `part.Part(schema, id, name, kind, size, mass, provides, requires, thrust, torque, sprite)`
  - `part.load_all(dir: String) -> Result(dict.Dict(String, Part), String)`
  - `part.size_rank(size: String) -> Result(Int, Nil)` — `"s"`→0, `"m"`→1, `"l"`→2

- [ ] **Step 1: Write the failing tests**

Create `server/test/module_test.gleam`:

```gleam
import dh_server/module
import dh_server/part
import gleam/dict

const module_doc = "{
  \"schema\": 1,
  \"id\": \"testhull.cockpit.stock\",
  \"hull\": \"testhull\",
  \"slot\": \"cockpit\",
  \"name\": \"Stock cockpit\",
  \"mass\": 4.0,
  \"provides\": { \"seats\": 1 },
  \"requires\": { \"power\": 2 },
  \"patches\": [
    { \"deck\": 0, \"x\": 6, \"y\": 3, \"grid\": [\"#h#\", \"#e \", \"## \"] }
  ]
}"

pub fn decode_module_document_test() {
  let assert Ok(m) = module.decode(module_doc)
  assert m.id == "testhull.cockpit.stock"
  assert m.hull == "testhull"
  assert m.slot == "cockpit"
  assert m.mass == 4.0
  assert dict.get(m.requires, "power") == Ok(2)
  let assert [p] = m.patches
  assert p.deck == 0
  assert p.x == 6
  assert p.y == 3
  assert p.rows == ["#h#", "#e ", "## "]
}

pub fn ragged_patch_is_rejected_test() {
  let bad = "{ \"schema\": 1, \"id\": \"a\", \"hull\": \"h\", \"slot\": \"s\",
    \"name\": \"A\", \"mass\": 1.0,
    \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 0, \"grid\": [\"###\", \"# #\"] } ] }"
  let assert Error(_) = module.decode(bad)
}

const part_doc = "{
  \"schema\": 1,
  \"id\": \"test.engine\",
  \"name\": \"Test engine\",
  \"kind\": \"engine\",
  \"size\": \"m\",
  \"mass\": 0.0,
  \"provides\": { \"engine\": 1 },
  \"requires\": { \"power\": 3 },
  \"thrust\": 4800.0,
  \"torque\": 21600.0,
  \"sprite\": \"engine_consol\"
}"

pub fn decode_part_document_test() {
  let assert Ok(p) = part.decode(part_doc)
  assert p.kind == "engine"
  assert p.size == "m"
  assert p.thrust == 4800.0
  assert p.torque == 21600.0
  assert dict.get(p.provides, "engine") == Ok(1)
}

pub fn size_rank_orders_the_scale_test() {
  assert part.size_rank("s") == Ok(0)
  assert part.size_rank("m") == Ok(1)
  assert part.size_rank("l") == Ok(2)
  assert part.size_rank("xl") == Error(Nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: compile error — modules `dh_server/module` and `dh_server/part` do not exist.

- [ ] **Step 3: Write `module.gleam`**

Create `server/src/dh_server/module.gleam`:

```gleam
//// An interior MODULE: a per-(hull, slot) hand-authored overlay, drawn in the
//// same 3x3-per-cell ASCII the hull itself uses (`docs/deckplan-format.md`).
//// Installing it stamps its patches onto the hull's rows, where **a void cell
//// leaves the hull untouched and any other cell overwrites it**
//// (`docs/modules.md`). Because the overlay is drawn against one specific
//// hull's coordinate space, shape-matching never happens: the doors line up
//// because a human drew them lining up, and loadout validation never does
//// reachability analysis.

import dh_server/hull
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// One rectangle of overlay, `rows` in the 3x3 block format, with its top-left
/// TILE (not character) position on deck `deck` of the hull.
pub type Patch {
  Patch(deck: Int, x: Int, y: Int, rows: List(String))
}

pub type Module {
  Module(
    schema: Int,
    id: String,
    /// The hull id this overlay is drawn for. A module is never portable
    /// between hulls — that is the whole trade the design makes.
    hull: String,
    /// The hull slot id it occupies.
    slot: String,
    name: String,
    mass: Float,
    provides: Dict(String, Int),
    requires: Dict(String, Int),
    patches: List(Patch),
  )
}

/// Read and decode one module document.
pub fn load(path: String) -> Result(Module, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read module file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Every module under `dir`, indexed by id. Modules are filed per hull
/// (`server/modules/<hull>/<id>.json`), so this walks one level of
/// subdirectories as well as any loose files.
pub fn load_all(dir: String) -> Result(Dict(String, Module), String) {
  use entries <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "failed to list module directory " <> dir <> ": " <> string.inspect(err)
    }),
  )
  let sorted = list.sort(entries, string.compare)
  use files <- result.try(
    list.try_fold(sorted, [], fn(acc, entry) {
      let path = dir <> "/" <> entry
      case string.ends_with(entry, ".json") {
        True -> Ok(list.append(acc, [path]))
        False ->
          case simplifile.read_directory(path) {
            // Not a directory (or unreadable): skip it rather than fail the
            // whole registry on a stray file.
            Error(_) -> Ok(acc)
            Ok(inner) ->
              Ok(
                list.append(
                  acc,
                  inner
                    |> list.filter(fn(n) { string.ends_with(n, ".json") })
                    |> list.sort(string.compare)
                    |> list.map(fn(n) { path <> "/" <> n }),
                ),
              )
          }
      }
    }),
  )
  list.try_fold(files, dict.new(), fn(acc, path) {
    use m <- result.try(load(path))
    case dict.has_key(acc, m.id) {
      True -> Error("duplicate module id \"" <> m.id <> "\" at " <> path)
      False -> Ok(dict.insert(acc, m.id, m))
    }
  })
}

/// Decode a module document from JSON text.
pub fn decode(json_text: String) -> Result(Module, String) {
  case json.parse(json_text, module_decoder()) {
    Ok(m) -> validate(m)
    Error(err) -> Error("invalid module document: " <> string.inspect(err))
  }
}

fn validate(m: Module) -> Result(Module, String) {
  list.try_fold(m.patches, m, fn(_, p) {
    let count = list.length(p.rows)
    let lengths = list.map(p.rows, string.length)
    let ok =
      count > 0
      && count % 3 == 0
      && list.all(lengths, fn(l) { l > 0 && l % 3 == 0 })
      && list.length(list.unique(lengths)) == 1
    case ok, p.deck >= 0 && p.x >= 0 && p.y >= 0 {
      True, True -> Ok(m)
      _, _ ->
        Error(
          "module \""
          <> m.id
          <> "\" has a patch that is not a positive multiple of 3 in both "
          <> "dimensions with a non-negative origin",
        )
    }
  })
}

fn module_decoder() -> decode.Decoder(Module) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use hull_id <- decode.field("hull", decode.string)
  use slot <- decode.field("slot", decode.string)
  use name <- decode.field("name", decode.string)
  use mass <- decode.optional_field("mass", 0.0, decode.float)
  use provides <- decode.optional_field("provides", dict.new(), hull.tags_decoder())
  use requires <- decode.optional_field("requires", dict.new(), hull.tags_decoder())
  use patches <- decode.optional_field("patches", [], decode.list(patch_decoder()))
  decode.success(Module(
    schema: schema,
    id: id,
    hull: hull_id,
    slot: slot,
    name: name,
    mass: mass,
    provides: provides,
    requires: requires,
    patches: patches,
  ))
}

fn patch_decoder() -> decode.Decoder(Patch) {
  use deck <- decode.field("deck", decode.int)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  use rows <- decode.field("grid", decode.list(decode.string))
  decode.success(Patch(deck: deck, x: x, y: y, rows: rows))
}
```

- [ ] **Step 4: Write `part.gleam`**

Create `server/src/dh_server/part.gleam`:

```gleam
//// An exterior PART: the shared, cross-hull half of the loadout. A part hangs
//// on a hull mount point of matching `kind` and sufficient `size`, contributes
//// its mass and its capability tags, and — for engines — carries the thrust and
//// torque that used to be global constants in `ship.gleam` (`docs/modules.md`).
////
//// Parts are shared across hulls by design: the Rijay nacelle the Mockingbird
//// mounts is the same document the Finch mounts. `sprite` is the client's key
//// for layering the part onto the hull at its mount; the layering itself lands
//// in M4 iteration 2, and until then the client draws the whole-hull bake.

import dh_server/hull
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

pub type Part {
  Part(
    schema: Int,
    id: String,
    name: String,
    /// What sort of mount takes it — "engine" for now.
    kind: String,
    /// The ordered scale "s" | "m" | "l".
    size: String,
    mass: Float,
    provides: Dict(String, Int),
    requires: Dict(String, Int),
    /// Force along the heading; 0 for a non-engine part. Divided by the fit's
    /// total mass to give acceleration.
    thrust: Float,
    /// Turning authority; divided by total mass to give degrees/s.
    torque: Float,
    sprite: Option(String),
  )
}

/// Read and decode one part document.
pub fn load(path: String) -> Result(Part, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read part file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Every `*.json` in `dir`, indexed by part id.
pub fn load_all(dir: String) -> Result(Dict(String, Part), String) {
  use names <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "failed to list part directory " <> dir <> ": " <> string.inspect(err)
    }),
  )
  names
  |> list.filter(fn(n) { string.ends_with(n, ".json") })
  |> list.sort(string.compare)
  |> list.try_fold(dict.new(), fn(acc, name) {
    use p <- result.try(load(dir <> "/" <> name))
    case dict.has_key(acc, p.id) {
      True -> Error("duplicate part id \"" <> p.id <> "\" in " <> dir)
      False -> Ok(dict.insert(acc, p.id, p))
    }
  })
}

/// Decode a part document from JSON text.
pub fn decode(json_text: String) -> Result(Part, String) {
  case json.parse(json_text, part_decoder()) {
    Ok(p) ->
      case size_rank(p.size) {
        Ok(_) -> Ok(p)
        Error(Nil) ->
          Error("part \"" <> p.id <> "\" has size outside \"s\"|\"m\"|\"l\"")
      }
    Error(err) -> Error("invalid part document: " <> string.inspect(err))
  }
}

/// The size scale as an ordering: a mount takes any part of its kind whose
/// rank is at most the mount's.
pub fn size_rank(size: String) -> Result(Int, Nil) {
  case size {
    "s" -> Ok(0)
    "m" -> Ok(1)
    "l" -> Ok(2)
    _ -> Error(Nil)
  }
}

fn part_decoder() -> decode.Decoder(Part) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.string)
  use size <- decode.field("size", decode.string)
  use mass <- decode.optional_field("mass", 0.0, decode.float)
  use provides <- decode.optional_field("provides", dict.new(), hull.tags_decoder())
  use requires <- decode.optional_field("requires", dict.new(), hull.tags_decoder())
  use thrust <- decode.optional_field("thrust", 0.0, decode.float)
  use torque <- decode.optional_field("torque", 0.0, decode.float)
  use sprite <- decode.optional_field(
    "sprite",
    None,
    decode.map(decode.string, Some),
  )
  decode.success(Part(
    schema: schema,
    id: id,
    name: name,
    kind: kind,
    size: size,
    mass: mass,
    provides: provides,
    requires: requires,
    thrust: thrust,
    torque: torque,
    sprite: sprite,
  ))
}
```

- [ ] **Step 5: Run the tests**

Run: `cd server; gleam test`
Expected: PASS, whole suite — the new documents are additive and nothing else references them yet.

- [ ] **Step 6: Commit**

```bash
git add server/src/dh_server/module.gleam server/src/dh_server/part.gleam server/test/module_test.gleam
git commit -m "feat(modules): interior module + exterior part documents (#M4)"
```

---

### Task 5: `loadout.gleam` — the stamp, the validator, the bake

The heart of the milestone. Everything here is pure: hull + registries + loadout in, a resolved `Fit` or a reason string out.

**Files:**
- Create: `server/src/dh_server/loadout.gleam`
- Test: `server/test/loadout_test.gleam`

**Interfaces:**
- Consumes: `hull.Hull`, `module.Module`, `part.Part`, `deckplan.from_rows`, `shipclass.from_plan`.
- Produces:
  - `loadout.Loadout(hull: String, modules: List(#(String, String)), parts: List(#(String, String)))`
  - `loadout.Fit(loadout: Loadout, class: shipclass.ShipClass, mass: Float)`
  - `loadout.default_for(h: hull.Hull) -> Loadout`
  - `loadout.resolve(reg, h, modules, parts, lo) -> Result(Fit, String)`

- [ ] **Step 1: Write the failing tests**

Create `server/test/loadout_test.gleam`:

```gleam
import dh_server/deckplan
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/list
import gleam/option

// A 4x3-tile hull: a fixed corridor row on top, a two-tile slot-1 bay below.
// The bay's tiles carry SW digit "1"; the corridor tile above the bay leaves
// its south edge OPEN so a module can put a door there.
const hull_doc = "{
  \"schema\": 3,
  \"id\": \"testhull\",
  \"name\": \"Test Hull\",
  \"mass\": 96.0,
  \"provides\": { \"power\": 10 },
  \"requires\": { \"engine\": 1 },
  \"slots\": [ { \"digit\": 1, \"id\": \"bay\", \"name\": \"Bay\" } ],
  \"mounts\": [ { \"id\": \"engine_center\", \"kind\": \"engine\", \"size\": \"m\" } ],
  \"cargo\": { \"capacity\": 0, \"handling\": \"breakbulk\" },
  \"decks\": [ { \"name\": \"Main\", \"grid\": [
    \"############\",
    \"#h  Q      #\",
    \"##         #\",
    \"##         #\",
    \"#          #\",
    \"1##1##1##1##\"
  ] } ]
}"

fn a_hull() -> hull.Hull {
  let assert Ok(h) = hull.decode(hull_doc)
  h
}

fn a_module(id: String, mass: String, requires: String, grid: String) -> module.Module {
  let assert Ok(m) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"" <> id <> "\", \"hull\": \"testhull\",
         \"slot\": \"bay\", \"name\": \"M\", \"mass\": " <> mass <> ",
         \"requires\": " <> requires <> ",
         \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 1, \"grid\": " <> grid <> " } ] }",
    )
  m
}

fn an_engine() -> part.Part {
  let assert Ok(p) =
    part.decode(
      "{ \"schema\": 1, \"id\": \"test.engine\", \"name\": \"E\",
         \"kind\": \"engine\", \"size\": \"m\", \"mass\": 24.0,
         \"provides\": { \"engine\": 1 }, \"requires\": { \"power\": 3 },
         \"thrust\": 4800.0, \"torque\": 21600.0 }",
    )
  p
}

fn registries(
  mods: List(module.Module),
) -> #(dict.Dict(String, module.Module), dict.Dict(String, part.Part)) {
  let by_id = dict.from_list(list.map(mods, fn(m) { #(m.id, m) }))
  #(by_id, dict.from_list([#("test.engine", an_engine())]))
}

fn fit_of(mods: List(module.Module), lo: loadout.Loadout) {
  let #(m, p) = registries(mods)
  loadout.resolve(glyphs.default(), a_hull(), m, p, lo)
}

fn bay_loadout(module_id: String) -> loadout.Loadout {
  loadout.Loadout(
    hull: "testhull",
    modules: [#("bay", module_id)],
    parts: [#("engine_center", "test.engine")],
  )
}

pub fn void_cells_pass_through_test() {
  // A patch whose left tile is void and right tile is a pallet: the hull's
  // left bay tile survives untouched, the right one becomes a pallet.
  let m = a_module("m.void", "0.0", "{}", "[\"   \", \" . \", \"   \", \"   \", \" p \", \"   \"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.void"))
  let assert Ok(g) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(left) = deckplan.cell_at_xy(g, 0, 1)
  let assert Ok(right) = deckplan.cell_at_xy(g, 0, 2)
  assert left.decor == option.None
  assert right.decor == option.Some("p")
}

pub fn stamp_preserves_the_hull_slot_digit_test() {
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.p"))
  let assert Ok(g) = deckplan.deck_at(fit.class.plan, 0)
  let assert Ok(c) = deckplan.cell_at_xy(g, 0, 1)
  // SW corner is hull-owned: the tile is still in slot 1 after the stamp.
  assert c.slot == option.Some(1)
}

pub fn derived_capacity_follows_the_stamp_test() {
  let empty = a_module("m.empty", "0.0", "{}", "[\"   \", \"   \", \"   \"]")
  let pallets = a_module("m.pallets", "0.0", "{}", "[\"      \", \" p  p \", \"      \"]")
  let assert Ok(a) = fit_of([empty, pallets], bay_loadout("m.empty"))
  let assert Ok(b) = fit_of([empty, pallets], bay_loadout("m.pallets"))
  assert a.class.cargo_capacity == 0
  assert b.class.cargo_capacity == 2
}

pub fn flight_is_thrust_over_total_mass_test() {
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let assert Ok(fit) = fit_of([m], bay_loadout("m.p"))
  // hull 96 + module 0 + engine 24 = 120; 4800/120 = 40, 21600/120 = 180.
  assert fit.mass == 120.0
  assert fit.class.flight.accel == 40.0
  assert fit.class.flight.turn_rate == 180.0
}

pub fn heavier_module_is_slower_test() {
  let light = a_module("m.light", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let heavy = a_module("m.heavy", "40.0", "{}", "[\"   \", \" p \", \"   \"]")
  let assert Ok(a) = fit_of([light, heavy], bay_loadout("m.light"))
  let assert Ok(b) = fit_of([light, heavy], bay_loadout("m.heavy"))
  assert b.class.flight.accel <. a.class.flight.accel
}

pub fn out_of_slot_bounds_is_rejected_test() {
  // y=0 is the fixed corridor row, not slot 1.
  let assert Ok(m) =
    module.decode(
      "{ \"schema\": 1, \"id\": \"m.trespass\", \"hull\": \"testhull\",
         \"slot\": \"bay\", \"name\": \"M\",
         \"patches\": [ { \"deck\": 0, \"x\": 0, \"y\": 0, \"grid\": [\"   \", \" p \", \"   \"] } ] }",
    )
  let assert Error(e) = fit_of([m], bay_loadout("m.trespass"))
  assert e == "out_of_slot_bounds:m.trespass"
}

pub fn tag_deficit_is_rejected_test() {
  let hog = a_module("m.hog", "0.0", "{ \"power\": 99 }", "[\"   \", \" p \", \"   \"]")
  let assert Error(e) = fit_of([hog], bay_loadout("m.hog"))
  assert e == "tag_deficit:power"
}

pub fn missing_engine_is_rejected_test() {
  // The hull requires {"engine": 1} and nothing provides it.
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let bare = loadout.Loadout(hull: "testhull", modules: [#("bay", "m.p")], parts: [])
  let #(mods, parts) = registries([m])
  let assert Error(e) = loadout.resolve(glyphs.default(), a_hull(), mods, parts, bare)
  assert e == "tag_deficit:engine"
}

pub fn unknown_slot_and_module_are_rejected_test() {
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let #(mods, parts) = registries([m])
  let bad_slot =
    loadout.Loadout(hull: "testhull", modules: [#("nope", "m.p")], parts: [])
  let assert Error(a) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, bad_slot)
  assert a == "slot_not_on_hull:nope"
  let bad_module =
    loadout.Loadout(hull: "testhull", modules: [#("bay", "m.nope")], parts: [])
  let assert Error(b) =
    loadout.resolve(glyphs.default(), a_hull(), mods, parts, bad_module)
  assert b == "unknown_module:m.nope"
}

pub fn two_modules_in_one_slot_are_rejected_test() {
  let a = a_module("m.a", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let b = a_module("m.b", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let lo =
    loadout.Loadout(
      hull: "testhull",
      modules: [#("bay", "m.a"), #("bay", "m.b")],
      parts: [#("engine_center", "test.engine")],
    )
  let assert Error(e) = fit_of([a, b], lo)
  assert e == "duplicate_slot:bay"
}

pub fn oversized_part_is_rejected_test() {
  let assert Ok(big) =
    part.decode(
      "{ \"schema\": 1, \"id\": \"test.bigengine\", \"name\": \"E\",
         \"kind\": \"engine\", \"size\": \"l\", \"mass\": 1.0,
         \"provides\": { \"engine\": 1 }, \"thrust\": 1.0, \"torque\": 1.0 }",
    )
  let m = a_module("m.p", "0.0", "{}", "[\"   \", \" p \", \"   \"]")
  let #(mods, _) = registries([m])
  let parts = dict.from_list([#("test.bigengine", big)])
  let lo =
    loadout.Loadout(
      hull: "testhull",
      modules: [#("bay", "m.p")],
      parts: [#("engine_center", "test.bigengine")],
    )
  let assert Error(e) = loadout.resolve(glyphs.default(), a_hull(), mods, parts, lo)
  assert e == "mount_too_small:engine_center"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: compile error — module `dh_server/loadout` does not exist.

- [ ] **Step 3: Write `loadout.gleam`**

Create `server/src/dh_server/loadout.gleam`:

```gleam
//// LOADOUTS: which interior module sits in each of a hull's slots and which
//// exterior part hangs on each of its mounts — and the bake that turns
//// hull + loadout into the resolved `ShipClass` the sim, the composite and the
//// wire already speak (`docs/modules.md`).
////
//// The bake is deliberately dumb: it splices each module's authored character
//// blocks into the hull's authored rows (void = passthrough) and re-runs the
//// ordinary v3 parse. Consoles, the mooring tile, docking ports and the
//// pallet-derived hold capacity therefore all fall out of the STAMPED map,
//// with no derivation logic of its own — install a cockpit and the helm
//// console exists because the glyph does.
////
//// Validation is one rule — `sum(provides) >= sum(requires)` pooled per tag —
//// plus three structural checks (one module per slot, every non-void overlay
//// cell lands on that slot's digit, mount kind/size fits the part). There is
//// never any reachability or geometry analysis: walkability is the hull
//// author's responsibility and the module guarantees its own insides.

import dh_server/deckplan.{type DeckPlan}
import dh_server/glyphs
import dh_server/hull.{type Hull, type Mount, type Slot}
import dh_server/module.{type Module, type Patch}
import dh_server/part.{type Part}
import dh_server/shipclass.{type ShipClass}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// What a specific ship is fitted with: its hull id, its slot -> module
/// assignments and its mount -> part assignments.
pub type Loadout {
  Loadout(
    hull: String,
    modules: List(#(String, String)),
    parts: List(#(String, String)),
  )
}

/// A resolved loadout: the fit itself, the baked class it produced, and the
/// total mass the flight stats were divided by.
pub type Fit {
  Fit(loadout: Loadout, class: ShipClass, mass: Float)
}

/// The loadout a hull ships with — the Mockingbird's default loadout is how
/// today's authored deck is expressed, so nothing about her out-of-the-box
/// look changes.
pub fn default_for(h: Hull) -> Loadout {
  Loadout(hull: h.id, modules: h.default_modules, parts: h.default_parts)
}

/// Resolve a loadout onto a hull. `Error` carries a machine-readable reason
/// (`"tag_deficit:power"`, `"out_of_slot_bounds:<module id>"`, …) that the
/// `refit_result` wire message forwards verbatim.
pub fn resolve(
  reg: glyphs.Registry,
  h: Hull,
  modules: Dict(String, Module),
  parts: Dict(String, Part),
  lo: Loadout,
) -> Result(Fit, String) {
  use <- guard(lo.hull == h.id, "loadout_wrong_hull:" <> lo.hull)
  use fitted <- result.try(lookup_modules(h, modules, lo))
  use mounted <- result.try(lookup_parts(h, parts, lo))
  use _ <- result.try(check_tags(h, fitted, mounted))
  use base <- result.try(
    deckplan.from_rows(reg, h.decks)
    |> result.map_error(fn(e) { "invalid_hull_plan:" <> e }),
  )
  use _ <- result.try(check_bounds(reg, base, fitted))
  use plan <- result.try(
    deckplan.from_rows(reg, stamp_all(reg, h.decks, fitted))
    |> result.map_error(fn(e) { "invalid_resolved_plan:" <> e }),
  )
  let mass = total_mass(h, fitted, mounted)
  use flight <- result.try(flight_of(mass, mounted))
  use class <- result.try(
    shipclass.from_plan(
      reg,
      h.id,
      h.name,
      h.schema,
      plan,
      h.fallback_capacity,
      h.handling,
      h.dock_port_orientation,
      h.dock_standoff,
      flight,
    )
    |> result.map_error(fn(e) { "invalid_resolved_plan:" <> e }),
  )
  Ok(Fit(loadout: lo, class: class, mass: mass))
}

// ------------------------------------------------------------- lookups --

fn lookup_modules(
  h: Hull,
  modules: Dict(String, Module),
  lo: Loadout,
) -> Result(List(#(Slot, Module)), String) {
  list.try_fold(lo.modules, [], fn(acc, entry) {
    let #(slot_id, module_id) = entry
    use slot <- result.try(
      hull.slot_by_id(h, slot_id)
      |> result.replace_error("slot_not_on_hull:" <> slot_id),
    )
    use <- guard(
      !list.any(acc, fn(a) { { a.0 }.id == slot_id }),
      "duplicate_slot:" <> slot_id,
    )
    use m <- result.try(
      dict.get(modules, module_id)
      |> result.replace_error("unknown_module:" <> module_id),
    )
    use <- guard(m.hull == h.id, "module_wrong_hull:" <> module_id)
    use <- guard(m.slot == slot_id, "module_wrong_slot:" <> module_id)
    Ok(list.append(acc, [#(slot, m)]))
  })
}

fn lookup_parts(
  h: Hull,
  parts: Dict(String, Part),
  lo: Loadout,
) -> Result(List(#(Mount, Part)), String) {
  list.try_fold(lo.parts, [], fn(acc, entry) {
    let #(mount_id, part_id) = entry
    use mount <- result.try(
      hull.mount_by_id(h, mount_id)
      |> result.replace_error("mount_not_on_hull:" <> mount_id),
    )
    use <- guard(
      !list.any(acc, fn(a) { { a.0 }.id == mount_id }),
      "duplicate_mount:" <> mount_id,
    )
    use p <- result.try(
      dict.get(parts, part_id)
      |> result.replace_error("unknown_part:" <> part_id),
    )
    use <- guard(p.kind == mount.kind, "mount_wrong_kind:" <> mount_id)
    use mount_rank <- result.try(
      part.size_rank(mount.size)
      |> result.replace_error("mount_bad_size:" <> mount_id),
    )
    use part_rank <- result.try(
      part.size_rank(p.size)
      |> result.replace_error("part_bad_size:" <> part_id),
    )
    use <- guard(part_rank <= mount_rank, "mount_too_small:" <> mount_id)
    Ok(list.append(acc, [#(mount, p)]))
  })
}

// ---------------------------------------------------------- validation --

/// The single loadout rule: for every tag, pooled `provides` across the hull,
/// its modules and its parts must cover pooled `requires`. Power is the
/// cross-cutting currency this expresses; `gun_control` (M5) is the same rule
/// linking a gun to any sufficient gun room, not to one specific partner.
fn check_tags(
  h: Hull,
  fitted: List(#(Slot, Module)),
  mounted: List(#(Mount, Part)),
) -> Result(Nil, String) {
  let provides =
    h.provides
    |> merge_all(list.map(fitted, fn(f) { { f.1 }.provides }))
    |> merge_all(list.map(mounted, fn(m) { { m.1 }.provides }))
  let requires =
    h.requires
    |> merge_all(list.map(fitted, fn(f) { { f.1 }.requires }))
    |> merge_all(list.map(mounted, fn(m) { { m.1 }.requires }))
  list.try_fold(dict.to_list(requires), Nil, fn(_, entry) {
    let #(tag, needed) = entry
    let supplied = case dict.get(provides, tag) {
      Ok(v) -> v
      Error(Nil) -> 0
    }
    case supplied >= needed {
      True -> Ok(Nil)
      False -> Error("tag_deficit:" <> tag)
    }
  })
}

fn merge_all(base: Dict(String, Int), others: List(Dict(String, Int))) -> Dict(String, Int) {
  list.fold(others, base, fn(acc, d) {
    list.fold(dict.to_list(d), acc, fn(acc, entry) {
      let #(tag, n) = entry
      let current = case dict.get(acc, tag) {
        Ok(v) -> v
        Error(Nil) -> 0
      }
      dict.insert(acc, tag, current + n)
    })
  })
}

/// Every non-void overlay cell must land on a hull cell carrying that slot's
/// digit — the cheap bounds check that stops a module scribbling on hull
/// structure. This reads the AUTHORED hull, never the previously resolved
/// plan, so a refit always validates against the same fixed structure.
fn check_bounds(
  reg: glyphs.Registry,
  base: DeckPlan,
  fitted: List(#(Slot, Module)),
) -> Result(Nil, String) {
  list.try_fold(fitted, Nil, fn(_, entry) {
    let #(slot, m) = entry
    list.try_fold(m.patches, Nil, fn(_, p) {
      case deckplan.deck_at(base, p.deck) {
        Error(Nil) -> Error("patch_bad_deck:" <> m.id)
        Ok(g) ->
          list.try_fold(patch_tiles(reg, p), Nil, fn(_, tile) {
            let #(tx, ty) = tile
            case deckplan.cell_at_xy(g, p.x + tx, p.y + ty) {
              Error(Nil) -> Error("out_of_slot_bounds:" <> m.id)
              Ok(cell) ->
                case cell.slot == Some(slot.digit) {
                  True -> Ok(Nil)
                  False -> Error("out_of_slot_bounds:" <> m.id)
                }
            }
          })
      }
    })
  })
}

/// The patch-local tile coordinates whose centre glyph is NOT void — the cells
/// that actually overwrite the hull.
fn patch_tiles(reg: glyphs.Registry, p: Patch) -> List(#(Int, Int)) {
  let cells = list.map(p.rows, string.to_graphemes)
  let width = case list.first(p.rows) {
    Ok(r) -> string.length(r) / 3
    Error(Nil) -> 0
  }
  let height = list.length(p.rows) / 3
  list.flat_map(range(0, height), fn(y) {
    list.filter_map(range(0, width), fn(x) {
      case is_void(reg, at(cells, 3 * y + 1, 3 * x + 1)) {
        True -> Error(Nil)
        False -> Ok(#(x, y))
      }
    })
  })
}

// --------------------------------------------------------------- stamp --

/// Stamp every fitted module's patches into the hull's rows, deck by deck.
fn stamp_all(
  reg: glyphs.Registry,
  decks: List(#(String, List(String))),
  fitted: List(#(Slot, Module)),
) -> List(#(String, List(String))) {
  list.index_map(decks, fn(deck, index) {
    let #(name, rows) = deck
    let patches =
      list.flat_map(fitted, fn(f) {
        list.filter({ f.1 }.patches, fn(p) { p.deck == index })
      })
    #(name, list.fold(patches, rows, fn(acc, p) { stamp(reg, acc, p) }))
  })
}

/// Splice one patch into a deck's rows. A patch tile whose centre glyph is
/// VOID leaves the hull's tile untouched (the passthrough rule); any other
/// tile overwrites the hull's 3x3 block — **except its SW corner**, which stays
/// the hull's because slot regions are hull-owned and a later refit has to
/// find them again.
fn stamp(
  reg: glyphs.Registry,
  rows: List(String),
  p: Patch,
) -> List(String) {
  let base = list.map(rows, string.to_graphemes)
  let patch = list.map(p.rows, string.to_graphemes)
  let stamped =
    list.fold(patch_tiles(reg, p), base, fn(acc, tile) {
      let #(px, py) = tile
      copy_tile(acc, patch, p.x + px, p.y + py, px, py)
    })
  list.map(stamped, string.concat)
}

/// Copy the eight non-SW characters of patch tile `(px, py)` onto base tile
/// `(tx, ty)`.
fn copy_tile(
  base: List(List(String)),
  patch: List(List(String)),
  tx: Int,
  ty: Int,
  px: Int,
  py: Int,
) -> List(List(String)) {
  list.fold(block_offsets(), base, fn(acc, off) {
    let #(dr, dc) = off
    set_at(acc, 3 * ty + dr, 3 * tx + dc, at(patch, 3 * py + dr, 3 * px + dc))
  })
}

/// The 3x3 block positions a stamp writes: everything but the SW corner
/// `#(2, 0)`, the hull's slot digit.
fn block_offsets() -> List(#(Int, Int)) {
  [#(0, 0), #(0, 1), #(0, 2), #(1, 0), #(1, 1), #(1, 2), #(2, 1), #(2, 2)]
}

fn is_void(reg: glyphs.Registry, ch: String) -> Bool {
  glyphs.center(reg, ch).tile == glyphs.Void
}

fn at(rows: List(List(String)), r: Int, c: Int) -> String {
  case list.drop(rows, r) |> list.first {
    Error(Nil) -> " "
    Ok(row) ->
      case list.drop(row, c) |> list.first {
        Error(Nil) -> " "
        Ok(ch) -> ch
      }
  }
}

fn set_at(
  rows: List(List(String)),
  r: Int,
  c: Int,
  value: String,
) -> List(List(String)) {
  list.index_map(rows, fn(row, ri) {
    case ri == r {
      False -> row
      True ->
        list.index_map(row, fn(ch, ci) {
          case ci == c {
            False -> ch
            True -> value
          }
        })
    }
  })
}

// ------------------------------------------------------------- numbers --

fn total_mass(
  h: Hull,
  fitted: List(#(Slot, Module)),
  mounted: List(#(Mount, Part)),
) -> Float {
  let modules = list.fold(fitted, 0.0, fn(t, f) { t +. { f.1 }.mass })
  let parts = list.fold(mounted, 0.0, fn(t, m) { t +. { m.1 }.mass })
  h.mass +. modules +. parts
}

/// Flight performance is the fitted engines' pooled thrust and torque over the
/// fit's total mass, so hull choice and every installed module change how she
/// flies. A hull that requires `{"engine": 1}` cannot resolve without one, so
/// a zero-thrust fit never reaches the sim.
fn flight_of(
  mass: Float,
  mounted: List(#(Mount, Part)),
) -> Result(shipclass.Flight, String) {
  case mass >. 0.0 {
    False -> Error("zero_mass")
    True -> {
      let thrust = list.fold(mounted, 0.0, fn(t, m) { t +. { m.1 }.thrust })
      let torque = list.fold(mounted, 0.0, fn(t, m) { t +. { m.1 }.torque })
      Ok(shipclass.Flight(accel: thrust /. mass, turn_rate: torque /. mass))
    }
  }
}

// -------------------------------------------------------------- helpers --

fn guard(
  condition: Bool,
  error: String,
  next: fn() -> Result(a, String),
) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(error)
  }
}

/// [from, to) as a list of ints (the pinned gleam_stdlib has no `list.range`;
/// matches the local helper idiom used in `deckplan` and `composite`).
fn range(from: Int, to: Int) -> List(Int) {
  case from >= to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
```

Note for the implementer: `{ f.1 }.provides` is tuple-element access followed by a record field. If the Gleam compiler rejects that form, destructure instead — `let #(_, m) = f` then `m.provides`. Prefer whichever compiles; do not leave both.

Also delete the unused `None` import if the compiler warns.

- [ ] **Step 4: Run the tests**

Run: `cd server; gleam test`
Expected: all `loadout_test` cases PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/dh_server/loadout.gleam server/test/loadout_test.gleam
git commit -m "feat(loadout): overlay stamp, pooled-tag validator, resolved bake (#M4)"
```

---

### Task 6: Engine parts, flight numbers, and hull metadata

Parts and the hull's non-slot metadata land *before* the sim rewiring, so that when Task 7 switches every ship to a resolved fit there is already something to resolve. The Mockingbird is not carved yet — she resolves here with **zero modules**, which is exactly the "hull with no slots is legal" case.

**Files:**
- Create: `server/parts/rijay_engine_consol_patch.json`
- Create: `server/parts/rijay_engine_stock.json`
- Modify: `server/shipclasses/mockingbird.json` (metadata only — no slot digits yet)
- Modify: `harness/fixtures/test_fixture.json`
- Test: `server/test/parts_test.gleam`

**Interfaces:**
- Consumes: `hull.load`, `part.load_all`, `loadout.resolve` (Task 5).
- Produces: part ids `rijay.engine.consol_patch` (the default) and `rijay.engine.stock`; the Mockingbird hull gains `mass`, `provides`, `requires`, `mounts` and `default_loadout.parts`.

- [ ] **Step 1: Author the Consol patch engine**

Create `server/parts/rijay_engine_consol_patch.json`:

```json
{
  "schema": 1,
  "id": "rijay.engine.consol_patch",
  "name": "Consol patch engine",
  "kind": "engine",
  "size": "m",
  "mass": 0.0,
  "provides": { "engine": 1 },
  "requires": { "power": 3 },
  "thrust": 4800.0,
  "torque": 21600.0,
  "sprite": "engine_consol"
}
```

Every Mockingbird fit masses 120.0 — as an uncarved hull here (mass 120.0, no modules) and as a carved one after Task 8 (mass 96.0 + 24.0 of modules) — so this engine is exactly `accel = 40.0` and `turn_rate = 180.0`, the two constants `ship.gleam` carried before M4. Nothing about how she flies today changes.

- [ ] **Step 2: Author the Rijay original**

Create `server/parts/rijay_engine_stock.json`:

```json
{
  "schema": 1,
  "id": "rijay.engine.stock",
  "name": "Rijay original engine",
  "kind": "engine",
  "size": "m",
  "mass": 4.0,
  "provides": { "engine": 1 },
  "requires": { "power": 4 },
  "thrust": 6820.0,
  "torque": 19840.0,
  "sprite": "engine_rijay"
}
```

At a Mockingbird fit's resulting 124.0 total mass that is `accel = 55.0`, `turn_rate = 160.0` — stronger in a straight line, lazier in a turn. That contrast is the milestone's exit demo: swapping the patch for the original moves the flight stats in opposite directions, so it is a *choice*, not an upgrade.

- [ ] **Step 3: Give the Mockingbird her hull metadata (no slots yet)**

Add to the top level of `server/shipclasses/mockingbird.json`, leaving her `decks` completely untouched:

```jsonc
  "mass": 120.0,
  "provides": { "power": 10 },
  "requires": { "engine": 1 },
  "mounts": [ { "id": "engine_center", "kind": "engine", "size": "m" } ],
  "default_loadout": { "parts": { "engine_center": "rijay.engine.consol_patch" } }
```

Mass is 120.0 *here* because the hull is still the whole ship — nothing has been carved out into modules. Task 8 drops it to 96.0 as the five default modules take up the other 24.0, and the resolved total stays 120.0 either way. The old `shipclass.load` path (still live until Task 7) ignores these unknown fields, so the running server is unaffected.

- [ ] **Step 4: Update the harness fixture hull**

Every harness test spawns from `harness/fixtures/test_fixture.json`, so it needs mass and a default engine or its ships cannot resolve. Add to that file's top level (keeping everything else untouched):

```jsonc
  "mass": 120.0,
  "provides": { "power": 10 },
  "requires": { "engine": 1 },
  "mounts": [ { "id": "engine_center", "kind": "engine", "size": "m" } ],
  "default_loadout": { "parts": { "engine_center": "rijay.engine.consol_patch" } }
```

120.0 plus the patch engine's 0.0 keeps the fixture hull at exactly `accel = 40.0` / `turn_rate = 180.0`, so `harness/test_m1_flight.py`'s "~20 u for ~1 s of full thrust" assertions stay green untouched. The fixture declares no slots and no default modules until Task 10 — a hull with no slots is perfectly legal, it just cannot be refitted.

- [ ] **Step 5: Write the test**

Create `server/test/parts_test.gleam`:

```gleam
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict

pub fn shipped_parts_load_test() {
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(patch) = dict.get(parts, "rijay.engine.consol_patch")
  assert patch.kind == "engine"
  assert patch.size == "m"
  let assert Ok(stock) = dict.get(parts, "rijay.engine.stock")
  assert stock.thrust >. patch.thrust
  assert stock.torque <. patch.torque
}

/// The uncarved Mockingbird resolves with an engine and no modules at all —
/// the "a hull with no slots is legal" case — at exactly the pre-M4 constants.
pub fn uncarved_mockingbird_flies_at_the_pre_m4_constants_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, dict.new(), parts, loadout.default_for(h))
  assert fit.mass == 120.0
  assert fit.class.flight.accel == 40.0
  assert fit.class.flight.turn_rate == 180.0
  assert fit.class.cargo_capacity == 60
}

pub fn the_stock_engine_trades_turn_for_thrust_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(parts) = part.load_all("parts")
  let swapped =
    loadout.Loadout(
      hull: "mockingbird",
      modules: [],
      parts: [#("engine_center", "rijay.engine.stock")],
    )
  let assert Ok(fit) =
    loadout.resolve(glyphs.default(), h, dict.new(), parts, swapped)
  assert fit.class.flight.accel == 55.0
  assert fit.class.flight.turn_rate == 160.0
}

/// A hull that requires `{"engine": 1}` cannot resolve with nothing mounted —
/// this is the pooled-tag rule doing the "she has to be able to move" job, not
/// a special case in the engine.
pub fn no_engine_is_refused_test() {
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let bare = loadout.Loadout(hull: "mockingbird", modules: [], parts: [])
  let assert Error(e) =
    loadout.resolve(glyphs.default(), h, dict.new(), dict.new(), bare)
  assert e == "tag_deficit:engine"
}
```

Add `import dh_server/module` only if the compiler needs it; the tests above pass `dict.new()` for the module registry, so it may be unused — delete the import if so.

- [ ] **Step 6: Run the server suite**

Run: `cd server; gleam test`
Expected: PASS, whole suite. The live server still boots through the old `shipclass.load` path — the Mockingbird's decks were not touched.

- [ ] **Step 7: Commit**

```bash
git add server/parts server/shipclasses/mockingbird.json harness/fixtures/test_fixture.json server/test/parts_test.gleam
git commit -m "feat(parts): Consol patch + Rijay original engines; hull flight metadata (#M4)"
```

---

### Task 7: Per-ship fits in the sim

Unwind the single shared `ShipClass`. Every ship gets its own resolved `Fit`; the registries load at boot; the temporary `shipclass.load` shim from Task 3 comes out.

**Files:**
- Modify: `server/src/dh_server/shipclass.gleam` (delete the `load`/`load_with` shim)
- Modify: `server/test/shipclass_test.gleam`
- Modify: `server/src/dh_server.gleam` (lines 13, 25, 142-152)
- Modify: `server/src/dh_server/sim.gleam` (the `State` record at 280-299, `start` at 302-338, and every `state.class` reference — lines 368, 388, 448, 480, 507, 547, 762, 797, 826, 842, 977, 1049, 1161, 1202-1206, 1401, 1449, 1515)
- Modify: `server/src/dh_server/server.gleam` (line 22 and its `ShipClass` plumbing)
- Modify: `server/src/dh_server/ship.gleam` (constants at 19-25, `step` at 140-165)
- Modify: `server/src/dh_server/protocol.gleam` (`encode_welcome` at 168-191)
- Test: `server/test/ship_test.gleam`, `server/test/sim_test.gleam`

**Interfaces:**
- Consumes: `loadout.Fit`, `loadout.resolve`, `hull.load_all`, `module.load_all`, `part.load_all`.
- Produces: `sim` holds `fits: List(#(Int, loadout.Fit))` keyed by ship id, plus `fn fit_for(state: State, ship_id: Int) -> Result(loadout.Fit, Nil)`.
- Produces: `ship.step(ship, world, t, standoff, flight: shipclass.Flight) -> Ship` (new 5th parameter).

- [ ] **Step 1: Move the flight constants out of `ship.gleam`**

Delete `main_accel` (lines 19-20) and `turn_rate` (lines 22-25). Keep `dt`, `max_dock_speed`, `starting_wallet`.

Change `step`'s signature and body:

```gleam
/// Advance a ship by one tick of `dt` at sim time `t`. A docked ship is pinned
/// to its station's analytic position/velocity and ignores its controls; a
/// flying ship integrates thrust + gravity. `flight` is the ship's RESOLVED
/// performance (`loadout.resolve`) — acceleration and turn rate are per-ship
/// loadout data since M4, not global constants.
pub fn step(
  ship: Ship,
  world: World,
  t: Float,
  standoff: Float,
  flight: shipclass.Flight,
) -> Ship {
```

and inside the `Flying` branch:

```gleam
      let heading = ship.heading +. ship.controls.rotate *. flight.turn_rate *. dt
      let #(gx, gy) = world.gravity_at(world, ship.x, ship.y, t)
      let heading_rad = angle.deg_to_rad(heading)
      let ax = ship.controls.thrust *. flight.accel *. cos(heading_rad) +. gx
      let ay = ship.controls.thrust *. flight.accel *. sin(heading_rad) +. gy
```

Add `import dh_server/shipclass` to `ship.gleam`.

- [ ] **Step 2: Update `ship_test.gleam`**

Every `ship.step(...)` call in that file gains a flight argument. Add a helper at the top of the file and use it at each call site:

```gleam
fn test_flight() -> shipclass.Flight {
  // The pre-M4 constants, so these tests keep asserting the same numbers.
  shipclass.Flight(accel: 40.0, turn_rate: 180.0)
}
```

Add `import dh_server/shipclass`. Any test that referenced `ship.main_accel` or `ship.turn_rate` uses `test_flight().accel` / `.turn_rate` instead.

- [ ] **Step 3: Load the registries at boot**

In `server/src/dh_server.gleam`, replace the single-class load (lines 25 and 142-152) with:

```gleam
const default_hull_dir = "shipclasses"

const module_dir = "modules"

const part_dir = "parts"

const default_hull_id = "mockingbird"
```

and, where the class was loaded:

```gleam
  // DH_SHIP_CLASS names ONE extra hull document to load and spawn from — the
  // pytest harness points it at its own fixture hull (harness/fixtures/).
  let assert Ok(hulls) = case hull.load_all(default_hull_dir) {
    Ok(hulls) -> Ok(hulls)
    Error(err) -> panic as { "failed to load hulls: " <> err }
  }
  let #(hulls, spawn_hull) = case envoy.get("DH_SHIP_CLASS") {
    Error(Nil) -> #(hulls, default_hull_id)
    Ok(path) -> {
      let assert Ok(h) = hull.load(path)
      #(dict.insert(hulls, h.id, h), h.id)
    }
  }
  let assert Ok(modules) = module.load_all(module_dir)
  let assert Ok(parts) = part.load_all(part_dir)
```

Follow the file's existing error-reporting idiom for the failure branches rather than bare `panic` if one is already established there; the point is that a broken data file must stop the server at boot, loudly, not produce a half-fitted world.

Pass `hulls`, `modules`, `parts`, `spawn_hull` into `sim.start` (and through `server.gleam`, which currently threads a `ShipClass`).

`modules` will be an empty registry until Task 8 authors the Mockingbird's — that is fine and must not be treated as an error: an empty `server/modules/` directory resolves every hull with zero modules.

Nothing loads a `ShipClass` from a file any more, so delete the Task 3 shim from `shipclass.gleam`: `pub fn load`, `pub fn load_with`, and the `default_shim_flight` constant, plus the `simplifile` import if it becomes unused. A `ShipClass` is now only ever produced by `from_plan` or decoded from the wire — which is the invariant that makes "a ship is its resolved fit" true rather than aspirational.

- [ ] **Step 4: Give the sim per-ship fits**

In `sim.gleam`, replace the `class: ShipClass` field of `State` with:

```gleam
    /// Every hull, module and part the world knows — the content registries.
    hulls: dict.Dict(String, hull.Hull),
    modules: dict.Dict(String, module.Module),
    parts: dict.Dict(String, part.Part),
    glyphs: glyphs.Registry,
    /// The hull new ships spawn on.
    spawn_hull: String,
    /// Resolved fit per ship id. A ship without one cannot be simulated, so
    /// spawn refuses rather than falling back to a default.
    fits: List(#(Int, loadout.Fit)),
```

and add the lookup helper:

```gleam
/// The resolved fit of one ship. Every consumer of the old single shared
/// `state.class` goes through here: since M4 a hull is per-ship data, not a
/// world-wide constant.
fn fit_for(state: State, ship_id: Int) -> Result(loadout.Fit, Nil) {
  case list.find(state.fits, fn(entry) { entry.0 == ship_id }) {
    Ok(#(_, fit)) -> Ok(fit)
    Error(Nil) -> Error(Nil)
  }
}

/// Resolve the default loadout of `hull_id` — the fit a freshly spawned ship
/// gets.
fn default_fit(state: State, hull_id: String) -> Result(loadout.Fit, String) {
  case dict.get(state.hulls, hull_id) {
    Error(Nil) -> Error("unknown_hull:" <> hull_id)
    Ok(h) ->
      loadout.resolve(
        state.glyphs,
        h,
        state.modules,
        state.parts,
        loadout.default_for(h),
      )
  }
}
```

Then work through each `state.class` site the compiler reports. The mechanical substitution is `state.class.<field>` → `fit.class.<field>` where `fit` comes from `fit_for(state, ship.id)`. Guidance per site group:

- **Spawn (around line 368, 480):** resolve `default_fit(state, state.spawn_hull)` first, store it in `fits`, then use its `class.dock_port_orientation` / `class.dock_standoff`.
- **Console/helm lookups (388, 448, 547, 762, 797, 842, 1161, 1401):** these are per-character; find the character's ship, then its fit, then `fit.class.plan`.
- **Composite build (507, 1202-1206):** the docked ship's own `fit.class.plan` — the comment at 1202 saying `state.class.plan is the single-hull assumption` is exactly what this deletes; remove the comment with the assumption.
- **Cargo (977, 1049, 1515):** `fit.class.handling` / `fit.class.cargo_capacity`.
- **Ship stepping (1449):** `ship.step(s, state.world, t, fit.class.dock_standoff, fit.class.flight)`.
- **Undock (826):** `fit.class.dock_standoff`.

Where a fit lookup can fail (a ship id with no fit), treat it the same way the code already treats a missing ship: skip the ship rather than crashing the tick.

Drop `fits` entries when a ship despawns, wherever the ship list is pruned.

- [ ] **Step 5: Thread the resolved class into `welcome`**

`protocol.encode_welcome` already takes a `ShipClass` — pass `fit.class` for the connecting player's ship. No signature change needed.

- [ ] **Step 6: Retrain `shipclass_test.gleam`**

Its four cases still call the deleted `shipclass.load`. They were really *hull* assertions; the hull-level ones now live in `hull_test`/`parts_test`, so what remains is the wire-form contract. Replace the file with:

```gleam
import dh_server/deckplan
import dh_server/glyphs
import dh_server/shipclass
import gleam/json

const rows = [
  "#h#######",
  "#       #",
  "#########",
  "#########",
  "=Q     p#",
  "#########",
]

fn a_class() -> shipclass.ShipClass {
  let reg = glyphs.default()
  let assert Ok(plan) = deckplan.from_rows(reg, [#("Main", rows)])
  let assert Ok(c) =
    shipclass.from_plan(
      reg,
      "testhull",
      "Test Hull",
      3,
      plan,
      7,
      shipclass.BreakBulk,
      90.0,
      20.0,
      shipclass.Flight(accel: 40.0, turn_rate: 180.0),
    )
  c
}

pub fn from_plan_derives_capacity_from_pallets_test() {
  // The single `p` tile on the map beats the authored fallback of 7.
  assert a_class().cargo_capacity == 1
}

pub fn from_plan_requires_a_helm_test() {
  let reg = glyphs.default()
  let assert Ok(plan) =
    deckplan.from_rows(reg, [
      #("Main", ["#########", "#       #", "#########"]),
    ])
  let assert Error(e) =
    shipclass.from_plan(
      reg,
      "h",
      "H",
      3,
      plan,
      0,
      shipclass.BreakBulk,
      90.0,
      20.0,
      shipclass.Flight(accel: 1.0, turn_rate: 1.0),
    )
  assert e == "no console of kind \"helm\""
}

pub fn decode_encode_round_trips_test() {
  let c = a_class()
  let text = shipclass.encode(c) |> json.to_string
  let assert Ok(c2) = shipclass.decode(text)
  assert c == c2
}

pub fn helm_console_is_found_test() {
  let assert Ok(console) = shipclass.helm_console(a_class())
  assert console.kind == "helm"
}
```

- [ ] **Step 7: Fix `sim_test.gleam`**

`sim.start` gains parameters. Add a helper at the top of `sim_test.gleam` that builds the registries from disk once and calls `start` with them:

```gleam
fn test_sim_args() {
  let assert Ok(hulls) = hull.load_all("shipclasses")
  let assert Ok(modules) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  #(hulls, modules, parts, glyphs.default(), "mockingbird")
}
```

and update every `sim.start(world, class)` call to pass them.

- [ ] **Step 7: Run the whole suite**

Run: `cd server; gleam test`
Expected: PASS, all suites.

- [ ] **Step 8: Run the harness to prove the live server still works**

Run: `cd harness; python -m pytest test_m1_flight.py test_m2_interior.py -v`
Expected: PASS — the fixture hull resolves, ships spawn with 40 u/s² of thrust, interiors still walk.

- [ ] **Step 9: Commit**

```bash
git add server/src server/test
git commit -m "refactor(sim): per-ship resolved fits replace the single shared class (#M4)"
```

---

### Task 8: Carve the Mockingbird into a hull plus default modules

The content task, and the riskiest one — which is why it runs last, against live machinery: by now the server already resolves every ship through `loadout.resolve`, so a bad carve fails loudly and locally instead of hiding behind unwired code.

Today's `mockingbird.json` gets slot digits and has its slot regions emptied to open floor; five modules stamp back exactly what is there now. A golden test against the frozen pre-M4 map is the arbiter.

**Files:**
- Create: `server/test/fixtures/mockingbird_authored.json` (frozen copy of today's map)
- Modify: `server/shipclasses/mockingbird.json`
- Create: `server/modules/mockingbird/cockpit_stock.json`
- Create: `server/modules/mockingbird/forward_crew_cabins.json`
- Create: `server/modules/mockingbird/commons_mess.json`
- Create: `server/modules/mockingbird/aft_crew_cabins.json`
- Create: `server/modules/mockingbird/hold_breakbulk.json`
- Create: `server/modules/mockingbird/forward_crew_passenger.json` (alternate)
- Create: `server/modules/mockingbird/hold_tank.json` (alternate)
- Test: `server/test/mockingbird_test.gleam`

**Interfaces:**
- Consumes: `loadout.resolve`, `loadout.default_for`, `hull.load`, `module.load_all`, `part.load_all`.
- Produces: the hull id `mockingbird` with slots `cockpit`, `forward_crew`, `commons`, `aft_crew`, `hold`; module ids `mockingbird.cockpit.stock`, `mockingbird.forward_crew.cabins`, `mockingbird.commons.mess`, `mockingbird.aft_crew.cabins`, `mockingbird.hold.breakbulk`, `mockingbird.forward_crew.passenger`, `mockingbird.hold.tank`.

- [ ] **Step 1: Freeze today's map as the golden fixture**

```bash
mkdir -p server/test/fixtures
cp server/shipclasses/mockingbird.json server/test/fixtures/mockingbird_authored.json
git add server/test/fixtures/mockingbird_authored.json
git commit -m "test(mockingbird): freeze the authored v3 deck as the carve's golden (#M4)"
```

- [ ] **Step 2: Write the failing golden test**

Create `server/test/mockingbird_test.gleam`:

```gleam
import dh_server/deckplan
import dh_server/glyphs
import dh_server/hull
import dh_server/loadout
import dh_server/module
import dh_server/part
import gleam/dict
import gleam/list
import gleam/option
import simplifile

fn resolved_default() -> loadout.Fit {
  let reg = glyphs.default()
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let assert Ok(fit) = loadout.resolve(reg, h, mods, parts, loadout.default_for(h))
  fit
}

/// The frozen pre-M4 authored map, parsed. The carve is only correct if the
/// default loadout reproduces it tile for tile.
fn authored_plan() -> deckplan.DeckPlan {
  let assert Ok(text) = simplifile.read("test/fixtures/mockingbird_authored.json")
  let assert Ok(h) = hull.decode(text)
  let assert Ok(plan) = deckplan.from_rows(glyphs.default(), h.decks)
  plan
}

/// Slot digits are new structure the frozen map does not have, so compare with
/// them stripped — everything else (tile kind, all four edges, decor, colour,
/// consoles, spawn) must match exactly.
fn strip_slots(plan: deckplan.DeckPlan) -> deckplan.DeckPlan {
  deckplan.DeckPlan(
    ..plan,
    decks: list.map(plan.decks, fn(g) {
      deckplan.DeckGrid(
        ..g,
        cells: list.map(g.cells, fn(row) {
          list.map(row, fn(c) { deckplan.Cell(..c, slot: option.None) })
        }),
      )
    }),
  )
}

pub fn default_loadout_reproduces_the_authored_deck_test() {
  assert strip_slots(resolved_default().class.plan) == strip_slots(authored_plan())
}

pub fn default_capacity_is_still_sixty_test() {
  assert resolved_default().class.cargo_capacity == 60
}

pub fn default_flight_matches_the_pre_m4_constants_test() {
  let fit = resolved_default()
  assert fit.class.flight.accel == 40.0
  assert fit.class.flight.turn_rate == 180.0
}

pub fn swapping_the_hold_for_a_tank_drops_capacity_test() {
  let reg = glyphs.default()
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let base = loadout.default_for(h)
  let swapped =
    loadout.Loadout(
      ..base,
      modules: list.map(base.modules, fn(entry) {
        case entry.0 == "hold" {
          True -> #("hold", "mockingbird.hold.tank")
          False -> entry
        }
      }),
    )
  let assert Ok(fit) = loadout.resolve(reg, h, mods, parts, swapped)
  assert fit.class.cargo_capacity < 60
}

pub fn every_shipped_module_resolves_in_its_slot_test() {
  let reg = glyphs.default()
  let assert Ok(h) = hull.load("shipclasses/mockingbird.json")
  let assert Ok(mods) = module.load_all("modules")
  let assert Ok(parts) = part.load_all("parts")
  let base = loadout.default_for(h)
  // Each shipped module, installed alone in its own slot over the default fit,
  // must resolve — the cheapest guard against a patch drifting off its slot.
  dict.to_list(mods)
  |> list.each(fn(entry) {
    let #(id, m) = entry
    let swapped =
      loadout.Loadout(
        ..base,
        modules: list.map(base.modules, fn(e) {
          case e.0 == m.slot {
            True -> #(m.slot, id)
            False -> e
          }
        }),
      )
    let assert Ok(_) = loadout.resolve(reg, h, mods, parts, swapped)
  })
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — `default_loadout_reproduces_the_authored_deck_test` fails because the hull has no slots and no modules yet, so the "resolved" plan is just the authored one with an empty loadout. (It may in fact *pass* trivially at this point, since an uncarved hull with no modules resolves to exactly the authored map. That is fine and expected — the test only becomes load-bearing once Step 5 empties the slot regions, and it must still pass then. `default_capacity_is_still_sixty_test` and the flight test pass from the start; they are regression anchors, not new behaviour.)

- [ ] **Step 4: Choose the slot regions**

Read `server/shipclasses/mockingbird.json`. Her Upper deck is 14 tiles wide × 23 tall; Lower likewise; the Mezzanine holds only the stair columns and the two `Q` docking ports. Working from the authored map, assign:

| digit | slot id | region |
|---|---|---|
| 1 | `cockpit` | Upper, the bow cabin (the `#h####` / `#e   #` block and the two tiles below it) |
| 2 | `forward_crew` | Upper, the twin cabins between the cockpit and the mess (the `#d##`/`we==` pairs) |
| 3 | `commons` | Upper, the wide mess/commons block (the `t`/`e` tables and seats) |
| 4 | `aft_crew` | Upper, the aft cabin block (the `wd`/`##d` bunk rows) |
| 5 | `hold` | Lower, every pallet tile and the open hold floor between the bow ramp and the stern |

Fixed hull structure (**no** digit): all void, every corridor and passage tile, the stair columns (`x`), the whole Mezzanine, the Lower bow ramp doors, and both `Q` docking ports. The `Q` ports and the `x` stairs must stay hull-owned — a refit that could delete the mooring tile or a staircase would be a bug factory.

- [ ] **Step 5: Mark the slot digits in the hull and empty the slot regions**

Edit `server/shipclasses/mockingbird.json`:

1. For every tile in a slot region, put its digit in the tile's SW corner character (row `3y+2`, column `3x` of that deck's grid).
2. **Empty each slot region**: inside a slot, every tile becomes plain open floor — remove interior partitions, decor (`d`/`e`/`t`/`p`), and wall consoles (`h`) that a module will stamp back. On the slot **perimeter**, the hull-side edges default to **open** (not `#`): the module supplies both the walls and the doors along its own boundary, so an unfitted slot reads as a bare open bay. Draw a hull-side perimeter wall only where the structure is genuinely fixed and no module should ever open it — the pressure boundary between the Lower hold and the bow ramp is the one place on this hull that plausibly qualifies. Everywhere else, leave it open.
3. Change `"mass"` from the 120.0 Task 6 gave her to **96.0** — the five default modules account for the other 24.0, so every resolved fit still totals 120.0 and she still flies at exactly 40.0 / 180.0. Then add the new top-level fields (`provides`, `requires` and `mounts` are already there from Task 6 — do not duplicate them):

```jsonc
  "mass": 96.0,
  "slots": [
    { "digit": 1, "id": "cockpit",      "name": "Cockpit" },
    { "digit": 2, "id": "forward_crew", "name": "Forward crew space" },
    { "digit": 3, "id": "commons",      "name": "Commons" },
    { "digit": 4, "id": "aft_crew",     "name": "Aft crew space" },
    { "digit": 5, "id": "hold",         "name": "Main hold" }
  ],
  "default_loadout": {
    "modules": {
      "cockpit":      "mockingbird.cockpit.stock",
      "forward_crew": "mockingbird.forward_crew.cabins",
      "commons":      "mockingbird.commons.mess",
      "aft_crew":     "mockingbird.aft_crew.cabins",
      "hold":         "mockingbird.hold.breakbulk"
    },
    "parts": { "engine_center": "rijay.engine.consol_patch" }
  }
```

Keep `schema`, `id`, `name`, `decks`, `cargo`, `dock_port_orientation`, `dock_standoff` as they are.

- [ ] **Step 6: Author the five default modules**

Each is `server/modules/mockingbird/<name>.json` in this shape — the `grid` is lifted verbatim out of the frozen `server/test/fixtures/mockingbird_authored.json` for exactly the tiles of that slot, and `x`/`y` is the patch's top-left **tile** position on that deck:

```jsonc
{
  "schema": 1,
  "id": "mockingbird.cockpit.stock",
  "hull": "mockingbird",
  "slot": "cockpit",
  "name": "Stock cockpit",
  "mass": 4.0,
  "provides": { "seats": 1 },
  "requires": { "power": 2 },
  "patches": [
    { "deck": 0, "x": 6, "y": 3, "grid": [ "…rows lifted from the authored map…" ] }
  ]
}
```

Masses and tags, chosen so the default loadout totals exactly 120.0 (96 hull + 24 modules) and 10 power covers 6 required:

| module | slot | mass | provides | requires |
|---|---|---|---|---|
| `mockingbird.cockpit.stock` | cockpit | 4.0 | `{"seats": 1}` | `{"power": 2}` |
| `mockingbird.forward_crew.cabins` | forward_crew | 6.0 | `{"berths": 4}` | `{"power": 1}` |
| `mockingbird.commons.mess` | commons | 4.0 | `{"galley": 1}` | `{"power": 1}` |
| `mockingbird.aft_crew.cabins` | aft_crew | 6.0 | `{"berths": 4}` | `{"power": 1}` |
| `mockingbird.hold.breakbulk` | hold | 4.0 | `{}` | `{"power": 1}` |

Rule while lifting rows: a patch tile you want the hull to keep is drawn `.` (void) at its centre — the passthrough. Only draw the tiles the module actually installs.

- [ ] **Step 7: Author the two alternates**

- `server/modules/mockingbird/forward_crew_passenger.json` — id `mockingbird.forward_crew.passenger`, slot `forward_crew`, mass `8.0`, `"provides": {"passengers": 4}`, `"requires": {"power": 4}`. Draw passenger staterooms in the same region: a different partition layout with `d` beds and doors onto the same corridor tiles the cabins use.
- `server/modules/mockingbird/hold_tank.json` — id `mockingbird.hold.tank`, slot `hold`, mass `9.0`, `"provides": {"fuel": 20}`, `"requires": {"power": 1}`. Draw the same hold with roughly half its `p` pallet tiles replaced by plain floor, so the derived capacity visibly drops.

- [ ] **Step 8: Run the golden test, iterate until it passes**

Run: `cd server; gleam test`
Expected: `default_loadout_reproduces_the_authored_deck_test` PASSES. It will not on the first try — when it fails, print both sides to find the offending tile:

```bash
cd server; gleam test 2>&1 | head -60
```

The mismatch is always one of: a slot digit missing from a hull tile the module writes into (→ `out_of_slot_bounds`), a hull tile that kept decor the module also draws, or a hull perimeter tile drawing `#` where the module needs a door.

- [ ] **Step 9: Run the harness — the carve must not move a single door**

Run: `cd harness; python -m pytest -v`
Expected: PASS, unchanged. The walking tests are the real proof that the carve preserved her interior: they walk the Mockingbird's corridors and sit at her consoles, and they neither know nor care that five modules now supply those tiles.

- [ ] **Step 10: Commit**

```bash
git add server/shipclasses/mockingbird.json server/modules server/test/mockingbird_test.gleam
git commit -m "feat(mockingbird): carve the hull into five slots + default modules (#M4)"
```

---

### Task 9: The refit verb

Docked-only, free, whole-loadout replacement. Iteration 3 layers console proximity, catalogs and cost on top.

**Files:**
- Modify: `server/src/dh_server/protocol.gleam`
- Modify: `server/src/dh_server/sim.gleam`
- Test: `server/test/protocol_test.gleam`

**Interfaces:**
- Produces:
  - `protocol.Refit(modules: List(#(String, String)), parts: List(#(String, String)))` variant of `ClientMessage`
  - `protocol.encode_refit_result(result: Result(Nil, String)) -> String`
  - `protocol.encode_ship_fit(ship_id: Int, class: shipclass.ShipClass, lo: loadout.Loadout) -> String`

- [ ] **Step 1: Write the failing protocol tests**

Append to `server/test/protocol_test.gleam`:

```gleam
pub fn parse_refit_message_test() {
  let text =
    "{\"v\":1,\"type\":\"refit\","
    <> "\"modules\":[{\"slot\":\"hold\",\"module\":\"mockingbird.hold.tank\"}],"
    <> "\"parts\":[{\"mount\":\"engine_center\",\"part\":\"rijay.engine.stock\"}]}"
  let assert Ok(protocol.Refit(modules, parts)) =
    protocol.parse_client_message(text)
  assert modules == [#("hold", "mockingbird.hold.tank")]
  assert parts == [#("engine_center", "rijay.engine.stock")]
}

pub fn encode_refit_failure_carries_the_reason_test() {
  let text = protocol.encode_refit_result(Error("tag_deficit:power"))
  assert string.contains(text, "\"ok\":false")
  assert string.contains(text, "tag_deficit:power")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd server; gleam test`
Expected: FAIL — no `Refit` variant.

- [ ] **Step 3: Add the wire messages**

In `protocol.gleam`, add to `ClientMessage`:

```gleam
  /// Replace this ship's whole loadout (docked only). Whole-loadout rather
  /// than a delta so it is idempotent and the refit UI can send exactly what
  /// the player sees.
  Refit(modules: List(#(String, String)), parts: List(#(String, String)))
```

In `client_message_decoder`, add the arm:

```gleam
    1, "refit" -> {
      use modules <- decode.field("modules", decode.list(slot_module_decoder()))
      use parts <- decode.field("parts", decode.list(mount_part_decoder()))
      decode.success(Ok(Refit(modules: modules, parts: parts)))
    }
```

with

```gleam
fn slot_module_decoder() -> decode.Decoder(#(String, String)) {
  use slot <- decode.field("slot", decode.string)
  use module_id <- decode.field("module", decode.string)
  decode.success(#(slot, module_id))
}

fn mount_part_decoder() -> decode.Decoder(#(String, String)) {
  use mount <- decode.field("mount", decode.string)
  use part_id <- decode.field("part", decode.string)
  decode.success(#(mount, part_id))
}
```

Add the two encoders:

```gleam
/// Serialize a `refit_result`. `reason` is null when `ok`, otherwise the
/// machine-readable reason `loadout.resolve` produced (`"tag_deficit:power"`,
/// `"out_of_slot_bounds:<module>"`, …) or `"not_docked"`.
pub fn encode_refit_result(result: Result(Nil, String)) -> String {
  let #(ok, reason) = case result {
    Ok(Nil) -> #(True, None)
    Error(reason) -> #(False, Some(reason))
  }
  json.object([
    #("v", json.int(version)),
    #("type", json.string("refit_result")),
    #("ok", json.bool(ok)),
    #("reason", json.nullable(reason, json.string)),
  ])
  |> json.to_string
}

/// Serialize a `ship_fit`: the ship's newly resolved class and the loadout
/// that produced it, pushed to its crew after a successful refit. Same
/// `ship_class` payload the `welcome` carries, so a client adopts it the same
/// way.
pub fn encode_ship_fit(
  ship_id: Int,
  class: ShipClass,
  lo: loadout.Loadout,
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("ship_fit")),
    #("ship_id", json.int(ship_id)),
    #("ship_class", shipclass.encode(class)),
    #(
      "loadout",
      json.object([
        #("hull", json.string(lo.hull)),
        #(
          "modules",
          json.array(lo.modules, fn(entry) {
            json.object([
              #("slot", json.string(entry.0)),
              #("module", json.string(entry.1)),
            ])
          }),
        ),
        #(
          "parts",
          json.array(lo.parts, fn(entry) {
            json.object([
              #("mount", json.string(entry.0)),
              #("part", json.string(entry.1)),
            ])
          }),
        ),
      ]),
    ),
  ])
  |> json.to_string
}
```

Add `import dh_server/loadout` to `protocol.gleam`, and document both messages in the module's header comment block alongside the existing message list, including the reason vocabulary:

```
//// {"v":1,"type":"refit","modules":[{"slot","module"}...],
////  "parts":[{"mount","part"}...]} — replace the whole loadout; docked only.
//// {"v":1,"type":"refit_result","ok":Bool,"reason":null|S} — reasons:
////   not_docked | unknown_hull | loadout_wrong_hull | slot_not_on_hull |
////   duplicate_slot | unknown_module | module_wrong_hull | module_wrong_slot |
////   mount_not_on_hull | duplicate_mount | unknown_part | mount_wrong_kind |
////   mount_too_small | out_of_slot_bounds:<module> | tag_deficit:<tag> |
////   invalid_resolved_plan:<detail>
//// {"v":1,"type":"ship_fit","ship_id":N,"ship_class":{...},"loadout":{...}}
```

- [ ] **Step 4: Handle `Refit` in the sim**

In `sim.gleam`, add the handler. It must:

1. Find the client's ship; `Error("not_docked")` unless `ship.dock` is `Docked(_, _)`. Refit is dockside work: you do not swap an engine under way.
2. Build `loadout.Loadout(hull: <the ship's current hull id>, modules:, parts:)` from the message.
3. `loadout.resolve(state.glyphs, hull, state.modules, state.parts, lo)`; on `Error(reason)` reply `encode_refit_result(Error(reason))` and change nothing — a refused refit must leave the ship exactly as it was.
4. On success: replace the ship's entry in `fits`, reply `encode_refit_result(Ok(Nil))`, push `encode_ship_fit(...)` to that ship's crew, and **rebuild the station's composite space** through the same path `dock`/`undock` already use, so everyone aboard and ashore gets a fresh `space` message with the new deck.
5. Clamp the hold: if the new `cargo_capacity` is smaller than what is aboard, the refit is refused with `Error("hold_over_capacity")` — silently deleting a player's cargo is not an acceptable failure mode. Add that reason to the protocol doc block.

- [ ] **Step 5: Run the suite**

Run: `cd server; gleam test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add server/src server/test
git commit -m "feat(refit): docked refit verb, refit_result + ship_fit pushes (#M4)"
```

---

### Task 10: Harness integration test

**Files:**
- Create: `harness/test_m4_refit.py`
- Modify: `harness/fixtures/test_fixture.json` (add one slot + a module for it)
- Create: `server/modules/test_fixture/bunkroom.json`

**Interfaces:**
- Consumes: `harness/dh_client.py`'s `DHClient`, the `server` fixture from `conftest.py`.

- [ ] **Step 1: Give the fixture hull one slot to refit**

In `harness/fixtures/test_fixture.json`, mark a small block of the Main deck's open floor with SW digit `1`, and add:

```jsonc
  "slots": [ { "digit": 1, "id": "bay", "name": "Bay" } ],
```

Leave `default_loadout.modules` empty — the fixture's bare state is "empty bay".

Create `server/modules/test_fixture/bunkroom.json`:

```json
{
  "schema": 1,
  "id": "test_fixture.bay.bunkroom",
  "hull": "test_fixture",
  "slot": "bay",
  "name": "Bunkroom",
  "mass": 4.0,
  "provides": { "berths": 2 },
  "requires": { "power": 1 },
  "patches": [
    { "deck": 0, "x": 0, "y": 0, "grid": ["   ", " d ", "   "] }
  ]
}
```

Set the patch's `x`/`y` to the tile you marked with digit `1`.

- [ ] **Step 2: Write the test**

Create `harness/test_m4_refit.py`, following the structure of `harness/test_m3_trade.py` (same `server` fixture, same `DHClient` login):

```python
"""M4 module engine: refit a docked ship and watch the resolved plan change.

The engine's whole promise is that a loadout swap is a real change to the
deck the server serves, not a cosmetic label — so these assertions read the
deck plan on the wire before and after, not a module list.
"""
```

Cases:
1. `test_welcome_carries_flight_stats` — the `welcome`'s `ship_class` has `flight.accel == 40.0` and `flight.turn_rate == 180.0`.
2. `test_refit_installs_a_module` — send `refit` with the bunkroom in `bay`; expect `refit_result.ok == True`, then a `ship_fit` whose `ship_class` deck rows differ from the welcome's at the patched tile, and a fresh `space` message.
3. `test_refit_while_flying_is_refused` — undock, send `refit`, expect `ok == False` and `reason == "not_docked"`, and confirm a following `ship_fit` never arrives.
4. `test_refit_with_unknown_module_is_refused` — `reason == "unknown_module:nope"`, and the ship's plan is unchanged afterwards.

- [ ] **Step 3: Run it**

Run: `cd harness; python -m pytest test_m4_refit.py -v`
Expected: PASS (first run is slow — it builds the Gleam server).

- [ ] **Step 4: Run the whole harness**

Run: `cd harness; python -m pytest -v`
Expected: PASS. If `test_deckplan.py` or `test_walk.py` trip on the SW slot digit, fix `harness/deckplan.py` to ignore corners the way the Gleam parser does — it reads centre and edge-mids only, so no change should be needed.

- [ ] **Step 5: Commit**

```bash
git add harness/test_m4_refit.py harness/fixtures/test_fixture.json server/modules/test_fixture
git commit -m "test(harness): M4 refit integration coverage (#M4)"
```

---

### Task 11: Schemas and documentation

**Files:**
- Modify: `server/schemas/ship_class.schema.json`
- Create: `server/schemas/module.schema.json`
- Create: `server/schemas/part.schema.json`
- Modify: `server/test/data_schema_test.gleam`
- Modify: `docs/modules.md`
- Modify: `DESIGN.md`

- [ ] **Step 1: Extend the hull schema**

In `server/schemas/ship_class.schema.json`, add `slots`, `mounts`, `mass`, `provides`, `requires` and `default_loadout` to `properties` (it is `additionalProperties: false`, so every new hull field must be listed or the schema test fails). Update the `title`/`description` to say this is the **authored hull document** decoded by `hull.gleam`, and that a resolved `ShipClass` is a different, wire-only shape.

Tag objects are `{"type": "object", "additionalProperties": {"type": "integer"}}`.

- [ ] **Step 2: Write the module and part schemas**

Create `server/schemas/module.schema.json` and `server/schemas/part.schema.json` mirroring `module.gleam`'s and `part.gleam`'s decoders exactly, `additionalProperties: false` at every level, each with a `description` naming the Gleam decoder as the source of truth (the house style in `ship_class.schema.json`).

- [ ] **Step 3: Validate the new data in `data_schema_test.gleam`**

Add constants and cases alongside the existing ones:

```gleam
const module_schema_path = "schemas/module.schema.json"

const part_schema_path = "schemas/part.schema.json"

const modules_dir = "modules"

const parts_dir = "parts"
```

and tests that validate every `server/modules/*/*.json` against the module schema and every `server/parts/*.json` against the part schema, following the existing directory-walking test for `shipclasses`.

- [ ] **Step 4: Run the suite**

Run: `cd server; gleam test`
Expected: PASS.

- [ ] **Step 5: Update `docs/modules.md`**

The doc is the design; bring its concrete shapes in line with what shipped:

- In "Data shapes", replace the sketched interior-module JSON with the real one (`patches` with `deck`/`x`/`y`/`grid`, not a whole `grid`), and the exterior part with the real one (`kind`/`size`/`thrust`/`torque`, not `flight: {thrust, handling}`).
- In "Slots and mounts", note that a mount is currently `{id, kind, size}` — mount *geometry* arrives with client-side layering in iteration 2.
- In "The M4 slice (iteration 1)", replace the bullet list with what actually landed and what moved to iterations 2 and 3 (see this plan's Scope section).
- Add the two authoring rules from Task 1 Step 6, with the reasoning: a module rewrites its slot completely including both halves of any interior partition; only the slot *perimeter* is shared with hull tiles, so the perimeter defaults to open (the module supplies its own walls and doors there) and a hull-side perimeter wall is a deliberate "no module ever opens this" declaration; and a stamp never overwrites the SW corner.
- Record that flight is `thrust / total_mass` and `torque / total_mass`, hull dry mass plus every fitted module and part.

- [ ] **Step 6: Update `DESIGN.md`**

- In "Ship customization", replace the shape-agnostic "modules rotate and fit any room" model with the authored per-hull overlay model, per `docs/modules.md`'s closing section.
- In "Open questions", the entry **"How much interior can a module rewrite?"** is resolved — replace it with the answer (a module rewrites only its slot, marked by the SW digit; the hull owns all structure outside slots and every corridor; connectivity is guaranteed by authoring, never analysed) or delete it and let the Ship customization text carry it.
- Leave the **"Exterior composition at runtime"** open question in place — client-side layering is iteration 2's work and is not proven yet.
- Do **not** mark M4 done in Milestones: this is iteration 1 of three.

- [ ] **Step 7: Commit**

```bash
git add server/schemas server/test/data_schema_test.gleam docs/modules.md DESIGN.md
git commit -m "docs(m4): schemas for modules/parts; modules.md + DESIGN.md match what shipped (#M4)"
```

---

## Definition of done

- `cd server; gleam test` — all suites green.
- `cd harness; python -m pytest -v` — all suites green.
- The Mockingbird's default loadout resolves to her pre-M4 authored deck, tile for tile (`default_loadout_reproduces_the_authored_deck_test`), at capacity 60, at 40 u/s² and 180°/s.
- A docked ship can swap a module and the server serves a different deck; refusals leave the ship untouched and name a machine-readable reason.
- No `main_accel` or `turn_rate` constants remain in `ship.gleam`; no `state.class` remains in `sim.gleam`.
