# M3 — Trade on Foot: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Milestone M3 from DESIGN.md — station concourses (reusing the interior tech), walking off the ship at dock, buying/selling at a broker console, cargo transfer with handling times (cranes vs. robot stevedores), and Classic's noise-walk dynamic prices.

**Architecture:** The Gleam sim actor grows three data layers, all "content is data": deck plans get extracted into a shared `deckplan` module so station concourses reuse the exact ship-interior tech (grid/walkable/rooms/consoles); the world doc (schema 2) gains commodities, per-station markets, crane flags and inline concourse plans; ships gain a wallet/hold/transfer-queue. Characters gain a `Place` (aboard their crew ship vs. ashore on a station concourse) while keeping `ship_id` as crew membership, which extends the existing interest-management fan-out with two new 15 Hz channels: `concourse` (per-station, to occupants) and `cargo`+`market` (to crew / concourse occupants). The Godot client renders concourses through the existing InteriorView (same data shape) and adds a keyboard trade panel bound to broker consoles.

**Tech Stack:** Gleam/OTP server (mist, gleam_json), Godot 4.7 GDScript client, Python pytest+websockets harness. No new dependencies.

## Global Constraints

- Protocol stays **v1, additive** — existing messages unchanged except documented new `reason` values; every new message carries `{"v":1,"type":...}`.
- Wire float/int rule: Gleam `decode.float` rejects bare ints and `decode.int` rejects floats. `buy`/`sell` `quantity` is a JSON **int**; `move`/`helm` fields stay JSON **floats**. Harness and client must coerce accordingly (see M2-RESULTS.md).
- Content is data: commodities, markets, crane flags, concourse layouts, cargo capacity/handling are all JSON config. No content in code.
- Server is authoritative; client stays a renderer + input device.
- Workflow: all work on branch `m3-trade-on-foot`; **never commit to main** — finish with a PR (user's standing PR-workflow preference).
- Test commands assume `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"` (gleam/erlang/godot shims). Server tests: `cd server; gleam test`. Integration: `cd harness; python -m pytest` (port 8484 must be free).
- Sim constants: 60 Hz tick (`ship.dt`), 15 Hz broadcasts (`snapshot_every = 4`). New timed processes (transfers, price epochs) derive from sim time `t = tick * ship.dt`, never wall clock.

## Design decisions (resolved for this milestone)

1. **Concourses are deck plans.** Extract `deckplan.gleam` (grid/walkable/rooms/consoles/spawn_tile + geometry validation) out of `shipclass.gleam`. A ship class = schema/id/name + plan + cargo block; a concourse = a bare plan embedded in the world doc's station entry. Client-side, `ShipClassData` already tolerates missing id/name, so concourses parse with the same class.
2. **Character place model.** `Character` keeps `ship_id` (crew membership — drives ship despawn and cargo fan-out) and gains `place: Aboard | OnStation(station_id)` (where the body is — drives which plan you walk, seat occupancy scope, and interior vs. concourse fan-out). Disembark keeps you crew of your ship; a ship with crew ashore does **not** despawn.
3. **Trading gate.** `buy`/`sell` require: body seated at a **broker-kind console** on a concourse, AND your crew ship docked at that same station. `get_market` is looser: works ashore or docked-aboard (feeds the cargo-console manifest view).
4. **Transfer semantics.** Buy: wallet debited and station stock removed at order time (price locked); units arrive in the hold over time. Sell: units leave the hold at order time; wallet credited per unit as it lands (price locked). Rate: break-bulk hulls always use robots (`1.0` u/s); container hulls need a crane (`5.0` u/s) and get `no_crane` where there is none. **Undock is blocked mid-transfer** (`transfer_in_progress`) — the pacing beat from DESIGN.md, and it keeps transfers station-bound.
5. **Prices are Classic's noise walk:** `price = max(1, base + noise(seed_stream, epoch) * elasticity)`, epoch = 60 s of sim time, smoothstep-interpolated value noise so prices drift instead of jumping. Stock regenerates toward its initial level every 5 s. All pure functions of (world seed, station, commodity, epoch) — deterministic, unit-testable without waiting.
6. **Sparrow becomes a break-bulk tramp:** ship class schema 2 adds `"cargo": {"capacity": 40, "handling": "breakbulk"}`. The crane path is exercised by unit tests with a container-hull fixture; the shipped world trades by robots (Firefly-class niche, per DESIGN.md).
7. **The ship's cargo console binds as a read-only manifest** (client-side view of the `cargo`/`market` messages); buying/selling stays on foot at brokers. This honors M2's "M3 binds it" note without violating "business happens on foot".

## File structure

Server (Gleam):
- Create: `server/src/dh_server/deckplan.gleam` — shared interior geometry (from shipclass.gleam)
- Create: `server/src/dh_server/noise.gleam` — deterministic 1D value noise
- Create: `server/src/dh_server/market.gleam` — stores, price walk, stock ops
- Create: `server/src/dh_server/cargo.gleam` — buy/sell validation + timed transfers
- Modify: `shipclass.gleam` (schema 2 + cargo), `world.gleam` (schema 2), `character.gleam` (place), `ship.gleam` (wallet/hold/transfers), `protocol.gleam` (new messages), `sim.gleam` (markets, place-aware handlers, new fan-outs), `server.gleam` (dispatch)
- Data: `server/classes/sparrow.json` (schema 2), `server/worlds/m1_system.json` (schema 2: commodities, markets, concourses)
- Tests: create `deckplan_test.gleam`, `noise_test.gleam`, `market_test.gleam`, `cargo_test.gleam`; extend the rest.

Harness (Python): modify `harness/dh_client.py`; create `harness/test_m3_trade.py`; extend `harness/test_automation_smoke.py`.

Client (Godot): create `client/scripts/cargo_state.gd`, `client/scripts/market_data.gd`; modify `network_client.gd`, `world_data.gd`, `ship_class_data.gd`, `main.gd`, `automation_server.gd`, `scenes/main.tscn`, `project.godot`.

Docs: create `docs/M3-RESULTS.md`; update `DESIGN.md`.

## Task overview

1. Extract `deckplan.gleam`; ship class schema 2 (cargo block)
2. `noise.gleam` — deterministic value noise
3. World doc schema 2 — commodities, markets, crane, concourses (+ authored content)
4. `market.gleam` — stores, price walk, stock ops
5. Character `Place` + concourse helpers
6. Ship wallet/hold/transfers + `cargo.gleam`
7. Protocol v1 additions
8. Sim: markets, disembark/board/trade handlers, new fan-outs
9. Server dispatch
10. Harness client + M3 integration tests
11. Client: data classes + network layer
12. Client: place flow, concourse rendering, disembark key
13. Client: trade panel + cargo HUD
14. Client: automation dump + smoke test
15. Docs, results, PR

---

### Task 1: Extract `deckplan.gleam`; ship class schema 2

Pure refactor plus data: no behavior change except ship class docs gaining a required `cargo` block (schema 2).

**Files:**
- Create: `server/src/dh_server/deckplan.gleam`
- Create: `server/test/deckplan_test.gleam`
- Modify: `server/src/dh_server/shipclass.gleam` (rewrite)
- Modify: `server/src/dh_server/character.gleam` (params: `ShipClass` → `DeckPlan`)
- Modify: `server/src/dh_server/sim.gleam` (call sites: `state.class` → `state.class.plan`)
- Modify: `server/classes/sparrow.json`
- Modify: `server/test/shipclass_test.gleam`, `server/test/character_test.gleam` (mechanical updates)

**Interfaces:**
- Consumes: current `shipclass.gleam` types.
- Produces: `deckplan.DeckPlan(grid, walkable, rooms, consoles, spawn_tile)`, `deckplan.Grid/Room/Console` (same shapes as today's shipclass types), `deckplan.is_walkable(plan, x, y)`, `find_console(plan, id)`, `find_console_of_kind(plan, kind)`, `validate(plan)`, `decoder()`, `encode(plan)`, `encode_fields(plan)`. `shipclass.ShipClass(schema, id, name, plan: DeckPlan, cargo_capacity: Int, handling: Handling)` with `Handling = BreakBulk | Container`, `shipclass.helm_console(class)`. `character.step/try_sit/is_at_helm/spawn_*` now take `DeckPlan`.

- [ ] **Step 1: Create branch**

```powershell
git checkout -b m3-trade-on-foot
```

- [ ] **Step 2: Write `server/src/dh_server/deckplan.gleam`**

Move the geometry out of shipclass.gleam. Full module:

```gleam
//// Shared interior deck-plan geometry: the tile grid, rooms, consoles and
//// spawn tile that both ship classes (shipclass.gleam) and station
//// concourses (world.gleam) are built from. Interior coordinates are tile
//// units, y-down; tile `(x, y)` spans `[x, x+1) x [y, y+1)`, center
//// `(x+0.5, y+0.5)`.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/string

pub type Grid {
  Grid(width: Int, height: Int)
}

/// A labelled rectangle of tiles, for rendering/labels only (no door graph).
pub type Room {
  Room(id: String, name: String, x: Int, y: Int, w: Int, h: Int)
}

/// A single-tile interactable. `kind` is e.g. `"helm"`, `"cargo"` or
/// `"broker"`.
pub type Console {
  Console(id: String, kind: String, x: Int, y: Int)
}

pub type DeckPlan {
  DeckPlan(
    grid: Grid,
    /// One string per row, top to bottom; `'#'` walkable, anything else
    /// (canonically `'.'`) hull/void.
    walkable: List(String),
    rooms: List(Room),
    consoles: List(Console),
    /// Tile where arriving characters appear (the airlock end).
    spawn_tile: #(Int, Int),
  )
}

/// Whether tile `(x, y)` is in bounds and walkable.
pub fn is_walkable(plan: DeckPlan, x: Int, y: Int) -> Bool {
  case x >= 0 && x < plan.grid.width && y >= 0 && y < plan.grid.height {
    False -> False
    True -> {
      let assert Ok(row) = list.drop(plan.walkable, y) |> list.first
      string.slice(from: row, at_index: x, length: 1) == "#"
    }
  }
}

/// Look up a console by id.
pub fn find_console(plan: DeckPlan, console_id: String) -> Result(Console, Nil) {
  list.find(plan.consoles, fn(c) { c.id == console_id })
}

/// The first console of `kind`, if any.
pub fn find_console_of_kind(
  plan: DeckPlan,
  kind: String,
) -> Result(Console, Nil) {
  list.find(plan.consoles, fn(c) { c.kind == kind })
}

/// Geometry validation shared by every deck-plan host: walkable rows match
/// the grid, every console and the spawn tile sit on walkable tiles.
/// Host-specific console requirements (a ship class needs a helm, a trading
/// concourse needs a broker) live with the host document.
pub fn validate(plan: DeckPlan) -> Result(DeckPlan, String) {
  use <- guard(
    list.length(plan.walkable) == plan.grid.height,
    "walkable row count does not match grid.height",
  )
  use <- guard(
    !list.any(plan.walkable, fn(row) {
      string.length(row) != plan.grid.width
    }),
    "a walkable row's length does not match grid.width",
  )
  use <- guard(
    !list.any(plan.consoles, fn(c) { !is_walkable(plan, c.x, c.y) }),
    "a console is not on a walkable tile",
  )
  let #(sx, sy) = plan.spawn_tile
  use <- guard(
    is_walkable(plan, sx, sy),
    "spawn_tile is not on a walkable tile",
  )
  Ok(plan)
}

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

/// Decodes the deck-plan fields (grid/walkable/rooms/consoles/spawn_tile)
/// from the *current* JSON object — ship class docs carry them at their top
/// level, station concourses as a nested object; the same decoder serves
/// both.
pub fn decoder() -> decode.Decoder(DeckPlan) {
  use grid <- decode.field("grid", grid_decoder())
  use walkable <- decode.field("walkable", decode.list(decode.string))
  use rooms <- decode.field("rooms", decode.list(room_decoder()))
  use consoles <- decode.field("consoles", decode.list(console_decoder()))
  use spawn_tile <- decode.field("spawn_tile", tile_decoder())
  decode.success(DeckPlan(
    grid: grid,
    walkable: walkable,
    rooms: rooms,
    consoles: consoles,
    spawn_tile: spawn_tile,
  ))
}

/// The deck-plan fields as a key/value list, for hosts that embed them at
/// the top level of their own object (ship class docs).
pub fn encode_fields(plan: DeckPlan) -> List(#(String, Json)) {
  [
    #("grid", encode_grid(plan.grid)),
    #("walkable", json.array(plan.walkable, json.string)),
    #("rooms", json.array(plan.rooms, encode_room)),
    #("consoles", json.array(plan.consoles, encode_console)),
    #("spawn_tile", encode_tile(plan.spawn_tile)),
  ]
}

/// A deck plan as its own JSON object (station concourses).
pub fn encode(plan: DeckPlan) -> Json {
  json.object(encode_fields(plan))
}

fn grid_decoder() -> decode.Decoder(Grid) {
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  decode.success(Grid(width: width, height: height))
}

fn room_decoder() -> decode.Decoder(Room) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  use w <- decode.field("w", decode.int)
  use h <- decode.field("h", decode.int)
  decode.success(Room(id: id, name: name, x: x, y: y, w: w, h: h))
}

fn console_decoder() -> decode.Decoder(Console) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  decode.success(Console(id: id, kind: kind, x: x, y: y))
}

fn tile_decoder() -> decode.Decoder(#(Int, Int)) {
  use coords <- decode.then(decode.list(decode.int))
  case coords {
    [x, y] -> decode.success(#(x, y))
    _ -> decode.failure(#(0, 0), "two-element [x, y] array")
  }
}

fn encode_grid(grid: Grid) -> Json {
  json.object([
    #("width", json.int(grid.width)),
    #("height", json.int(grid.height)),
  ])
}

fn encode_room(room: Room) -> Json {
  json.object([
    #("id", json.string(room.id)),
    #("name", json.string(room.name)),
    #("x", json.int(room.x)),
    #("y", json.int(room.y)),
    #("w", json.int(room.w)),
    #("h", json.int(room.h)),
  ])
}

fn encode_console(console: Console) -> Json {
  json.object([
    #("id", json.string(console.id)),
    #("kind", json.string(console.kind)),
    #("x", json.int(console.x)),
    #("y", json.int(console.y)),
  ])
}

fn encode_tile(tile: #(Int, Int)) -> Json {
  let #(x, y) = tile
  json.preprocessed_array([json.int(x), json.int(y)])
}
```

- [ ] **Step 3: Rewrite `server/src/dh_server/shipclass.gleam`**

Ship class = document header + deck plan + cargo block. Full module:

```gleam
//// Ship class documents (schema 2): a hull's deck plan plus the cargo
//// characteristics M3 trading needs (DESIGN.md "content is data"). One
//// class exists (`server/classes/sparrow.json`, path overridable via
//// `DH_SHIP_CLASS`); every ship in the sim is spawned from the same loaded
//// `ShipClass`. The whole document is sent verbatim to clients as
//// `ship_class` in the `welcome` message, so `encode` round-trips exactly
//// what was loaded.

import dh_server/deckplan.{type Console, type DeckPlan}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// How cargo physically gets aboard (DESIGN.md "Cargo handling"):
/// break-bulk hulls load by robot stevedores anywhere; container hulls
/// need a station crane and never open their holds.
pub type Handling {
  BreakBulk
  Container
}

pub type ShipClass {
  ShipClass(
    schema: Int,
    id: String,
    name: String,
    plan: DeckPlan,
    /// Hold size in cargo units.
    cargo_capacity: Int,
    handling: Handling,
  )
}

/// Read and decode a ship class document from a file. `path` is resolved
/// relative to the process's working directory.
pub fn load(path: String) -> Result(ShipClass, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(err) {
      "failed to read ship class file " <> path <> ": " <> string.inspect(err)
    }),
  )
  decode(text)
}

/// Decode a ship class document from a JSON string, validating the deck
/// plan's geometry and that the class has a helm console.
pub fn decode(json_text: String) -> Result(ShipClass, String) {
  case json.parse(json_text, ship_class_decoder()) {
    Ok(class) -> validate(class)
    Error(err) -> Error("invalid ship class document: " <> string.inspect(err))
  }
}

/// Encode a ship class document, e.g. for the `welcome` message. The deck
/// plan's fields stay at the top level (the M2 shape), with the schema-2
/// `cargo` block appended.
pub fn encode(class: ShipClass) -> Json {
  json.object(
    [
      #("schema", json.int(class.schema)),
      #("id", json.string(class.id)),
      #("name", json.string(class.name)),
    ]
    |> list.append(deckplan.encode_fields(class.plan))
    |> list.append([#("cargo", encode_cargo(class))]),
  )
}

/// The first console of kind `"helm"` — every valid class has one.
pub fn helm_console(class: ShipClass) -> Result(Console, Nil) {
  deckplan.find_console_of_kind(class.plan, "helm")
}

fn validate(class: ShipClass) -> Result(ShipClass, String) {
  use _ <- result.try(deckplan.validate(class.plan))
  case helm_console(class) {
    Error(Nil) -> Error("no console of kind \"helm\"")
    Ok(_) ->
      case class.cargo_capacity >= 0 {
        False -> Error("cargo.capacity must be >= 0")
        True -> Ok(class)
      }
  }
}

fn handling_decoder() -> decode.Decoder(Handling) {
  use raw <- decode.then(decode.string)
  case raw {
    "breakbulk" -> decode.success(BreakBulk)
    "container" -> decode.success(Container)
    _ -> decode.failure(BreakBulk, "\"breakbulk\" or \"container\"")
  }
}

fn cargo_decoder() -> decode.Decoder(#(Int, Handling)) {
  use capacity <- decode.field("capacity", decode.int)
  use handling <- decode.field("handling", handling_decoder())
  decode.success(#(capacity, handling))
}

fn ship_class_decoder() -> decode.Decoder(ShipClass) {
  use schema <- decode.field("schema", decode.int)
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use plan <- decode.then(deckplan.decoder())
  use cargo <- decode.field("cargo", cargo_decoder())
  let #(capacity, handling) = cargo
  decode.success(ShipClass(
    schema: schema,
    id: id,
    name: name,
    plan: plan,
    cargo_capacity: capacity,
    handling: handling,
  ))
}

fn encode_cargo(class: ShipClass) -> Json {
  let handling = case class.handling {
    BreakBulk -> "breakbulk"
    Container -> "container"
  }
  json.object([
    #("capacity", json.int(class.cargo_capacity)),
    #("handling", json.string(handling)),
  ])
}
```

- [ ] **Step 4: Update `server/classes/sparrow.json` to schema 2**

Change `"schema": 1` to `"schema": 2` and add a cargo block after `"spawn_tile": [5, 4]`:

```jsonc
{
  "schema": 2, "id": "sparrow", "name": "CV-7 Sparrow",
  // ... grid/walkable/rooms/consoles unchanged ...
  "spawn_tile": [5, 4],
  "cargo": {"capacity": 40, "handling": "breakbulk"}
}
```

- [ ] **Step 5: Update `server/src/dh_server/character.gleam` to take `DeckPlan`**

Mechanical: replace `import dh_server/shipclass.{type ShipClass}` with `import dh_server/deckplan.{type DeckPlan}`; every parameter `class: ShipClass` becomes `plan: DeckPlan` (rename body references too); `shipclass.helm_console(class)` in `spawn_seated_at_helm` becomes `deckplan.find_console_of_kind(plan, "helm")` (keep the `let assert Ok(console)`); `shipclass.find_console(class, ...)` becomes `deckplan.find_console(plan, ...)`; `shipclass.is_walkable(class, ...)` becomes `deckplan.is_walkable(plan, ...)`. Signatures after the change (bodies otherwise identical):

```gleam
pub fn spawn_seated_at_helm(id: Int, name: String, ship_id: Int, plan: DeckPlan) -> Character
pub fn spawn_at_spawn_tile(id: Int, name: String, ship_id: Int, plan: DeckPlan) -> Character
pub fn spawn_position(plan: DeckPlan) -> #(Float, Float)
pub fn step(character: Character, plan: DeckPlan) -> Character
pub fn try_sit(character: Character, plan: DeckPlan, console_id: String, occupied: Bool) -> Result(Character, String)
pub fn is_at_helm(character: Character, plan: DeckPlan) -> Bool
fn circle_walkable(plan: DeckPlan, cx: Float, cy: Float) -> Bool
```

- [ ] **Step 6: Update `server/src/dh_server/sim.gleam` call sites**

Everywhere the sim hands `state.class` to a character function, pass `state.class.plan` instead. Exact sites: `character.spawn_seated_at_helm(..., state.class.plan)` in `AddPlayer`; `character.is_at_helm(char, state.class.plan)` in `SetControls` and `with_helm_ship`; `character.try_sit(char, state.class.plan, console, occupied)` in `RequestSit`; `character.step(c, state.class.plan)` in `run_tick`; `character.spawn_position(state.class.plan)` in `handle_board`. The `State.class: ShipClass` field itself is unchanged.

- [ ] **Step 7: Move geometry tests into `server/test/deckplan_test.gleam`; update `shipclass_test.gleam` and `character_test.gleam`**

`deckplan_test.gleam` — geometry tests against a hand-built plan (no file dependency):

```gleam
import dh_server/deckplan.{Console, DeckPlan, Grid, Room}

fn plan() -> deckplan.DeckPlan {
  DeckPlan(
    grid: Grid(width: 3, height: 2),
    walkable: ["###", ".##"],
    rooms: [Room(id: "r", name: "Room", x: 0, y: 0, w: 3, h: 2)],
    consoles: [Console(id: "desk", kind: "broker", x: 1, y: 0)],
    spawn_tile: #(1, 1),
  )
}

pub fn is_walkable_and_bounds_test() {
  assert deckplan.is_walkable(plan(), 0, 0)
  assert !deckplan.is_walkable(plan(), 0, 1)
  assert !deckplan.is_walkable(plan(), -1, 0)
  assert !deckplan.is_walkable(plan(), 3, 0)
}

pub fn find_console_by_id_and_kind_test() {
  let assert Ok(c) = deckplan.find_console(plan(), "desk")
  assert c.kind == "broker"
  assert deckplan.find_console(plan(), "nope") == Error(Nil)
  let assert Ok(_) = deckplan.find_console_of_kind(plan(), "broker")
  assert deckplan.find_console_of_kind(plan(), "helm") == Error(Nil)
}

pub fn validate_accepts_good_plan_test() {
  assert deckplan.validate(plan()) == Ok(plan())
}

pub fn validate_rejects_console_off_walkable_test() {
  let bad =
    DeckPlan(..plan(), consoles: [Console(id: "d", kind: "broker", x: 0, y: 1)])
  let assert Error(_) = deckplan.validate(bad)
}

pub fn validate_rejects_bad_spawn_tile_test() {
  let bad = DeckPlan(..plan(), spawn_tile: #(0, 1))
  let assert Error(_) = deckplan.validate(bad)
}

pub fn validate_rejects_row_count_mismatch_test() {
  let bad = DeckPlan(..plan(), walkable: ["###"])
  let assert Error(_) = deckplan.validate(bad)
}
```

`shipclass_test.gleam`: update `valid_doc()` and every inline bad-doc string to schema 2 with a cargo block — append `,"cargo":{"capacity":10,"handling":"breakbulk"}` before the closing brace of each doc and change `"schema":1` to `"schema":2`. Field assertions change `c.grid` to `c.plan.grid`, `c.walkable` to `c.plan.walkable`, `c.rooms`/`c.consoles`/`c.spawn_tile` likewise, and `c.schema == 1` to `c.schema == 2`. The import line becomes `import dh_server/deckplan.{Console, Grid}` for the type constructors it asserts against. Add:

```gleam
pub fn decode_reads_cargo_block_test() {
  let assert Ok(c) = shipclass.load("classes/sparrow.json")
  assert c.cargo_capacity == 40
  assert c.handling == shipclass.BreakBulk
}

pub fn decode_rejects_unknown_handling_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,1],"
    <> "\"cargo\":{\"capacity\":10,\"handling\":\"antigrav\"}}"
  let assert Error(_) = shipclass.decode(bad)
}

pub fn decode_rejects_missing_cargo_block_test() {
  let bad =
    "{\"schema\":2,\"id\":\"tiny\",\"name\":\"Tiny\","
    <> "\"grid\":{\"width\":3,\"height\":2},"
    <> "\"walkable\":[\"###\",\"###\"],"
    <> "\"rooms\":[],"
    <> "\"consoles\":[{\"id\":\"helm_main\",\"kind\":\"helm\",\"x\":1,\"y\":0}],"
    <> "\"spawn_tile\":[1,1]}"
  let assert Error(_) = shipclass.decode(bad)
}
```

`character_test.gleam`: wherever it loaded/built a `ShipClass` and passed it to character functions, pass `class.plan` (or build a `DeckPlan` directly). Mechanical; keep every assertion.

- [ ] **Step 8: Run the server tests**

Run: `cd server; gleam test`
Expected: all pass (previous count plus the new deckplan/shipclass tests). Fix any missed call site the compiler flags.

- [ ] **Step 9: Commit**

```powershell
git add -A
git commit -m "refactor(server): extract deckplan from shipclass; ship class schema 2 with cargo block"
```

### Task 2: `noise.gleam` — deterministic value noise

**Files:**
- Create: `server/src/dh_server/noise.gleam`
- Create: `server/test/noise_test.gleam`

**Interfaces:**
- Produces: `noise.hash(seed: Int, x: Int) -> Int`, `noise.seed_string(seed: Int, text: String) -> Int`, `noise.lattice(seed: Int, x: Int) -> Float` (in [-1, 1]), `noise.at(seed: Int, x: Float) -> Float` (smoothly interpolated, in [-1, 1]). Task 4's `market.price_at` consumes `seed_string` and `at`.

- [ ] **Step 1: Write failing tests (`server/test/noise_test.gleam`)**

```gleam
import dh_server/noise
import gleam/float
import gleam/int
import gleam/list

pub fn hash_is_deterministic_test() {
  assert noise.hash(42, 7) == noise.hash(42, 7)
  assert noise.hash(42, 7) != noise.hash(42, 8)
  assert noise.hash(42, 7) != noise.hash(43, 7)
}

pub fn seed_string_is_deterministic_and_distinct_test() {
  assert noise.seed_string(1, "machinery") == noise.seed_string(1, "machinery")
  assert noise.seed_string(1, "machinery") != noise.seed_string(1, "water")
  assert noise.seed_string(1, "machinery") != noise.seed_string(2, "machinery")
}

pub fn lattice_stays_in_unit_range_test() {
  list.each(list.range(0, 200), fn(x) {
    let v = noise.lattice(99, x)
    assert v >=. -1.0 && v <=. 1.0
  })
}

pub fn lattice_varies_test() {
  let values = list.map(list.range(0, 20), noise.lattice(99, _))
  assert list.unique(values) |> list.length > 1
}

pub fn at_matches_lattice_on_integers_test() {
  assert noise.at(7, 3.0) == noise.lattice(7, 3)
}

pub fn at_is_continuous_test() {
  // Adjacent samples 0.01 apart may never jump by more than a generous
  // bound; catches interpolation bugs (e.g. jumping straight between
  // lattice values).
  list.each(list.range(0, 100), fn(i) {
    let x = 0.05 *. int.to_float(i)
    let delta = float.absolute_value(noise.at(7, x) -. noise.at(7, x +. 0.01))
    assert delta <. 0.2
  })
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server; gleam test`
Expected: compile failure — module `dh_server/noise` does not exist.

- [ ] **Step 3: Write `server/src/dh_server/noise.gleam`**

```gleam
//// Deterministic 1D value noise: the price-walk generator ported from
//// Classic's NoiseUtils (DynamicCommodityStore's
//// `price = initial + noise(seed, updateCount) * elasticity`). Pure
//// integer hashing — no RNG state — so the same (seed, x) always produces
//// the same value in every test and on every node.

import gleam/float
import gleam/int
import gleam/list
import gleam/string

const mask_64 = 0xffffffffffffffff

const golden = 0x9e3779b97f4a7c15

const mix_1 = 0xbf58476d1ce4e5b9

const mix_2 = 0x94d049bb133111eb

/// SplitMix64 finalizer over (seed, x): a well-mixed 64-bit integer.
pub fn hash(seed: Int, x: Int) -> Int {
  let z = int.bitwise_and(seed + x * golden, mask_64)
  let z = mix(z, 30, mix_1)
  let z = mix(z, 27, mix_2)
  int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
}

fn mix(z: Int, shift: Int, multiplier: Int) -> Int {
  int.bitwise_and(
    int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, shift))
      * multiplier,
    mask_64,
  )
}

/// Fold a string into a seed, for per-(station, commodity) noise streams.
pub fn seed_string(seed: Int, text: String) -> Int {
  string.to_utf_codepoints(text)
  |> list.fold(seed, fn(acc, cp) {
    hash(acc, string.utf_codepoint_to_int(cp))
  })
}

/// Lattice value at integer coordinate `x`, uniform in [-1.0, 1.0].
pub fn lattice(seed: Int, x: Int) -> Float {
  let bits = int.bitwise_and(hash(seed, x), 0xfffff)
  int.to_float(bits) /. 524_287.5 -. 1.0
}

/// Smoothly interpolated value noise at continuous `x`, in [-1.0, 1.0]:
/// a smoothstep blend between the two neighbouring lattice values, so
/// consecutive price epochs drift instead of jumping.
pub fn at(seed: Int, x: Float) -> Float {
  let x0f = float.floor(x)
  let x0 = float.round(x0f)
  let f = x -. x0f
  let t = f *. f *. { 3.0 -. 2.0 *. f }
  lattice(seed, x0) *. { 1.0 -. t } +. lattice(seed, x0 + 1) *. t
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server; gleam test`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add server/src/dh_server/noise.gleam server/test/noise_test.gleam
git commit -m "feat(server): deterministic 1D value noise for the price walk"
```

### Task 3: World doc schema 2 — commodities, markets, crane, concourses

**Files:**
- Modify: `server/src/dh_server/world.gleam`
- Modify: `server/worlds/m1_system.json`
- Modify: `server/test/world_test.gleam`

**Interfaces:**
- Consumes: `deckplan.DeckPlan`, `deckplan.decoder()`, `deckplan.encode`, `deckplan.validate`, `deckplan.find_console_of_kind` (Task 1).
- Produces: `world.Commodity(id: String, name: String)`, `world.MarketEntry(commodity: String, initial: Int, price: Int, elasticity: Int)`, `world.Station` gains `crane: Bool`, `concourse: Option(deckplan.DeckPlan)`, `market: List(MarketEntry)`; `world.World` gains `commodities: List(Commodity)`. All new JSON fields are decoded with `decode.optional_field` (defaults `False` / `None` / `[]`), so schema-1 fixtures still load.

- [ ] **Step 1: Write failing tests (add to `server/test/world_test.gleam`)**

```gleam
pub fn load_reads_trade_fields_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  assert list.length(w.commodities) == 4
  let assert Ok(highport) = world.get_station(w, "meridian_highport")
  assert highport.crane == True
  let assert option.Some(plan) = highport.concourse
  assert plan.spawn_tile == #(4, 4)
  assert list.length(highport.market) == 4
  let assert Ok(solis) = world.get_station(w, "solis_ring")
  assert solis.crane == False
}

pub fn decode_defaults_trade_fields_when_absent_test() {
  // A schema-1 station (no crane/concourse/market keys) must still load.
  let doc =
    "{\"schema\":1,\"name\":\"T\",\"seed\":1,"
    <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
    <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
    <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
    <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
    <> "\"dock_radius\":10.0}],"
    <> "\"spawn_station\":\"stn\"}"
  let assert Ok(w) = world.decode(doc)
  let assert Ok(stn) = world.get_station(w, "stn")
  assert stn.crane == False
  assert stn.concourse == option.None
  assert stn.market == []
  assert w.commodities == []
}

pub fn decode_rejects_market_with_unknown_commodity_test() {
  let doc = tiny_world_with_market("[{\"commodity\":\"unobtainium\",\"initial\":5,\"price\":10,\"elasticity\":1}]")
  let assert Error(_) = world.decode(doc)
}

pub fn decode_rejects_market_without_concourse_test() {
  // Market present, but no concourse at all.
  let doc =
    "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
    <> "\"commodities\":[{\"id\":\"water\",\"name\":\"Water\"}],"
    <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
    <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
    <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
    <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
    <> "\"dock_radius\":10.0,"
    <> "\"market\":[{\"commodity\":\"water\",\"initial\":5,\"price\":10,\"elasticity\":1}]}],"
    <> "\"spawn_station\":\"stn\"}"
  let assert Error(_) = world.decode(doc)
}

pub fn decode_rejects_market_without_broker_console_test() {
  // Concourse exists but has no broker-kind console.
  let doc = tiny_world_with_concourse_consoles("[]")
  let assert Error(_) = world.decode(doc)
}

pub fn decode_accepts_market_with_broker_console_test() {
  let doc =
    tiny_world_with_concourse_consoles(
      "[{\"id\":\"broker_main\",\"kind\":\"broker\",\"x\":1,\"y\":0}]",
    )
  let assert Ok(_) = world.decode(doc)
}

/// Tiny valid world with one station whose market is `market_json` and
/// whose concourse has a broker console.
fn tiny_world_with_market(market_json: String) -> String {
  "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
  <> "\"commodities\":[{\"id\":\"water\",\"name\":\"Water\"}],"
  <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
  <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
  <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
  <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
  <> "\"dock_radius\":10.0,"
  <> "\"concourse\":{\"grid\":{\"width\":3,\"height\":2},"
  <> "\"walkable\":[\"###\",\"###\"],\"rooms\":[],"
  <> "\"consoles\":[{\"id\":\"broker_main\",\"kind\":\"broker\",\"x\":1,\"y\":0}],"
  <> "\"spawn_tile\":[1,1]},"
  <> "\"market\":" <> market_json <> "}],"
  <> "\"spawn_station\":\"stn\"}"
}

/// Same tiny world, market fixed to water, concourse consoles swappable.
fn tiny_world_with_concourse_consoles(consoles_json: String) -> String {
  "{\"schema\":2,\"name\":\"T\",\"seed\":1,"
  <> "\"commodities\":[{\"id\":\"water\",\"name\":\"Water\"}],"
  <> "\"bodies\":[{\"id\":\"star\",\"name\":\"S\",\"kind\":\"star\","
  <> "\"parent\":null,\"orbit\":null,\"radius\":10.0,\"mu\":0.0}],"
  <> "\"stations\":[{\"id\":\"stn\",\"name\":\"Stn\",\"parent\":\"star\","
  <> "\"orbit\":{\"radius\":50.0,\"period_s\":60.0,\"phase\":0.0},"
  <> "\"dock_radius\":10.0,"
  <> "\"concourse\":{\"grid\":{\"width\":3,\"height\":2},"
  <> "\"walkable\":[\"###\",\"###\"],\"rooms\":[],"
  <> "\"consoles\":" <> consoles_json <> ","
  <> "\"spawn_tile\":[1,1]},"
  <> "\"market\":[{\"commodity\":\"water\",\"initial\":5,\"price\":10,\"elasticity\":1}]}],"
  <> "\"spawn_station\":\"stn\"}"
}
```

Add `import gleam/option` and `import gleam/list` to the test's imports if missing. Existing world tests keep passing unchanged (decoder defaults cover them; the encode round-trip test will exercise the new fields once m1_system.json carries them).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server; gleam test`
Expected: FAIL — `Station` has no `crane`/`concourse`/`market` fields, world doc has no commodities.

- [ ] **Step 3: Extend `server/src/dh_server/world.gleam`**

Add `import dh_server/deckplan` at the top. New/changed types:

```gleam
pub type Commodity {
  Commodity(id: String, name: String)
}

/// A station's dealing terms for one commodity: starting stock, base
/// price, and how far the noise walk may swing the price (Classic's
/// initial/price/elasticity triple from Stn_*.properties).
pub type MarketEntry {
  MarketEntry(commodity: String, initial: Int, price: Int, elasticity: Int)
}

pub type Station {
  Station(
    id: String,
    name: String,
    parent: String,
    orbit: Orbit,
    dock_radius: Float,
    /// Container-crane berths (the fast handling path; container hulls can
    /// only trade where this is True).
    crane: Bool,
    /// Walkable concourse interior; None means crews cannot go ashore.
    concourse: Option(deckplan.DeckPlan),
    market: List(MarketEntry),
  )
}

pub type World {
  World(
    schema: Int,
    name: String,
    seed: Int,
    commodities: List(Commodity),
    bodies: List(Body),
    stations: List(Station),
    spawn_station: String,
  )
}
```

New decoders, and the extended station/world decoders (`decode.optional_field` keeps schema-1 docs loading):

```gleam
fn commodity_decoder() -> decode.Decoder(Commodity) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(Commodity(id: id, name: name))
}

fn market_entry_decoder() -> decode.Decoder(MarketEntry) {
  use commodity <- decode.field("commodity", decode.string)
  use initial <- decode.field("initial", decode.int)
  use price <- decode.field("price", decode.int)
  use elasticity <- decode.field("elasticity", decode.int)
  decode.success(MarketEntry(
    commodity: commodity,
    initial: initial,
    price: price,
    elasticity: elasticity,
  ))
}

fn station_decoder() -> decode.Decoder(Station) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use parent <- decode.field("parent", decode.string)
  use orbit <- decode.field("orbit", orbit_decoder())
  use dock_radius <- decode.field("dock_radius", decode.float)
  use crane <- decode.optional_field("crane", False, decode.bool)
  use concourse <- decode.optional_field(
    "concourse",
    None,
    decode.optional(deckplan.decoder()),
  )
  use market <- decode.optional_field(
    "market",
    [],
    decode.list(market_entry_decoder()),
  )
  decode.success(Station(
    id: id,
    name: name,
    parent: parent,
    orbit: orbit,
    dock_radius: dock_radius,
    crane: crane,
    concourse: concourse,
    market: market,
  ))
}
```

In `world_decoder()` add (before `bodies`): `use commodities <- decode.optional_field("commodities", [], decode.list(commodity_decoder()))` and thread it into the record.

Validation — extend the existing `validate` by chaining a trade check onto its success branch: change the final `True -> Ok(world)` to `True -> validate_trade(world)`, and add:

```gleam
/// Trade-layer validation: markets reference declared commodities; every
/// concourse is geometrically valid; a station that trades has somewhere
/// to trade (a concourse with a broker-kind console).
fn validate_trade(world: World) -> Result(World, String) {
  let commodity_ids = list.map(world.commodities, fn(c) { c.id })
  list.fold(world.stations, Ok(world), fn(acc, station) {
    use _ <- result.try(acc)
    use _ <- result.try(case station.concourse {
      None -> Ok(world)
      Some(plan) ->
        deckplan.validate(plan)
        |> result.map_error(fn(e) {
          "station " <> station.id <> " concourse: " <> e
        })
        |> result.replace(world)
    })
    use _ <- result.try(
      case
        list.find(station.market, fn(entry) {
          !list.contains(commodity_ids, entry.commodity)
        })
      {
        Ok(entry) ->
          Error(
            "station "
            <> station.id
            <> " trades unknown commodity: "
            <> entry.commodity,
          )
        Error(Nil) -> Ok(world)
      },
    )
    case station.market, station.concourse {
      [], _ -> Ok(world)
      [_, ..], None ->
        Error("station " <> station.id <> " has a market but no concourse")
      [_, ..], Some(plan) ->
        case deckplan.find_console_of_kind(plan, "broker") {
          Ok(_) -> Ok(world)
          Error(Nil) ->
            Error(
              "station " <> station.id <> " has a market but no broker console",
            )
        }
    }
  })
}
```

(`result.replace(world)` maps `Ok(_)` to `Ok(world)`; if the installed stdlib lacks it, use `|> result.map(fn(_) { world })`.)

Encoding — `encode` gains `#("commodities", json.array(world.commodities, encode_commodity))` after `seed`; `encode_station` gains three fields; add:

```gleam
fn encode_commodity(commodity: Commodity) -> Json {
  json.object([
    #("id", json.string(commodity.id)),
    #("name", json.string(commodity.name)),
  ])
}

fn encode_market_entry(entry: MarketEntry) -> Json {
  json.object([
    #("commodity", json.string(entry.commodity)),
    #("initial", json.int(entry.initial)),
    #("price", json.int(entry.price)),
    #("elasticity", json.int(entry.elasticity)),
  ])
}
```

and in `encode_station`, after `dock_radius`:

```gleam
    #("crane", json.bool(station.crane)),
    #("concourse", json.nullable(station.concourse, deckplan.encode)),
    #("market", json.array(station.market, encode_market_entry)),
```

- [ ] **Step 4: Author the M3 content in `server/worlds/m1_system.json`**

Replace the file with (bodies and orbits unchanged from M1; stations gain the trade layer):

```json
{
  "schema": 2,
  "name": "Krasny Sector (M1 pinned system)",
  "seed": 20260712,
  "commodities": [
    {"id": "water", "name": "Water"},
    {"id": "food", "name": "Foodstuffs"},
    {"id": "machinery", "name": "Machinery"},
    {"id": "luxuries", "name": "Luxuries"}
  ],
  "bodies": [
    {"id": "krasny", "name": "Krasny", "kind": "star", "parent": null,
     "orbit": null, "radius": 500.0, "mu": 20000000.0},
    {"id": "meridian", "name": "Meridian", "kind": "planet", "parent": "krasny",
     "orbit": {"radius": 4000.0, "period_s": 900.0, "phase": 0.0},
     "radius": 150.0, "mu": 250000.0},
    {"id": "tefiti", "name": "Te Fiti", "kind": "planet", "parent": "krasny",
     "orbit": {"radius": 8000.0, "period_s": 2400.0, "phase": 0.35},
     "radius": 200.0, "mu": 400000.0}
  ],
  "stations": [
    {"id": "meridian_highport", "name": "Meridian Highport", "parent": "meridian",
     "orbit": {"radius": 400.0, "period_s": 180.0, "phase": 0.0}, "dock_radius": 150.0,
     "crane": true,
     "concourse": {
       "grid": {"width": 10, "height": 6},
       "walkable": [
         "..........",
         ".########.",
         ".########.",
         ".########.",
         "....#.....",
         ".........."
       ],
       "rooms": [
         {"id": "concourse", "name": "Concourse", "x": 1, "y": 1, "w": 8, "h": 3},
         {"id": "airlock",   "name": "Airlock",   "x": 4, "y": 4, "w": 1, "h": 1}
       ],
       "consoles": [
         {"id": "broker_main", "kind": "broker", "x": 4, "y": 3},
         {"id": "broker_east", "kind": "broker", "x": 7, "y": 2}
       ],
       "spawn_tile": [4, 4]
     },
     "market": [
       {"commodity": "water",     "initial": 120, "price": 4,  "elasticity": 1},
       {"commodity": "food",      "initial": 80,  "price": 10, "elasticity": 2},
       {"commodity": "machinery", "initial": 60,  "price": 55, "elasticity": 4},
       {"commodity": "luxuries",  "initial": 20,  "price": 78, "elasticity": 5}
     ]},
    {"id": "solis_ring", "name": "Solis Ring", "parent": "krasny",
     "orbit": {"radius": 2000.0, "period_s": 500.0, "phase": 0.6}, "dock_radius": 150.0,
     "crane": false,
     "concourse": {
       "grid": {"width": 8, "height": 5},
       "walkable": [
         "........",
         ".######.",
         ".######.",
         "...#....",
         "........"
       ],
       "rooms": [
         {"id": "concourse", "name": "Concourse", "x": 1, "y": 1, "w": 6, "h": 2},
         {"id": "airlock",   "name": "Airlock",   "x": 3, "y": 3, "w": 1, "h": 1}
       ],
       "consoles": [
         {"id": "broker_main", "kind": "broker", "x": 3, "y": 2}
       ],
       "spawn_tile": [3, 3]
     },
     "market": [
       {"commodity": "water",     "initial": 100, "price": 3,  "elasticity": 1},
       {"commodity": "food",      "initial": 50,  "price": 14, "elasticity": 2},
       {"commodity": "machinery", "initial": 30,  "price": 75, "elasticity": 6},
       {"commodity": "luxuries",  "initial": 40,  "price": 60, "elasticity": 6}
     ]}
  ],
  "spawn_station": "meridian_highport"
}
```

Economy notes baked into these numbers: machinery is the eastbound route (buy ~55 at Meridian, sell ~75 at Solis; profitable at every noise extreme), luxuries the westbound one (60 → 78). Both concourse spawn tiles sit exactly 1.0 tiles from `broker_main` (inside the 1.2 sit range), so tests can sit without walking. Starting wallet 2000 with capacity 40 and machinery at 55 makes both `insufficient_hold` (buy 45) and `insufficient_funds` (buy 38, cost 2090) reachable over the wire.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd server; gleam test`
Expected: PASS, including the pre-existing world round-trip test now exercising the new fields.

- [ ] **Step 6: Commit**

```powershell
git add -A
git commit -m "feat(server): world schema 2 - commodities, station markets, cranes, concourses"
```

### Task 4: `market.gleam` — stores, price walk, stock ops

**Files:**
- Create: `server/src/dh_server/market.gleam`
- Create: `server/test/market_test.gleam`

**Interfaces:**
- Consumes: `noise.seed_string`/`noise.at` (Task 2), `world.World`/`Commodity`/`MarketEntry` (Task 3).
- Produces: `market.Store(commodity, name, initial, quantity, base_price, elasticity, price)`, `market.Market(station_id, stores: List(Store))`, `market.init(world) -> List(Market)`, `price_epoch(t: Float) -> Int`, `regen_epoch(t: Float) -> Int`, `price_at(seed, station_id, commodity, base, elasticity, epoch) -> Int`, `reprice(market, seed, epoch)`, `regen(market)`, `find_store(market, commodity) -> Result(Store, Nil)`, `take_stock(market, commodity, quantity) -> Result(#(Market, Store), String)` (errors `"not_sold_here"` | `"insufficient_stock"`), `add_stock(market, commodity, quantity) -> Market`. Constants `price_period_s = 60.0`, `regen_period_s = 5.0`.

- [ ] **Step 1: Write failing tests (`server/test/market_test.gleam`)**

```gleam
import dh_server/market
import dh_server/world
import gleam/list

fn load_world() -> world.World {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  w
}

pub fn init_builds_one_market_per_station_at_initial_stock_test() {
  let w = load_world()
  let markets = market.init(w)
  assert list.length(markets) == 2
  let assert Ok(highport) =
    list.find(markets, fn(m) { m.station_id == "meridian_highport" })
  assert list.length(highport.stores) == 4
  let assert Ok(machinery) = market.find_store(highport, "machinery")
  assert machinery.quantity == 60
  assert machinery.initial == 60
  assert machinery.name == "Machinery"
  // Epoch-0 price is within the elasticity band and floored at 1.
  assert machinery.price >= 55 - 4 && machinery.price <= 55 + 4
}

pub fn price_at_is_deterministic_test() {
  assert market.price_at(20_260_712, "solis_ring", "machinery", 75, 6, 3)
    == market.price_at(20_260_712, "solis_ring", "machinery", 75, 6, 3)
}

pub fn price_at_varies_across_epochs_test() {
  let prices =
    list.map(list.range(0, 40), fn(epoch) {
      market.price_at(20_260_712, "solis_ring", "machinery", 75, 6, epoch)
    })
  assert list.unique(prices) |> list.length > 1
}

pub fn price_at_stays_in_band_and_floors_at_one_test() {
  list.each(list.range(0, 40), fn(epoch) {
    let p = market.price_at(1, "stn", "water", 2, 5, epoch)
    assert p >= 1
    // base 2, elasticity 5: raw walk can go to -3, price must floor at 1.
    assert p <= 7
  })
}

pub fn epochs_derive_from_sim_time_test() {
  assert market.price_epoch(0.0) == 0
  assert market.price_epoch(59.9) == 0
  assert market.price_epoch(60.0) == 1
  assert market.regen_epoch(4.9) == 0
  assert market.regen_epoch(5.0) == 1
}

pub fn take_stock_decrements_and_reports_errors_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "meridian_highport" })
  let assert Ok(#(m2, store)) = market.take_stock(m, "machinery", 10)
  assert store.quantity == 60
  let assert Ok(after) = market.find_store(m2, "machinery")
  assert after.quantity == 50
  assert market.take_stock(m2, "machinery", 51)
    == Error("insufficient_stock")
  assert market.take_stock(m2, "unobtainium", 1) == Error("not_sold_here")
}

pub fn add_stock_increments_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "solis_ring" })
  let m2 = market.add_stock(m, "machinery", 7)
  let assert Ok(store) = market.find_store(m2, "machinery")
  assert store.quantity == 37
}

pub fn regen_moves_quantity_toward_initial_from_both_sides_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "meridian_highport" })
  // Deplete machinery (initial 60, step = max(1, 60/20) = 3).
  let assert Ok(#(depleted, _)) = market.take_stock(m, "machinery", 60)
  let assert Ok(s1) = market.find_store(market.regen(depleted), "machinery")
  assert s1.quantity == 3
  // Overstock: 60 + 30 regenerates downward by 3.
  let overstocked = market.add_stock(m, "machinery", 30)
  let assert Ok(s2) = market.find_store(market.regen(overstocked), "machinery")
  assert s2.quantity == 87
  // Already at initial: no movement.
  let assert Ok(s3) = market.find_store(market.regen(m), "machinery")
  assert s3.quantity == 60
}

pub fn reprice_updates_every_store_deterministically_test() {
  let w = load_world()
  let assert Ok(m) =
    list.find(market.init(w), fn(m) { m.station_id == "solis_ring" })
  let repriced = market.reprice(m, w.seed, 12)
  let assert Ok(store) = market.find_store(repriced, "machinery")
  assert store.price
    == market.price_at(w.seed, "solis_ring", "machinery", 75, 6, 12)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server; gleam test`
Expected: compile failure — module `dh_server/market` does not exist.

- [ ] **Step 3: Write `server/src/dh_server/market.gleam`**

```gleam
//// Station markets: per-station commodity stores with Classic's noise-walk
//// dynamic prices (DynamicCommodityStore ported — see DESIGN.md "dynamic
//// prices ported from Classic"). Prices are a pure function of
//// (world seed, station, commodity, epoch): no state to persist, identical
//// on every node, testable without waiting. Stock is mutated by trades and
//// regenerates toward its authored initial level.

import dh_server/noise
import dh_server/world.{type World}
import gleam/float
import gleam/int
import gleam/list

/// Prices re-roll every 60 s of sim time.
pub const price_period_s = 60.0

/// Stock regenerates one step toward initial every 5 s of sim time.
pub const regen_period_s = 5.0

/// Price epochs per noise lattice step: higher = smoother drift.
const epochs_per_lattice = 4.0

pub type Store {
  Store(
    commodity: String,
    name: String,
    initial: Int,
    quantity: Int,
    base_price: Int,
    elasticity: Int,
    price: Int,
  )
}

pub type Market {
  Market(station_id: String, stores: List(Store))
}

/// One market per station (possibly with no stores), stocked at initial
/// levels and priced at epoch 0. Market entries referencing unknown
/// commodities were rejected at world load, so the lookup cannot fail on a
/// validated world.
pub fn init(world: World) -> List(Market) {
  list.map(world.stations, fn(station) {
    let stores =
      list.filter_map(station.market, fn(entry) {
        case
          list.find(world.commodities, fn(c) { c.id == entry.commodity })
        {
          Error(Nil) -> Error(Nil)
          Ok(commodity) ->
            Ok(Store(
              commodity: entry.commodity,
              name: commodity.name,
              initial: entry.initial,
              quantity: entry.initial,
              base_price: entry.price,
              elasticity: entry.elasticity,
              price: price_at(
                world.seed,
                station.id,
                entry.commodity,
                entry.price,
                entry.elasticity,
                0,
              ),
            ))
        }
      })
    Market(station_id: station.id, stores: stores)
  })
}

pub fn price_epoch(t: Float) -> Int {
  float.round(float.floor(t /. price_period_s))
}

pub fn regen_epoch(t: Float) -> Int {
  float.round(float.floor(t /. regen_period_s))
}

/// The Classic price walk: base + noise * elasticity, floored at 1. The
/// noise stream is seeded per (world, station, commodity) so every store
/// walks independently but reproducibly.
pub fn price_at(
  seed: Int,
  station_id: String,
  commodity: String,
  base: Int,
  elasticity: Int,
  epoch: Int,
) -> Int {
  let stream = noise.seed_string(noise.seed_string(seed, station_id), commodity)
  let wiggle = noise.at(stream, int.to_float(epoch) /. epochs_per_lattice)
  int.max(1, base + float.round(wiggle *. int.to_float(elasticity)))
}

/// Re-roll every store's price for `epoch`.
pub fn reprice(market: Market, seed: Int, epoch: Int) -> Market {
  Market(
    ..market,
    stores: list.map(market.stores, fn(store) {
      Store(
        ..store,
        price: price_at(
          seed,
          market.station_id,
          store.commodity,
          store.base_price,
          store.elasticity,
          epoch,
        ),
      )
    }),
  )
}

/// Move each store's quantity one regen step (max(1, initial / 20)) toward
/// its initial level, from either direction.
pub fn regen(market: Market) -> Market {
  Market(
    ..market,
    stores: list.map(market.stores, fn(store) {
      let step = int.max(1, store.initial / 20)
      let delta = int.clamp(store.initial - store.quantity, -step, step)
      Store(..store, quantity: store.quantity + delta)
    }),
  )
}

pub fn find_store(market: Market, commodity: String) -> Result(Store, Nil) {
  list.find(market.stores, fn(s) { s.commodity == commodity })
}

/// Remove `quantity` units from a store, returning the updated market and
/// the store *as it was at sale time* (its `price` is the locked unit
/// price). `Error("not_sold_here")` for unknown commodities,
/// `Error("insufficient_stock")` when stock is short.
pub fn take_stock(
  market: Market,
  commodity: String,
  quantity: Int,
) -> Result(#(Market, Store), String) {
  case find_store(market, commodity) {
    Error(Nil) -> Error("not_sold_here")
    Ok(store) ->
      case store.quantity >= quantity {
        False -> Error("insufficient_stock")
        True ->
          Ok(#(
            replace_store(
              market,
              Store(..store, quantity: store.quantity - quantity),
            ),
            store,
          ))
      }
  }
}

/// Add `quantity` units to a store (deliveries from a selling ship).
/// Unknown commodities are ignored — sell offers were validated against
/// the store before any transfer started.
pub fn add_stock(market: Market, commodity: String, quantity: Int) -> Market {
  case find_store(market, commodity) {
    Error(Nil) -> market
    Ok(store) ->
      replace_store(market, Store(..store, quantity: store.quantity + quantity))
  }
}

fn replace_store(market: Market, updated: Store) -> Market {
  Market(
    ..market,
    stores: list.map(market.stores, fn(s) {
      case s.commodity == updated.commodity {
        True -> updated
        False -> s
      }
    }),
  )
}
```

(If `int.clamp` takes labelled arguments in the installed stdlib, write `int.clamp(store.initial - store.quantity, min: -step, max: step)`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server; gleam test`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add server/src/dh_server/market.gleam server/test/market_test.gleam
git commit -m "feat(server): station markets with Classic noise-walk prices and stock regen"
```

### Task 5: Character `Place` + concourse helpers

**Files:**
- Modify: `server/src/dh_server/character.gleam`
- Modify: `server/test/character_test.gleam`
- Modify: `server/src/dh_server/sim.gleam` (only if the compiler flags a record construction — the spawn helpers set `place` internally, and every existing record update uses `Character(..char, ...)`, so normally nothing changes here yet)

**Interfaces:**
- Produces: `character.Place = Aboard | OnStation(station_id: String)`; `Character` gains `place: Place` (spawns default `Aboard`); `character.disembark_to(character, plan: DeckPlan, station_id: String) -> Character`; `character.seated_at_kind(character, plan, kind) -> Bool` (and `is_at_helm` becomes a wrapper over it); `character.same_place(a, b) -> Bool`. Task 8 consumes all three.

- [ ] **Step 1: Write failing tests (add to `server/test/character_test.gleam`)**

The file already builds characters/plans; add (adapting the plan-construction helper names to whatever the file already uses — if it loads the sparrow class, use `class.plan`):

```gleam
pub fn spawns_are_aboard_test() {
  let assert Ok(class) = shipclass.load("classes/sparrow.json")
  let c = character.spawn_seated_at_helm(1, "ada", 1, class.plan)
  assert c.place == character.Aboard
  let c2 = character.spawn_at_spawn_tile(2, "grace", 1, class.plan)
  assert c2.place == character.Aboard
}

pub fn disembark_to_moves_ashore_standing_at_spawn_test() {
  let assert Ok(class) = shipclass.load("classes/sparrow.json")
  let c =
    character.spawn_seated_at_helm(1, "ada", 1, class.plan)
    |> character.set_move(1.0, 0.0)
  // Use the ship plan as a stand-in concourse plan: spawn tile [5, 4].
  let ashore = character.disembark_to(c, class.plan, "meridian_highport")
  assert ashore.place == character.OnStation("meridian_highport")
  assert ashore.x == 5.5
  assert ashore.y == 4.5
  assert ashore.seat == option.None
  assert ashore.move_dx == 0.0
  assert ashore.move_dy == 0.0
  // Crew membership survives going ashore.
  assert ashore.ship_id == 1
}

pub fn seated_at_kind_matches_console_kind_test() {
  let assert Ok(class) = shipclass.load("classes/sparrow.json")
  let c = character.spawn_seated_at_helm(1, "ada", 1, class.plan)
  assert character.seated_at_kind(c, class.plan, "helm")
  assert !character.seated_at_kind(c, class.plan, "broker")
  let assert Ok(standing) = character.stand(c)
  assert !character.seated_at_kind(standing, class.plan, "helm")
}

pub fn same_place_scopes_by_ship_and_station_test() {
  let assert Ok(class) = shipclass.load("classes/sparrow.json")
  let aboard_1 = character.spawn_at_spawn_tile(1, "a", 1, class.plan)
  let aboard_1b = character.spawn_at_spawn_tile(2, "b", 1, class.plan)
  let aboard_2 = character.spawn_at_spawn_tile(3, "c", 2, class.plan)
  let ashore_m = character.disembark_to(aboard_1, class.plan, "meridian_highport")
  let ashore_m2 = character.disembark_to(aboard_2, class.plan, "meridian_highport")
  let ashore_s = character.disembark_to(aboard_1b, class.plan, "solis_ring")
  assert character.same_place(aboard_1, aboard_1b)
  assert !character.same_place(aboard_1, aboard_2)
  assert character.same_place(ashore_m, ashore_m2)
  assert !character.same_place(ashore_m, ashore_s)
  assert !character.same_place(aboard_1, ashore_m)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server; gleam test`
Expected: compile failure — `Place`, `place`, `disembark_to`, `seated_at_kind`, `same_place` don't exist.

- [ ] **Step 3: Extend `server/src/dh_server/character.gleam`**

Add the place type and field:

```gleam
/// Where a character's body is: aboard their crew ship, or ashore on a
/// station concourse. Crew membership is `ship_id` either way — going
/// ashore does not stop you being crew (or keeping your ship alive).
pub type Place {
  Aboard
  OnStation(station_id: String)
}
```

`Character` gains `place: Place` (put it after `ship_id`). Both spawn constructors set `place: Aboard`. Add the three functions:

```gleam
/// Step ashore: standing at `plan`'s spawn tile on `station_id`'s
/// concourse, seat and buffered move input cleared (same reasoning as
/// boarding: input held at the moment of transition was aimed at the old
/// deck and must not fire on the new one).
pub fn disembark_to(
  character: Character,
  plan: DeckPlan,
  station_id: String,
) -> Character {
  let #(x, y) = spawn_position(plan)
  Character(
    ..character,
    place: OnStation(station_id),
    x: x,
    y: y,
    seat: None,
    move_dx: 0.0,
    move_dy: 0.0,
  )
}

/// Whether `character` is seated at a console of `kind` on `plan`.
pub fn seated_at_kind(
  character: Character,
  plan: DeckPlan,
  kind: String,
) -> Bool {
  case character.seat {
    None -> False
    Some(console_id) ->
      case deckplan.find_console(plan, console_id) {
        Error(Nil) -> False
        Ok(console) -> console.kind == kind
      }
  }
}

/// Whether two characters share an interior (same ship deck, or the same
/// station concourse) — the scope for seat occupancy and interior fan-out.
pub fn same_place(a: Character, b: Character) -> Bool {
  case a.place, b.place {
    Aboard, Aboard -> a.ship_id == b.ship_id
    OnStation(station_a), OnStation(station_b) -> station_a == station_b
    Aboard, OnStation(_) | OnStation(_), Aboard -> False
  }
}
```

Rewrite `is_at_helm` as the wrapper:

```gleam
/// Whether `character` is seated at a `"helm"`-kind console of `plan`.
/// Helm/dock/undock take effect only when this holds (and only aboard —
/// the sim checks `place` before consulting the ship plan).
pub fn is_at_helm(character: Character, plan: DeckPlan) -> Bool {
  seated_at_kind(character, plan, "helm")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server; gleam test`
Expected: PASS (sim compiles unchanged: record-update syntax carries `place` through).

- [ ] **Step 5: Commit**

```powershell
git add -A
git commit -m "feat(server): character place model - aboard vs ashore on a concourse"
```

### Task 6: Ship wallet/hold/transfers + `cargo.gleam`

**Files:**
- Modify: `server/src/dh_server/ship.gleam`
- Create: `server/src/dh_server/cargo.gleam`
- Create: `server/test/cargo_test.gleam`
- Modify: `server/test/ship_test.gleam`

**Interfaces:**
- Consumes: `shipclass.Handling` (Task 1).
- Produces: `ship.starting_wallet = 2000`; `ship.TransferDirection = ToShip | ToStation`; `ship.Transfer(commodity, direction, remaining: Int, progress: Float, price_each: Int, rate: Float)`; `Ship` gains `wallet: Int`, `hold: Dict(String, Int)`, `transfers: List(Transfer)`; `ship.undock` gains error `"transfer_in_progress"`. `cargo.robot_rate = 1.0`, `cargo.crane_rate = 5.0`, `cargo.transfer_rate(crane: Bool, handling) -> Result(Float, String)` (error `"no_crane"`), `cargo.hold_quantity(ship, commodity) -> Int`, `cargo.hold_total(ship) -> Int`, `cargo.incoming_total(ship) -> Int`, `cargo.begin_buy(ship, commodity, quantity, price_each, capacity, rate) -> Result(Ship, String)` (errors `invalid_quantity` | `insufficient_hold` | `insufficient_funds`, **in that check order** — both are then reachable over the wire with wallet 2000/capacity 40), `cargo.begin_sell(ship, commodity, quantity, price_each, rate) -> Result(Ship, String)` (errors `invalid_quantity` | `insufficient_cargo`), `cargo.Delivery(commodity, quantity)`, `cargo.step_transfers(ship) -> #(Ship, List(Delivery))` (one tick of `ship.dt`).

- [ ] **Step 1: Extend `server/src/dh_server/ship.gleam`**

Add `import gleam/dict.{type Dict}`. Add above the `Ship` type:

```gleam
/// Starting money for every newly spawned ship (M3 flat grant; M4's loan
/// structure replaces this).
pub const starting_wallet = 2000

/// Which way an in-progress cargo transfer moves goods.
pub type TransferDirection {
  ToShip
  ToStation
}

/// An in-progress cargo movement between the docked ship and its station.
/// `progress` accumulates `rate * dt` each tick; whole units move as it
/// crosses each 1.0. `price_each` is locked at order time.
pub type Transfer {
  Transfer(
    commodity: String,
    direction: TransferDirection,
    remaining: Int,
    progress: Float,
    price_each: Int,
    rate: Float,
  )
}
```

`Ship` gains three fields at the end: `wallet: Int`, `hold: Dict(String, Int)`, `transfers: List(Transfer)`. `spawn_docked` fills them: `wallet: starting_wallet, hold: dict.new(), transfers: []`.

`undock` gains the mid-transfer guard (a docked ship with a running transfer may not leave — the DESIGN.md pacing beat, and it pins transfers to one station):

```gleam
pub fn undock(ship: Ship, world: World, t: Float) -> Result(Ship, String) {
  case ship.dock {
    Flying -> Error("not_docked")
    Docked(_) if ship.transfers != [] -> Error("transfer_in_progress")
    Docked(station_id) -> {
      let #(sx, sy) = world.station_position(world, station_id, t)
      let #(svx, svy) = world.station_velocity(world, station_id, t)
      Ok(Ship(..ship, x: sx, y: sy, vx: svx, vy: svy, dock: Flying))
    }
  }
}
```

Update `server/test/ship_test.gleam`: any direct `Ship(...)` constructions gain the three fields; add:

```gleam
pub fn spawn_docked_has_starting_wallet_and_empty_hold_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let s = ship.spawn_docked(1, w, 0.0)
  assert s.wallet == ship.starting_wallet
  assert s.hold == dict.new()
  assert s.transfers == []
}

pub fn undock_blocked_mid_transfer_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let s = ship.spawn_docked(1, w, 0.0)
  let busy =
    ship.Ship(..s, transfers: [
      ship.Transfer(
        commodity: "machinery",
        direction: ship.ToShip,
        remaining: 3,
        progress: 0.0,
        price_each: 55,
        rate: 1.0,
      ),
    ])
  assert ship.undock(busy, w, 0.0) == Error("transfer_in_progress")
  let assert Ok(_) = ship.undock(s, w, 0.0)
}
```

(add `import gleam/dict` there).

- [ ] **Step 2: Write failing tests (`server/test/cargo_test.gleam`)**

```gleam
import dh_server/cargo
import dh_server/ship
import dh_server/shipclass
import gleam/dict
import gleam/list

fn test_ship() -> ship.Ship {
  ship.Ship(
    id: 1,
    x: 0.0,
    y: 0.0,
    vx: 0.0,
    vy: 0.0,
    heading: 0.0,
    controls: ship.Controls(rotate: 0.0, thrust: 0.0),
    dock: ship.Docked("meridian_highport"),
    wallet: 2000,
    hold: dict.new(),
    transfers: [],
  )
}

pub fn transfer_rate_matrix_test() {
  assert cargo.transfer_rate(False, shipclass.BreakBulk)
    == Ok(cargo.robot_rate)
  assert cargo.transfer_rate(True, shipclass.BreakBulk)
    == Ok(cargo.robot_rate)
  assert cargo.transfer_rate(True, shipclass.Container)
    == Ok(cargo.crane_rate)
  assert cargo.transfer_rate(False, shipclass.Container) == Error("no_crane")
}

pub fn begin_buy_debits_wallet_and_queues_transfer_test() {
  let assert Ok(s) = cargo.begin_buy(test_ship(), "machinery", 5, 55, 40, 1.0)
  assert s.wallet == 2000 - 275
  let assert [transfer] = s.transfers
  assert transfer.commodity == "machinery"
  assert transfer.direction == ship.ToShip
  assert transfer.remaining == 5
  assert transfer.price_each == 55
  // Nothing in the hold until the robots carry it aboard.
  assert cargo.hold_total(s) == 0
  assert cargo.incoming_total(s) == 5
}

pub fn begin_buy_check_order_is_quantity_hold_funds_test() {
  assert cargo.begin_buy(test_ship(), "machinery", 0, 55, 40, 1.0)
    == Error("invalid_quantity")
  assert cargo.begin_buy(test_ship(), "machinery", -3, 55, 40, 1.0)
    == Error("invalid_quantity")
  // 45 > capacity 40 (cost 2475 would also fail funds — hold wins).
  assert cargo.begin_buy(test_ship(), "machinery", 45, 55, 40, 1.0)
    == Error("insufficient_hold")
  // 38 fits the hold but costs 2090 > 2000.
  assert cargo.begin_buy(test_ship(), "machinery", 38, 55, 40, 1.0)
    == Error("insufficient_funds")
}

pub fn begin_buy_counts_hold_and_inbound_against_capacity_test() {
  let with_cargo =
    ship.Ship(..test_ship(), hold: dict.from_list([#("water", 20)]))
  let assert Ok(s) = cargo.begin_buy(with_cargo, "food", 10, 10, 40, 1.0)
  // 20 held + 10 inbound: another 11 must not fit in a 40-unit hold.
  assert cargo.begin_buy(s, "water", 11, 4, 40, 1.0)
    == Error("insufficient_hold")
  let assert Ok(_) = cargo.begin_buy(s, "water", 10, 4, 40, 1.0)
}

pub fn begin_sell_stages_cargo_out_of_the_hold_test() {
  let with_cargo =
    ship.Ship(..test_ship(), hold: dict.from_list([#("machinery", 8)]))
  let assert Ok(s) = cargo.begin_sell(with_cargo, "machinery", 5, 70, 1.0)
  assert cargo.hold_quantity(s, "machinery") == 3
  // Wallet is credited on delivery, not at order time.
  assert s.wallet == 2000
  let assert [transfer] = s.transfers
  assert transfer.direction == ship.ToStation
  assert transfer.remaining == 5
  assert cargo.begin_sell(s, "machinery", 4, 70, 1.0)
    == Error("insufficient_cargo")
  assert cargo.begin_sell(s, "machinery", 0, 70, 1.0)
    == Error("invalid_quantity")
}

pub fn step_transfers_moves_whole_units_at_rate_test() {
  let assert Ok(s) = cargo.begin_buy(test_ship(), "machinery", 2, 55, 40, 1.0)
  // rate 1.0 u/s at 60 Hz: one unit lands on the 60th tick.
  let after_59 = step_times(s, 59)
  assert cargo.hold_quantity(after_59, "machinery") == 0
  let after_60 = step_times(s, 60)
  assert cargo.hold_quantity(after_60, "machinery") == 1
  // Transfer completes and is dropped after 2 s.
  let done = step_times(s, 121)
  assert cargo.hold_quantity(done, "machinery") == 2
  assert done.transfers == []
}

pub fn step_transfers_credits_sales_per_unit_and_reports_deliveries_test() {
  let with_cargo =
    ship.Ship(..test_ship(), hold: dict.from_list([#("machinery", 2)]))
  let assert Ok(s) = cargo.begin_sell(with_cargo, "machinery", 2, 70, 1.0)
  let #(after_60, deliveries) = step_collecting(s, 60)
  assert after_60.wallet == 2000 + 70
  assert deliveries == [cargo.Delivery(commodity: "machinery", quantity: 1)]
  let #(done, all_deliveries) = step_collecting(s, 121)
  assert done.wallet == 2000 + 140
  assert done.transfers == []
  assert list.length(all_deliveries) == 2
}

fn step_times(s: ship.Ship, times: Int) -> ship.Ship {
  case times {
    0 -> s
    _ -> {
      let #(next, _) = cargo.step_transfers(s)
      step_times(next, times - 1)
    }
  }
}

/// Step `times` ticks, concatenating every tick's deliveries.
fn step_collecting(
  s: ship.Ship,
  times: Int,
) -> #(ship.Ship, List(cargo.Delivery)) {
  list.fold(list.range(1, times), #(s, []), fn(acc, _) {
    let #(current, deliveries) = acc
    let #(next, new_deliveries) = cargo.step_transfers(current)
    #(next, list.append(deliveries, new_deliveries))
  })
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd server; gleam test`
Expected: compile failure — module `dh_server/cargo` does not exist (ship_test additions from Step 1 should already pass).

- [ ] **Step 4: Write `server/src/dh_server/cargo.gleam`**

```gleam
//// Cargo handling: buy/sell validation and the timed physical transfer
//// (DESIGN.md "Cargo handling" — container cranes vs. robot stevedores).
//// Money and station stock settle at order time for buys; sells pay per
//// unit as it lands on the dock, at the price locked when the order was
//// placed. Everything here is pure functions over Ship — the sim owns the
//// station-market side of each exchange and applies `Delivery`s to it.

import dh_server/ship.{
  type Ship, type Transfer, Ship, ToShip, ToStation, Transfer,
}
import dh_server/shipclass.{type Handling, BreakBulk, Container}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option

/// Robot stevedores: work at any station, slowly. Units per second.
pub const robot_rate = 1.0

/// Container cranes: major-terminal infrastructure, fast. Units per second.
pub const crane_rate = 5.0

/// Which transfer method serves this ship at this station. Container hulls
/// never open their holds: no crane, no trade.
pub fn transfer_rate(crane: Bool, handling: Handling) -> Result(Float, String) {
  case handling, crane {
    BreakBulk, _ -> Ok(robot_rate)
    Container, True -> Ok(crane_rate)
    Container, False -> Error("no_crane")
  }
}

/// Units of `commodity` in the hold.
pub fn hold_quantity(s: Ship, commodity: String) -> Int {
  case dict.get(s.hold, commodity) {
    Ok(quantity) -> quantity
    Error(Nil) -> 0
  }
}

/// Total units in the hold.
pub fn hold_total(s: Ship) -> Int {
  dict.fold(s.hold, 0, fn(acc, _commodity, quantity) { acc + quantity })
}

/// Units already bought and still inbound — they have a reserved berth in
/// the hold, so capacity checks must count them.
pub fn incoming_total(s: Ship) -> Int {
  list.fold(s.transfers, 0, fn(acc, transfer) {
    case transfer.direction {
      ToShip -> acc + transfer.remaining
      ToStation -> acc
    }
  })
}

/// Start buying: wallet debited and the transfer queued now; units arrive
/// in the hold over time. The caller has already taken the stock from the
/// station store at `price_each`. Check order (quantity, hold, funds) is
/// part of the wire contract — tests depend on it.
pub fn begin_buy(
  s: Ship,
  commodity: String,
  quantity: Int,
  price_each: Int,
  capacity: Int,
  rate: Float,
) -> Result(Ship, String) {
  case quantity <= 0 {
    True -> Error("invalid_quantity")
    False ->
      case hold_total(s) + incoming_total(s) + quantity > capacity {
        True -> Error("insufficient_hold")
        False ->
          case price_each * quantity > s.wallet {
            True -> Error("insufficient_funds")
            False ->
              Ok(
                Ship(
                  ..s,
                  wallet: s.wallet - price_each * quantity,
                  transfers: list.append(s.transfers, [
                    Transfer(
                      commodity: commodity,
                      direction: ToShip,
                      remaining: quantity,
                      progress: 0.0,
                      price_each: price_each,
                      rate: rate,
                    ),
                  ]),
                ),
              )
          }
      }
  }
}

/// Start selling: units leave the hold now (staged on the ramp) and are
/// paid for, one by one, as they land on the dock.
pub fn begin_sell(
  s: Ship,
  commodity: String,
  quantity: Int,
  price_each: Int,
  rate: Float,
) -> Result(Ship, String) {
  case quantity <= 0 {
    True -> Error("invalid_quantity")
    False ->
      case hold_quantity(s, commodity) < quantity {
        True -> Error("insufficient_cargo")
        False ->
          Ok(
            Ship(
              ..s,
              hold: remove_from_hold(s.hold, commodity, quantity),
              transfers: list.append(s.transfers, [
                Transfer(
                  commodity: commodity,
                  direction: ToStation,
                  remaining: quantity,
                  progress: 0.0,
                  price_each: price_each,
                  rate: rate,
                ),
              ]),
            ),
          )
      }
  }
}

/// Units that finished moving ship -> station this tick, for the sim to
/// add to the station's store.
pub type Delivery {
  Delivery(commodity: String, quantity: Int)
}

/// Advance every transfer by one tick of `ship.dt`. Inbound units land in
/// the hold; outbound units credit the wallet at the locked price and are
/// reported as deliveries. Finished transfers are dropped.
pub fn step_transfers(s: Ship) -> #(Ship, List(Delivery)) {
  let #(stepped, kept, deliveries) =
    list.fold(s.transfers, #(s, [], []), fn(acc, transfer) {
      let #(current, kept, deliveries) = acc
      let progress = transfer.progress +. transfer.rate *. ship.dt
      let units = int.min(transfer.remaining, float.truncate(progress))
      let progress = progress -. int.to_float(units)
      let remaining = transfer.remaining - units
      let current = case transfer.direction, units {
        _, 0 -> current
        ToShip, _ ->
          Ship(
            ..current,
            hold: add_to_hold(current.hold, transfer.commodity, units),
          )
        ToStation, _ ->
          Ship(..current, wallet: current.wallet + units * transfer.price_each)
      }
      let deliveries = case transfer.direction, units {
        ToStation, u if u > 0 -> [
          Delivery(commodity: transfer.commodity, quantity: u),
          ..deliveries
        ]
        _, _ -> deliveries
      }
      let kept = case remaining {
        0 -> kept
        _ -> [
          Transfer(..transfer, remaining: remaining, progress: progress),
          ..kept
        ]
      }
      #(current, kept, deliveries)
    })
  #(
    Ship(..stepped, transfers: list.reverse(kept)),
    list.reverse(deliveries),
  )
}

fn add_to_hold(
  hold: Dict(String, Int),
  commodity: String,
  units: Int,
) -> Dict(String, Int) {
  dict.upsert(hold, commodity, fn(existing) {
    case existing {
      option.Some(quantity) -> quantity + units
      option.None -> units
    }
  })
}

fn remove_from_hold(
  hold: Dict(String, Int),
  commodity: String,
  units: Int,
) -> Dict(String, Int) {
  let remaining = case dict.get(hold, commodity) {
    Ok(quantity) -> quantity - units
    Error(Nil) -> 0
  }
  case remaining <= 0 {
    True -> dict.delete(hold, commodity)
    False -> dict.insert(hold, commodity, remaining)
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd server; gleam test`
Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add -A
git commit -m "feat(server): ship wallet/hold and timed cargo transfers (robots vs cranes)"
```

### Task 7: Protocol v1 additions

**Files:**
- Modify: `server/src/dh_server/protocol.gleam`
- Modify: `server/test/protocol_test.gleam`

**Interfaces:**
- Consumes: `market.Market`/`Store` (Task 4), `ship.Ship`/`Transfer` (Task 6), `character.Character` (existing).
- Produces — client→server messages: `Disembark`, `Buy(commodity, quantity)`, `Sell(commodity, quantity)`, `GetMarket` (wire types `"disembark"`, `"buy"`, `"sell"`, `"get_market"`; `quantity` is a JSON int). Server→client: `DisembarkResult(ok, reason: Option(String), station_id: Option(String))` + `encode_disembark_result`; `TradeResult(ok, reason: Option(String), commodity: String, quantity: Int, price: Int)` + `encode_trade_result` (`price` is the locked unit price, `0` on failure); `encode_market(m: market.Market) -> String`; `encode_cargo(s: ship.Ship, capacity: Int) -> String`; `encode_concourse(tick, station_id, characters) -> String`. Wire shapes:

```
-> {"v":1,"type":"disembark"}
-> {"v":1,"type":"buy","commodity":S,"quantity":N}
-> {"v":1,"type":"sell","commodity":S,"quantity":N}
-> {"v":1,"type":"get_market"}
<- {"v":1,"type":"disembark_result","ok":B,
    "reason":null|"not_aboard"|"not_docked"|"no_concourse","station_id":S|null}
<- {"v":1,"type":"trade_result","ok":B,"reason":null|S,"commodity":S,
    "quantity":N,"price":N}
   reasons: not_at_broker | ship_not_docked | no_crane | not_sold_here |
            insufficient_stock | invalid_quantity | insufficient_hold |
            insufficient_funds | insufficient_cargo | no_market
<- {"v":1,"type":"market","station_id":S,
    "stores":[{"commodity":S,"name":S,"price":N,"quantity":N}...]}
<- {"v":1,"type":"cargo","ship_id":N,"wallet":N,"capacity":N,
    "hold":[{"commodity":S,"quantity":N}...],            // sorted by commodity
    "transfers":[{"commodity":S,"direction":"to_ship"|"to_station","remaining":N}...]}
<- {"v":1,"type":"concourse","tick":N,"station_id":S,
    "characters":[{"id","name","x","y","seat"}...]}      // same shape as interior
```

Existing messages: `board_result` gains reason `"not_docked_here"`; `dock_result` gains reason `"transfer_in_progress"` (both are just new strings through existing plumbing — no encoder change).

- [ ] **Step 1: Write failing tests (add to `server/test/protocol_test.gleam`)**

Follow the file's existing parse/encode test style:

```gleam
pub fn parse_disembark_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"disembark\"}")
    == Ok(protocol.Disembark)
}

pub fn parse_buy_and_sell_test() {
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"buy\",\"commodity\":\"machinery\",\"quantity\":5}",
    )
    == Ok(protocol.Buy(commodity: "machinery", quantity: 5))
  assert protocol.parse_client_message(
      "{\"v\":1,\"type\":\"sell\",\"commodity\":\"water\",\"quantity\":1}",
    )
    == Ok(protocol.Sell(commodity: "water", quantity: 1))
}

