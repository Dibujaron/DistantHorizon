# Station classes, Q-derived berths, glyph registry — Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Extract station designs into `stationclasses/`, rename `classes/`→`shipclasses/`, derive station berths from `Q` glyphs with a per-ship standoff, and move the tile-glyph vocabulary into a runtime-loaded `glyphs.json` registry.

**Architecture:** A new `glyphs.gleam` registry loaded at startup threads a `Registry` into `deckplan` parsing, so `deckplan.gleam` stops hardcoding the legend. Stations become `StationClass` docs referenced from worlds by `class` id. Berths derive from `Q` glyphs (door-faces-void → orientation); the moored sim pose is computed from the berth tile + the docking ship's per-class `dock_standoff`.

**Tech Stack:** Gleam (server), GDScript/Godot (client), jesse JSON-schema validation via existing FFI. Spec: `docs/superpowers/specs/2026-07-19-station-classes-and-glyph-registry-design.md`.

## Global Constraints

- Gleam formatted (`gleam format src test`); a pre-commit hook blocks unformatted staged `.gleam`.
- Tests: `gleam test` from `server/`. Toolchain PATH: `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"`.
- Pinned stdlib has **no `list.range`**; use the local `range(from, to)` helper idiom.
- `decode.float` rejects bare JSON ints — floats must be written `5.0`.
- Schemas are typo-catchers (`additionalProperties:false`); decoders are the source of truth.
- One PR on branch `feat/station-classes-glyph-registry`.

---

### Task 1: Glyph registry data + schema + loader (#32 foundation)

**Files:**
- Create: `server/glyphs.json`, `server/schemas/glyphs.schema.json`
- Create: `server/src/dh_server/glyphs.gleam`
- Test: `server/test/glyphs_test.gleam`, extend `server/test/data_schema_test.gleam`

**Produces:** `glyphs.Registry`; `glyphs.load(path) -> Result(Registry, String)`; `glyphs.default() -> Registry` (the built-in legend, for tests/fallback); `registry.center(glyph) -> CenterSpec`, `registry.edge(glyph) -> Edge`. `CenterSpec` carries `tile: Tile`, `console: Option(String)`, `dock: Bool`, `spawn: Bool`.

- [ ] Author `glyphs.json` (centers: floor/void/stairs/helm/cargo/broker/dock/spawn; edges: open/wall/door/viewscreen) with `glyph,id,role,description`, `walkable`/`blocks`, `console`/`dock`, and client `sprite` fields (server ignores `sprite`/`description`). Shape per spec §#32.
- [ ] Write `glyphs.gleam`: `Registry` (dicts glyph→CenterSpec, glyph→Edge, plus kind→glyph inverse for encoding). Decoder + `load`. `default()` returns today's hardcoded legend so nothing depends on the file existing in unit tests. Unknown edge glyph → generic `Fixture(char)`; unknown center → `Floor` (matches current fallback).
- [ ] `glyphs.schema.json` mirrors the file; add a `glyphs_dir`/file case to `data_schema_test`.
- [ ] `glyphs_test`: load `glyphs.json`; `center("Q").dock == True`; `center(" ").tile == Floor`; `edge("#") == Wall`; `edge("v")` is `Fixture("v")`; `default()` agrees with loaded file on the core glyphs.
- [ ] `gleam format`, `gleam test`, commit.

---

### Task 2: deckplan consults the Registry (#32 wiring)

**Files:**
- Modify: `server/src/dh_server/deckplan.gleam`
- Modify: `server/test/deckplan_test.gleam`

**Consumes:** `glyphs.Registry`, `glyphs.default()`.
**Produces:** `parse_deck(reg, name, rows)`, `decoder(reg)`, `console_kind(reg, glyph)`, `console_glyph(reg, kind)`, and a shared `docking_ports(plan) -> List(#(Int,Int,Int,Dir))` (deck,x,y,outward_dir) used by both ship spawn and station berths.

- [ ] Thread `reg` through `parse_center`/`parse_edge`/`scan_markers`/`derive_markers`/`parse_deck`/`decoder`. `console_kind` now reads `reg.center(glyph).console`; dock is `.dock`; spawn is `.spawn`.
- [ ] Add `docking_ports(plan)`: for each deck, each `Q` tile, find the edge whose `Edge==Door` and whose neighbor tile is `Void`; that `Dir` is the outward normal. Refactor `derive_spawn` to pick the west-facing port via this list (ship mooring) — behavior unchanged.
- [ ] Existing `deckplan_test` updated to pass `glyphs.default()`; add a `docking_ports` test (north-facing and west-facing ports resolve correct `Dir`).
- [ ] `gleam test` (deckplan + downstream still green after signature change — update callers minimally to compile). Commit.

