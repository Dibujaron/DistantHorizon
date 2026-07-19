# Station classes, Q-derived berths, and a data-driven glyph registry

Design for GitHub issues **#30** (extract station classes + rename `classes/`),
**#31** (derive station berths from `Q` glyphs), and **#32** (formalize a JSON
glyph registry as the single source of truth for maps). One design, one PR.

The three are inseparable: #30 is where a station's concourse becomes the
canonical geometry, #31 makes that geometry the source of the berths, and #32
gives ships and stations one shared, moddable tile vocabulary that both the
extraction and the berth derivation lean on.

## Goals

- Stations are **reusable classes** referenced from worlds, exactly as ship
  classes are — the on-disk layout reads `shipclass ↔ stationclass`, both
  referenced from worlds.
- **One source of truth for docking geometry**: a `Q` glyph in the concourse
  grid *is* the berth. No parallel hand-tuned coord list.
- **One moddable tile vocabulary**: the server loads a glyph registry at
  runtime and interprets maps from it; adding a tile is a registry entry + a
  sprite, not a Gleam edit. This is the same externalization that already makes
  ships and stations data.

## Non-goals

- No change to the exterior visual pipeline: moored hulls still render at the
  station **sprite's** `"berth"` anchors (`world_view.gd`), indexed by berth
  number. This work only touches the *sim-space* mooring pose and the
  *interior/data* representation.
- Per-docking-port standoff (a ship with multiple ports, each a different
  size). We do **per-ship-class** standoff now; per-port is a later refinement.
