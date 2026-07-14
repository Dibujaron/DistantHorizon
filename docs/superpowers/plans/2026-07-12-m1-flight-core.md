# M1 — Flight Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DESIGN.md Milestone 1 — one star system loaded from a config document, planets/stations on analytic rails, per-player Newtonian ships flyable with Classic feel, two clients seeing each other fly, station docking, Postgres accounts, plus the permanent protocol test harness and the Godot client automation hook.

**Architecture:** The M0 Gleam server keeps its shape (sim actor with drift-corrected 60 Hz tick loop, mist WebSocket front end, versioned v1 JSON protocol) but the 500 fake orbiting ships are **replaced** by one player-controlled Newtonian ship per authenticated connection. The world (star, planets, stations) is loaded at startup from a hand-authored JSON world document; bodies are on rails (analytic circular orbits, position computable for any t) and are **never** sent in snapshots — clients receive the world document once in the `welcome` message and compute rail positions locally from the snapshot tick. Auth is an interface: Task 3 ships an accept-all stub, Task 4 swaps in Postgres behind the same function type.

**Tech Stack:** Gleam 1.17 / OTP 29, mist 6.x, gleam_json, new deps: `simplifile` (file IO), `pog` (Postgres), `gleam_crypto` (password hashing), `envoy` (env vars). Python 3 + `websockets` + `pytest`/`pytest-asyncio` for the harness. Godot 4.7 GDScript client. PostgreSQL 18 (dev instance: scoop-installed, trust auth, superuser `postgres`, db `dh_dev` on 127.0.0.1:5432).

## Global Constraints

- Protocol stays **version 1**: every message is a JSON object with `"v": 1` and a `"type"` discriminator. Unknown/malformed inbound messages are ignored by the server, never crash it.
- Tick model unchanged: 60 Hz sim (`dt = 0.016666666666666666`), snapshot every 4th tick (15 Hz). Sim time for rails is `t = int.to_float(tick) *. ship.dt` seconds since server start.
- Server binds `127.0.0.1:8484`, route `/ws` (unchanged).
- Bodies on rails are never in snapshots; clients compute them from the world doc + tick.
- All Gleam code passes `gleam format --check src test`; all tests via `gleam test` from `server/`.
- Windows dev environment; Postgres binaries at `~\scoop\apps\postgresql\current\bin` (NOT on default PATH). Python is `python`, Godot is `godot` via `~\scoop\shims`.
- Commit style: short imperative subject prefixed by area, e.g. `M1 server: world document and rails`. Never commit to `main` — work happens on branch `m1-flight-core`.
- YAGNI hard: no universes/runs/economy/interiors — that's M2+. One world instance per server process.

## Wire protocol additions (single source of truth)

Client → server:
- `{"v":1,"type":"login","username":"alice","password":"secret"}` — first message a client must send. Until a successful login the server sends this connection no snapshots and ignores every other message type except `get_stats`.
- `{"v":1,"type":"helm","rotate":R,"thrust":T}` — R float in [-1,1] (counter-clockwise positive), T float in [0,1]. Server clamps out-of-range values. Ignored while docked.
- `{"v":1,"type":"dock"}` — request docking at the nearest station.
- `{"v":1,"type":"undock"}`
- `{"v":1,"type":"get_stats"}` — unchanged from M0.

Server → client:
- `{"v":1,"type":"welcome","account_id":N,"ship_id":N,"tick_rate":60,"dt":0.016666666666666666,"world":{...}}` — sent on successful login. `world` is the full world document (schema below).
- `{"v":1,"type":"error","code":"auth_failed","message":"..."}` — login rejected; also `"code":"storage_error"`. Connection stays open, client may retry login.
- `{"v":1,"type":"dock_result","ok":true|false,"reason":null|"out_of_range"|"too_fast"|"already_docked"|"not_docked"}` — reply to dock/undock. `reason` is null when ok.
- `{"v":1,"type":"snapshot","tick":N,"ships":[{"id":N,"x":F,"y":F,"vx":F,"vy":F,"heading":F,"thrust":F,"docked":null|"station_id"},...]}` — all player ships in the world (interest management stays coarse). Heading in radians, world y-up, heading 0 = +x.
- `{"v":1,"type":"stats",...}` — unchanged from M0.