---

### Task 3: Registry reaches ship/world/station decoders + startup load

**Files:**
- Modify: `server/src/dh_server/shipclass.gleam`, `server/src/dh_server/world.gleam`, `server/src/dh_server.gleam`
- Modify: affected tests (`shipclass_test`, `world_test`, `dh_server_test`)

**Consumes:** Task 2 signatures.
**Produces:** `shipclass.decode(reg, text)`/`load(reg, path)`; `world.decode(reg, classes, text)`/`load(reg, classes, path)` (classes added in Task 4 — for now pass `reg` only, keep station shape).

- [ ] Add `reg` param to `shipclass.decode`/`load` and `world.decode`/`load`; startup in `dh_server.gleam` loads `glyphs.json` (env `DH_GLYPHS`, default `glyphs.json`, fallback `glyphs.default()` on read error) before world/class.
- [ ] Update all test call sites to pass `glyphs.default()`.
- [ ] `gleam test`, commit. (Pure plumbing; no behavior change yet.)

---

### Task 4: StationClass module + world references class (#30)

**Files:**
- Create: `server/src/dh_server/stationclass.gleam`, `server/schemas/station_class.schema.json`
- Rename dir: `server/classes/` → `server/shipclasses/`; create `server/stationclasses/highport.json`, `server/stationclasses/ring.json`
- Modify: `server/worlds/m1_system.json`, `server/src/dh_server/world.gleam`, `server/src/dh_server.gleam`, `server/schemas/world.schema.json`, `server/README.md`, `server/test/data_schema_test.gleam`, `server/test/world_test.gleam`
- Create: `server/test/stationclass_test.gleam`

**Consumes:** Task 3 signatures.
**Produces:** `stationclass.StationClass(id,name,dock_radius,crane,concourse)`; `stationclass.load(reg,path)`/`decode`; `world.load(reg, station_classes, path)` where `station_classes: dict(String, StationClass)`.

- [ ] `git mv classes shipclasses`; update `default_ship_class_path`→`shipclasses/mockingbird.json`, `classes_dir` in `data_schema_test`→`shipclasses`.
- [ ] Write `stationclass.gleam` mirroring `shipclass.gleam` (deck plan via `deckplan.decoder(reg)`, `dock_radius`, `crane`, validate: concourse geometry + broker console present). Extract `highport.json` (from meridian_highport) and `ring.json` (from solis_ring): concourse decks + dock_radius + crane. **Keep the concourse grids as-is here** (Q added in Task 6).
- [ ] `world.gleam`: `station_decoder` reads `class` (string) + per-instance `id/name/parent/orbit/market/spawn_station`; resolves `class` against the passed `station_classes` dict (unknown → decode failure). `Station` runtime type keeps `dock_radius/crane/concourse` (backfilled from the class). Remove inline concourse/dock_radius/crane decoding.
- [ ] Rewrite `worlds/m1_system.json` stations as instances (`class`, `market`, orbit). `dh_server.gleam` loads `stationclasses/*.json` into a dict (env `DH_STATION_CLASSES`, default `stationclasses`) and passes it to `world.load`.
- [ ] Schemas: new `station_class.schema.json`; `world.schema.json` station requires `class`, drops inline `concourse/dock_radius/crane` (berths handled Task 6). `data_schema_test` validates `stationclasses/` + shipclasses dir rename.
- [ ] `stationclass_test`: load highport/ring; missing broker → error. `world_test`: station resolves class; unknown class id → error.
- [ ] `gleam test`, commit.

---

### Task 5: Per-ship `dock_standoff` (#31 prep)

**Files:**
- Modify: `server/src/dh_server/shipclass.gleam`, `server/schemas/ship_class.schema.json`, `server/shipclasses/mockingbird.json`
- Modify: `server/test/shipclass_test.gleam`

**Produces:** `ShipClass.dock_standoff: Float` (meters, mooring-line→hull-center), optional field default `default_dock_standoff`.