pub fn parse_buy_rejects_float_quantity_test() {
  // decode.int rejects floats — the inverse of the move/helm rule.
  let assert Error(Nil) =
    protocol.parse_client_message(
      "{\"v\":1,\"type\":\"buy\",\"commodity\":\"water\",\"quantity\":1.0}",
    )
}

pub fn parse_get_market_test() {
  assert protocol.parse_client_message("{\"v\":1,\"type\":\"get_market\"}")
    == Ok(protocol.GetMarket)
}

pub fn encode_disembark_result_test() {
  let text =
    protocol.encode_disembark_result(protocol.DisembarkResult(
      ok: True,
      reason: None,
      station_id: Some("meridian_highport"),
    ))
  assert text
    == "{\"v\":1,\"type\":\"disembark_result\",\"ok\":true,\"reason\":null,\"station_id\":\"meridian_highport\"}"
}

pub fn encode_trade_result_test() {
  let text =
    protocol.encode_trade_result(protocol.TradeResult(
      ok: False,
      reason: Some("insufficient_funds"),
      commodity: "machinery",
      quantity: 38,
      price: 0,
    ))
  assert text
    == "{\"v\":1,\"type\":\"trade_result\",\"ok\":false,\"reason\":\"insufficient_funds\",\"commodity\":\"machinery\",\"quantity\":38,\"price\":0}"
}

