# M2 — Ship Interior Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One ship class with a walkable interior: characters walk the deck, sit at the
helm to fly, and two players crew one ship (one flying, one walking), proven by harness
tests.

**Architecture:** The server grows a character layer inside the existing sim actor —
characters live aboard ships, walk in ship-local tile coordinates fully decoupled from
exterior physics, and consoles bind seated characters to ship controls. Exterior
`snapshot` stays a shared broadcast; a new per-ship `interior` message goes only to the
crew aboard (interest management). The Godot client adds an interior view and a smooth
zoom transition keyed off seat state.

**Tech Stack:** Gleam/OTP (server), Godot 4 GDScript (client), Python pytest harness.

**Contract:** `docs/superpowers/specs/2026-07-14-m2-ship-interior-design.md` is the
single source of truth for the wire protocol, the `sparrow.json` deck plan (copy it
verbatim), movement/seat/board rules, and the test list. Read it before any task.

## Global Constraints

- Protocol stays `v: 1`; existing message shapes unchanged except `welcome` (+`character_id`, +`ship_class`) and `dock_result` (+reason `"not_at_helm"`).
- Login spawns ship + character **seated at helm** — all M1 tests must pass unchanged.
- Walk speed 3.0 tiles/s, character radius 0.3 tiles, sit range 1.2 tiles, 60 Hz sim, 15 Hz interior/snapshot cadence.
- Ships with zero characters aboard despawn.
- Windows dev shell: prefix PATH with `$env:USERPROFILE\scoop\shims` for gleam/erlang/godot.

---

### Task 1: Server — ship class, characters, protocol, sim (Gleam)

**Files:**
- Create: `server/classes/sparrow.json` (verbatim from spec)
- Create: `server/src/dh_server/shipclass.gleam` — parse/validate/encode class doc; `is_walkable(class, x, y)`; loaded at boot (default `server/classes/sparrow.json`, env `DH_SHIP_CLASS` overrides — mirror how `DH_WORLD` is handled in `dh_server.gleam`)
- Create: `server/src/dh_server/character.gleam` — `Character(id, name, ship_id, x, y, seat: Option(String), move_dx, move_dy)`; `step(character, class) -> Character` (normalize input, per-axis circle-vs-tile collision); `try_sit`, `stand`, spawn helpers (`spawn_seated_at_helm`, `spawn_at_spawn_tile`)
- Modify: `server/src/dh_server/protocol.gleam` — decode `move`/`sit`/`stand`/`board`; encode `seat_result`/`board_result`/`interior`; `encode_welcome` gains `character_id` + `ship_class`
- Modify: `server/src/dh_server/sim.gleam` — state gains characters + ship class; `AddShip` → `AddPlayer(name, client, reply: Subject(#(Int, Int)))` returning `#(ship_id, character_id)`; route `SetControls`/`RequestDock`/`RequestUndock` by **character id** with helm-seat gating; new msgs `SetMove`, `RequestSit`, `RequestStand`, `RequestBoard`; tick steps characters; interior fan-out at 15 Hz per crewed ship to that ship's clients only; `ClientDown` removes character then despawns empty ships
- Modify: `server/src/dh_server/server.gleam` — session `LoggedIn(client, ship_id, character_id)`; wire new messages; ship_id updates on successful board
- Modify: `server/src/dh_server/dh_server.gleam` — load class, pass to sim
- Test: `server/test/shipclass_test.gleam`, `server/test/character_test.gleam`, extend `server/test/protocol_test.gleam`

**Interfaces:**
- Consumes: existing `ship.gleam` (unchanged), `world.gleam`, spec protocol tables.
- Produces: the exact wire messages in the spec — harness (Task 2) and client (Task 3) are built against them, not against Gleam types.

- [ ] Write failing tests: shipclass parse/validate/walkable; character step collision (walk into wall → slide/stop; never on non-walkable tile), sit range/occupancy rules; protocol round-trips for the new messages
- [ ] Run `cd server; gleam test` — new tests fail
- [ ] Implement shipclass.gleam, character.gleam, protocol.gleam changes
- [ ] Implement sim.gleam + server.gleam + dh_server.gleam wiring
- [ ] `gleam test` passes; `gleam run` boots and logs class load
- [ ] Commit `M2 server: walkable characters, consoles, boarding`

### Task 2: Harness — client helpers + M2 integration tests (Python)

**Files:**
- Modify: `harness/dh_client.py` — expose `character_id`/`ship_class` from welcome; add `move(dx, dy)`, `sit(console_id)`, `stand()`, `board(ship_id)` (await their `seat_result`/`board_result`), `next_interior()` capture alongside snapshots
- Create: `harness/test_m2_interior.py` — the five tests from the spec's Harness section (spawn state; stand/walk/collide; seat rules + `not_at_helm`; boarding; exit criterion: one flies while one walks)

**Interfaces:**
- Consumes: spec wire protocol; `server_fixture.py` unchanged (server must be built — run after Task 1).
- Produces: `test_m2_interior.py::test_one_flies_one_walks` — the M2 exit-criterion test named in results docs.

- [ ] Write helpers + all five tests against the spec (mirror `test_m1_flight.py` style: one server fixture, async clients, generous-but-bounded waits)
- [ ] `cd harness; python -m pytest test_m2_interior.py -v` — passes against Task 1 server
- [ ] `python -m pytest` — M1 tests still green
- [ ] Commit `M2 harness: interior client helpers and tests`

### Task 3: Client — interior view, seat-driven modes, zoom transition (Godot)

**Files:**
- Create: `client/scripts/interior_view.gd` + `client/scripts/character_state.gd` — deck rendering (floor tiles, room tints/labels, consoles, characters as circles, own highlighted), crew positions from `interior` messages (extrapolate/lerp like ships)
- Modify: `client/scripts/network_client.gd` — parse `interior`/`seat_result`/`board_result`, welcome extras; new signals
- Modify: `client/scripts/world_data.gd` or new `ship_class_data.gd` — parsed class doc with walkable/room/console lookups
- Modify: `client/scripts/main.gd` — view-mode state machine (INTERIOR standing ↔ SYSTEM at helm) with ~0.6 s animated zoom+crossfade; WASD move intents (send on change); `E` sit/stand; `B` board; status label shows mode/prompts
- Modify: `client/scenes/main.tscn` — add InteriorView node; input map entries (`move_up/down/left/right`, `interact`, `board`) in `client/project.godot`
- Modify: `client/scripts/automation_server.gd` — state dump gains `view_mode`, `character {id,x,y,seat}`, `ship_id`

**Interfaces:**
- Consumes: spec wire protocol + class doc; existing `world_view.gd` untouched.
- Produces: automation state fields used by smoke checks (`view_mode`, `character`).

- [ ] Implement per above; keep M1 flight controls exactly as-is when seated at helm
- [ ] Verify: `godot --path client --headless --quit` (script parse check), then manual/automation sanity vs a running server
- [ ] Commit `M2 client: interior view, sit/stand, zoom transition, boarding`

### Task 4: Integration & results (do inline, not subagent)

- [ ] `cd server; gleam test`; `cd harness; python -m pytest` (M1 + M2, server fixture builds current branch)
- [ ] Automation smoke: two real clients against a dev server; screenshot interior + transition; assert state dump fields
- [ ] Fix whatever integration shakes out (protocol drift between agents lands here)
- [ ] Write `docs/M2-RESULTS.md` (mirror M1 results format: what built, how to run, protocol delta, known gaps); mark DESIGN.md open questions (interior movement, system depth) as decided-in-M2 with one-line answers
- [ ] PR to main (per user workflow: PRs, never direct commits to main)