- [ ] Add `dock_standoff` (optional_field, default constant chosen to preserve Mockingbird's current side-on pose — derive from its old anchor magnitude). Author it in `mockingbird.json`. Encode round-trips it. Schema documents it.
- [ ] `shipclass_test`: decodes present + defaulted.
- [ ] `gleam test`, commit.

---

### Task 6: Q-derived berths + computed mooring pose (#31)

**Files:**
- Modify: `server/stationclasses/highport.json`, `server/stationclasses/ring.json` (add `Q` glyphs)
- Modify: `server/src/dh_server/world.gleam`, `server/schemas/world.schema.json`, `server/schemas/station_class.schema.json`
- Modify: `server/src/dh_server/sim.gleam`, `server/src/dh_server/ship.gleam` (moored_position callers)
- Modify: `server/test/world_test.gleam`

**Consumes:** `deckplan.docking_ports` (Task 2), `ShipClass.dock_standoff` (Task 5).
**Produces:** `world.station_berths(station) -> List(Berth)` derived from the concourse; `world.moored_position(world, station_id, berth_index, standoff, t)` and `moored_heading` reading derived berths.

- [ ] Put `Q` at the berth tiles in each concourse (`(22,1)/(54,1)/(86,1)` highport; `(5,1)` ring), each with `=` on its **north** edge and `Void` north (matches existing berth-mouth structure). Verify `deck_to_rows` round-trip.
- [ ] `world.gleam`: derive `Berth` list from the concourse via `docking_ports` (north-facing). `Berth` keeps `x,y,orientation`; **drop `anchor`**. `moored_position` = `station_center + berth_planar_offset(tile, concourse_dims) + outward_normal(orientation) * standoff`. Add `standoff` param; thread the docking ship's `dock_standoff` from callers in `sim`/`ship`. Remove `berth_decoder`/`berth_tuple_decoder`/`encode_berth` and the `berths` optional_field; `validate_berths` → checks derived tiles (walkable, void outward).
- [ ] Schemas: remove `berths` from world station; note berths derive from `Q` in the station-class concourse.
- [ ] `world_test`: derived berths match the old tiles/orientation for both stations; `moored_position` with a known standoff lands at the expected pose; unknown berth index falls back to bare station pose.
- [ ] `gleam test`, commit.

---

### Task 7: Client — registry ids, station classes, derived berths (#30/#31/#32 client)

**Files:**
- Modify: `client/scripts/world_data.gd`, `client/scripts/ship_class_data.gd`, `client/scripts/space_data.gd`, `client/scripts/main.gd`, `client/scripts/asset_library.gd`, `client/scripts/interior_view.gd`, `client/scripts/network_client.gd` (as needed)
- Check wire shape emitted by `server/src/dh_server/protocol.gleam` / `server.gleam` `welcome`.

**Consumes:** the `welcome` wire shape the server now emits (station_classes table + refs; ship `dock_standoff`; derived berths; optional glyph registry with `sprite`).

- [ ] Confirm what `welcome` now carries (Task 4/6 changed station encoding). Update `world_data.gd`: station reads `class` + resolves against a `station_classes` table; `Berth` drops `anchor` (derived server-side and sent, or re-derived from `Q` client-side to match). `ship_class_data.gd` reads `dock_standoff`.
- [ ] Registry id→sprite: deliver `glyphs.json` (or its client subset) in `welcome`; `asset_library`/`interior_view` key sprites on long-form ids where they currently branch on raw glyphs. Keep changes minimal — only where the server shape moved.
- [ ] Manual: server boots, client connects, dock/undock at both stations reads correctly. (Playtest checkpoint — hand to user.)

---

### Task 8: Docs — deckplan-format.md points at the registry (#32)

**Files:**
- Modify: `docs/deckplan-format.md`

- [ ] Replace the glyph-key tables with prose that references `server/glyphs.json` as the source; keep the 3×3 model, collision rules, decks/stairs, "one fact one position" rationale. Note stations derive berths from `Q` (north-facing door) and ships from `Q` (west-facing), and that `dock_standoff` is per ship class.
- [ ] Commit.

---

## Self-Review notes

- Spec coverage: #30 → T4; #31 → T5,T6; #32 → T1,T2,T8; client → T7. ✓
- Signature threading: `reg` added in T2, propagated T3; `station_classes` dict added T4; `standoff` added T6 — each task updates its own call sites to keep `gleam test` green.
- Playtest gate is T7 (hand to user); PR after T8.
