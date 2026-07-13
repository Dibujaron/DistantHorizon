# Distant Horizon protocol harness

Python side of the permanent Distant Horizon protocol test harness: a
reusable async client (`dh_client.py`), the M1 flight-core integration
tests (`test_m1_flight.py`) driven by a self-managed server fixture
(`server_fixture.py`), and the load benchmark (`benchmark.py`). Tests and
the benchmark both talk to the server through `DHClient` so protocol
changes stay in one place.

## Setup

```powershell
$env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"   # gleam on PATH
cd harness
python -m pip install -r requirements.txt
```

## Running the integration tests

```powershell
cd harness
python -m pytest test_m1_flight.py -v
```

This builds and spawns a real `gleam run` server from `server/` for the
whole test session (see `server_fixture.py`), so:

- **First run is slow** (~60 s timeout budgeted for the initial Gleam
  build); subsequent runs are fast since the build is cached.
- **Port 8484 must be free.** The fixture refuses to start if something
  is already listening there — a stale or shared server would invalidate
  the results. If a previous run didn't get torn down cleanly:
  ```powershell
  netstat -ano | findstr 8484
  taskkill /F /T /PID <pid>
  ```
- **No local Postgres required, and none touched.** The fixture points
  the spawned server's `DATABASE_URL` at an address that refuses
  connections, which forces the server's accept-all auth fallback
  deterministically — regardless of whether this machine happens to have
  a reachable `dh_dev` Postgres instance (it does, in dev). This keeps
  the tests decoupled from local database state and from CI's lack of
  one, and stops test accounts from leaking into the real dev database.

The 6 tests cover: login/welcome (world doc, spawn-docked), rejected
login, undock + fly + drift-stop, two clients observing each other (the
M1 exit criterion, headless), the dock/undock/redock cycle including
`already_docked` and `out_of_range`, and that pre-login messages are
inert except `get_stats`.

Tests that need "N seconds of simulated time" drain the snapshot stream
by server `tick` number rather than sleeping — snapshots arrive
continuously in the background, so sleeping without reading would just
leave old snapshots queued for the next `recv()`.

## Running the benchmark

```powershell
cd harness
python benchmark.py                 # full 60 s run, 20 clients
python benchmark.py --duration 10 --clients 5   # quick smoke run
```

Each of the N clients logs in (`bench_0`, `bench_1`, ...), so the
expected ship count per snapshot is just N — M1 has one ship per
logged-in connection, unlike M0's fixed 500 fake ships. PASS requires
every client sustaining >= `--min-rate` snapshots/s (default 14),
well-formed snapshots with exactly N ships and strictly increasing
ticks, and server tick p99 under `--budget-ms` (default 5.0 ms). Exit
code is the pass/fail (0/1), so it's CI-friendly.

The benchmark keeps its own freshness guard (`--max-server-age`,
default 30 s): it probes the server before connecting any load and
fails fast if the server has been running suspiciously long or already
has other clients attached, since either would pollute the cumulative
tick stats. The probe never logs in, so it never owns a ship and is
never counted as a "client" itself.

Run it against a server you started yourself (any auth mode — accept-all
or real Postgres both work, since each client just logs in with a fixed
per-client username/password):

```powershell
cd server; gleam run
# in another terminal:
cd harness; python benchmark.py --clients 5 --duration 10
```

## Files

- `dh_client.py` — `DHClient`: connect/send/recv plus typed wrappers for
  every v1 message (`login`, `send_helm`, `dock`, `undock`,
  `next_snapshot`, `get_stats`) and `ship_in` for pulling one ship out of
  a snapshot. Every reply-waiting method has a default 10 s timeout
  (override per call, `timeout=None` waits forever), so a server that
  stops replying fails the run fast instead of hanging it.
- `server_fixture.py` — session-scoped pytest fixture that builds, spawns,
  waits on, and tears down a real `gleam run` server for the test session.
- `test_m1_flight.py` — the 6 M1 flight-core integration tests.
- `benchmark.py` — the load/decision-gate benchmark.
- `requirements.txt` — `websockets`, `pytest`, `pytest-asyncio`.