## World document schema (v1)

File: `server/worlds/m1_system.json` (server reads path from `DH_WORLD` env var via envoy, default `worlds/m1_system.json` relative to `server/`).

```json
{
  "schema": 1,
  "name": "Krasny Sector (M1 pinned system)",
  "seed": 20260712,
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
     "orbit": {"radius": 400.0, "period_s": 180.0, "phase": 0.0}, "dock_radius": 150.0},
    {"id": "solis_ring", "name": "Solis Ring", "parent": "krasny",
     "orbit": {"radius": 2000.0, "period_s": 500.0, "phase": 0.6}, "dock_radius": 150.0}
  ],
  "spawn_station": "meridian_highport"
}
```

Orbit semantics: `angle(t) = phase *. 2π +. 2π *. t /. period_s`; `position(t) = parent_position(t) + radius * (cos(angle), sin(angle))`; velocity is the analytic derivative `parent_velocity(t) + (2π*radius/period_s) * (-sin(angle), cos(angle))`. Parents chain (station → planet → star). The star has no orbit: position (0,0), velocity (0,0).

Gravity: every **body** (never stations) with `mu > 0` pulls ships: `a = mu /. max(r, body_radius)²` toward the body (clamp r to body radius to avoid the singularity). With the values above, gravity is a gentle perturbation (star pull ~1.25 u/s² at r=4000) vs. ship thrust 40 u/s² — Classic feel, tunable later in data only.

## Ship physics constants (Classic feel, `server/src/dh_server/ship.gleam`)

- `main_accel = 40.0` u/s² at full thrust, along heading.
- `turn_rate = 3.0` rad/s at full rotate input.
- `max_dock_speed = 60.0` u/s relative to station; dock also requires distance ≤ station `dock_radius`.
- Integration per tick (semi-implicit Euler): heading += rotate·turn_rate·dt; a = thrust·main_accel·(cos h, sin h) + Σ gravity; vel += a·dt; pos += vel·dt.
- Docked ships are pinned to the station's analytic position/velocity each tick; controls ignored.
- Undock: ship placed at station position + (dock_radius, 0), station velocity, heading 0, then flies free.
- New connections spawn **docked at `spawn_station`**.

---

### Task 1: World document + rails (server)

**Files:**
- Create: `server/src/dh_server/world.gleam`, `server/worlds/m1_system.json`, `server/test/world_test.gleam`
- Modify: `server/gleam.toml` (add `simplifile >= 2.0.0 and < 3.0.0`, `envoy >= 1.0.0 and < 2.0.0`)

**Interfaces (Produces):**
```gleam
pub type Orbit { Orbit(radius: Float, period_s: Float, phase: Float) }
pub type Body { Body(id: String, name: String, kind: String, parent: option.Option(String), orbit: option.Option(Orbit), radius: Float, mu: Float) }
pub type Station { Station(id: String, name: String, parent: String, orbit: Orbit, dock_radius: Float) }
pub type World { World(schema: Int, name: String, seed: Int, bodies: List(Body), stations: List(Station), spawn_station: String) }

pub fn load(path: String) -> Result(World, String)      // simplifile read + decode; Error is a human-readable reason
pub fn decode(json_text: String) -> Result(World, String)
pub fn encode(world: World) -> json.Json                 // for the welcome message; encode(decode(x)) round-trips
pub fn body_position(world: World, body_id: String, t: Float) -> #(Float, Float)
pub fn station_position(world: World, station_id: String, t: Float) -> #(Float, Float)
pub fn station_velocity(world: World, station_id: String, t: Float) -> #(Float, Float)
pub fn get_station(world: World, station_id: String) -> Result(Station, Nil)
pub fn gravity_at(world: World, x: Float, y: Float, t: Float) -> #(Float, Float)  // summed accel from all bodies with mu > 0
```
Orbit math per the schema section above (positions chain through parents; unknown ids may `panic` — world is validated at decode time: every `parent` and `spawn_station` must reference an existing id, else `decode` returns `Error`).