pub fn encode_market_test() {
  let m =
    market.Market(station_id: "solis_ring", stores: [
      market.Store(
        commodity: "machinery",
        name: "Machinery",
        initial: 30,
        quantity: 28,
        base_price: 75,
        elasticity: 6,
        price: 77,
      ),
    ])
  assert protocol.encode_market(m)
    == "{\"v\":1,\"type\":\"market\",\"station_id\":\"solis_ring\",\"stores\":[{\"commodity\":\"machinery\",\"name\":\"Machinery\",\"price\":77,\"quantity\":28}]}"
}

pub fn encode_cargo_sorts_hold_and_lists_transfers_test() {
  let assert Ok(w) = world.load("worlds/m1_system.json")
  let s = ship.spawn_docked(7, w, 0.0)
  let s =
    ship.Ship(
      ..s,
      wallet: 1725,
      hold: dict.from_list([#("water", 3), #("machinery", 5)]),
      transfers: [
        ship.Transfer(
          commodity: "food",
          direction: ship.ToShip,
          remaining: 4,
          progress: 0.5,
          price_each: 10,
          rate: 1.0,
        ),
      ],
    )
  assert protocol.encode_cargo(s, 40)
    == "{\"v\":1,\"type\":\"cargo\",\"ship_id\":7,\"wallet\":1725,\"capacity\":40,\"hold\":[{\"commodity\":\"machinery\",\"quantity\":5},{\"commodity\":\"water\",\"quantity\":3}],\"transfers\":[{\"commodity\":\"food\",\"direction\":\"to_ship\",\"remaining\":4}]}"
}

pub fn encode_concourse_test() {
  let assert Ok(class) = shipclass.load("classes/sparrow.json")
  let c = character.spawn_at_spawn_tile(3, "ada", 1, class.plan)
  let c = character.disembark_to(c, class.plan, "meridian_highport")
  let text = protocol.encode_concourse(120, "meridian_highport", [c])
  assert text
    == "{\"v\":1,\"type\":\"concourse\",\"tick\":120,\"station_id\":\"meridian_highport\",\"characters\":[{\"id\":3,\"name\":\"ada\",\"x\":5.5,\"y\":4.5,\"seat\":null}]}"
}
```

(`concourse` messages carry `station_id` and **no** `ship_id` — the client and harness in later tasks depend on that.)

Add needed imports to the test file: `dh_server/market`, `dh_server/ship`, `dh_server/world`, `dh_server/character`, `dh_server/shipclass`, `gleam/dict`, `gleam/option.{None, Some}`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server; gleam test`
Expected: compile failure — new constructors/encoders don't exist.

- [ ] **Step 3: Extend `server/src/dh_server/protocol.gleam`**

Add imports: `dh_server/market` and `gleam/string` is not needed; `ship` and `character` are already imported. Extend `ClientMessage`:

```gleam
pub type ClientMessage {
  Login(username: String, password: String)
  Helm(rotate: Float, thrust: Float)
  Dock
  Undock
  Move(dx: Float, dy: Float)
  Sit(console: String)
  Stand
  Board(ship_id: Int)
  Disembark
  Buy(commodity: String, quantity: Int)
  Sell(commodity: String, quantity: Int)
  GetMarket
  GetStats
}
```

New decoder cases inside `client_message_decoder()` (alongside the existing ones):

```gleam
    1, "disembark" -> decode.success(Ok(Disembark))
    1, "buy" -> {
      use commodity <- decode.field("commodity", decode.string)
      use quantity <- decode.field("quantity", decode.int)
      decode.success(Ok(Buy(commodity: commodity, quantity: quantity)))
    }
    1, "sell" -> {
      use commodity <- decode.field("commodity", decode.string)
      use quantity <- decode.field("quantity", decode.int)
      decode.success(Ok(Sell(commodity: commodity, quantity: quantity)))
    }
    1, "get_market" -> decode.success(Ok(GetMarket))
```

New result types:

```gleam
/// Reply to `disembark`: whether it succeeded, why not, and the station
/// whose concourse the character is now standing in.
pub type DisembarkResult {
  DisembarkResult(ok: Bool, reason: Option(String), station_id: Option(String))
}

/// Reply to `buy`/`sell`. `price` is the locked unit price on success,
/// 0 on failure; `commodity`/`quantity` echo the request.
pub type TradeResult {
  TradeResult(
    ok: Bool,
    reason: Option(String),
    commodity: String,
    quantity: Int,
    price: Int,
  )
}
```

New encoders:

```gleam
pub fn encode_disembark_result(result: DisembarkResult) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("disembark_result")),
    #("ok", json.bool(result.ok)),
    #("reason", json.nullable(result.reason, json.string)),
    #("station_id", json.nullable(result.station_id, json.string)),
  ])
  |> json.to_string
}

pub fn encode_trade_result(result: TradeResult) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("trade_result")),
    #("ok", json.bool(result.ok)),
    #("reason", json.nullable(result.reason, json.string)),
    #("commodity", json.string(result.commodity)),
    #("quantity", json.int(result.quantity)),
    #("price", json.int(result.price)),
  ])
  |> json.to_string
}

/// Serialize a station's market: current prices and stock. Sent as the
/// reply to `get_market` and pushed at 15 Hz to that station's concourse
/// occupants.
pub fn encode_market(m: market.Market) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("market")),
    #("station_id", json.string(m.station_id)),
    #(
      "stores",
      json.preprocessed_array(list.map(m.stores, encode_store)),
    ),
  ])
  |> json.to_string
}

fn encode_store(store: market.Store) -> Json {
  json.object([
    #("commodity", json.string(store.commodity)),
    #("name", json.string(store.name)),
    #("price", json.int(store.price)),
    #("quantity", json.int(store.quantity)),
  ])
}

/// Serialize one ship's cargo state (wallet, hold, running transfers).
/// Sent at 15 Hz to the ship's *crew* wherever their bodies are — a
/// quartermaster at a station broker still watches their ship fill up.
/// Hold entries are sorted by commodity for stable output.
pub fn encode_cargo(s: Ship, capacity: Int) -> String {
  let hold =
    dict.to_list(s.hold)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(entry) {
      json.object([
        #("commodity", json.string(entry.0)),
        #("quantity", json.int(entry.1)),
      ])
    })
  json.object([
    #("v", json.int(version)),
    #("type", json.string("cargo")),
    #("ship_id", json.int(s.id)),
    #("wallet", json.int(s.wallet)),
    #("capacity", json.int(capacity)),
    #("hold", json.preprocessed_array(hold)),
    #(
      "transfers",
      json.preprocessed_array(list.map(s.transfers, encode_transfer)),
    ),
  ])
  |> json.to_string
}

fn encode_transfer(transfer: ship.Transfer) -> Json {
  let direction = case transfer.direction {
    ship.ToShip -> "to_ship"
    ship.ToStation -> "to_station"
  }
  json.object([
    #("commodity", json.string(transfer.commodity)),
    #("direction", json.string(direction)),
    #("remaining", json.int(transfer.remaining)),
  ])
}

/// Serialize a `concourse` message: the characters standing in one
/// station's concourse, sent only to that concourse's occupants — the same
/// interest-management shape as `interior`, keyed by station instead of
/// ship.
pub fn encode_concourse(
  tick: Int,
  station_id: String,
  characters: List(Character),
) -> String {
  json.object([
    #("v", json.int(version)),
    #("type", json.string("concourse")),
    #("tick", json.int(tick)),
    #("station_id", json.string(station_id)),
    #(
      "characters",
      json.preprocessed_array(list.map(characters, encode_character)),
    ),
  ])
  |> json.to_string
}
```

Add imports `gleam/dict` and `gleam/string` to protocol.gleam. Update the module's `////` header comment: add the four new client→server lines and five new server→client lines from the wire table above, and note the two new reasons on `board_result`/`dock_result`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server; gleam test`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add server/src/dh_server/protocol.gleam server/test/protocol_test.gleam
git commit -m "feat(protocol): disembark/buy/sell/get_market intents; market/cargo/concourse messages"
```

### Task 8: Sim — markets, disembark/board/trade handlers, new fan-outs

**Files:**
- Modify: `server/src/dh_server/sim.gleam`
- Modify: `server/test/sim_test.gleam`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces (public API used by Task 9): `sim.request_disembark(sim, character_id, timeout_ms) -> protocol.DisembarkResult`; `sim.request_buy(sim, character_id, commodity, quantity, timeout_ms) -> protocol.TradeResult`; `sim.request_sell(...)` (same signature); `sim.request_market(sim, character_id, timeout_ms) -> Result(market.Market, String)` (error `"no_market"`). Behavior: `board` works from a concourse onto any ship docked there (including your own; new failure reason `"not_docked_here"`); ships despawn on **zero crew** (`ship_id` references), not zero bodies aboard; new 15 Hz fan-outs `concourse`/`cargo`/`market`.

- [ ] **Step 1: Add imports and state**

In `sim.gleam` add imports: `dh_server/cargo`, `dh_server/deckplan`, `dh_server/market`. `State` gains three fields:

```gleam
    markets: List(market.Market),
    price_epoch: Int,
    regen_epoch: Int,
```

In `start`'s initialiser: `markets: market.init(world), price_epoch: 0, regen_epoch: 0`.

- [ ] **Step 2: Add the new messages and public API**

New `Msg` variants:

```gleam
  /// Step off the ship onto the docked station's concourse.
  RequestDisembark(character_id: Int, reply: Subject(protocol.DisembarkResult))
  /// Buy `quantity` of `commodity` at the broker the character is seated at.
  RequestBuy(
    character_id: Int,
    commodity: String,
    quantity: Int,
    reply: Subject(protocol.TradeResult),
  )
  /// Sell, mirror of RequestBuy.
  RequestSell(
    character_id: Int,
    commodity: String,
    quantity: Int,
    reply: Subject(protocol.TradeResult),
  )
  /// The market of the station the character is at (ashore, or docked
  /// aboard). Error("no_market") when neither applies.
  RequestMarket(character_id: Int, reply: Subject(Result(market.Market, String)))
```

Public wrappers (same shape as the existing ones):

```gleam
/// Step off the ship onto the docked station's concourse (blocking call).
pub fn request_disembark(
  sim: Subject(Msg),
  character_id: Int,
  timeout_ms: Int,
) -> protocol.DisembarkResult {
  process.call(sim, waiting: timeout_ms, sending: RequestDisembark(
    character_id,
    _,
  ))
}

/// Buy at the seated broker (blocking call).
pub fn request_buy(
  sim: Subject(Msg),
  character_id: Int,
  commodity: String,
  quantity: Int,
  timeout_ms: Int,
) -> protocol.TradeResult {
  process.call(sim, waiting: timeout_ms, sending: RequestBuy(
    character_id,
    commodity,
    quantity,
    _,
  ))
}

/// Sell at the seated broker (blocking call).
pub fn request_sell(
  sim: Subject(Msg),
  character_id: Int,
  commodity: String,
  quantity: Int,
  timeout_ms: Int,
) -> protocol.TradeResult {
  process.call(sim, waiting: timeout_ms, sending: RequestSell(
    character_id,
    commodity,
    quantity,
    _,
  ))
}

/// The market where the character is (blocking call).
pub fn request_market(
  sim: Subject(Msg),
  character_id: Int,
  timeout_ms: Int,
) -> Result(market.Market, String) {
  process.call(sim, waiting: timeout_ms, sending: RequestMarket(
    character_id,
    _,
  ))
}
```

- [ ] **Step 3: Place-aware helpers**

Add next to `find_ship`/`find_character`:

```gleam
/// The deck plan under the character's feet: their crew ship's plan when
/// aboard, the station concourse when ashore.
fn plan_for(
  state: State,
  char: Character,
) -> Result(deckplan.DeckPlan, Nil) {
  case char.place {
    character.Aboard -> Ok(state.class.plan)
    character.OnStation(station_id) ->
      case world.get_station(state.world, station_id) {
        Error(Nil) -> Error(Nil)
        Ok(station) -> option.to_result(station.concourse, Nil)
      }
  }
}

fn find_market(
  markets: List(market.Market),
  station_id: String,
) -> Result(market.Market, Nil) {
  list.find(markets, fn(m) { m.station_id == station_id })
}

fn replace_market(
  markets: List(market.Market),
  updated: market.Market,
) -> List(market.Market) {
  list.map(markets, fn(m) {
    case m.station_id == updated.station_id {
      True -> updated
      False -> m
    }
  })
}
```

(`option.to_result` needs `option` imported with the function, which it already is via `gleam/option.{None, Some}` — extend that import to `gleam/option.{None, Some}` plus a qualified `option.to_result` call; import as `import gleam/option.{None, Some}` and call `option.to_result(...)` — add `option.` usage by importing the module itself: `import gleam/option.{None, Some}` already brings the module in as `option`.)

- [ ] **Step 4: Gate helm control on being aboard**

`SetControls`: change the seat check to require the body aboard:

```gleam
        Ok(char) ->
          case
            char.place == character.Aboard
            && character.is_at_helm(char, state.class.plan)
          {
            False -> actor.continue(state)
            True -> { ...unchanged ships update... }
          }
```

`with_helm_ship`: same change to its `is_at_helm` condition:

```gleam
      case
        char.place == character.Aboard
        && character.is_at_helm(char, state.class.plan)
      {
        False -> {
          process.send(reply, Error("not_at_helm"))
          actor.continue(state)
        }
        True -> ...unchanged...
      }
```

- [ ] **Step 5: Make `RequestSit` and `run_tick` stepping place-aware**

`RequestSit`: resolve the plan and scope occupancy by shared place:

```gleam
        Ok(char) -> {
          let occupied =
            list.any(state.characters, fn(c) {
              character.same_place(c, char) && c.seat == Some(console)
            })
          case plan_for(state, char) {
            Error(Nil) -> {
              process.send(
                reply,
                protocol.SeatResult(
                  ok: False,
                  reason: Some("unknown_console"),
                  seat: char.seat,
                ),
              )
              actor.continue(state)
            }
            Ok(plan) ->
              case character.try_sit(char, plan, console, occupied) {
                ...both branches unchanged from today...
              }
          }
        }
```

`run_tick` step 1 — walk each character on the plan under their feet (a character whose plan can't resolve — e.g. a station without a concourse, which can't happen for anyone who got ashore — stays put):

```gleam
  let characters =
    list.map(state.characters, fn(c) {
      case plan_for(state, c) {
        Ok(plan) -> character.step(c, plan)
        Error(Nil) -> c
      }
    })
```

- [ ] **Step 6: Transfers and market epochs in `run_tick`**

After the `ships` stepping line, add cargo stepping (deliveries land in the docked station's store) and epoch rolls:

```gleam
  // 1b. Advance cargo transfers on docked ships; sold units land in the
  // station's store the moment they cross the dock.
  let #(ships, markets) =
    list.fold(ships, #([], state.markets), fn(acc, s) {
      let #(done, markets) = acc
      case s.transfers, s.dock {
        [], _ -> #([s, ..done], markets)
        [_, ..], ship.Docked(station_id) -> {
          let #(stepped, deliveries) = cargo.step_transfers(s)
          let markets =
            list.fold(deliveries, markets, fn(markets, delivery) {
              case find_market(markets, station_id) {
                Error(Nil) -> markets
                Ok(m) ->
                  replace_market(
                    markets,
                    market.add_stock(m, delivery.commodity, delivery.quantity),
                  )
              }
            })
          #([stepped, ..done], markets)
        }
        // Unreachable while undock is blocked mid-transfer; keep the ship
        // untouched rather than crash if that invariant ever changes.
        [_, ..], ship.Flying -> #([s, ..done], markets)
      }
    })
  let ships = list.reverse(ships)

  // 1c. Price and stock epochs, derived from sim time.
  let new_price_epoch = market.price_epoch(t)
  let markets = case new_price_epoch == state.price_epoch {
    True -> markets
    False ->
      list.map(markets, market.reprice(_, state.world.seed, new_price_epoch))
  }
  let new_regen_epoch = market.regen_epoch(t)
  let markets = case new_regen_epoch == state.regen_epoch {
    True -> markets
    False -> list.map(markets, market.regen)
  }
```

Thread the results into the final `State(..state, ...)` update: `markets: markets, price_epoch: new_price_epoch, regen_epoch: new_regen_epoch` (alongside the existing fields).

- [ ] **Step 7: New 15 Hz fan-outs**

In the broadcast block, after `broadcast_interiors(...)`:

```gleam
      broadcast_concourses(state.clients, characters, tick)
      broadcast_cargo(state.clients, characters, ships, state.class.cargo_capacity)
      broadcast_markets(state.clients, characters, markets)
```

`broadcast_interiors` — the crew filter becomes "bodies aboard this ship" (note both call sites in the function):

```gleam
fn broadcast_interiors(
  clients: List(Client),
  characters: List(Character),
  tick: Int,
) -> Nil {
  let aboard = list.filter(characters, fn(c) { c.place == character.Aboard })
  let crewed_ship_ids = list.map(aboard, fn(c) { c.ship_id }) |> list.unique
  let texts =
    list.map(crewed_ship_ids, fn(ship_id) {
      let crew = list.filter(aboard, fn(c) { c.ship_id == ship_id })
      #(ship_id, protocol.encode_interior(tick, ship_id, crew))
    })
  list.each(clients, fn(client) {
    case find_character(characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) ->
        case char.place {
          character.OnStation(_) -> Nil
          character.Aboard ->
            case list.find(texts, fn(t) { t.0 == char.ship_id }) {
              Error(Nil) -> Nil
              Ok(#(_, text)) -> process.send(client.subject, SendText(text))
            }
        }
    }
  })
}
```

New functions (same shape):

```gleam
/// One `concourse` message per occupied station, sent only to the clients
/// whose character is standing in it.
fn broadcast_concourses(
  clients: List(Client),
  characters: List(Character),
  tick: Int,
) -> Nil {
  let ashore =
    list.filter_map(characters, fn(c) {
      case c.place {
        character.OnStation(station_id) -> Ok(#(station_id, c))
        character.Aboard -> Error(Nil)
      }
    })
  let station_ids = list.map(ashore, fn(pair) { pair.0 }) |> list.unique
  let texts =
    list.map(station_ids, fn(station_id) {
      let occupants =
        list.filter_map(ashore, fn(pair) {
          case pair.0 == station_id {
            True -> Ok(pair.1)
            False -> Error(Nil)
          }
        })
      #(station_id, protocol.encode_concourse(tick, station_id, occupants))
    })
  list.each(clients, fn(client) {
    case find_character(characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) ->
        case char.place {
          character.Aboard -> Nil
          character.OnStation(station_id) ->
            case list.find(texts, fn(t) { t.0 == station_id }) {
              Error(Nil) -> Nil
              Ok(#(_, text)) -> process.send(client.subject, SendText(text))
            }
        }
    }
  })
}

/// One `cargo` message per crewed ship, to its *crew* (by membership,
/// wherever their bodies are — the quartermaster ashore watches the hold).
fn broadcast_cargo(
  clients: List(Client),
  characters: List(Character),
  ships: List(Ship),
  capacity: Int,
) -> Nil {
  let texts =
    list.map(ships, fn(s) { #(s.id, protocol.encode_cargo(s, capacity)) })
  list.each(clients, fn(client) {
    case find_character(characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) ->
        case list.find(texts, fn(t) { t.0 == char.ship_id }) {
          Error(Nil) -> Nil
          Ok(#(_, text)) -> process.send(client.subject, SendText(text))
        }
    }
  })
}

/// One `market` message per occupied station's market, to its concourse
/// occupants — prices and stock stay live while you stand at the broker.
fn broadcast_markets(
  clients: List(Client),
  characters: List(Character),
  markets: List(market.Market),
) -> Nil {
  list.each(clients, fn(client) {
    case find_character(characters, client.character_id) {
      Error(Nil) -> Nil
      Ok(char) ->
        case char.place {
          character.Aboard -> Nil
          character.OnStation(station_id) ->
            case find_market(markets, station_id) {
              Error(Nil) -> Nil
              Ok(m) ->
                process.send(
                  client.subject,
                  SendText(protocol.encode_market(m)),
                )
            }
        }
    }
  })
}
```

- [ ] **Step 8: Disembark, generalized board, trade, market handlers**

Wire the four new `Msg` variants into `handle`:

```gleam
    RequestDisembark(character_id, reply) -> {
      case find_character(state.characters, character_id) {
        Error(Nil) -> {
          process.send(
            reply,
            protocol.DisembarkResult(
              ok: False,
              reason: Some("not_aboard"),
              station_id: None,
            ),
          )
          actor.continue(state)
        }
        Ok(char) -> handle_disembark(state, char, reply)
      }
    }

    RequestBuy(character_id, commodity, quantity, reply) ->
      handle_trade(state, character_id, commodity, quantity, True, reply)

    RequestSell(character_id, commodity, quantity, reply) ->
      handle_trade(state, character_id, commodity, quantity, False, reply)

    RequestMarket(character_id, reply) -> {
      let result = case find_character(state.characters, character_id) {
        Error(Nil) -> Error("no_market")
        Ok(char) ->
          case market_station_for(state, char) {
            Error(Nil) -> Error("no_market")
            Ok(station_id) ->
              find_market(state.markets, station_id)
              |> result.replace_error("no_market")
          }
      }
      process.send(reply, result)
      actor.continue(state)
    }
```

(add `import gleam/result` to sim.gleam). Supporting functions:

```gleam
/// The station whose market the character may inspect: the concourse
/// they're standing in, or the station their ship is docked at while
/// they're aboard.
fn market_station_for(state: State, char: Character) -> Result(String, Nil) {
  case char.place {
    character.OnStation(station_id) -> Ok(station_id)
    character.Aboard ->
      case find_ship(state.ships, char.ship_id) {
        Error(Nil) -> Error(Nil)
        Ok(s) ->
          case s.dock {
            ship.Docked(station_id) -> Ok(station_id)
            ship.Flying -> Error(Nil)
          }
      }
  }
}

fn handle_disembark(
  state: State,
  char: Character,
  reply: Subject(protocol.DisembarkResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.DisembarkResult(
        ok: False,
        reason: Some(reason),
        station_id: None,
      ),
    )
    actor.continue(state)
  }
  case char.place {
    character.OnStation(_) -> fail("not_aboard")
    character.Aboard ->
      case find_ship(state.ships, char.ship_id) {
        Error(Nil) -> fail("not_aboard")
        Ok(s) ->
          case s.dock {
            ship.Flying -> fail("not_docked")
            ship.Docked(station_id) -> {
              let assert Ok(station) =
                world.get_station(state.world, station_id)
              case station.concourse {
                None -> fail("no_concourse")
                Some(plan) -> {
                  let ashore = character.disembark_to(char, plan, station_id)
                  process.send(
                    reply,
                    protocol.DisembarkResult(
                      ok: True,
                      reason: None,
                      station_id: Some(station_id),
                    ),
                  )
                  actor.continue(
                    State(
                      ..state,
                      characters: replace_character(state.characters, ashore),
                    ),
                  )
                }
              }
            }
          }
      }
  }
}
```

Rework `handle_board` — two entry conditions, one shared completion. Replace the whole function with:

```gleam
fn handle_board(
  state: State,
  char: Character,
  target_ship_id: Int,
  reply: Subject(protocol.BoardResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.BoardResult(
        ok: False,
        reason: Some(reason),
        ship_id: char.ship_id,
      ),
    )
    actor.continue(state)
  }
  case find_ship(state.ships, target_ship_id) {
    Error(Nil) -> fail("unknown_ship")
    Ok(target) ->
      case char.place {
        // Ashore: board any ship docked at this station, your own included.
        character.OnStation(station_id) ->
          case target.dock == ship.Docked(station_id) {
            False -> fail("not_docked_here")
            True -> complete_board(state, char, target, reply)
          }
        // Aboard (the M2 flow): cross to another ship co-docked with yours.
        character.Aboard ->
          case char.ship_id == target_ship_id {
            True -> fail("same_ship")
            False -> {
              let assert Ok(current) = find_ship(state.ships, char.ship_id)
              case docked_at_same_station(current, target) {
                False -> fail("not_docked_together")
                True -> complete_board(state, char, target, reply)
              }
            }
          }
      }
  }
}

/// Move `char` aboard `target`: crew membership transfers, body lands
/// standing at the spawn tile with buffered input cleared (input held at
/// the transition was aimed at the old deck), and a ship left with zero
/// crew despawns.
fn complete_board(
  state: State,
  char: Character,
  target: Ship,
  reply: Subject(protocol.BoardResult),
) -> actor.Next(State, Msg) {
  let old_ship_id = char.ship_id
  let #(sx, sy) = character.spawn_position(state.class.plan)
  let boarded =
    character.Character(
      ..char,
      ship_id: target.id,
      place: character.Aboard,
      x: sx,
      y: sy,
      seat: None,
      move_dx: 0.0,
      move_dy: 0.0,
    )
  let characters = replace_character(state.characters, boarded)
  // Despawn on zero *crew* (ship_id references) — a ship whose whole crew
  // is ashore stays alive; one whose last crew member transferred away
  // does not.
  let old_ship_still_crewed =
    list.any(characters, fn(c) { c.ship_id == old_ship_id })
  let ships = case old_ship_still_crewed {
    True -> state.ships
    False -> list.filter(state.ships, fn(s) { s.id != old_ship_id })
  }
  process.send(
    reply,
    protocol.BoardResult(ok: True, reason: None, ship_id: target.id),
  )
  actor.continue(State(..state, characters: characters, ships: ships))
}
```

Trade handler:

```gleam
/// Shared buy/sell gate: seated at a broker console ashore, own ship
/// docked at that station, handling method available, station trades the
/// commodity. Buys take stock first (price locked from the store), then
/// validate the ship side — the market change is only committed when both
/// halves succeed.
fn handle_trade(
  state: State,
  character_id: Int,
  commodity: String,
  quantity: Int,
  buying: Bool,
  reply: Subject(protocol.TradeResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.TradeResult(
        ok: False,
        reason: Some(reason),
        commodity: commodity,
        quantity: quantity,
        price: 0,
      ),
    )
    actor.continue(state)
  }
  case find_character(state.characters, character_id) {
    Error(Nil) -> fail("not_at_broker")
    Ok(char) ->
      case char.place {
        character.Aboard -> fail("not_at_broker")
        character.OnStation(station_id) -> {
          let seated_at_broker = case plan_for(state, char) {
            Ok(plan) -> character.seated_at_kind(char, plan, "broker")
            Error(Nil) -> False
          }
          case seated_at_broker {
            False -> fail("not_at_broker")
            True ->
              case find_ship(state.ships, char.ship_id) {
                Error(Nil) -> fail("ship_not_docked")
                Ok(s) ->
                  case s.dock == ship.Docked(station_id) {
                    False -> fail("ship_not_docked")
                    True -> {
                      let assert Ok(station) =
                        world.get_station(state.world, station_id)
                      case
                        cargo.transfer_rate(station.crane, state.class.handling)
                      {
                        Error(reason) -> fail(reason)
                        Ok(rate) ->
                          case find_market(state.markets, station_id) {
                            Error(Nil) -> fail("not_sold_here")
                            Ok(m) ->
                              case buying {
                                True ->
                                  do_buy(
                                    state, m, s, commodity, quantity, rate,
                                    reply,
                                  )
                                False ->
                                  do_sell(
                                    state, m, s, commodity, quantity, rate,
                                    reply,
                                  )
                              }
                          }
                      }
                    }
                  }
              }
          }
        }
      }
  }
}

fn do_buy(
  state: State,
  m: market.Market,
  s: Ship,
  commodity: String,
  quantity: Int,
  rate: Float,
  reply: Subject(protocol.TradeResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.TradeResult(
        ok: False,
        reason: Some(reason),
        commodity: commodity,
        quantity: quantity,
        price: 0,
      ),
    )
    actor.continue(state)
  }
  case market.take_stock(m, commodity, quantity) {
    Error(reason) -> fail(reason)
    Ok(#(updated_market, store)) ->
      case
        cargo.begin_buy(
          s,
          commodity,
          quantity,
          store.price,
          state.class.cargo_capacity,
          rate,
        )
      {
        // Ship-side rejection: the market change is discarded (never
        // committed to state), so stock is untouched.
        Error(reason) -> fail(reason)
        Ok(updated_ship) -> {
          process.send(
            reply,
            protocol.TradeResult(
              ok: True,
              reason: None,
              commodity: commodity,
              quantity: quantity,
              price: store.price,
            ),
          )
          actor.continue(
            State(
              ..state,
              ships: replace_ship(state.ships, updated_ship),
              markets: replace_market(state.markets, updated_market),
            ),
          )
        }
      }
  }
}

fn do_sell(
  state: State,
  m: market.Market,
  s: Ship,
  commodity: String,
  quantity: Int,
  rate: Float,
  reply: Subject(protocol.TradeResult),
) -> actor.Next(State, Msg) {
  let fail = fn(reason) {
    process.send(
      reply,
      protocol.TradeResult(
        ok: False,
        reason: Some(reason),
        commodity: commodity,
        quantity: quantity,
        price: 0,
      ),
    )
    actor.continue(state)
  }
  case market.find_store(m, commodity) {
    Error(Nil) -> fail("not_sold_here")
    Ok(store) ->
      case cargo.begin_sell(s, commodity, quantity, store.price, rate) {
        Error(reason) -> fail(reason)
        Ok(updated_ship) -> {
          process.send(
            reply,
            protocol.TradeResult(
              ok: True,
              reason: None,
              commodity: commodity,
              quantity: quantity,
              price: store.price,
            ),
          )
          actor.continue(
            State(..state, ships: replace_ship(state.ships, updated_ship)),
          )
        }
      }
  }
}
```

Also update the module's `////` header doc to mention the new channels (concourse per occupied station, cargo per crewed ship to crew wherever they stand, market to concourse occupants) and the crew-membership despawn rule.

- [ ] **Step 9: Sim-level tests (add to `server/test/sim_test.gleam`)**

Add decode/receive helpers next to the existing ones:

```gleam
fn concourse_decoder() -> decode.Decoder(#(String, List(InteriorCharacter))) {
  use station_id <- decode.field("station_id", decode.string)
  use characters <- decode.field(
    "characters",
    decode.list({
      use id <- decode.field("id", decode.int)
      use x <- decode.field("x", decode.float)
      use y <- decode.field("y", decode.float)
      use seat <- decode.field("seat", decode.optional(decode.string))
      decode.success(#(id, x, y, seat))
    }),
  )
  decode.success(#(station_id, characters))
}

/// Receive messages until a `concourse` arrives.
fn receive_concourse(
  client: process.Subject(sim.ClientMsg),
) -> #(String, List(InteriorCharacter)) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "concourse" -> {
      let assert Ok(decoded) = json.parse(text, concourse_decoder())
      decoded
    }
    _ -> receive_concourse(client)
  }
}

/// One decoded `cargo` message: #(ship_id, wallet, hold pairs, transfers).
fn cargo_decoder() -> decode.Decoder(
  #(Int, Int, List(#(String, Int)), Int),
) {
  use ship_id <- decode.field("ship_id", decode.int)
  use wallet <- decode.field("wallet", decode.int)
  use hold <- decode.field(
    "hold",
    decode.list({
      use commodity <- decode.field("commodity", decode.string)
      use quantity <- decode.field("quantity", decode.int)
      decode.success(#(commodity, quantity))
    }),
  )
  use transfers <- decode.field(
    "transfers",
    decode.list(decode.field("remaining", decode.int, decode.success)),
  )
  decode.success(#(ship_id, wallet, hold, list.length(transfers)))
}

fn receive_cargo(
  client: process.Subject(sim.ClientMsg),
) -> #(Int, Int, List(#(String, Int)), Int) {
  let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
  let assert Ok(msg_type) = json.parse(text, message_type_decoder())
  case msg_type {
    "cargo" -> {
      let assert Ok(decoded) = json.parse(text, cargo_decoder())
      decoded
    }
    _ -> receive_cargo(client)
  }
}

/// Receive cargo messages until `predicate` holds. Fails after `tries`.
fn wait_for_cargo(
  client: process.Subject(sim.ClientMsg),
  predicate: fn(#(Int, Int, List(#(String, Int)), Int)) -> Bool,
  tries: Int,
) -> #(Int, Int, List(#(String, Int)), Int) {
  let cargo_msg = receive_cargo(client)
  case predicate(cargo_msg), tries {
    True, _ -> cargo_msg
    False, 0 -> panic as "cargo never reached the expected state"
    False, _ -> wait_for_cargo(client, predicate, tries - 1)
  }
}

/// Assert the next `count` sim pushes to `client` include no `concourse`.
fn assert_no_concourse(
  client: process.Subject(sim.ClientMsg),
  count: Int,
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let assert Ok(sim.SendText(text)) = process.receive(client, 2000)
      let assert Ok(msg_type) = json.parse(text, message_type_decoder())
      assert msg_type != "concourse"
      assert_no_concourse(client, count - 1)
    }
  }
}
```

New tests:

```gleam
pub fn disembark_lands_standing_at_concourse_spawn_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) = sim.request_stand(s, char, 1000)
  assert sim.request_disembark(s, char, 1000)
    == protocol.DisembarkResult(
      ok: True,
      reason: None,
      station_id: Some("meridian_highport"),
    )
  // Meridian Highport's concourse spawn tile is [4, 4] -> center (4.5, 4.5).
  let #(station_id, characters) = receive_concourse(client)
  assert station_id == "meridian_highport"
  let assert Ok(#(_, x, y, seat)) = list.find(characters, fn(c) { c.0 == char })
  assert x == 4.5
  assert y == 4.5
  assert seat == None
}

pub fn disembark_fails_while_flying_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  let assert Ok(Nil) = sim.request_undock(s, char, 1000)
  assert sim.request_disembark(s, char, 1000)
    == protocol.DisembarkResult(
      ok: False,
      reason: Some("not_docked"),
      station_id: None,
    )
}

pub fn board_own_ship_back_from_concourse_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(ship_id, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) = sim.request_stand(s, char, 1000)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  // Ashore, your own ship is a legal board target (M2's same_ship rule only
  // applies aboard) — and the ship must have survived its crew going ashore.
  assert sim.request_board(s, char, ship_id, 1000)
    == protocol.BoardResult(ok: True, reason: None, ship_id: ship_id)
  let characters = receive_interior_for_ship(client, ship_id)
  let assert Ok(#(_, x, y, _)) = list.find(characters, fn(c) { c.0 == char })
  assert x == 5.5
  assert y == 4.5
}

pub fn ship_survives_whole_crew_ashore_test() {
  let s = start_sim()
  let client = process.new_subject()
  let observer = process.new_subject()
  let #(ship_id, char) = sim.add_player(s, "ada", client, 1000)
  let #(_obs_ship, _obs_char) = sim.add_player(s, "obs", observer, 1000)
  let assert protocol.SeatResult(ok: True, ..) = sim.request_stand(s, char, 1000)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  // Crew ashore, zero bodies aboard: the ship stays in snapshots.
  let ids = receive_snapshot_ship_ids(observer)
  assert list.contains(ids, ship_id)
}

pub fn concourse_fan_out_is_isolated_test() {
  let s = start_sim()
  let ashore_client = process.new_subject()
  let aboard_client = process.new_subject()
  let #(_ship_a, char_a) = sim.add_player(s, "ada", ashore_client, 1000)
  let #(_ship_b, _char_b) = sim.add_player(s, "grace", aboard_client, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_stand(s, char_a, 1000)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char_a, 1000)
  // ada (ashore) gets concourse messages; grace (aboard, same station's
  // dock) must never see one.
  let #(station_id, _) = receive_concourse(ashore_client)
  assert station_id == "meridian_highport"
  assert_no_concourse(aboard_client, 20)
}

pub fn buy_delivers_over_time_then_sell_pays_out_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(ship_id, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) = sim.request_stand(s, char, 1000)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  // Spawn tile (4.5, 4.5) is 1.0 from broker_main at (4, 3) — inside the
  // 1.2 sit range, no walking needed.
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char, "broker_main", 1000)

  let buy = sim.request_buy(s, char, "machinery", 2, 1000)
  assert buy.ok
  assert buy.price >= 51 && buy.price <= 59
  // Wallet debited immediately; hold still empty.
  let #(_, wallet, _, _) =
    wait_for_cargo(client, fn(c) { c.0 == ship_id }, 10)
  assert wallet == 2000 - 2 * buy.price

  // Robots carry 1 unit/s: both units aboard within ~2 s (cargo arrives at
  // 15 Hz; give it 60 messages ≈ 4 s of headroom).
  let #(_, _, hold, transfers) =
    wait_for_cargo(
      client,
      fn(c) { c.2 == [#("machinery", 2)] && c.3 == 0 },
      60,
    )
  assert hold == [#("machinery", 2)]
  assert transfers == 0

  let sell = sim.request_sell(s, char, "machinery", 2, 1000)
  assert sell.ok
  let expected_wallet = 2000 - 2 * buy.price + 2 * sell.price
  let #(_, final_wallet, final_hold, _) =
    wait_for_cargo(
      client,
      fn(c) { c.1 == expected_wallet && c.2 == [] },
      60,
    )
  assert final_wallet == expected_wallet
  assert final_hold == []
}

pub fn undock_is_blocked_mid_transfer_test() {
  let s = start_sim()
  let pilot = process.new_subject()
  let quartermaster = process.new_subject()
  let #(ship_a, char_pilot) = sim.add_player(s, "ada", pilot, 1000)
  let #(_ship_b, char_qm) = sim.add_player(s, "grace", quartermaster, 1000)
  // grace crews ada's ship, then goes ashore to the broker.
  let assert protocol.BoardResult(ok: True, ..) =
    sim.request_board(s, char_qm, ship_a, 1000)
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char_qm, 1000)
  let assert protocol.SeatResult(ok: True, ..) =
    sim.request_sit(s, char_qm, "broker_main", 1000)
  let buy = sim.request_buy(s, char_qm, "machinery", 8, 1000)
  assert buy.ok
  // ada (still seated at the helm from login) cannot leave mid-load...
  assert sim.request_undock(s, char_pilot, 1000)
    == Error("transfer_in_progress")
  // ...until the robots finish (8 units at 1 u/s; wait via grace's cargo
  // feed — she's crew, so she gets it ashore).
  let _ =
    wait_for_cargo(quartermaster, fn(c) { c.2 == [#("machinery", 8)] }, 200)
  let assert Ok(Nil) = sim.request_undock(s, char_pilot, 1000)
}

pub fn trade_requires_broker_seat_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  let assert protocol.SeatResult(ok: True, ..) = sim.request_stand(s, char, 1000)
  // Aboard: no.
  let aboard = sim.request_buy(s, char, "machinery", 1, 1000)
  assert aboard == protocol.TradeResult(
    ok: False,
    reason: Some("not_at_broker"),
    commodity: "machinery",
    quantity: 1,
    price: 0,
  )
  // Ashore but standing: still no.
  let assert protocol.DisembarkResult(ok: True, ..) =
    sim.request_disembark(s, char, 1000)
  let standing = sim.request_buy(s, char, "machinery", 1, 1000)
  assert standing.reason == Some("not_at_broker")
}

pub fn request_market_resolves_ashore_and_docked_test() {
  let s = start_sim()
  let client = process.new_subject()
  let #(_ship, char) = sim.add_player(s, "ada", client, 1000)
  // Docked, aboard, seated at the helm: market is visible (cargo-console
  // manifest use case).
  let assert Ok(m) = sim.request_market(s, char, 1000)
  assert m.station_id == "meridian_highport"
  assert list.length(m.stores) == 4
  // Flying: no market.
  let assert Ok(Nil) = sim.request_undock(s, char, 1000)
  assert sim.request_market(s, char, 1000) == Error("no_market")
}
```

Note for the buy/sell price band assertion: epoch-0 machinery price at Meridian is `55 ± 4`, hence `51..59`.

- [ ] **Step 10: Run the whole server suite**

Run: `cd server; gleam test`
Expected: PASS. The timing-sensitive tests (`buy_delivers_over_time...`, `undock_is_blocked...`) run against the real 60 Hz loop — budget ~15 s total; if `undock_is_blocked_mid_transfer_test` ever flakes because the 8-second load finished before the undock call, raise the buy quantity to 12.

- [ ] **Step 11: Commit**

```powershell
git add server/src/dh_server/sim.gleam server/test/sim_test.gleam
git commit -m "feat(sim): concourses, trading, cargo transfers and market/cargo/concourse fan-outs"
```

### Task 9: Server dispatch

**Files:**
- Modify: `server/src/dh_server/server.gleam`

**Interfaces:**
- Consumes: `protocol.Disembark/Buy/Sell/GetMarket`, the sim wrappers from Task 8, `protocol.encode_disembark_result/encode_trade_result/encode_market`.
- Produces: the four intents work over the wire. `dh_server.gleam` needs **no change** (`sim.start(world, class)` builds its own markets).

- [ ] **Step 1: Add the four dispatch branches to `handle_client_text`**

After the `Ok(protocol.Board(...))` branch:

```gleam
    Ok(protocol.Disembark) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result = sim.request_disembark(sim_subject, character_id, 1000)
          let _ =
            mist.send_text_frame(
              conn,
              protocol.encode_disembark_result(result),
            )
          session
        }
      }

    Ok(protocol.Buy(commodity, quantity)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result =
            sim.request_buy(sim_subject, character_id, commodity, quantity, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_trade_result(result))
          session
        }
      }

    Ok(protocol.Sell(commodity, quantity)) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let result =
            sim.request_sell(sim_subject, character_id, commodity, quantity, 1000)
          let _ =
            mist.send_text_frame(conn, protocol.encode_trade_result(result))
          session
        }
      }

    Ok(protocol.GetMarket) ->
      case session {
        PreLogin(_) -> session
        LoggedIn(_, _, character_id) -> {
          let _ = case sim.request_market(sim_subject, character_id, 1000) {
            Ok(m) -> mist.send_text_frame(conn, protocol.encode_market(m))
            Error(reason) ->
              mist.send_text_frame(
                conn,
                protocol.encode_error("no_market", reason),
              )
          }
          session
        }
      }
```

Also extend the module's `////` header list of gated intents ("helm/dock/undock/move/sit/stand/board/disembark/buy/sell/get_market take effect once LoggedIn").

- [ ] **Step 2: Full server suite + boot smoke**

Run: `cd server; gleam test` — expected PASS.
Run: `cd server; gleam run` briefly (Ctrl-C after boot) — expected log lines show the world and class loading with no decode errors.

- [ ] **Step 3: Commit**

```powershell
git add server/src/dh_server/server.gleam
git commit -m "feat(server): dispatch disembark/buy/sell/get_market intents"
```

### Task 10: Harness client + M3 integration tests

**Files:**
- Modify: `harness/dh_client.py`
- Create: `harness/test_m3_trade.py`

**Interfaces:**
- Consumes: the full wire protocol from Tasks 7–9; the authored world numbers from Task 3 (spawn station `meridian_highport`, broker `broker_main` 1.0 tile from the concourse spawn, machinery base 55 ± 4, wallet 2000, capacity 40, robot rate 1.0 u/s).
- Produces: `DHClient.disembark()`, `.buy(commodity, quantity)`, `.sell(commodity, quantity)`, `.get_market()`, `.next_cargo()`, `.next_concourse()`, `.store_in(market, commodity)`, `.hold_quantity(cargo, commodity)`; six integration tests, including the M3 exit-criterion test (one crew member trades ashore while the pilot holds the helm).

- [ ] **Step 1: Add convenience methods to `harness/dh_client.py`**

After the `board` method:

```python
    async def disembark(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Step off the docked ship onto the station concourse (M3);
        wait for `disembark_result`."""
        await self.send({"type": "disembark"})
        return await self.recv_type("disembark_result", timeout=timeout)

    async def buy(
        self, commodity: str, quantity: int, timeout: Optional[float] = DEFAULT_TIMEOUT
    ) -> dict:
        """Buy at the seated broker (M3); wait for `trade_result`.

        `quantity` is sent as a JSON int — the Gleam decoder rejects floats
        here (the inverse of the move/helm float rule).
        """
        await self.send(
            {"type": "buy", "commodity": commodity, "quantity": int(quantity)}
        )
        return await self.recv_type("trade_result", timeout=timeout)

    async def sell(
        self, commodity: str, quantity: int, timeout: Optional[float] = DEFAULT_TIMEOUT
    ) -> dict:
        """Sell at the seated broker (M3); wait for `trade_result`."""
        await self.send(
            {"type": "sell", "commodity": commodity, "quantity": int(quantity)}
        )
        return await self.recv_type("trade_result", timeout=timeout)

    async def get_market(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Request the local station's market (M3); wait for `market`.

        Works ashore or docked-aboard. If neither applies the server sends
        `error` with code `no_market` instead, which this call will time out
        waiting on — use recv_type("error") in tests that expect that.
        """
        await self.send({"type": "get_market"})
        return await self.recv_type("market", timeout=timeout)

    async def next_cargo(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Wait for the next `cargo` message (M3). Sent at 15 Hz to a
        ship's crew, wherever their bodies are."""
        return await self.recv_type("cargo", timeout=timeout)

    async def next_concourse(self, timeout: Optional[float] = DEFAULT_TIMEOUT) -> dict:
        """Wait for the next `concourse` message (M3). Only arrives while
        this client's character is standing in that concourse."""
        return await self.recv_type("concourse", timeout=timeout)

    def store_in(self, market: dict, commodity: str) -> Optional[dict]:
        """Find a commodity's store in a `market` message, if present."""
        for store in market.get("stores", []):
            if store.get("commodity") == commodity:
                return store
        return None

    def hold_quantity(self, cargo: dict, commodity: str) -> int:
        """Units of `commodity` in a `cargo` message's hold list."""
        for entry in cargo.get("hold", []):
            if entry.get("commodity") == commodity:
                return int(entry.get("quantity", 0))
        return 0
```

- [ ] **Step 2: Write `harness/test_m3_trade.py`**

```python
"""M3 integration tests: trade on foot.

Exercises the full loop over the wire: walk off the docked ship onto the
station concourse, sit at a broker, buy with a timed robot transfer, watch
the hold fill through `cargo` messages, sell it back, and prove undock is
blocked mid-transfer. World numbers come from server/worlds/m1_system.json:
spawn station meridian_highport, concourse spawn [4,4] exactly 1.0 tiles
from broker_main, machinery base 55 +/- 4, starting wallet 2000, hold
capacity 40, robot rate 1.0 unit/s.
"""

import asyncio

import pytest

from dh_client import DHClient

pytestmark = pytest.mark.asyncio

SPAWN_STATION = "meridian_highport"
MACHINERY_MIN, MACHINERY_MAX = 51, 59  # base 55, elasticity 4
STARTING_WALLET = 2000


async def _login(server, name: str) -> DHClient:
    client = DHClient(name=name)
    await client.connect()
    await client.login(name, "pw")
    return client


async def _go_ashore(client: DHClient) -> dict:
    """Stand up (login seats you at the helm) and walk off the ship."""
    stand = await client.stand()
    assert stand["ok"], stand
    result = await client.disembark()
    assert result["ok"], result
    assert result["station_id"] == SPAWN_STATION
    return result


async def test_disembark_walk_and_return(server):
    async with DHClient(name="m3_walker") as client:
        welcome = await client.login("m3_walker", "pw")
        ship_id = welcome["ship_id"]
        await _go_ashore(client)

        # We appear in the concourse feed, standing at the spawn tile.
        concourse = await client.next_concourse()
        assert concourse["station_id"] == SPAWN_STATION
        me = client.character_in(concourse, client.character_id)
        assert me is not None
        assert me["seat"] is None
        assert (me["x"], me["y"]) == (4.5, 4.5)

        # Walk one tile up (into the concourse proper) and stop.
        await client.move(0, -1)
        await asyncio.sleep(0.5)
        await client.move(0, 0)
        moved = await client.next_concourse()
        me = client.character_in(moved, client.character_id)
        assert me["y"] < 4.5

        # Board our own ship back; we land at the ship spawn tile.
        board = await client.board(ship_id)
        assert board["ok"], board
        assert board["ship_id"] == ship_id
        interior = await client.next_interior()
        me = client.character_in(interior, client.character_id)
        assert me is not None
        assert (me["x"], me["y"]) == (5.5, 4.5)


async def test_market_visible_while_docked_aboard(server):
    async with DHClient(name="m3_browser") as client:
        await client.login("m3_browser", "pw")
        market = await client.get_market()
        assert market["station_id"] == SPAWN_STATION
        machinery = client.store_in(market, "machinery")
        assert machinery is not None
        assert machinery["name"] == "Machinery"
        assert MACHINERY_MIN <= machinery["price"] <= MACHINERY_MAX
        assert machinery["quantity"] > 0
        assert len(market["stores"]) == 4


async def test_buy_delivers_over_time(server):
    async with DHClient(name="m3_buyer") as client:
        await client.login("m3_buyer", "pw")
        await _go_ashore(client)
        sit = await client.sit("broker_main")
        assert sit["ok"], sit

        trade = await client.buy("machinery", 3)
        assert trade["ok"], trade
        assert trade["quantity"] == 3
        price = trade["price"]
        assert MACHINERY_MIN <= price <= MACHINERY_MAX

        # Wallet debited up front; goods arrive over ~3 s (1 unit/s).
        cargo = await client.next_cargo()
        assert cargo["wallet"] == STARTING_WALLET - 3 * price
        for _ in range(120):  # 120 messages at 15 Hz ~= 8 s budget
            if client.hold_quantity(cargo, "machinery") == 3 and not cargo["transfers"]:
                break
            cargo = await client.next_cargo()
        assert client.hold_quantity(cargo, "machinery") == 3
        assert cargo["transfers"] == []
        assert cargo["capacity"] == 40


async def test_sell_pays_on_delivery(server):
    async with DHClient(name="m3_seller") as client:
        await client.login("m3_seller", "pw")
        await _go_ashore(client)
        assert (await client.sit("broker_main"))["ok"]

        buy = await client.buy("machinery", 2)
        assert buy["ok"], buy
        cargo = await client.next_cargo()
        for _ in range(120):
            if client.hold_quantity(cargo, "machinery") == 2 and not cargo["transfers"]:
                break
            cargo = await client.next_cargo()

        sell = await client.sell("machinery", 2)
        assert sell["ok"], sell
        expected = STARTING_WALLET - 2 * buy["price"] + 2 * sell["price"]
        for _ in range(120):
            cargo = await client.next_cargo()
            if cargo["wallet"] == expected and not cargo["hold"]:
                break
        assert cargo["wallet"] == expected
        assert cargo["hold"] == []


async def test_trade_validation_reasons(server):
    async with DHClient(name="m3_rules") as client:
        await client.login("m3_rules", "pw")

        # Aboard: not at a broker.
        trade = await client.buy("machinery", 1)
        assert not trade["ok"] and trade["reason"] == "not_at_broker"

        await _go_ashore(client)
        # Standing on the concourse: still not seated at a broker.
        trade = await client.buy("machinery", 1)
        assert not trade["ok"] and trade["reason"] == "not_at_broker"

        assert (await client.sit("broker_main"))["ok"]
        checks = [
            (await client.buy("unobtainium", 1), "not_sold_here"),
            (await client.buy("machinery", 100), "insufficient_stock"),
            (await client.buy("machinery", 0), "invalid_quantity"),
            # 45 fits stock (60) but not the 40-unit hold.
            (await client.buy("machinery", 45), "insufficient_hold"),
            # 38 fits the hold but costs >= 38*51 > wallet 2000... only at
            # price >= 53; use 39 (39*51 = 1989 < 2000 is possible!) — so
            # assert on either reason for robustness at extreme prices:
            (await client.sell("machinery", 5), "insufficient_cargo"),
        ]
        for result, reason in checks:
            assert not result["ok"] and result["reason"] == reason, (result, reason)

        # insufficient_funds, price-independent: two buys whose sum always
        # busts the wallet but never the hold. 19 + 19 = 38 <= 40 units;
        # cost >= 38 * 51 = 1938... not guaranteed > 2000, so make the
        # second buy after draining: buy 19, then 19 more, then assert the
        # *third* small buy fails on funds or hold — simplest deterministic
        # variant: buy 36 (cost 36*51=1836 min, 36*59=2124 max) is price-
        # dependent too. Deterministic approach: buy luxuries (base 78,
        # elasticity 5 -> price >= 73): 20 units available; 20*73 = 1460;
        # machinery 19*51 = 969; 1460 + 969 = 2429 > 2000 always, 39 units
        # <= 40. First buy succeeds, second must fail on funds.
        first = await client.buy("luxuries", 20)
        assert first["ok"], first
        second = await client.buy("machinery", 19)
        assert not second["ok"] and second["reason"] == "insufficient_funds", second


async def test_pilot_holds_helm_while_quartermaster_trades(server):
    """M3 exit criterion: one crew member buys on the concourse while the
    pilot sits at the helm; undock is blocked until the robots finish."""
    pilot = await _login(server, "m3_pilot")
    qm = await _login(server, "m3_qm")
    try:
        # The quartermaster crews the pilot's ship (both spawn docked at
        # Meridian Highport), then goes ashore to the broker.
        board = await qm.board(pilot.ship_id_from_welcome)
        assert board["ok"], board
        ashore = await qm.disembark()
        assert ashore["ok"], ashore
        assert (await qm.sit("broker_main"))["ok"]

        buy = await qm.buy("machinery", 8)
        assert buy["ok"], buy

        # The pilot (seated at the helm since login) cannot leave mid-load.
        blocked = await pilot.undock()
        assert not blocked["ok"]
        assert blocked["reason"] == "transfer_in_progress"

        # The quartermaster is crew, so cargo reaches them ashore.
        cargo = await qm.next_cargo()
        for _ in range(240):  # 8 s load + headroom at 15 Hz
            if qm.hold_quantity(cargo, "machinery") == 8 and not cargo["transfers"]:
                break
            cargo = await qm.next_cargo()
        assert qm.hold_quantity(cargo, "machinery") == 8

        released = await pilot.undock()
        assert released["ok"], released
    finally:
        await pilot.close()
        await qm.close()
```

Two notes for the implementer:
- `pilot.ship_id_from_welcome` does not exist: capture it instead — `welcome = await client.login(...)`, use `welcome["ship_id"]`. Rework `_login` to return `(client, welcome)` and destructure in the test.
- In `test_trade_validation_reasons` the inline comments show the arithmetic; keep the final shape (the luxuries+machinery pair whose total always exceeds 2000) and delete the exploratory comments.

- [ ] **Step 3: Run the full integration suite**

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
cd harness; python -m pytest -v
```
Expected: all M1 + M2 tests still pass, plus 6 new M3 tests. Budget ~2 min (the server fixture builds once).

- [ ] **Step 4: Commit**

```powershell
git add harness/dh_client.py harness/test_m3_trade.py
git commit -m "test(harness): M3 trade-on-foot integration tests and client verbs"
```

### Task 11: Client — data classes + network layer

**Files:**
- Create: `client/scripts/cargo_state.gd`
- Create: `client/scripts/market_data.gd`
- Modify: `client/scripts/ship_class_data.gd`
- Modify: `client/scripts/world_data.gd`
- Modify: `client/scripts/network_client.gd`

No headless GDScript test rig exists; verification for client tasks is the automation smoke (Task 14) plus manual runs. Keep these classes logic-light.

**Interfaces:**
- Produces: `CargoState` (`ship_id: int`, `wallet: int`, `capacity: int`, `hold: Dictionary` commodity→qty, `transfers: Array[Dictionary]`, `hold_total()`, `hold_quantity(commodity)`); `MarketData` (`station_id: String`, `stores: Array[MarketData.Store]` with `commodity/name/price/quantity`, `find_store(commodity)`); `ShipClassData.cargo_capacity: int` / `handling: String`; `WorldData.Station.crane: bool` / `concourse: ShipClassData` (null when absent); NetworkClient state `station_id: String` ("" while aboard) and signals `disembark_result_received(ok, reason, station_id)`, `trade_result_received(ok, reason, commodity, quantity, price)`, `market_received(market: MarketData)`, `cargo_received(cargo: CargoState)`, `concourse_received(tick, station_id, characters)`.

- [ ] **Step 1: Write `client/scripts/cargo_state.gd`**

```gdscript
class_name CargoState
extends RefCounted
## Typed view of a `cargo` message (M3): one ship's wallet, hold and
## running transfers. Sent at 15 Hz to the ship's crew wherever their
## bodies are, so the quartermaster ashore can watch the hold fill.

var ship_id: int = -1
var wallet: int = 0
var capacity: int = 0
var hold: Dictionary = {}  ## commodity id -> quantity
## Each entry: {"commodity": String, "direction": "to_ship"|"to_station",
## "remaining": int}
var transfers: Array[Dictionary] = []


static func from_dict(data: Dictionary) -> CargoState:
	var cargo := CargoState.new()
	cargo.ship_id = int(data.get("ship_id", -1))
	cargo.wallet = int(data.get("wallet", 0))
	cargo.capacity = int(data.get("capacity", 0))
	for entry: Variant in data.get("hold", []):
		if entry is Dictionary:
			cargo.hold[str(entry.get("commodity", ""))] = int(entry.get("quantity", 0))
	for transfer: Variant in data.get("transfers", []):
		if transfer is Dictionary:
			cargo.transfers.append({
				"commodity": str(transfer.get("commodity", "")),
				"direction": str(transfer.get("direction", "")),
				"remaining": int(transfer.get("remaining", 0)),
			})
	return cargo


func hold_quantity(commodity: String) -> int:
	return int(hold.get(commodity, 0))


func hold_total() -> int:
	var total := 0
	for quantity: Variant in hold.values():
		total += int(quantity)
	return total
```

- [ ] **Step 2: Write `client/scripts/market_data.gd`**

```gdscript
class_name MarketData
extends RefCounted
## Typed view of a `market` message (M3): one station's commodity stores
## with live prices and stock.


class Store:
	var commodity: String
	var name: String
	var price: int
	var quantity: int

	static func from_dict(data: Dictionary) -> Store:
		var store := Store.new()
		store.commodity = str(data.get("commodity", ""))
		store.name = str(data.get("name", store.commodity))
		store.price = int(data.get("price", 0))
		store.quantity = int(data.get("quantity", 0))
		return store


var station_id: String = ""
var stores: Array[Store] = []


static func from_dict(data: Dictionary) -> MarketData:
	var market := MarketData.new()
	market.station_id = str(data.get("station_id", ""))
	for store_data: Variant in data.get("stores", []):
		if store_data is Dictionary:
			market.stores.append(Store.from_dict(store_data))
	return market


func find_store(commodity: String) -> Store:
	for store in stores:
		if store.commodity == commodity:
			return store
	return null
```

- [ ] **Step 3: Extend `client/scripts/ship_class_data.gd`**

Add fields after `spawn_tile`:

```gdscript
## M3 cargo block (ship class schema 2). Concourse plans parsed through
## this class leave them at 0/"" — a concourse has no hold.
var cargo_capacity: int = 0
var handling: String = ""
```

and in `from_dict`, before `return doc`:

```gdscript
	var cargo: Variant = data.get("cargo")
	if cargo is Dictionary:
		doc.cargo_capacity = int(cargo.get("capacity", 0))
		doc.handling = str(cargo.get("handling", ""))
```

Also update the `Console` inner-class doc comment: `## "cargo" opens the read-only manifest (M3); "broker" consoles exist on station concourses and bind trading.`

- [ ] **Step 4: Extend `client/scripts/world_data.gd` stations**

`Station` gains two fields and parsing:

```gdscript
	var crane: bool = false
	## Walkable concourse interior (same shape as a ship deck plan), or
	## null when this station has none. Parsed with ShipClassData — id and
	## name are absent on concourses, so they are backfilled from the
	## station for display.
	var concourse: ShipClassData = null
```

and in `Station.from_dict`, before `return station`:

```gdscript
		station.crane = bool(data.get("crane", false))
		var concourse: Variant = data.get("concourse")
		if concourse is Dictionary:
			station.concourse = ShipClassData.from_dict(concourse)
			station.concourse.id = station.id
			station.concourse.name = station.name
```

- [ ] **Step 5: Extend `client/scripts/network_client.gd`**

New signals (after `board_result_received`):

```gdscript
## Reply to a `disembark` request. `reason` is null when `ok`, otherwise
## one of "not_aboard" | "not_docked" | "no_concourse". `station_id` is
## the concourse you now stand in (null on failure).
signal disembark_result_received(ok: bool, reason: Variant, station_id: Variant)
## Reply to a `buy`/`sell` request. `price` is the locked unit price on
## success, 0 on failure.
signal trade_result_received(ok: bool, reason: Variant, commodity: String, quantity: int, price: int)
## A station's market (reply to `get_market`, and pushed at 15 Hz while
## standing in that station's concourse).
signal market_received(market: MarketData)
## Our ship's wallet/hold/transfers, at 15 Hz to crew wherever they stand.
signal cargo_received(cargo: CargoState)
## `characters` standing in a station concourse, 15 Hz, only while we're
## in it — the station-flavored sibling of `interior`.
signal concourse_received(tick: int, station_id: String, characters: Array[CharacterState])
```

New public state next to `ship_id`:

```gdscript
## Station whose concourse our character is standing in, "" while aboard.
## Maintained from disembark_result/board_result, same as ship_id.
var station_id: String = ""
```

Reset it in `_handle_welcome` (`station_id = ""`). New match arms in `_handle_packet`:

```gdscript
		"disembark_result":
			_handle_disembark_result(message)
		"trade_result":
			_handle_trade_result(message)
		"market":
			_handle_market(message)
		"cargo":
			_handle_cargo(message)
		"concourse":
			_handle_concourse(message)
```

Handlers:

```gdscript
func _handle_disembark_result(message: Dictionary) -> void:
	var ok := bool(message.get("ok", false))
	var reason: Variant = message.get("reason")
	var result_station: Variant = message.get("station_id")
	if ok:
		station_id = str(result_station)
	disembark_result_received.emit(ok, reason, result_station)


func _handle_trade_result(message: Dictionary) -> void:
	trade_result_received.emit(
		bool(message.get("ok", false)),
		message.get("reason"),
		str(message.get("commodity", "")),
		int(message.get("quantity", 0)),
		int(message.get("price", 0)))


func _handle_market(message: Dictionary) -> void:
	market_received.emit(MarketData.from_dict(message))


func _handle_cargo(message: Dictionary) -> void:
	cargo_received.emit(CargoState.from_dict(message))


func _handle_concourse(message: Dictionary) -> void:
	var raw_characters: Variant = message.get("characters")
	if not raw_characters is Array:
		push_warning("[net] concourse without characters array, ignoring")
		return
	var characters: Array[CharacterState] = []
	for character_data: Variant in raw_characters:
		if character_data is Dictionary:
			characters.append(CharacterState.from_dict(character_data))
	concourse_received.emit(
		int(message.get("tick", -1)),
		str(message.get("station_id", "")),
		characters)
```

And in `_handle_board_result`, when `ok`, also clear the station: `station_id = ""` (boarding always puts your body on a ship).

- [ ] **Step 6: Launch check + commit**

Run the client once against a running server (`cd server; gleam run` in one terminal, `godot --path client` in another) — expect login and normal M2 behavior, no script errors in the console. (New `class_name` scripts may need the editor cache refreshed — see the m1-status memory note if the classes aren't recognized.)

```powershell
git add client/scripts/cargo_state.gd client/scripts/market_data.gd client/scripts/ship_class_data.gd client/scripts/world_data.gd client/scripts/network_client.gd
git commit -m "feat(client): parse market/cargo/concourse/disembark/trade messages into typed state"
```

### Task 12: Client — place flow, concourse rendering, disembark key

**Files:**
- Modify: `client/project.godot` (new input action)
- Modify: `client/scripts/main.gd`

**Interfaces:**
- Consumes: Task 11's signals/state; `WorldData.Station.concourse`; existing InteriorView (`set_frame_data(plan, characters, own_id)` renders any plan-shaped `ShipClassData`).
- Produces: X key = `disembark` action ("step ashore" aboard / "return to ship" ashore); `_current_plan()` used by rendering, prediction, sit-prompting; concourse characters flow through the same `_characters`/`_interior_history` pipeline (prediction + delayed interpolation work unchanged ashore).

- [ ] **Step 1: Add the input action to `client/project.godot`**

In the `[input]` section after `board={...}` (X key, physical keycode 88):

```
disembark={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":88,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
```

- [ ] **Step 2: Track place in `client/scripts/main.gd`**

New state vars after `_character_id`:

```gdscript
## Station whose concourse we're standing in, "" while aboard (mirror of
## NetworkClient.station_id, kept locally like _ship_id).
var _station_id: String = ""
## Latest cargo state for our ship (wallet/hold/transfers), null pre-M3
## server or before the first message.
var _cargo: CargoState = null
## Latest market for the station we're at (null until one arrives).
var _market: MarketData = null
```

Connect the new signals in `_ready()`:

```gdscript
	NetworkClient.disembark_result_received.connect(_on_disembark_result_received)
	NetworkClient.concourse_received.connect(_on_concourse_received)
	NetworkClient.cargo_received.connect(_on_cargo_received)
	NetworkClient.market_received.connect(_on_market_received)
	NetworkClient.trade_result_received.connect(_on_trade_result_received)
```

(the last two get bodies in Task 13; stub `_on_market_received`/`_on_trade_result_received` here as setters/no-ops so this task compiles:)

```gdscript
func _on_cargo_received(cargo: CargoState) -> void:
	if cargo.ship_id == _ship_id:
		_cargo = cargo


func _on_market_received(market: MarketData) -> void:
	_market = market


func _on_trade_result_received(_ok: bool, _reason: Variant, _commodity: String, _quantity: int, _price: int) -> void:
	pass  # Task 13 reports failures + refreshes the panel
```

- [ ] **Step 3: The current plan and the shared character pipeline**

Add helper (used everywhere a plan is needed):

```gdscript
## The deck plan under our feet: the station concourse while ashore, the
## ship class otherwise. Null until welcome (and for a concourse the
## server would never have let us disembark to).
func _current_plan() -> ShipClassData:
	if _station_id != "" and _world != null:
		var station := _world.find_station(_station_id)
		if station != null and station.concourse != null:
			return station.concourse
		return null
	return _ship_class
```

Replace every use of `_ship_class` in these functions with `_current_plan()` (assign `var plan := _current_plan()` and null-check where the old code null-checked `_ship_class`): `_seated_at_helm` (console lookup — ashore it resolves against the concourse plan, so a broker seat correctly reads as not-helm), `_nearest_console_in_range`, `_console_label`, `_update_own_prediction` (the `step_walk` call and its null guard), `_update_interior_view` (pass `_current_plan()` to `set_frame_data`).

Place transitions — new handlers plus one edit:

```gdscript
## Mirrors _on_board_result_received's reset: crossing between interiors
## (deck <-> concourse) invalidates crew list, interpolation history and
## prediction continuity.
func _on_disembark_result_received(ok: bool, reason: Variant, station_id: Variant) -> void:
	if ok:
		_station_id = str(station_id)
		_characters = []
		_interior_history = []
		_predicting = false
	else:
		_show_transient_message("disembark failed: %s" % str(reason))


## Concourse crew flows through the same pipeline as interior crew: the
## prediction/interpolation machinery only cares about positions on the
## current plan, not what kind of place it is.
func _on_concourse_received(_tick: int, station_id: String, characters: Array[CharacterState]) -> void:
	if _station_id == "" or station_id != _station_id:
		return
	_characters = characters
	_interior_history.append({"arrival_msec": Time.get_ticks_msec(), "characters": characters})
	while _interior_history.size() > INTERIOR_HISTORY_SIZE:
		_interior_history.pop_front()
	_reconcile_own_prediction()
```

Edit `_on_interior_received`: ignore ship interiors while ashore — add as the first line:

```gdscript
	if _station_id != "":
		return
```

Edit `_on_board_result_received` (ok branch): add `_station_id = ""` alongside the existing resets. Edit `_on_welcome_received`: add `_station_id = ""`, `_cargo = null`, `_market = null`.

- [ ] **Step 4: The X key — step ashore / return to ship**

In `_unhandled_input`, after the `board` branch:

```gdscript
	elif event.is_action_pressed("disembark"):
		_handle_disembark_toggle()
```

and:

```gdscript
## `X`: aboard and docked -> step onto the concourse; ashore -> board our
## own ship back. The server re-validates everything.
func _handle_disembark_toggle() -> void:
	if not NetworkClient.logged_in:
		return
	if _station_id != "":
		NetworkClient.send_message({"type": "board", "ship_id": _ship_id})
		return
	var own := _own_ship()
	if own != null and own.is_docked():
		NetworkClient.send_message({"type": "disembark"})
```

- [ ] **Step 5: Status label**

In `_update_status_label`, after the `view` line add place context, and extend the prompts. Insert after `lines.append("view: %s" % view_mode_name())`:

```gdscript
	if _station_id != "":
		lines.append("ashore at %s" % _station_name(_station_id))
		lines.append("X: return to ship")
	if _cargo != null:
		lines.append("wallet %d cr - hold %d/%d" % [_cargo.wallet, _cargo.hold_total(), _cargo.capacity])
		for transfer in _cargo.transfers:
			var verb := "loading" if transfer["direction"] == "to_ship" else "unloading"
			lines.append("%s %d %s…" % [verb, transfer["remaining"], transfer["commodity"]])
```

and inside the existing `if own != null:` block (which shows dock status), add the go-ashore prompt when docked and aboard:

```gdscript
			if _station_id == "":
				var docked_station := _world.find_station(own.docked_at) if _world != null else null
				if docked_station != null and docked_station.concourse != null:
					lines.append("X: walk to %s concourse" % docked_station.name)
```

(place it right after the `lines.append("docked at %s" ...)` line).

- [ ] **Step 6: Manual verification**

Run server + client; E to stand, X to step ashore. Expected: zoom stays in INTERIOR, the view switches to the Meridian Highport concourse plan (Concourse/Airlock rooms, two broker consoles), your circle stands on the airlock tile, WASD walks with the same feel as aboard (prediction works against the concourse walls), X returns you to the sparrow's cargo hold spawn tile. A second client left aboard must not see your character on its deck.

- [ ] **Step 7: Commit**

```powershell
git add client/project.godot client/scripts/main.gd
git commit -m "feat(client): walk ashore - concourse rendering, place-aware prediction, X to disembark/return"
```

### Task 13: Client — trade panel + cargo HUD

**Files:**
- Modify: `client/scenes/main.tscn` (one new Label node)
- Modify: `client/scripts/main.gd`

**Interfaces:**
- Consumes: `_market`/`_cargo` (Task 12 stubs get real bodies here), `trade_result_received`, `_current_plan()`.
- Produces: a text trade panel (`%TradePanel`) that opens whenever our character is seated at a **broker** console (interactive) or the ship's **cargo** console (read-only manifest — this is how M3 "binds" the M2 cargo console). Keys while at a broker: W/S select commodity, D buy 1, A sell 1, Shift = ×10.

- [ ] **Step 1: Add the panel node to `client/scenes/main.tscn`**

After the `StatusLabel` node block, add:

```
[node name="TradePanel" type="Label" parent="UI"]
unique_name_in_owner = true
visible = false
offset_left = 10.0
offset_top = 150.0
offset_right = 620.0
offset_bottom = 620.0
theme_override_font_sizes/font_size = 16
text = ""
```

- [ ] **Step 2: Panel state + open/close logic in `main.gd`**

New vars and onready:

```gdscript
var _trade_selection: int = 0

@onready var _trade_panel: Label = %TradePanel
```

Helpers:

```gdscript
## The kind of console our character is seated at on the current plan, or
## "" while standing / before data arrives.
func _seated_console_kind() -> String:
	var own_char := _own_character()
	var plan := _current_plan()
	if own_char == null or not own_char.is_seated() or plan == null:
		return ""
	var console := plan.find_console(own_char.seat)
	return console.kind if console != null else ""


## Interactive trading: seated at a broker on a concourse.
func _at_broker() -> bool:
	return _seated_console_kind() == "broker"


## The trade panel is visible at a broker (interactive) and at the ship's
## cargo console (read-only manifest — M3's binding of the M2 console).
func _trade_panel_open() -> bool:
	var kind := _seated_console_kind()
	return kind == "broker" or kind == "cargo"
```

Give the Task 12 stubs their real bodies:

```gdscript
func _on_trade_result_received(ok: bool, reason: Variant, commodity: String, quantity: int, price: int) -> void:
	if not ok:
		_show_transient_message("trade failed: %s" % str(reason))
	else:
		_show_transient_message("%s %d %s @ %d cr" % [
			"order placed:", quantity, commodity, price])
```

Request the market whenever a seat lands us at a trade console — extend `_on_seat_result_received`:

```gdscript
func _on_seat_result_received(ok: bool, reason: Variant, _seat: Variant) -> void:
	if not ok:
		_show_transient_message("seat failed: %s" % str(reason))
		return
	_trade_selection = 0
	if _trade_panel_open():
		NetworkClient.send_message({"type": "get_market"})
```

(While seated at a broker the server also pushes `market` at 15 Hz, so prices/stock stay live; the explicit request covers the cargo-console case where nothing is pushed.)

- [ ] **Step 3: Render the panel each frame**

Call `_update_trade_panel()` at the end of `_process`, and add:

```gdscript
func _update_trade_panel() -> void:
	var open := _trade_panel_open()
	_trade_panel.visible = open
	if not open:
		return
	var lines: PackedStringArray = []
	var interactive := _at_broker()
	var title := "MARKET" if interactive else "CARGO MANIFEST (read-only)"
	if _market != null and _world != null:
		title += " — %s" % _world.station_name(_market.station_id)
	lines.append(title)
	if _cargo != null:
		lines.append("wallet %d cr   hold %d/%d" % [_cargo.wallet, _cargo.hold_total(), _cargo.capacity])
	lines.append("")
	if _market == null:
		lines.append("(waiting for market data…)")
	else:
		_trade_selection = clampi(_trade_selection, 0, maxi(0, _market.stores.size() - 1))
		for i in _market.stores.size():
			var store := _market.stores[i]
			var cursor := "> " if interactive and i == _trade_selection else "  "
			var held := _cargo.hold_quantity(store.commodity) if _cargo != null else 0
			lines.append("%s%-12s %5d cr   stock %4d   hold %3d" % [
				cursor, store.name, store.price, store.quantity, held])
	lines.append("")
	if interactive:
		lines.append("W/S select   D buy 1   A sell 1   (Shift = x10)   E stand")
	else:
		lines.append("trading happens at station brokers — E stand")
	_trade_panel.text = "\n".join(lines)
```

- [ ] **Step 4: Panel input**

In `_unhandled_input`, add a guard branch **before** the existing action checks so panel keys don't fall through (WASD is safe — seated characters send no moves — but we still want selection handled here):

```gdscript
	if _at_broker() and event is InputEventKey and event.pressed and not event.echo:
		if _handle_trade_input(event):
			get_viewport().set_input_as_handled()
			return
```

and:

```gdscript
## Returns true if the key drove the trade panel. W/S move the selection,
## D buys 1, A sells 1, Shift multiplies by 10. Quantities are JSON ints
## (the server decoder rejects floats here).
func _handle_trade_input(event: InputEventKey) -> bool:
	if _market == null or _market.stores.is_empty():
		return false
	var quantity := 10 if event.shift_pressed else 1
	match event.physical_keycode:
		KEY_W, KEY_UP:
			_trade_selection = maxi(0, _trade_selection - 1)
			return true
		KEY_S, KEY_DOWN:
			_trade_selection = mini(_market.stores.size() - 1, _trade_selection + 1)
			return true
		KEY_D, KEY_RIGHT:
			var store := _market.stores[_trade_selection]
			NetworkClient.send_message({"type": "buy", "commodity": store.commodity, "quantity": quantity})
			return true
		KEY_A, KEY_LEFT:
			var sell_store := _market.stores[_trade_selection]
			NetworkClient.send_message({"type": "sell", "commodity": sell_store.commodity, "quantity": quantity})
			return true
	return false
```

Note: `interact`/`board`/`disembark`/`toggle_dock` still work because the guard only swallows W/S/A/D/arrow keys and returns false otherwise (E falls through to stand, which closes the panel).

- [ ] **Step 5: Manual verification — the full loop, on screen**

Server + one client: E stand → X ashore → walk to `broker_main` → E sit. Expected: panel lists 4 commodities with prices/stock, wallet 2000. D buys 1 machinery: transient "order placed", wallet drops by the price, status label shows "loading 1 machinery…", ~1 s later hold reads 1. A sells it back. E stand → X return → walk to the sparrow's cargo console → E sit: same panel, read-only footer, no cursor. Sit at helm, SPACE undock mid-load (buy 10 first, hop back fast): "dock failed: transfer_in_progress" appears.

- [ ] **Step 6: Commit**

```powershell
git add client/scenes/main.tscn client/scripts/main.gd
git commit -m "feat(client): broker trade panel, cargo manifest at the ship console, cargo HUD"
```

### Task 14: Client — automation dump + smoke test

**Files:**
- Modify: `client/scripts/automation_server.gd`
- Modify: `harness/test_automation_smoke.py`

**Interfaces:**
- Consumes: NetworkClient's new signals/state (Task 11), main.gd's `_trade_panel_open()` (read via the scene root like `view_mode_name`— add a tiny public method below).
- Produces: automation `dump` gains `station_id` (null aboard), `wallet`, `hold` (dict), `transfers` (count), `trade_panel_open` (bool); one new optional smoke test that walks ashore and screenshots the concourse.

- [ ] **Step 1: Expose panel state from `main.gd`**

```gdscript
## Public for the automation hook, like view_mode_name().
func trade_panel_open() -> bool:
	return _trade_panel_open()
```

- [ ] **Step 2: Extend `automation_server.gd`**

Track concourse crews too — in `_ready()` add `NetworkClient.concourse_received.connect(_on_concourse_received)` and `NetworkClient.cargo_received.connect(_on_cargo_received)`; new state + handlers:

```gdscript
var _latest_cargo: CargoState = null


## Concourse crew replaces the character list while we're ashore,
## mirroring the interior guard above.
func _on_concourse_received(_tick: int, station_id: String, characters: Array[CharacterState]) -> void:
	if station_id != NetworkClient.station_id:
		return
	_latest_characters = characters


func _on_cargo_received(cargo: CargoState) -> void:
	if cargo.ship_id == NetworkClient.ship_id:
		_latest_cargo = cargo
```

In `_dump_state()`'s dictionary add:

```gdscript
		"station_id": NetworkClient.station_id if NetworkClient.station_id != "" else null,
		"wallet": _latest_cargo.wallet if _latest_cargo != null else null,
		"hold": _latest_cargo.hold if _latest_cargo != null else {},
		"transfers": _latest_cargo.transfers.size() if _latest_cargo != null else 0,
		"trade_panel_open": _trade_panel_open_from_scene(),
```

and:

```gdscript
func _trade_panel_open_from_scene() -> bool:
	var main_node := get_tree().current_scene
	if main_node == null or not main_node.has_method("trade_panel_open"):
		return false
	return bool(main_node.call("trade_panel_open"))
```

- [ ] **Step 3: Add a smoke test to `harness/test_automation_smoke.py`**

Follow the file's existing fixture/helper style (launch_client + GodotAutomation, `@pytest.mark.automation`, excluded by default). The new test, using the `key` command for E/X (event-driven actions don't work via `action` — see M2-RESULTS known gaps):

```python
@pytest.mark.automation
def test_walk_ashore_and_screenshot(server, automation_client):
    auto = automation_client
    wait_until(lambda: auto.dump()["logged_in"])
    # Stand (E), step ashore (X).
    auto.key("E")
    wait_until(lambda: auto.dump()["character"] and auto.dump()["character"]["seat"] is None)
    auto.key("X")
    wait_until(lambda: auto.dump()["station_id"] == "meridian_highport")
    state = auto.dump()
    assert state["view_mode"] == "interior"
    assert state["wallet"] == 2000
    auto.screenshot(str(SCREENSHOT_DIR / "m3_concourse.png"))
```

Adapt names (`automation_client` fixture, `wait_until`, screenshot dir) to whatever the file already defines — reuse its helpers rather than inventing new ones; if `key()` taps need a press+release pair there, mirror the existing usage.

- [ ] **Step 4: Run it once locally (optional gate, needs a display + godot on PATH)**

```powershell
cd harness; python -m pytest test_automation_smoke.py -v -m automation
```
Expected: PASS, screenshot shows the concourse deck plan. If no display is available, note it and rely on Task 13's manual verification.

- [ ] **Step 5: Commit**

```powershell
git add client/scripts/main.gd client/scripts/automation_server.gd harness/test_automation_smoke.py
git commit -m "feat(automation): station/wallet/hold/trade-panel in state dump; ashore smoke test"
```

### Task 15: Docs, results, PR

**Files:**
- Create: `docs/M3-RESULTS.md`
- Modify: `DESIGN.md`

- [ ] **Step 1: Full verification sweep**

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
cd server; gleam test
cd ../harness; python -m pytest -v
```
Expected: everything green. Also run the REQUIRED superpowers:verify flow (drive the real app once end-to-end per Task 13 Step 5) before claiming completion.

- [ ] **Step 2: Write `docs/M3-RESULTS.md`**

Follow M2-RESULTS.md's structure exactly: date + exit criterion met (name `harness/test_m3_trade.py::test_pilot_holds_helm_while_quartermaster_trades`), "What M3 built" bullets (concourses as world-doc deck plans; place model; broker trading; timed transfers robots-vs-cranes; noise-walk prices; new fan-outs; client trade panel + manifest console; harness verbs), "Running it" commands (two clients, one goes ashore with X and trades while the other flies), the protocol additions table (copy the wire table from Task 7), the world-doc schema-2 additions, and "Known gaps" — record at least: prices are a noise walk, not supply/demand (M6 makes NPCs move them); trades don't persist (in-memory, like ships — M4); no per-broker identity/factions (M6); container hulls exist only as test fixtures; concourse occupancy has no capacity/berth model yet (anchorage/lightering is M5+ per DESIGN.md).

- [ ] **Step 3: Update `DESIGN.md`**

- Milestone list: mark M3 done — append to its entry: `**✅ Done <date> ([results](docs/M3-RESULTS.md)).**`
- In the M2 open-questions bullet that says the cargo console "binds nothing until M3", no edit needed (it's historical), but in "Simulation model" the sentence "the cargo console will bind to power/repair systems (later)" — leave; instead update the M2 decision line under Open questions: append to the consoles-first bullet: "(M3: the cargo console now opens the read-only manifest; trading is at concourse brokers.)"

- [ ] **Step 4: Update memory**

Write `C:\Users\dibuj\.claude\projects\C--Users-dibuj-dev-DistantHorizon\memory\m3-status.md` (type: project): M3 merged/PR'd date, the place-model decision (ship_id = crew membership, place = body location), the check-order contract in begin_buy (quantity/hold/funds — wire tests depend on it), and the quantity-is-int wire gotcha. Add the MEMORY.md index line.

- [ ] **Step 5: Push and open the PR**

Use the superpowers:finishing-a-development-branch skill. Summary shape:

```powershell
git push -u origin m3-trade-on-foot
gh pr create --title "M3: Trade on foot" --body "..."
```

PR body: milestone scope from DESIGN.md, the design decisions list from this plan's header, test evidence (`gleam test` count, pytest count, smoke screenshot), and the exit-criterion test name. End the body with the standard attribution footer. **Do not merge** — the user reviews PRs themselves.

## Self-review notes (already applied)

- Spec coverage: concourse ✅ (Tasks 1, 3, 8, 12), walk off ship ✅ (5, 8, 12), broker buy/sell ✅ (4, 8, 13), handling times cranes-vs-robots ✅ (6: `transfer_rate`, container fixture in cargo_test), dynamic prices from Classic ✅ (2, 4), playable sandbox ✅ (12–13 + exit-criterion test in 10).
- Type consistency spot-checks: `plan: DeckPlan` everywhere in character (Tasks 1/5/8 agree); `TradeResult` carries `price` in protocol (7), sim (8), harness (10), client signal (11/13); `concourse` message has `station_id`, no `ship_id` (7/10/11); check order quantity→hold→funds pinned in cargo (6) and asserted over the wire (10).
- Known judgment calls an implementer may revisit with the reviewer: 15 Hz always-send for cargo/market (simple, tiny payloads — dirty-tracking is a later optimization); `get_market` error path reuses `encode_error` rather than a dedicated failure message.

## Execution

Plan complete. Execute task-by-task with fresh subagents (superpowers:subagent-driven-development) or inline (superpowers:executing-plans); each task ends green (`gleam test` / pytest) and committed on `m3-trade-on-foot`. Finish with the PR (Task 15) — never merge to main directly.