- No new tiles are introduced here (#28 is separate); #32 only relocates the
  *existing* vocabulary into data so #28 becomes a registry entry.

---

## #30 — Station classes + folder rename

### On-disk layout

```
server/shipclasses/        (was server/classes/)
  mockingbird.json
server/stationclasses/     (new)
  highport.json            (3-berth crane ring — Meridian Highport's design)
  ring.json                (1-berth ring — Solis Ring's design)
```

The two current stations have different concourses and different `crane`
values, so they are two distinct classes — mirroring the sprite archetypes
(`ring_3berth_crane`, `ring_1berth`) that already exist client-side.

### Class vs. instance split

**Station class file** (intrinsic, reusable) — same shape family as a ship
class:

```jsonc
{
  "schema": 1,
  "id": "highport",
  "name": "Highport-class ring",
  "dock_radius": 150.0,
  "crane": true,
  "decks": [ /* the concourse, as deck grids — now with Q berths (see #31) */ ]
  // consoles/spawn derived from grid glyphs, as today
}
```

**World station entry** (per-instance placement + economy):

```jsonc
{
  "id": "meridian_highport",
  "name": "Meridian Highport",
  "class": "highport",
  "parent": "meridian",
  "orbit": { "radius": 850.0, "period_s": 180.0, "phase": 0.0 },
  "market": [ /* per-instance prices/stock — stays in the world */ ]
}
```

`market` is per-instance (each station trades at its own prices) and stays in
the world. `dock_radius` and `crane` are intrinsic to the design and move to
the class, per the ticket.

### Loading

- New module `server/src/dh_server/stationclass.gleam`, mirroring
  `shipclass.gleam`: `load(path)`, `decode(text)`, `encode`, `validate`. A
  `StationClass` holds `dock_radius`, `crane`, and a `deckplan.DeckPlan`
  concourse.
- `world.gleam`: `Station` keeps its runtime shape (it still carries the
  resolved `dock_radius`/`crane`/`concourse`), but the **decoder** now reads a
  `class` id + per-instance fields and resolves the class. World loading takes
  a station-class resolver: `world.load` / `world.decode` gain access to a
  `dict(String, StationClass)` (loaded from `server/stationclasses/*.json` at
  startup), and `station_decoder` looks each station's `class` up in it.
  Unknown class id → decode error, same rigor as the existing parent-id
  validation.
- `dh_server.gleam`: load all station classes from `stationclasses/` (dir
  overridable via `DH_STATION_CLASSES`, paralleling `DH_SHIP_CLASS`) before
  loading the world; pass the map into `world.load`. Update
  `default_ship_class_path` to `shipclasses/mockingbird.json`.

### Ripples

- `server/schemas/world.schema.json`: drop inlined `concourse`/`dock_radius`/
  `crane`/`berths` from the station object; add required `class`. New
  `server/schemas/station_class.schema.json` (typo-catcher, same philosophy as
  the others). `data_schema_test.gleam` validates the new files/dirs.
- Client: `world_data.gd` station parsing reads `class` + resolves against a
  station-class table delivered in `welcome`. **The wire `welcome` shape is a
  server concern** — the server still sends each station fully resolved
  (concourse included) OR sends a `station_classes` table plus class refs. We
  send a **`station_classes` table + refs** (symmetric with `ship_class`),
  keeping the client's resolve step tiny.
- Docs: `server/README.md` and any `classes/` references updated.

---

## #31 — Berths derived from `Q`, no `berths` array

### Deriving tile + orientation

A station berth is a `Q` docking-port glyph in the concourse grid whose `=`
door faces **void** — identical to how a ship's mooring tile is already derived
(`deckplan.derive_spawn`), except the outward edge is **north** (into space
above the concourse) rather than the ship's **west** flank.

Generalize the existing rule into shared `deckplan` logic:

- A **berth** is a `Q` tile with a `=` door on an edge whose neighbor is
  `Void`. That edge's direction is the berth's **outward normal**; orientation
  (world radians) derives from it. North-facing void → the M3.5 side-on look.
- The berth's `tile` is the glyph's `(x, y)`.
- `deckplan` exposes a `berths(plan)` (or `docking_ports`) query returning the
  ordered list of `#(deck, x, y, outward_dir)`; stations use it for their berth
  list, ships reuse it for the mooring tile. This is the one place `Q` is
  interpreted.

Concourse grids gain `Q` glyphs at the current berth tiles (Meridian:
`(22,1)`, `(54,1)`, `(86,1)`; Solis: `(5,1)`), each with a `=` on its north
edge and `Void` to the north — which already satisfies today's
`validate_berths` "walkable, void to north" rule.

### The sim mooring pose — per-ship standoff

The old per-berth world-space `anchor` is **dropped**. It lived in a
coordinate system shared with neither the concourse tiles nor the sprite
anchors, and the exterior visual never used it. The docked hull's sim pose is
now **computed**:

```
moored_pos = station_center
           + berth_planar_offset          # from the Q tile, concourse is 1 m/tile,
                                           # centered on the station origin
           + outward_normal * standoff     # standoff is a per-ship-class property
```

- `berth_planar_offset`: the `Q` tile's position relative to the concourse
  centroid, at 1 m per tile — gives each berth a distinct base point. (The
  visual is sprite-driven, so exact magnitude is not load-bearing; this just
  needs to be sensible and stable for a non-jumpy undock.)
- `outward_normal`: unit vector from the berth orientation.
- **`standoff`**: new per-ship-class field (e.g. `dock_standoff`, meters from
  the mooring line to the hull center). Some hulls are tiny, some have wide
  wings — there is no good constant, so it is authored per class and is the
  tuning lever. Default preserves the Mockingbird's current side-on pose.

`world.moored_position` gains the ship's `standoff` argument, exactly as
`world.moored_heading` already takes the ship's `ship_port`
(`dock_port_orientation`). Callers in `sim`/`ship` thread the docking ship's
class standoff through.

### Ripples

- `world.gleam`: `Station` loses its `berths` field; berths become a derived
  query over its concourse. `station_berth` / `moored_position` /
  `moored_heading` read from the derived list. Berth `berth_decoder` /
  `encode_berth` and the `berths` schema section are removed. `validate_berths`
  becomes "every derived berth tile is walkable with void to its outward side"
  (mostly satisfied by construction).
- `shipclass.gleam` + schema: add `dock_standoff`.
- Client: `world_data.gd` `Berth` derivation mirrors the server (or receives
  the derived berths in `welcome`); `anchor` field removed. `ship_class_data.gd`
  reads `dock_standoff`.

---

## #32 — Runtime-loaded glyph registry

### The registry

`server/glyphs.json` (loaded at startup; path overridable via `DH_GLYPHS`),
the canonical vocabulary the parser interprets maps from:

```jsonc
{
  "schema": 1,
  "centers": [
    { "glyph": " ", "id": "floor",        "role": "center", "walkable": true,  "description": "Open floor" },
    { "glyph": ".", "id": "void",         "role": "center", "walkable": false, "description": "Outside the hull" },
    { "glyph": "x", "id": "stairs",       "role": "center", "walkable": true,  "description": "Stair/ladder to the aligned tile on an adjacent deck" },
    { "glyph": "h", "id": "helm_console", "role": "center", "walkable": true,  "console": "helm",   "sprite": "console_helm" },
    { "glyph": "c", "id": "cargo_console","role": "center", "walkable": true,  "console": "cargo",  "sprite": "console_cargo" },
    { "glyph": "b", "id": "broker_console","role": "center","walkable": true,  "console": "broker", "sprite": "console_broker" },
    { "glyph": "Q", "id": "docking_port", "role": "center", "walkable": true,  "dock": true,        "sprite": "airlock" },
    { "glyph": "s", "id": "spawn",        "role": "center", "walkable": true }
  ],
  "edges": [
    { "glyph": " ", "id": "open",  "role": "edge", "blocks": false },
    { "glyph": "#", "id": "wall",  "role": "edge", "blocks": true,  "sprite": "wall" },
    { "glyph": "=", "id": "door",  "role": "edge", "blocks": false, "sprite": "door" },
    { "glyph": "v", "id": "viewscreen", "role": "edge-fixture", "blocks": true, "sprite": "viewscreen" }
  ]
}
```

- **`role`** disambiguates a letter by position (center vs. edge-mid fixture),
  as the format already does. Any edge glyph not `open`/`wall`/`door` is a
  fixture (matches today's `Fixture(char)` fallback), so the fixture list is
  the *named* subset; unknown edge letters still parse as generic fixtures.
- The **`sprite`** field is the client's id→sprite hook. The **server ignores
  it**; one file, server and client read the same ids. This is what makes a new
  tile a registry entry + a sprite with no code change — the modding payoff the
  ticket is after.

### Server change

- New `server/src/dh_server/glyphs.gleam`: `load(path) -> Registry`,
  and a `Registry` that answers `center(glyph) -> Tile/console-kind/dock/spawn`
  and `edge(glyph) -> Edge`.
- `deckplan.gleam` gets **less data-y**: `parse_center`, `parse_edge`,
  `console_kind`, and `console_glyph` stop hardcoding the legend and consult a
  `Registry` passed into `parse_deck` / `decoder`. The registry threads through
  `world.decode` / `shipclass.decode` / `stationclass.decode` (loaded once at
  startup in `dh_server.gleam`).
- `data_schema_test.gleam` (or a new `glyphs_test`) validates `glyphs.json`
  against a `server/schemas/glyphs.schema.json`.

### Docs

`docs/deckplan-format.md` is reduced to **prose/rationale** — the 3×3 tile
model, collision rules, decks/stairs, the "one fact one position" idea — and
**points at `glyphs.json` for the glyph tables** instead of re-listing them, so
the doc and the code can no longer drift.

### Client

`asset_library.gd` / `interior_view.gd` map **`id` → sprite** using the
registry's `sprite` field (keyed on long-form ids, not raw glyphs), delivered
in `welcome` alongside the class tables. Art is decoupled from the single-char
encoding.

---

## Sequencing within the one PR

1. **#32 first** — stand up `glyphs.json` + `glyphs.gleam`, make `deckplan`
   consult a registry. Everything else then speaks the shared vocabulary.
2. **#30** — extract station classes, rename the folder, add the resolver.
3. **#31** — put `Q` in the concourses, derive berths, add per-ship
   `dock_standoff`, drop the `berths` array/anchor.

Each step keeps the suite green before the next.

## Testing

- `glyphs_test`: registry loads; `center`/`edge` lookups; unknown edge → generic
  fixture; round-trip a small deck through `parse_deck` + `deck_to_rows`.
- `world_test`: station resolves its `class`; unknown class → error; berths
  derived from `Q` match the old hand-authored tiles/orientation; `moored_*`
  poses with a given standoff.
- `stationclass_test`: load/validate a class; missing concourse/broker caught.
- `shipclass_test`: `dock_standoff` decodes + defaults.
- `data_schema_test`: new schemas + moved data files validate.
- Client parity is covered by the existing interior probe harness pattern where
  it applies.

## Migration

`schema` bumps: `glyphs.json` schema 1 (new); station class schema 1 (new);
world schema stays 2 but its station shape changes (class ref, no inline
concourse/berths) — there is only one world file, migrated in this PR. Ship
class stays schema 3 with an added optional `dock_standoff`.