**Tests (gleeunit, `world_test.gleam`):** decode the bundled `m1_system.json` via `load` succeeds with 3 bodies / 2 stations; `decode`→`encode`→`decode` round-trips to an equal `World`; decode rejects a doc whose `spawn_station` is unknown; star position is (0,0) at any t; planet at t=0 sits at phase angle (meridian: (4000, 0)); planet at quarter period sits 90° on; station position chains through its planet (station at t=0 = planet(0) + (400, 0)); `station_velocity` magnitude ≈ 2π·400/180 within 1e-6; `gravity_at` points from a test point toward the star and has magnitude mu/r² within 1e-6; inside `body_radius` the clamp holds (no blowup).

**Steps:** write failing tests → implement → `gleam test` green → `gleam format src test` → commit.

---

### Task 2: Newtonian player ships (server)

**Files:**
- Rewrite: `server/src/dh_server/ship.gleam` (delete the M0 circular-orbit fleet: `init_fleet`, `advance_fleet`, `advance`, the LCG)
- Modify: `server/test/dh_server_test.gleam` (drop M0 fleet tests; keep/adjust stats & protocol tests that still compile — protocol changes come in Task 3, so in THIS task only fix what the ship rewrite breaks; the sim still compiles by switching it to an empty ship list — minimal edit, full sim rework is Task 3)
- Create: `server/test/ship_test.gleam`

**Interfaces (Consumes):** `world.gleam` from Task 1. **(Produces):**
```gleam
pub const dt = 0.016666666666666666
pub const main_accel = 40.0
pub const turn_rate = 3.0
pub const max_dock_speed = 60.0

pub type Controls { Controls(rotate: Float, thrust: Float) }         // always stored clamped; set_controls does the clamping
pub type DockState { Flying Docked(station_id: String) }
pub type Ship { Ship(id: Int, x: Float, y: Float, vx: Float, vy: Float, heading: Float, controls: Controls, dock: DockState) }

pub fn spawn_docked(id: Int, world: world.World, t: Float) -> Ship   // docked at world.spawn_station, pinned to it
pub fn set_controls(ship: Ship, rotate: Float, thrust: Float) -> Ship // clamps rotate to [-1,1], thrust to [0,1]
pub fn step(ship: Ship, world: world.World, t: Float) -> Ship        // one dt of physics; docked ships pin to station pos/vel at t
pub fn try_dock(ship: Ship, world: world.World, t: Float) -> Result(Ship, String)   // Error("out_of_range"|"too_fast"|"already_docked"); docks at NEAREST station in range
pub fn undock(ship: Ship, world: world.World, t: Float) -> Result(Ship, String)     // Error("not_docked")
pub fn speed(ship: Ship) -> Float
```

**Tests (`ship_test.gleam`):** full thrust from rest for 60 ticks ≈ 40 u/s speed (tolerance: gravity perturbs — spawn far from bodies, e.g. (50000, 50000), tolerance 1.0); zero thrust coasts linearly; rotate 1.0 for 60 ticks turns heading by ≈ 3.0 rad; set_controls clamps (2.0, -0.5) → (1.0, 0.0); spawn_docked pins to spawn station position; docked ship stays pinned after 100 steps while the station moves; try_dock succeeds within dock_radius at low relative speed; fails "out_of_range" far away; fails "too_fast" in range at relative speed > 60; fails "already_docked" when docked; undock places ship at station + (dock_radius, 0) with station velocity; undock while flying errors "not_docked".

**Steps:** failing tests → implement → green → format → commit.

---

### Task 3: Sessions, helm, docking over the wire (server)

**Files:**
- Modify: `server/src/dh_server/protocol.gleam`, `server/src/dh_server/sim.gleam`, `server/src/dh_server/server.gleam`, `server/src/dh_server.gleam`, `server/test/dh_server_test.gleam`
- Create: `server/src/dh_server/auth.gleam`, `server/test/protocol_test.gleam`

