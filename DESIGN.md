# Distant Horizon — Design Document

*Rewrite of Distant Horizon ("Classic", see `../DistantHorizonClassic`). Living document — edit freely.*

## Vision

Distant Horizon is a multiplayer game about realistic space travel. You and your crew fly a merchant
spaceship between stations orbiting in a large solar system, using flip-and-burn trajectories to
navigate between moving planets. Zoomed out, it plays like Classic DH: a top-down 2D system view
with Newtonian flight. Zoomed in, you get out of your chair: an FTL-style deck view of your ship's
interior, where every crew member is a walking character interacting with the ship's systems.

The one-sentence pitch: **Classic DH's flight model + FTL's ship interior + shared-crew multiplayer.**

### Pillars

1. **Real space flight.** Planets orbit, trajectories matter, flip-and-burn is the core verb of travel.
2. **The ship is a place.** You don't *have* a ship, you're *in* one. Rooms, corridors, chairs,
   consoles. The interior view is where your body lives; the system view is what the helm sees.
3. **Crew multiplayer.** One ship, several players, different jobs: pilot, engineer, quartermaster,
   fighter jock. Solo play works too (you're a crew of one), but the design leans co-op.
4. **Motherships and small craft.** Shuttles, snub fighters, and tenders dock inside or alongside
   larger ships. Detaching a fighter while the carrier burns for a planet is a headline moment.

## What we keep, drop, and add vs. Classic

| | |
|---|---|
| **Keep** | 2D top-down system view; planets-on-rails orbital mechanics; flip-and-burn Newtonian flight; station docking; commodity trading and dynamic economy; shared persistent universe |
| **Drop** | The ~23-minute repeating universe cycle (`cycle.length.ticks`) and the script-recording/replay AI it existed to serve; the Python/Flask balancer; the website; MySQL |
| **Add** | Ship interiors (FTL-style deck view) with walkable crew characters; shared-ship crew multiplayer; detachable small craft (shuttles/snubs/carriers); real autopilot-driven NPC ships; Postgres persistence |
| **Defer** | Combat (design toward it, don't build it yet); routefinding royalties; passenger contracts; boarding other ships; LLM-driven characters/missions |

Dropping the time-loop is a big simplification: Classic needed deterministic, cycle-aligned
simulation so recorded AI scripts stayed valid. Without it, the sim no longer needs to be
deterministic or periodic, which frees up nearly every technical choice below.

## Architecture

```
┌──────────────┐   WebSocket (binary or JSON)   ┌──────────────────┐      ┌──────────┐
│ Godot 4.x    │ ◄────────────────────────────► │  Game server     │ ───► │ Postgres │
│ client       │      inputs / snapshots        │  (authoritative) │      │          │
└──────────────┘                                └──────────────────┘      └──────────┘
```

Two components plus a database. No balancer, no website. Single game server process to start;
nothing in the design should *prevent* sharding by star system later, but we don't build it now.

### Client: Godot 4.x (latest stable)

- GDScript to start; C# or GDExtension only if a hot spot demands it.
- Everything stays 2D. The system view is the Classic camera; the interior view is a tile/room
  scene rendered over (or in place of) the hull sprite.
- **Web export is kept viable but not committed to.** Hosting is TBD, so: transport is WebSocket
  (works everywhere), no reliance on threads-required web features, no UDP. If we later go
  desktop-only we lose nothing; if we go web we haven't painted ourselves into a corner.
- Client is a dumb-ish renderer + input device: it predicts/interpolates for feel, but the server
  owns all state.

### Server language: recommendation — **Gleam** (with an explicit escape hatch)

The candidates seriously considered:

| Option | Learning value | Fit | Risk |
|---|---|---|---|
| **Kotlin again** | none | proven by Classic | motivation; temptation to port old code instead of rethinking |
| **Gleam** | high — typed FP on the BEAM | actor model maps 1:1 onto the game | young ecosystem (v1 in 2024); immutable-only hot loops |
| **Elixir** | high, more practical than novel | same BEAM fit, huge ecosystem | dynamically typed; less "new" |
| **Rust** | high but heavy | max performance | iteration speed tax on gameplay experimentation |

**Why the BEAM at all:** this game is *shaped like* Erlang. One lightweight process per star
system, per ship, per player connection; ships and crews are naturally isolated state machines
that talk by message; a crashed ship process restarts without taking down the server. That's not
resume-driven language tourism — it's the concurrency model the design actually wants. (This is
the "actually valuable, not Haskell for lolz" bar.)

**Why Gleam over Elixir:** static types are worth a lot in a from-scratch rewrite where the
protocol and data model will churn, and Gleam can call Erlang/Elixir libraries when its own
ecosystem falls short. Concretely available today: `mist`/`wisp` (HTTP + WebSockets), `pog`
(Postgres), OTP actors via `gleam_otp`.

**The honest risk:** Gleam has no mutable arrays and the BEAM is not a numerics platform. Our
numbers say that's fine — Classic capped at 60 players, and integrating a few hundred 2D bodies
with planets on rails at 60 Hz is trivial arithmetic — but it must be *proven*, not assumed.

**Decision gate (Milestone 0):** build a spike — 60 Hz tick loop, 500 simulated ships, 20 fake
WebSocket clients receiving 15 Hz snapshots. If tick time stays comfortably under budget (< ~5 ms)
and the code feels good, Gleam is confirmed. If not, fall back to **Elixir** (same architecture,
same libraries, minimal redesign) or Kotlin (known quantity).

### Database: PostgreSQL

Persistence only — the live sim runs in memory, with periodic write-behind. Postgres stores:

- `accounts` — identity, auth (mechanism TBD; Classic's balancer-mediated login is gone)
- `characters` — per-account crew member(s): name, appearance, current ship + berth
- `ships` — owned ships: class, name, colors, fuel, condition, location (docked-at or system+state)
- `ship_cargo` / `wallets` — holds and money
- `stations` / `commodity_stores` — economy state so prices survive restarts
- `world` config stays in files (like Classic's `world/*.properties` and `shipclasses/*.properties`
  — that format was good; keep the idea, modernize to TOML/JSON)

### Protocol

- WebSocket, server-authoritative. Client sends **intents** (helm inputs, "walk to tile", "sit at
  console", "buy 10 units"); server sends **snapshots and events**.
- Start with JSON for debuggability; the envelope is versioned so hot paths (ship state snapshots)
  can move to a packed binary format when profiling says so.
- Interest management from day one, but coarse: you receive full-detail updates for (a) the ship
  you're aboard, including interior, and (b) exterior states of objects in your current star
  system. Nobody receives other ships' interiors unless aboard.
- Tick model: 60 Hz simulation, ~15 Hz network snapshots with client-side interpolation, ship
  physics state (pos/vel/accel) sent so the client can extrapolate smoothly between snapshots.
  No determinism requirement — the replay-AI constraint died with the time loop.

## Simulation model: two nested scales

The core technical idea of the rewrite. Every ship simulates at two scales:

**Exterior scale (system frame).** The Classic sim: ship is a point mass with position, velocity,
orientation, thrust. Planets and stations are on rails (analytic orbits, computable for any *t* —
keep this from Classic, it's cheap and lag-proof). Gravity, burns, docking.

**Interior scale (ship-local frame).** An FTL-style deck plan: a grid of tiles grouped into rooms
(helm, engine room, cargo hold, airlock, hangar), with consoles/chairs as interactable objects.
Crew characters have positions *in ship-local coordinates* and simple walk movement. The interior
does **not** feel the ship's acceleration — artificial gravity handwave, exactly like FTL. This is
the crucial simplification: interior sim is completely decoupled from exterior physics; the ship's
frame is just a container that happens to be moving.

The link between the scales is **consoles**: sitting at the helm console binds your inputs to the
ship's exterior controls (and your camera to the system view); the engineering console will bind
to power/repair systems (later); a turret seat binds to a weapon (much later). Getting out of your
chair unbinds you and returns you to your walking body. "Zoom" in the UI is really a view/control
mode switch, presented as a smooth camera zoom.

Ship classes gain an interior definition alongside the Classic-style stats: deck layout (tile
grid, rooms, door graph), console placements, docking ports, and hangar berths for small craft.

## Multiplayer & crew design

- **Ships have crews, not owners at the helm.** A ship has an owner (economic) and any number of
  aboard characters. Any crew member can use any console the owner's permissions allow (keep the
  permission model dead simple at first: owner + everyone-aboard-is-trusted).
- **Roles are emergent from consoles**, not from a class system. The pilot is whoever's in the
  pilot seat.
- **Solo play** is the same systems with a crew of one — you park the helm (autopilot holds
  course / keeps orbit) to walk to the cargo console. Autopilot is therefore a launch feature,
  not a luxury (and it's shared code with NPC piloting, below).
- Joining friends: spawn as a character *aboard someone's ship* rather than as a new ship. The
  new-player path can be "start with your own small ship" or "join a crew" — both cheap once
  characters and ships are separate entities.
- Chat: per-ship (intercom) and per-station/local, plus whatever global channel we feel like.
  Classic's Discord bridge was nice; port the idea eventually.

## Small craft, carriers, docking

Docking is one relationship with several flavors:

- **Ship ↔ station** (Classic behavior): dock at a port, trade, refuel.
- **Small craft ↔ mothership:** a shuttle or snub fighter occupies a *berth* (hangar tile region
  or external clamp) on the mother ship. While berthed, the small craft is not simulated at
  exterior scale — it's an interior object you can walk up to and board through.
- **Launch/recover:** boarding a berthed craft and launching detaches it into the system frame,
  seeded with the mothership's position/velocity. Recovery is a docking maneuver against the
  (possibly accelerating) mothership — this is deliberately a *skill moment*, with an autopilot
  assist option.

A berthed craft keeps its identity (it's a ship row in the DB with `docked_to = mothership`), so
fighters keep their fuel state, damage, and cargo across launch cycles. Nothing about this model
distinguishes a 2-berth freighter from a 30-berth carrier except the deck plan — carriers are
content, not code.

## NPC ships: real autopilot instead of tape replay

Classic's AI ships replayed recorded input scripts, which required the looping universe. The
replacement is layered:

1. **Autopilot (the hard part, build once):** given a target (station, orbit, rendezvous with a
   moving ship), produce thrust/rotation commands. Flip-and-burn intercept of an orbiting target
   is an iterative solve (guess arrival time → target position at that time → brachistochrone
   burn → refine). Classic's client already had PID-based assists; this is that idea promoted to
   a server-side module. **Players get it too** (autopilot/assist modes), so it's one codebase
   serving NPCs, solo-crew quality of life, and docking assists.
2. **Behavior layer:** utility-based or plain state machines choosing *what* to do — pick a
   profitable trade run, haul, dock, sell, repeat. This recreates Classic's ambient traffic
   without any recording infrastructure, and NPC traders can actually participate in the dynamic
   economy instead of faking it.
3. **LLM layer (deferred, optional):** flavor and characters — named NPC captains, hailing
   dialogue, generated missions. Explicitly *not* in the piloting loop (wrong latency, wrong
   cost); it rides on top of the behavior layer if/when we want it.

## Hosting & distribution (TBD, deliberately)

- Server: any box that runs the BEAM and Postgres; a single small VPS matches Classic's scale.
- Client: undecided between downloadable desktop builds (itch.io is the low-friction option) and
  web export. The WebSocket-only, no-web-hostile-features rule above keeps both open. Decide
  around Milestone 2 when there's something worth putting in front of people.
- No balancer: one server, clients connect directly (config/DNS). If multiple servers ever return,
  prefer a static server-list JSON over a live balancer service.

## Milestones

- **M0 — Spike / decision gate (small):** Gleam tick-loop + WebSocket benchmark (see decision
  gate above). Godot 4 walking-skeleton client: connect, see a dot move under server control.
  *Exit: server language locked.*
- **M1 — Flight core:** one star system loaded from config; planets on rails; flyable ship with
  Classic feel; two clients see each other fly; station docking; Postgres accounts + ship
  persistence.
- **M2 — The ship is a place:** interior deck plan for one ship class; walkable character; sit at
  helm ↔ walk around; zoom transition between views; two players aboard the same ship, one
  flying while the other walks. *This is the milestone that proves the new game.*
- **M3 — Trade loop:** cargo, commodity stores, dynamic economy port, buy low / fly / sell high.
  Playable game from here on.
- **M4 — Small craft:** shuttle berthed in a freighter; launch, fly, recover. One carrier-ish
  ship class to show off.
- **M5 — Living system:** autopilot module, NPC traders as ambient traffic, economy reacts to
  NPC + player trades.
- **M6+ — Expansion:** combat, multiple systems, boarding, passengers, routefinding, LLM
  characters — reprioritize when we get here.

## Open questions

- **Auth:** with the balancer gone, what's the login story? Simplest viable: server-issued
  accounts with username/password over TLS; or lean on itch.io/Steam identity later.
- **Godot minor version:** take latest stable 4.x at project start and pin it.
- **Interior fidelity:** FTL-style discrete tiles vs. free 2D movement inside rooms? (Leaning
  free movement with tile-based *layout* — feels less board-gamey — but FTL-style pathfinding
  simplicity is tempting. Decide in M2.)
- **How much ship-system depth at M2:** power distribution / repair / fires FTL-style, or just
  helm + cargo consoles first? (Leaning: consoles first, systems sim later — interiors are
  valuable for *embodiment* even before they're a systems game.)
- **Combat direction when it comes:** FTL-style stations-and-systems combat vs. Classic-style
  flight combat vs. both scales at once. The snub-fighter design suggests both, which is also
  the most work. Punt, but keep deck plans and the autopilot API combat-shaped.
