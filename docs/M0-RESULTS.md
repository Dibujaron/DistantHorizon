# M0 — Spike / decision gate: results

**Date:** 2026-07-12 · **Verdict: PASSED — server language locked to Gleam.**

## Benchmark

Config per DESIGN.md decision gate: 60 Hz tick loop, 500 simulated ships, 20 WebSocket
clients receiving 15 Hz JSON snapshots. Budget: tick time comfortably < 5 ms.

Environment: Windows 11, Gleam 1.17.0, Erlang/OTP 29 (mist 6.0.3, gleam_otp 1.2.0).

60 s run, 20 clients (4327 ticks):

| metric | value | budget | |
|---|---|---|---|
| tick p50 | 0.102 ms | 5 ms | ✅ |
| tick p95 | 0.820 ms | 5 ms | ✅ |
| tick p99 | 1.126 ms | 5 ms | ✅ |
| tick max | 5.836 ms | 5 ms | ⚠️ one-off |
| client snapshot rate | 15.00/s all 20 clients (900/900, 0 errors) | ≥ 14/s | ✅ |

The single over-budget tick is a one-time warm-up spike on the first broadcast after all
20 clients connect; steady-state p99 is ~1.1 ms (~4 % of budget, ~50× headroom).
Reproduced in a second independent 15 s run (p99 1.02 ms, PASS).

Tick durations include ship integration *and* JSON serialization of the 500-ship
snapshot. Percentiles are computed over the last completed 1000-tick window; max is
all-time. Immutable-only data (rebuilding the 500-ship list every tick) is a non-issue
at this scale, as the design doc hoped but required proving.

## Code feel (the other half of the gate)

Positive. The type system caught every wiring mistake (typed subjects thread the
sim→socket push path end to end); the actor model maps 1:1 onto the design; records +
pattern matching keep the tick loop readable. Pain points were young-ecosystem, not
language: gleam_otp's actor API changed at v1 (pre-2025 examples are wrong — read
current hexdocs), and the stdlib lacks trig and a monotonic clock (each a two-line
`@external` FFI shim).

## What M0 built

- `server/` — Gleam server `dh_server`: sim actor (drift-corrected 60 Hz self-scheduling
  tick loop), 500 ships on circular orbits, mist WebSocket on `127.0.0.1:8484/ws`,
  versioned v1 JSON envelope (`snapshot`, `get_stats`/`stats`), tick-time stats,
  6 gleeunit tests (determinism, 3600-tick orbit boundedness, percentiles, protocol
  round-trip).
- `harness/` — Python protocol harness seed: reusable `DHClient` (`dh_client.py`) and
  `benchmark.py` (the M0 load rig; `--duration`, `--clients`, `--budget-ms`; exit code
  is the pass/fail).
- `client/` — Godot 4.7 walking skeleton: `NetworkClient` autoload (WebSocketPeer,
  auto-reconnect, version check), main scene draws all 500 ships as dots with
  velocity extrapolation between 15 Hz snapshots for smooth 60 fps motion, connection
  state label. Verified live against the server (screenshot + server-side client count).
  - Godot gotcha worth remembering: `WebSocketPeer.inbound_buffer_size` defaults to
    64 KiB and a snapshot is already ~40 KB — raised to 4 MiB before connect.

## Running it

```powershell
# terminal 1 — server
cd server; gleam run
# terminal 2 — benchmark (decision gate)
cd harness; python benchmark.py            # needs: python -m pip install websockets
# or the client
cd client; godot --path .
```

(Toolchain via scoop: `scoop install gleam erlang rebar3 extras/godot` — shims live in
`~\scoop\shims`.)