**Interfaces (Consumes):** Tasks 1–2. **(Produces):**
```gleam
// auth.gleam — the seam Task 4 fills. account_id in Ok.
pub type AuthError { InvalidCredentials StorageError(String) }
pub type Authenticator = fn(String, String) -> Result(Int, AuthError)
pub fn accept_all() -> Authenticator   // Ok(0) for any non-empty username+password; InvalidCredentials if either is empty

// protocol.gleam
pub type ClientMessage { Login(username: String, password: String) Helm(rotate: Float, thrust: Float) Dock Undock GetStats }
pub fn parse_client_message(text: String) -> Result(ClientMessage, Nil)
pub fn encode_welcome(account_id: Int, ship_id: Int, world: world.World) -> String
pub fn encode_error(code: String, message: String) -> String
pub fn encode_dock_result(result: Result(Nil, String)) -> String   // ok:true reason:null / ok:false reason:code
pub fn encode_snapshot(tick: Int, ships: List(ship.Ship)) -> String // new ship fields: heading, thrust, docked

// sim.gleam — sim owns World (loaded before start) + List(ship.Ship) (starts empty) + next_ship_id
pub fn start(world: world.World) -> Result(actor.Started(Subject(Msg)), actor.StartError)
pub fn add_ship(sim: Subject(Msg), client: Subject(ClientMsg), timeout_ms: Int) -> Int
    // call: spawns ship docked at spawn_station at current t, registers client for snapshots
    // (monitor-based cleanup as in M0), returns the new ship id. ClientDown removes ship AND subscription.
pub fn set_controls(sim: Subject(Msg), ship_id: Int, rotate: Float, thrust: Float) -> Nil   // cast
pub fn request_dock(sim: Subject(Msg), ship_id: Int, timeout_ms: Int) -> Result(Nil, String)   // call
pub fn request_undock(sim: Subject(Msg), ship_id: Int, timeout_ms: Int) -> Result(Nil, String) // call
```
`server.gleam`: ws handler state becomes `Session { PreLogin(subject) LoggedIn(subject, ship_id) }`. On `Login` in PreLogin: run the `Authenticator` (passed into `server.start` alongside the sim subject) — on Ok, `add_ship`, send `welcome`; on Error send `error` (auth_failed / storage_error). `Login` while LoggedIn: ignore. Helm/Dock/Undock in PreLogin: ignore. Dock/Undock while LoggedIn reply with `dock_result`. `get_stats` works in both states. `dh_server.gleam` main: load world (path from `DH_WORLD` env default `worlds/m1_system.json`; crash with clear message on Error), `sim.start(world)`, `server.start(sim_subject, auth.accept_all())`, sleep forever.

Snapshot cadence/logging/stats stay as M0. With no clients the sim still ticks (world time advances).

**Tests:** `protocol_test.gleam` — parse each new client message (valid, wrong version, garbage); helm out-of-range values still parse (clamping is sim-side); `encode_welcome` contains world name + both station ids; `encode_snapshot` round-trip: encode 2 ships, decode with gleam/dynamic, check fields incl. `docked: null` vs `"meridian_highport"`; `encode_dock_result` both arms. Sim tests in `dh_server_test.gleam`: start sim with test world, `add_ship` returns 1 then 2 for two subjects; after add, subject receives a snapshot containing that ship docked at spawn (receive with `process.receive` timeout 2000ms); `set_controls` + undock: undocked full-thrust ship's x advances over ~30 ticks.

**Steps:** failing tests → implement → green → format → commit. (`gleam run` should boot and log ticks — verify once manually.)

---

### Task 4: Postgres accounts (server)

**Files:**
- Create: `server/src/dh_server/accounts.gleam`, `server/test/accounts_test.gleam`, `server/sql/schema.sql` (documentation copy of the DDL)
- Modify: `server/gleam.toml` (add `pog >= 4.0.0 and < 5.0.0`, `gleam_crypto >= 2.0.0 and < 3.0.0`), `server/src/dh_server.gleam` (wire real authenticator), `.github/workflows/server-test.yml` (postgres service), `server/README.md` (setup)

