# M1 — Flight core: results

**Date:** 2026-07-13 · **Exit criterion met: two clients see each other fly** (proven
continuously by `harness/test_m1_flight.py::test_two_clients_see_each_other_fly`).

## What M1 built

- **World from config, planets on rails** — the server loads a pinned star system from a
  JSON world doc (`server/worlds/m1_system.json`, path overridable via `DH_WORLD`).
  Bodies and stations move on analytic circular orbits ("rails"): position is a pure
  function of time, so bodies and stations are **never sent in snapshots** — the client
  computes them from the world doc (sent once in `welcome`) plus the snapshot tick,
  with exact server/client math parity.
- **Flyable Newtonian ship** — rotate + thrust helm (semi-implicit Euler at 60 Hz,
  `main_accel` 40 u/s², `turn_rate` 3 rad/s), point-mass gravity from every body,
  docking at stations (in `dock_radius`, relative speed ≤ 60 u/s) with docked ships
  pinned to the station's rail. Ships spawn docked at the world's spawn station.
- **Sessions over the wire** — v1 JSON protocol grows `login`/`welcome`/`error`,
  `helm`, `dock`/`undock`/`dock_result`; per-connection session state machine
  (pre-login inputs ignored); ship + snapshot subscription cleaned up by process
  monitor on disconnect.
- **Postgres accounts** — login-or-register against a real database (`DATABASE_URL`),
  salted-SHA-256 password hashes, accept-all fallback with a loud warning when the DB
  is unreachable. CI runs the account tests against a disposable `postgres:18` service.
- **Permanent Python protocol harness** — `harness/dh_client.py` (reusable async
  client), a self-managed server fixture, 6 integration tests
  (`test_m1_flight.py`), and the load benchmark (`benchmark.py`).
- **Godot client flies the system** — auto-login (`--username=X --password=Y`, default
  `pilot`/`pilot`), rails-rendered bodies/stations, keyboard flight, camera follow +
  wheel zoom, SPACE dock/undock with dock-prompt UX, other players' ships visible.
- **Client automation hook** — debug-only NDJSON control socket
  (`client/scripts/automation_server.gd`, `127.0.0.1:8486`) so the harness (and
  Claude) can drive and inspect a real client: ping / state dump / input injection /
  screenshot. Only opens when `OS.is_debug_build()` **and** `--automation` is passed;
  inert in release exports. Driven by `harness/automation.py` +
  `test_automation_smoke.py`.

## Running it

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"   # gleam/erlang/godot shims

# terminal 1 — server (reads DH_WORLD and DATABASE_URL, defaults shown below)
cd server; gleam run

# terminal 2 — a client (add --automation to arm the control socket)
godot --path client -- --username=ada --password=lovelace

# protocol integration tests (manage their own server; port 8484 must be free)
cd harness; python -m pytest            # automation smoke excluded by default
python -m pytest test_automation_smoke.py -v -m automation   # needs a display

# load benchmark (targets an already-running server — terminal 1 above)
cd harness; python benchmark.py --clients 5 --duration 10
```

Benchmark on this milestone's build: 5 clients at a flat 15.00 snapshots/s, server
tick p99 0.103 ms (budget 5 ms) — PASS.

Harness deps: `cd harness; python -m pip install -r requirements.txt`.

## Protocol v1

Every message is one JSON object with `"v": 1` and a `"type"` discriminator.

| dir | type | payload |
|---|---|---|
| → | `login` | `username`, `password` |
| → | `helm` | `rotate` (−1..1), `thrust` (0..1) — clamped sim-side |
| → | `dock` / `undock` | — |
| → | `get_stats` | — |
| ← | `welcome` | `account_id`, `ship_id`, `tick_rate`, `dt`, `world` (full world doc) |
| ← | `error` | `code` (`auth_failed` \| `storage_error`), `message` |
| ← | `dock_result` | `ok`, `reason` (`null` \| `out_of_range` \| `too_fast` \| `already_docked` \| `not_docked`) |
| ← | `snapshot` | `tick`, `ships: [{id,x,y,vx,vy,heading,thrust,docked}]` — `docked` is a station id or `null` |
| ← | `stats` | `ticks`, `clients`, `tick_ms {p50,p95,p99,max}` |

Snapshots are sent at 15 Hz (every 4th tick of the 60 Hz sim). Bodies/stations are
never in snapshots; clients evaluate rails at `t = tick × dt`:
`angle = phase·2π + 2π·t/period_s`, `pos = parent_pos + radius·(cos, sin)`, chained
station → planet → star (the root star is fixed at the origin).

## World doc schema (`schema: 1`)

```jsonc
{
  "schema": 1, "name": "...", "seed": 20260712,
  "bodies": [           // first entry must be the root (parent: null)
    {"id": "krasny", "name": "Krasny", "kind": "star|planet",
     "parent": null,    // or a body id
     "orbit": null,     // or {"radius": u, "period_s": s, "phase": 0..1}
     "radius": 500.0,   // collision/clamp radius, u
     "mu": 2.0e7}       // gravitational parameter (accel = mu / r²)
  ],
  "stations": [
    {"id": "meridian_highport", "name": "...", "parent": "meridian",
     "orbit": {...}, "dock_radius": 150.0}
  ],
  "spawn_station": "meridian_highport"
}
```

## Postgres setup (local dev)

```powershell
scoop install postgresql          # once; trust auth for local connections by default
& "$env:USERPROFILE\scoop\apps\postgresql\current\bin\pg_ctl.exe" `
  -D "$env:USERPROFILE\scoop\apps\postgresql\current\data" start
& "$env:USERPROFILE\scoop\apps\postgresql\current\bin\createdb.exe" -U postgres dh_dev
```

The server's default `DATABASE_URL` is `postgres://postgres@127.0.0.1:5432/dh_dev`
(no password — scoop's Postgres ships with trust auth for local connections; fine for
dev, not for anything reachable). Schema is created on boot; `server/sql/schema.sql`
is a documentation copy. See `server/README.md` for the env-gated account tests.

## Known gaps (deliberate, tracked)

- **Password hashing is salted SHA-256, not a real KDF** — fine for a dev milestone,
  must become argon2/scrypt/bcrypt before anything public.
- **Ships live only as long as their connection** — disconnect despawns the ship;
  there is no persistence of position/state between logins (accounts persist, ships
  don't). Ship persistence is a later milestone.
- Docking snaps position/velocity on the *next* tick after `dock_result`, so one
  snapshot can show a docked ship one frame off the station rail.
- The accept-all auth fallback means a dev server without Postgres accepts any
  credentials — by design for dev ergonomics, flagged loudly at boot.