**IMPORTANT context for the implementer:** `pog` v4 API — read current hexdocs (https://hexdocs.pm/pog) before coding; the API changed at v3/v4 (named connections, supervised pool via `pog.start` / `pog.default_config`). Pre-2025 examples are wrong. Same caveat as gleam_otp in M0.

**Interfaces (Produces):**
```gleam
// accounts.gleam
pub fn connect(database_url: String) -> Result(pog.Connection, String)  // starts supervised pool; also runs ensure_schema
pub fn ensure_schema(db: pog.Connection) -> Result(Nil, String)
// CREATE TABLE IF NOT EXISTS accounts (
//   id BIGSERIAL PRIMARY KEY, username TEXT NOT NULL UNIQUE,
//   password_hash TEXT NOT NULL, salt TEXT NOT NULL,
//   created_at TIMESTAMPTZ NOT NULL DEFAULT now());
pub fn authenticator(db: pog.Connection) -> auth.Authenticator
// login-or-register: unknown username => INSERT (register) and Ok(id);
// known username => verify hash, Ok(id) or Error(InvalidCredentials).
// Empty username or password => Error(InvalidCredentials). DB failures => Error(StorageError(reason)).
```
Hashing: `gleam/crypto` — salt = 16 random bytes (`crypto.strong_random_bytes(16)`) hex-encoded; hash = hex(sha256(salt_hex <> password)). Store both as text. Add a `// TODO(pre-launch): upgrade to a KDF (argon2/bcrypt)` comment.

`dh_server.gleam`: read `DATABASE_URL` via envoy, default `postgres://postgres@127.0.0.1:5432/dh_dev`. On connect failure: print a clear warning and fall back to `auth.accept_all()` (dev convenience — the server must still boot without a DB; the warning must say auth is not persistent).

**Tests (`accounts_test.gleam`):** env-gated — if `DH_TEST_DATABASE_URL` is unset, each test returns early (prints one "skipped: no DH_TEST_DATABASE_URL" line). With it set: connect + ensure_schema succeeds; new username registers and returns id > 0; same username + same password logs in with the SAME id; same username + wrong password => InvalidCredentials; empty password => InvalidCredentials without touching the DB. Use a random per-run username (timestamp suffix) so reruns don't collide. Local run:
`$env:DH_TEST_DATABASE_URL='postgres://postgres@127.0.0.1:5432/dh_dev'; gleam test` (PowerShell) — Postgres is already running locally.

**CI:** add to `server-test.yml` a `services: postgres:` block (image `postgres:18`, `POSTGRES_HOST_AUTH_METHOD: trust`, `POSTGRES_USER: postgres`, `POSTGRES_DB: dh_test`, health-cmd pg_isready, port 5432:5432) and set `DH_TEST_DATABASE_URL: postgres://postgres@127.0.0.1:5432/dh_test` in the test step env.

**Steps:** failing tests (run with env var against local pg) → implement → green → format → commit.

---

### Task 5: Protocol harness — M1 client + integration tests (Python)

**Files:**
- Modify: `harness/dh_client.py`, `harness/benchmark.py`
- Create: `harness/server_fixture.py`, `harness/test_m1_flight.py`, `harness/README.md`, `harness/requirements.txt` (`websockets`, `pytest`, `pytest-asyncio`)

**Interfaces (Consumes):** wire protocol section above. **(Produces):** `DHClient` methods used forever after:
```python
async def login(self, username: str, password: str) -> dict   # sends login, waits for welcome | error; raises AuthError on error message
async def send_helm(self, rotate: float, thrust: float) -> None
async def dock(self) -> dict      # sends dock, returns the dock_result message
async def undock(self) -> dict
async def next_snapshot(self) -> dict            # recv_type("snapshot")
def ship_in(self, snapshot: dict, ship_id: int) -> dict | None
```
`server_fixture.py`: pytest fixture `server` (session-scoped) that builds and spawns `gleam run` in `server/` as a subprocess (env: `DH_WORLD` default; NO `DATABASE_URL` so it uses accept-all fallback — keeps CI/db decoupled), waits for the port to accept, yields, terminates on teardown (kill process tree on Windows: `taskkill /F /T /PID`). Refuse to run if port 8484 is already listening (same principle as the benchmark's stale-server guard — a shared server invalidates results).

**Tests (`test_m1_flight.py`, each async, against the fixture):**
1. `test_login_welcome`: login → welcome has ship_id int, world with 2 stations, dt == 0.016666666666666666; snapshots then arrive and contain our ship docked at `meridian_highport`.
2. `test_login_rejected_empty_password` → error `auth_failed`.
3. `test_undock_and_fly`: login, undock (ok), helm(0.0, 1.0), sample two snapshots ~1s apart → our ship's position changed by > 10 units and `docked` is null; helm(0.0, 0.0) → speed roughly stable after.
4. `test_two_clients_see_each_other_fly` (the M1 exit criterion, headless): clients A and B login; both see 2 ships in snapshots; A undocks and thrusts; B observes A's ship moving between snapshots while B's own stays docked/pinned to its station.
5. `test_dock_cycle`: undock, dock immediately (still inside dock_radius at station velocity) → ok; snapshot shows docked again; second dock → `already_docked`; undock, full thrust 3s away, dock → `out_of_range`.
6. `test_prelogin_ignored`: without login, send helm + dock; no snapshot arrives within 1s (recv timeout); get_stats still answers.

**benchmark.py:** update for M1 — each of the N clients logs in (username `bench_N`), so expected ships per snapshot == number of clients; keep the stale-server guard, duration/budget flags, exit-code semantics. Delete `validate_snapshot`'s 500-ship assumption (parameterize).

Run: `cd harness; python -m pytest test_m1_flight.py -v` (builds the server on first fixture use — allow ~60s startup timeout).

**Steps:** write tests (they fail: methods missing) → implement client + fixture → all 6 pass locally → commit.

---

### Task 6: Godot client — fly the system (GDScript)

**Files:**
- Modify: `client/scripts/network_client.gd`, `client/scripts/main.gd`, `client/scenes/main.tscn`, `client/project.godot` (input map)
- Create: `client/scripts/world_view.gd` (if a separate node helps; implementer's call — keep main.gd focused)

**Interfaces (Consumes):** wire protocol + world doc schema above.

**Behavior requirements:**
- **Login:** on connect, auto-send `login` with username/password from CLI args `--username=X --password=Y` (read `OS.get_cmdline_user_args()`), defaults `pilot`/`pilot`. Handle `welcome` (store ship_id, world, dt) and `error` (show on status label). NetworkClient gains signals `welcome_received(ship_id, world)`, `dock_result_received(ok, reason)`; snapshot signal unchanged.
- **Rails rendering:** star, planets, stations drawn from the world doc — client computes positions with the same orbit math (`t = (last_snapshot_tick + 60.0 * seconds_since_snapshot) * dt`, extrapolated between snapshots, capped like M0). Star: filled circle radius from doc, warm color; planets: filled circles, distinct colors, faint orbit-path circles around parent; stations: small diamonds/squares + name label, `dock_radius` shown as a faint ring when own ship is undocked.
- **Ships:** own ship a triangle pointing along heading (server heading is world y-up radians, screen y-down — negate), other ships smaller/dimmer triangles with id labels. Velocity extrapolation between snapshots as M0.
- **Camera:** viewport centered on own ship; mouse-wheel zoom (clamp, e.g. 0.02×–2.0×); everything else moves relative.
- **Helm input:** input map actions `turn_left` (A/Left), `turn_right` (D/Right), `thrust` (W/Up), `toggle_dock` (Space). Each physics frame compose rotate ∈ {-1,0,1} and thrust ∈ {0,1}; send `helm` ONLY when the composed pair changed (don't spam 60 Hz).
- **Docking UX:** status label shows connection state, tick, own speed, docked-at name; when undocked and within any station's dock_radius show "SPACE: dock at <name>"; Space sends dock/undock; show dock_result reason briefly on failure.
- `screenshot_helper.gd` untouched.

**Verification (no unit-test framework in client yet — the automation hook is Task 7):** `godot --headless --path client` boots without script errors (exit after a few seconds); then run the real server + `godot --path client` and fly: undock, thrust, dock at Solis Ring. Capture one screenshot as evidence. The implementer runs server via `cd server; gleam run` (PATH prefix `~\scoop\shims`).

**Steps:** implement → headless boot check → live flight check + screenshot → commit.

---

### Task 7: Client automation hook + harness driver

**Files:**
- Create: `client/scripts/automation_server.gd` (autoload), `harness/automation.py`, `harness/test_automation_smoke.py`
- Modify: `client/project.godot` (register autoload)

**Behavior (from DESIGN.md "Letting Claude see and drive the UI"):** debug builds only — autoload starts a local TCP server on `127.0.0.1:8486` **only when** `OS.is_debug_build()` AND `--automation` is present in `OS.get_cmdline_user_args()`. Newline-delimited JSON request/response (one JSON object per line):
- `{"cmd":"ping"}` → `{"ok":true,"pong":true}`
- `{"cmd":"screenshot","path":"C:/abs/path.png"}` → captures viewport to path → `{"ok":true,"path":...}`
- `{"cmd":"dump"}` → `{"ok":true,"state":{...}}` — connection state name, last tick, snapshot_count, own ship_id/x/y/heading/speed/docked, camera zoom, current status-label text, and `scene_tree`: recursive node names+classes as a compact text tree.
- `{"cmd":"action","action":"thrust","pressed":true}` → `Input.action_press/release` for any input-map action → `{"ok":true}`
- `{"cmd":"key","keycode":"SPACE","pressed":true}` → builds `InputEventKey`, `Input.parse_input_event` → `{"ok":true}`
- Unknown cmd → `{"ok":false,"error":"unknown_cmd"}`; parse failure → `{"ok":false,"error":"bad_json"}`.

`harness/automation.py`: small sync client `GodotAutomation(host, port)` with `ping() screenshot(path) dump() action(name, pressed) key(code, pressed)` + `launch_client(extra_args) -> Popen` helper that runs `godot --path client -- --automation --username=X`.

`test_automation_smoke.py`: marked `@pytest.mark.automation` (excluded by default via `-m "not automation"` note in README — it needs a display): launches server fixture + client, pings, dumps state until `connected` and ship_id present, presses `thrust` action for 1s after an undock via key SPACE, dumps again → position changed; screenshots to scratch dir; terminates client.

**Steps:** implement hook → implement python driver → run smoke test locally (this machine has a display) → commit.

---

### Task 8: Docs + milestone wrap

**Files:**
- Create: `docs/M1-RESULTS.md` (what M1 built, how to run server/client/harness/automation, protocol v1 message table, world-doc schema reference, Postgres setup incl. scoop install + pg_ctl start + trust-auth note, known gaps: password KDF TODO, per-connection ship lifetime)
- Modify: `DESIGN.md` (M1 milestone line → done + link, mirroring the M0 pattern), `server/README.md` (env vars: `DH_WORLD`, `DATABASE_URL`; run instructions)

**Steps:** write docs (verify every command in them actually runs) → commit.

---

## Execution notes (controller)

- Branch: `m1-flight-core` off `main`; PR at the end (user reviews PRs, never commit to main).
- Task order is strictly 1→8 (each consumes the previous interfaces). No parallel implementers.
- Local Postgres is already installed & running (scoop, trust auth, `dh_dev` exists). `pg_ctl` lives at `~\scoop\apps\postgresql\current\bin`.
- Gleam/Godot/Python invocations need `$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"` in PowerShell (or `export PATH="$HOME/scoop/shims:$PATH"` in bash).
