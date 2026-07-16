# Distant Horizon — Design Document

*Rewrite of Distant Horizon ("Classic", see `../DistantHorizonClassic`). Living document — edit freely.*

## Vision

Distant Horizon is a multiplayer roguelike about realistic space travel. You and your crew take out
a loan on a merchant spaceship, fly it between stations orbiting in a freshly generated solar
system, and try to get rich before the bank gets you. Zoomed out, it plays like Classic DH: a
top-down 2D system view with Newtonian flight and flip-and-burn trajectories. Zoomed in, you get
out of your chair: an FTL-style deck view of your ship's interior, where every crew member is a
walking character interacting with the ship's systems. A campaign — a **run** — lasts a few hours
and then it's over: you retire rich, or the bank repossesses the ship.

The one-sentence pitch: **Classic DH's flight model + FTL's ship interior and run structure +
shared-crew multiplayer.**

### Pillars

1. **Real space flight.** Planets orbit, trajectories matter, flip-and-burn is the core verb of travel.
2. **The ship is a place.** You don't *have* a ship, you're *in* one. Rooms, corridors, chairs,
   consoles. The interior view is where your body lives; the system view is what the helm sees.
   Stations are places too — you dock, walk out the airlock, and do business on foot.
3. **Crew multiplayer.** One ship, several players, different jobs. Solo play works too (you're a
   crew of one), but the design leans co-op.
4. **A campaign is an evening, not a lifestyle.** The game is run-based: start broke and mortgaged,
   play a few hours, retire (or lose the ship). Crew multiplayer only works if the commitment is
   board-game-night sized, not MMO-sized. Persistent things live at the account level: scores,
   unlocks, run history — never a world you're behind on.
5. **Every seat is a real game.** A crew role only exists if its moment-to-moment activity would
   be fun as a standalone minigame. No filler jobs. (See "The seat test" below.)
6. **Motherships and small craft.** Shuttles, snub fighters, and tenders dock inside or alongside
   larger ships. Detaching a snub while the mothership burns for a planet is a headline moment.

## What we keep, drop, and add vs. Classic

| | |
|---|---|
| **Keep** | 2D top-down system view; planets-on-rails orbital mechanics; flip-and-burn Newtonian flight; station docking; commodity trading and dynamic economy |
| **Drop** | The shared persistent universe (replaced by per-run generated worlds + persistent accounts/scores); the ~23-minute repeating universe cycle (`cycle.length.ticks`) and the script-recording/replay AI it existed to serve; the Python/Flask balancer; the website; MySQL |
| **Add** | Run structure (mortgaged start → debt escape → retirement scoring); seed-deterministic world generation; data-driven content (worlds, ship classes, modules, stations — config files, not code); ship interiors (FTL-style deck view) with walkable crew characters; shared-ship crew multiplayer; walkable station concourses with faction brokers; cargo-handling as a physical, timed process; module-slot ship loadouts; run events and broker-contract quests; robot respawn / last-human death rules; detachable small craft (shuttles/snubs/tenders); real autopilot-driven NPC ships; Postgres for accounts/meta/resumable runs |
| **Defer** | Passenger transport (likely the *first* new career — see Careers); combat & piracy (design toward them, don't build yet); boarding (principle settled — missiles destroy, boarders capture — build later); LLM-driven characters/missions |

Dropping the time-loop is a big simplification: Classic needed deterministic, cycle-aligned
simulation so recorded AI scripts stayed valid. Without it, the sim no longer needs to be
deterministic or periodic. Dropping the persistent universe is a bigger one: the world no longer
has to survive restarts, balance across months of play, or absorb new content forever — each run
generates a fresh world, plays out, and is archived as a score.

## The run

The structural spine of the game. Sid Meier's Pirates! — already this design's lodestar for
careers — is secretly a roguelike: you play a career, you retire, you get scored. We steal that
ending.

- **Runs happen in universes, and universes come in two modes.** A *universe* is a generated
  world instance; a *run* is one crew's campaign inside it. In **solo-universe** mode the
  universe is private — your crew plus NPCs — and is discarded when your run ends. In
  **shared-universe** mode several crews inhabit the same universe, each starting and ending
  their runs on their own schedules: you see their burns across the system, compete with them
  for margins, and the universe lives as long as crews are active in it. Same sim either way —
  other crews and NPC traders are both just traffic.
- **You're a citizen, not the chosen one.** Nothing in the universe is about you. Contracts and
  (eventual) missions are open faction business that any crew could take, never a narrative arc
  that crowns your ship special. This isn't just tone — it's what makes shared universes work
  (every crew gets the same world, no one is its protagonist) and it's why the goal is "get rich
  somehow," not "kill the rebel flagship."
- **Shape of a run:** desperate → solvent → greedy. The crew starts with a ship they don't own —
  the bank does. Loan interest ticks, docking fees recur, fuel costs money. Paying off the ship is
  the floor goal every new player understands instantly; everything earned after that is score.
- **Debt is the rails.** The pressure that keeps an open world moving without a main quest. It's
  FTL's rebel fleet translated into economics: universal, career-agnostic (works identically for
  trading, passengers, or piracy), and it defines failure in a game where ships rarely explode —
  miss your payments and the bank repossesses the ship. Run over. Foreclosure is deliberately
  **crisp**: the bank calls the loan when the position is *unrecoverable*, not when the wallet
  hits zero — a doomed run should end in minutes, not limp for an hour — and there's always one
  desperation lever left (lightering work, a distress contract) so the final choice is a real
  one.
- **Ending a run:** retire whenever the crew chooses (once solvent, realistically). Retirement
  banks the crew's net worth as the run's score. Or the bank forecloses, or the last living
  human aboard dies (see Death and robots, under Multiplayer), or — later, when combat exists —
  the ship is lost. Either way the run ends; a solo universe is discarded with it, a shared
  universe keeps going for the crews still flying.
- **The world is generated per universe, deterministically from a seed:** system layout, station
  placement, commodity seeds, faction control map. Generation is a pure function of
  (parameters, seed) — the same inputs produce the identical initial universe, every time. The
  *sim* is free to diverge after t=0 (we dropped replay determinism with the time loop), but the
  starting state is exactly reproducible, which buys challenge seeds ("everyone race this
  Friday's universe"), per-seed score comparison, and regression-testable worldgen. This is
  where roguelike variety comes from — no two seeds have the same map or the same profitable
  routes.
- **Length target:** 2–4 hours. Solo-universe runs are **resumable** — the server snapshots the
  world so a crew can stop mid-run and pick it up next game night; a few hours *of play*, not
  necessarily one sitting. **Shared universes don't pause** — you can't stop a clock other crews
  live in — so shared runs are single-sitting: size your ambitions to the evening, and remember
  retirement is always one docking away. (An involuntary disconnect isn't death: the autopilot
  holds at anchorage until you're back, but the universe — and the debt clock — keeps moving.)
- **Meta-progression:** account-level and deliberately light — scoreboards, run history, and
  unlocks that add *variety*, not power (new starting hulls, starting scenarios, harder loan
  terms for bragging rights, and eventually a **Senti start** — play an AI captain under
  paper-captain rules, see the signatory rule under Multiplayer & crew design; strictly harder,
  textbook variety-not-power). Nothing should make run #50 mechanically stronger than run #1;
  roguelike replayability dies when the meta becomes a grind gate.
- **Crew and runs:** a run is created by a host crew (lobby flow); friends drop in mid-run as
  crew aboard the ship and drop out without ending anything. Solo runs are the same systems with
  a crew of one.

## Time and transit

Everything in a universe runs on one real-time clock, and **there is no time compression, ever**
— you can't fast-forward a world other crews are living in, and shared universes make that
permanent. Transit duration is therefore a *designed quantity*, not something a player skips:

- **The map is one big system, Firefly-style.** Like the Firefly 'verse — and exactly like
  Classic DH — the map is a *multi-star* system: subsidiary stars orbit the primary, and worlds
  orbit the stars. It's one continuous gravitational neighborhood; no interstellar hops, no
  jump drives. Classic already proved the numbers: every transit was **under five minutes** of
  wall-clock time. That's the baseline to keep — system scale, orbital spacing, and ship
  accelerations are tuned to preserve it, and it's what makes a 2–4 hour run hold a satisfying
  number of hops.
- **Underway life is an honest design debt.** The pilot has the proven game; between M2 and M6,
  everyone else is riding along. Some of that is genuinely fine — the interior as a social
  space carries real weight in co-op (Sea of Thieves runs largely on it), and a few-minute leg
  fills itself with trade planning at the cargo console, shuttle prep, and intercom chatter.
  But the debt comes due at M6: events and contracts should create *mid-transit decisions*
  (reroute for the rush delivery? abort the leg the embargo just closed?), and the deferred
  seats — gunner above all — land in transit time too. If a second crew member has nothing to
  do underway at M6, that's a failed milestone, not a shrug.

## Careers, not just trading

Trading is where Classic *started*, not where this game ends. The lodestar is **Sid Meier's
Pirates!**: one shared world, several careers, switch between them at will — within a run.
Trading stays as the first career because it exercises every core system (flight, docking,
economy, cargo), but it's scaffolding, not the point. Careers are how crews answer "how do we get
rich *this* run?"

- **Passenger transport** — the go-fast career, and the likely second one. Earnings scale with
  speed, so the gameplay is aggressive trajectories: harder burns, tighter flip points, riskier
  fuel margins. It rewards piloting skill directly in a way peddler-trading doesn't, and it needs
  almost nothing new mechanically (cabins as interior tiles, a fare/deadline system).
- **Piracy & combat** — wanted, and genuinely unsolved under these physics rules. What we know:
  there's no stealth (burns are visible system-wide), so ambush is social/economic, not sensory —
  pirates loiter where trade routes converge and interception is a *delta-v contest*: can you
  match velocity with the victim before they reach protection, with fuel left to escape?
  Engagements are therefore either split-second high-relative-velocity passes or
  matched-velocity standoffs, and the Pirates!/age-of-sail model suggests the payoff is
  submission and cargo, not destruction: force the victim to cut thrust, board or demand tribute.
  Fuel and delta-v become the strategic currency of both sides. One principle *is* settled:
  **missiles destroy, boarders capture.** You can kill a ship or a station from the gunner's
  seat, but if you want it — hull, cargo, or the station itself — somebody has to board it. And
  boarding falls out of the piloted-missile system almost for free: a boarding pod is the same
  fly-it-in minigame, except you latch and breach instead of detonate, and then you're a
  character in someone else's corridors. Boarding stays deferred as a *build* item, but it
  shapes deck plans, small-craft berths, and the autopilot API now. The rest needs real design
  work before it needs code.

## Stations, factions, and cargo

Docking at a station isn't a menu — you walk out of your ship. The airlock connects to a station
**concourse**: a small tile interior built from the same tech as ship interiors. Business happens
on foot: brokers, refueling, hiring, rumors. This is also where all the lore lives — delivered
through small touches (signage, cargo stacks, an NPC's idle line, whose flag hangs in the
concourse), never through codex dumps.

**Factions.** If this universe has factions, stations are where you meet them:

- Each station is **controlled by one faction**, usually with smaller presences of others — the
  concourse shows it (whose security walks the deck, whose brokers get the good real estate).
- A concourse hosts **several brokers**, each faction-affiliated. You choose whom to deal with,
  and dealing builds a relationship with that group over the run: better prices, contract offers,
  access to faction-controlled stations or restricted goods.
- Faction reputation is **per-run** (fresh world, fresh relationships), generated alongside the
  control map. Which factions dominate which routes is part of what makes each run's economy
  different.

**Cargo handling.** How cargo physically gets aboard splits by ship scale, and the split is an
economic niche, not just flavor:

- **Container ships never open their holds.** At major stations, external cranes swap
  containers — fast per-ton, but it requires crane infrastructure. Big hulls are locked to the
  major terminals on thick routes.
- **Break-bulk ships get robot stevedores.** A fleet of station robots trundles through the
  airlock and loads the hold from inside — slower, but it works at any dusty outpost. A
  Firefly-class tramp freighter can serve markets the big ships physically can't.
- **Transfer takes time**, scaled by method and tonnage, and that time is a pacing beat: the
  robots need twenty minutes, so you stretch your legs on the concourse. Loading time is why
  station-walking happens; station-walking is what makes loading time pleasant instead of a
  progress bar.
- **Berths are finite, but nobody waits in line.** A station's data declares a limited number
  of crane berths and break-bulk locks, plus effectively unlimited *anchorage* standing off the
  station. When the berths are busy, queueing is never the only option: hold at anchorage and
  pay for **lightering** — tender robots work your ship where it sits, at a slower rate; send
  the crew in by shuttle while the freighter waits its turn, so the queue advances while you're
  at the broker; or divert to a less congested port. Congestion is an economic signal, not dead
  time — a backed-up terminal moves prices and spawns rush contracts, and it's visible from
  across the system as traffic stacking up at anchorage, so you can see the line before you
  burn for it.

## Events & quests

The economy alone will converge — good crews will find the best route and grind it. Two layers
keep a run a *story* instead of a spreadsheet, both bound by the citizen rule (open faction
business, never a chosen-one arc):

- **Events** are universe-level happenings that reprice the map mid-run: a reactor accident
  spikes medicine prices at one station, a faction embargo closes the best route, a dock strike
  halts crane service so only break-bulk ships can trade at the main terminal for a week.
  Everyone in the universe feels the same event — in shared universes they're the common
  experience crews compare notes on. Events ride on the systems that already exist (economy,
  factions, cargo handling); they're content, not new machinery.
- **Quests are contracts:** broker-offered faction business — haul this by then, carry this
  passenger, escort this convoy, salvage that wreck. They're generated from the run's economic
  and faction state (an event often *becomes* a contract: the shortage becomes a rush delivery),
  offered to whoever's standing in the concourse, and first-come in shared universes. Better
  faction standing gets you better contracts — this is what the broker relationship pays off
  into.

## Architecture

```
┌──────────────┐   WebSocket (binary or JSON)   ┌──────────────────┐      ┌──────────┐
│ Godot 4.x    │ ◄────────────────────────────► │  Game server     │ ───► │ Postgres │
│ client       │      inputs / snapshots        │  (authoritative) │      │          │
└──────────────┘                                └──────────────────┘      └──────────┘
```

Two components plus a database. No balancer, no website. Single game server process hosting many
concurrent universes; each universe is an isolated world (with one crew or several), which makes
the process-per-universe isolation below even more natural than it was for star systems.

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

**Why the BEAM at all:** this game is *shaped like* Erlang. One lightweight process per universe,
per ship, per player connection; universes and ships are naturally isolated state machines that
talk by message; a crashed universe process restarts (from its snapshot) without taking down the
server or anyone else's world. That's not resume-driven language tourism — it's the concurrency model the
design actually wants. (This is the "actually valuable, not Haskell for lolz" bar.)

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

> **Gate result (2026-07-12): PASSED — Gleam confirmed.** Steady-state tick p99 ≈ 1.1 ms
> against the 5 ms budget with 500 ships and 20 clients at a rock-solid 15 snapshots/s.
> Details in [docs/M0-RESULTS.md](docs/M0-RESULTS.md).

### Database: PostgreSQL

Much smaller than Classic's persistence story: the live sim runs in memory, and the *world* no
longer outlives its run. Postgres stores:

- `accounts` — identity, auth (mechanism TBD; Classic's balancer-mediated login is gone)
- `meta` — per-account scores, run history, unlocks
- `universes` — resumable world state: the generation seed plus a periodic snapshot of everything
  that diverged from generation (prices, station stocks, NPC traffic). Written behind on an
  interval; discarded when its last run ends.
- `runs` — per-crew state within a universe: ship state and deck contents, cargo, wallet, debt
  clock, faction reputation. Archived to a score row at run end.
- World authoring is **data, not code.** The generator's output is a *world-state document*
  (TOML/JSON — the spiritual successor of Classic's `world/*.properties`, which was a good
  format), and a universe is always instantiated from such a document. Hand-authoring a
  universe means writing that document yourself — or a partial one the generator completes —
  never writing code. Generator params, hand-authored worlds, and test fixtures are all the
  same schema. Ship *classes* remain static config files in the same spirit.

### Protocol

- WebSocket, server-authoritative. Client sends **intents** (helm inputs, "walk to tile", "sit at
  console", "buy 10 units"); server sends **snapshots and events**.
- Start with JSON for debuggability; the envelope is versioned so hot paths (ship state snapshots)
  can move to a packed binary format when profiling says so.
- Interest management from day one, but coarse — and universes make it even coarser: you receive
  full-detail updates for (a) the ship you're aboard, including interior, (b) the concourse
  you're standing in, and (c) exterior states of objects in your universe's star system —
  including other crews' ships in shared mode. Nobody receives anything from other universes,
  and nobody receives other ships' interiors unless aboard.
- Tick model: 60 Hz simulation, ~15 Hz network snapshots with client-side interpolation, ship
  physics state (pos/vel/accel) sent so the client can extrapolate smoothly between snapshots.
  No determinism requirement — the replay-AI constraint died with the time loop.

## Simulation model: two nested scales

The core technical idea of the rewrite. Every ship simulates at two scales:

**Exterior scale (system frame).** The Classic sim: ship is a point mass with position, velocity,
orientation, thrust. Planets and stations are on rails (analytic orbits, computable for any *t* —
keep this from Classic, it's cheap and lag-proof). Gravity, burns, docking.

**Interior scale (ship-local frame).** An FTL-style deck plan: a grid of largeish tiles grouped
into rooms (helm, engine room, cargo hold, airlock, hangar) — a room is a handful of tiles, and
a module occupies a tile footprint within one (see "Content is data") — with consoles/chairs as
interactable objects.
Crew characters have positions *in ship-local coordinates* and simple walk movement. The interior
does **not** feel the ship's acceleration — artificial gravity handwave, exactly like FTL. This is
the crucial simplification: interior sim is completely decoupled from exterior physics; the ship's
frame is just a container that happens to be moving. Station concourses are the same interior
tech with a frame that happens to be a station.

The link between the scales is **consoles**: sitting at the helm console binds your inputs to the
ship's exterior controls (and your camera to the system view); the engineering console will bind
to power/repair systems (later); a turret seat binds to a weapon (much later). Getting out of your
chair unbinds you and returns you to your walking body. "Zoom" in the UI is really a view/control
mode switch, presented as a smooth camera zoom.

Ship classes gain an interior definition alongside the Classic-style stats: deck layout (tile
grid, rooms, door graph), console placements, docking ports, and hangar berths for small craft.

## Multiplayer & crew design

- **Ships have crews, not owners at the helm.** A ship has an owner (economic — in practice, the
  run's crew jointly, since the bank owns it first) and any number of aboard characters. Any crew
  member can use any console (keep the permission model dead simple: everyone-aboard-is-trusted).
- **Roles are emergent from consoles**, not from a class system. The pilot is whoever's in the
  pilot seat.
- **The seat test:** a crew role ships only if its moment-to-moment loop would be fun as a
  standalone minigame. This is the hard constraint on crew design, applied ruthlessly:
  - *Pilot* — passes; it's Classic's entire (proven) game.
  - *Gunner via piloted missiles* — passes, because it **is** the piloting minigame with a new
    win condition: you fly the missile into the enemy ship until you blow up, then you get
    another one. Point-defense turrets shooting down incoming piloted missiles then makes
    gunner-vs-gunner a dogfight, not a DPS check.
  - *Engineer as usually implemented* (route power, mop up fires, whack-a-mole repairs) —
    **fails**; it's a diner-dash minigame wearing a jumpsuit. We don't ship it just because FTL
    has one. If engineering ever exists, it must have a genuinely interesting core loop we
    haven't designed yet — until then, ships simply don't need an engineer.
  - *Quartermaster/cargo* — the broker-and-loading side of the game, done on foot at stations;
    fine, because it doesn't pretend to be a combat seat.

  Corollaries: ships must run fine with empty seats (crew size is capacity, not requirement),
  and new roles get added rarely and deliberately rather than to fill an org chart.
- **Solo play** is the same systems with a crew of one — you park the helm (autopilot holds
  course / keeps orbit) to walk to the cargo hold or the concourse. Autopilot is therefore a
  launch feature, not a luxury (and it's shared code with NPC piloting, below).
- **Joining a run:** the host crew creates the run (lobby flow, choosing solo- or
  shared-universe); friends join as characters aboard the ship, mid-run drop-in/drop-out
  included. No "new ship per player" — a *run* has one crew and (to start) one mothership plus
  its small craft; in a shared universe, other ships belong to other crews' runs.
- **Death and robots.** Personal permadeath with team continuation: if you die while the run
  survives, you respawn as a **robot** crew member — as capable as a human, walking the same
  corridors, sitting the same seats — and the ship's wallet is billed for the purchase. Death,
  like everything else in this game, is an economic wound. Respawn is player continuity, not
  resurrection: the character is dead; the player continues in a purchased chassis. (This also
  keeps Senti death consistent with the no-cloning rule — minds port but never copy, so no
  backups; see docs/lore.md, Technology.)
- **The signatory rule.** The bank's charter requires a living **natural-born human** signatory
  aboard — the in-world reason humans crew ships at all, and deliberately a piece of prejudice
  with a legal veneer: Senti (AI with legal personhood — docs/lore.md) can fly the ship but
  can't hold the note, and crew robots are non-sentient appliances. The run continues while at
  least one natural-born human is alive aboard, **player or NPC**:
  - All-human and mixed crews: unchanged — when the last human dies, the run is over, and a
    solo captain dies like a roguelike character should.
  - **The paper captain.** A Senti start (a variety unlock, not the default — see
    Meta-progression under The run) ships with a hired NPC signatory aboard: a salaried human
    whose entire job is to legally exist. They sit in a bunk, draw a wage from the ship's
    wallet, and are irreplaceable legal infrastructure — the robot rule inverted (humans keep
    robots as replaceable labor; Senti keep a human as an irreplaceable signature). Protect
    your useless human.
  - **Grace window.** A signatory-less ship isn't unrecoverable — humans are hireable at any
    concourse — so per the desperation-lever principle the bank grants a short window to get a
    new warm body under contract before foreclosure. "Our legal person died; burn for the
    nearest port and hire literally anyone" is a designed crisis, and per the Panic theme
    (docs/themes.md) it rewards route math, not reflexes.
- Chat: per-ship (intercom) and per-concourse/local, plus a lobby channel. Classic's Discord
  bridge was nice; port the idea eventually.

## Small craft and docking

Docking is one relationship with several flavors:

- **Ship ↔ station** (Classic behavior): dock at a port; then walk out and do business.
- **Small craft ↔ mothership:** a shuttle or snub fighter occupies a *berth* (hangar tile region
  or external clamp) on the mother ship. While berthed, the small craft is not simulated at
  exterior scale — it's an interior object you can walk up to and board through.
- **Launch/recover:** boarding a berthed craft and launching detaches it into the system frame,
  seeded with the mothership's position/velocity. Recovery is a docking maneuver against the
  (possibly accelerating) mothership — this is deliberately a *skill moment*, with an autopilot
  assist option.

A berthed craft keeps its identity (it's a ship record in the run state with
`docked_to = mothership`), so small craft keep their fuel state, damage, and cargo across launch
cycles. The model doesn't care how many berths a deck plan declares, but the *design* targets
run scale: a crew of two to five flying one mothership and one to three small craft. Fleet
carriers were persistent-world thinking — if they ever return, the model already supports them,
but nothing is designed around them.

## Ship customization

The hull is the fixed part; what's inside is the loadout.

- A ship *class* defines the hull: envelope shape, mass, engine block, airlocks, docking ports,
  and hangar berth locations — the structural stuff that's fixed.
- Everything inside the envelope is **modules on tiles**: consoles, cargo racks, fuel tanks,
  passenger cabins, crew bunks, (later) weapons and point-defense stations. Careers become
  loadout choices: strip cargo racks for cabins and you're a fast packet ship; trade a rack for
  a second berth and you're a small-craft mothership. This is how one hull supports multiple
  careers without new classes.
- **Module slots, not a layout editor** (decided). The class deck plan fixes the geometry;
  players choose, configure, and upgrade what occupies each slot (rack ↔ cabin ↔ berth;
  mk1 → mk2). The original free-form refit editor was justified as the economy's money sink,
  but debt service is the sink now, and a few-hour run never wants a tile editor — so we skip
  per-instance layout persistence, server-side reachability validation, and the editor UI
  entirely.
- Two constraints make slots satisfying instead of a menu:
  - **Breadth:** enough module types, tiers, and per-module configuration options that a
    loadout is a creative act — picking a build should say something about your plan for the
    run.
  - **Taste over solvedness:** no one or two configurations may be clearly best. Tradeoffs get
    tuned so many builds are defensible; if the community solves the loadout, the module
    catalog has failed and needs rebalancing, not more slots.

  Start-of-run loadout choice covers the early game; swapping modules at station refit arrives
  with M7+ depth.

Modules, hulls, and the matching between them are all declarative config — see "Content is
data, not code" below.

## Content is data, not code

The world-authoring rule (see Database) generalizes into a project-wide principle: **ship
classes, modules, stations, commodities, factions — as much of everything as possible is
declarative config files**, and adding content never means touching the sim. The engine
implements module and object *types*; content multiplies within those types via data. New code
is only written for genuinely new *behavior*. Variety should also *compose*: prefer many
simple, orthogonal axes of difference (hulls, modules, races, factions, commodities) over a
few deep ones — combinatorial explosion between simple axes is where emergent depth comes
from, and simple axes are far easier to keep balanced (FTL's base game is the model here;
its expansion is the cautionary tale).

The core pattern is **provides/requires matching**:

- A **hull** (ship class file) *provides*: envelope, mass, engine stats, the deck plan (tile
  grid, rooms, door graph), a **power budget**, hardpoints by size, hangar berths.
- A **module** (module file) *requires*: a footprint ("a 2×1 room"), placement constraints
  ("door on the short wall"), power ("3 units"), and declares its type plus that type's
  parameters (a `cargo_rack` with capacity, a `cabin` with berth count, a `console` with bound
  system, a `gun` of size S/M/L that mounts to a matching hardpoint). Placement is
  orientation-free: modules rotate and mirror freely, and constraints are written in
  orientation-independent terms ("a door on *a* short wall", never "the north wall"), so one
  module definition fits any room that satisfies it in any flip.
- **Loadout validation is constraint matching** against these declared specs — does it fit,
  does the power add up, is the hardpoint big enough. That's cheap, data-driven, and
  server-side, and it is *not* the geometry/reachability analysis we cut along with the layout
  editor: the deck plan's walkability is the hull author's problem, fixed at class-design time.
- **Power is the cross-cutting currency.** Every interesting module draws from one budget, so
  loadouts are tradeoffs by construction — a big gun costs you a cargo rack's worth of power —
  which is half the battle for "taste over solvedness."
- **Stations** get the same treatment: type, faction owner, services (crane terminal or not —
  this is *the* flag that creates the container/break-bulk niche split), berth counts, concourse
  layout, broker slots, commodity profile. Exteriors are *assembled* from a parts vocabulary
  driven by that same data plus the universe seed — crane gantries because it declares crane
  berths, habitat rings scaled to population, the controlling faction's colors — so two crane
  terminals share a silhouette language but never a sprite. Variety is generated from what the
  station *is*, not hand-drawn per station.

Payoffs beyond discipline: a modding surface for free, trivial test fixtures (a fake hull is a
TOML file), and content authoring that agents can do end-to-end — writing a new module or
station type is editing data and screenshotting the result, not a code review.

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
   within each run, and NPC traders actually move the run's prices, so the market the players
   are exploiting is being exploited by others too.
3. **LLM layer (deferred, optional):** flavor and characters — named NPC captains, hailing
   dialogue, generated missions. Explicitly *not* in the piloting loop (wrong latency, wrong
   cost); it rides on top of the behavior layer if/when we want it. Bound by the citizen rule:
   it generates faction business and local color, never chosen-one arcs.

## Hosting & distribution (TBD, deliberately)

- Server: any box that runs the BEAM and Postgres; a single small VPS hosts many concurrent runs
  at Classic's scale.
- Client: undecided between downloadable desktop builds (itch.io is the low-friction option) and
  web export. The WebSocket-only, no-web-hostile-features rule above keeps both open. Decide
  around Milestone 2 when there's something worth putting in front of people.
- No balancer: one server, clients connect directly (config/DNS). Runs-as-lobbies means
  player-hosted servers are conceivable someday, but not a design input now.

## Testing & agent-driven development

Classic shipped with essentially no tests. The rewrite treats testability — including *by Claude*
— as an architectural requirement, not an afterthought.

**Server (the easy 80%).** Because the client is thin and the server owns all state, most of the
game is testable without pixels:

- Unit/property tests from day one (`gleeunit` in Gleam, or Kotest if we fall back to Kotlin).
  Prime targets: orbit math, the intercept solver (does it converge from randomized starts?),
  economy pricing, world generation (same seed twice → identical world-state document; does
  every seed produce a solvable run — reachable stations, at least one profitable route at
  start?).
- **Protocol-level integration tests as the workhorse:** the server speaks WebSocket + JSON, so a
  test client is just a script. Spin up the server against a scratch Postgres, connect N fake
  clients, send intents, assert on the snapshots that come back. "Two players aboard one ship,
  one flies while one walks" is expressible as a test long before it's demoable — and so,
  eventually, is "a scripted bot crew completes a tiny run and retires." This harness doubles as
  the load-test rig (it *is* the M0 benchmark) and as a way for Claude to play the game headlessly.

**Client (Godot).** Testing in Godot is real but different:

- **gdUnit4** (or GUT) for GDScript unit tests — protocol encoding/decoding, interpolation math,
  UI view-model logic. Runs headless via `godot --headless` in CI.
- Keep client logic thin *because* the server side is the testable side; anything that can live
  behind the protocol should.

**Letting Claude see and drive the UI.** Built in from day one, debug builds only: an
**automation hook** in the client — a local control socket (or CLI-flag-driven script runner)
that can (a) inject input events through Godot's `Input.parse_input_event`, (b) dump the scene
tree and relevant game state as text, and (c) capture screenshots to disk on demand. An agent can
then drive the real client — connect, click, fly — and *see* the result by reading the screenshot
and the state dump. Text-form state dumps matter as much as pixels: most assertions ("the dock
prompt is visible", "camera is in interior mode") are cheaper against the tree than the image.
The combination — headless protocol harness for behavior, automation hook for presentation — is
what makes the game developable by agents rather than merely reviewable.

## Milestones

- **M0 — Spike / decision gate (small):** Gleam tick-loop + WebSocket benchmark (see decision
  gate above); the benchmark client is the seed of the permanent protocol test harness. Godot 4
  walking-skeleton client: connect, see a dot move under server control. *Exit: server language
  locked.* **✅ Done 2026-07-12 — gate passed, Gleam locked ([results](docs/M0-RESULTS.md)).**
- **M1 — Flight core:** one star system loaded from config (a pinned seed); planets on rails;
  flyable ship with Classic feel; two clients see each other fly; station docking; Postgres
  accounts. Protocol test harness and client automation hook land here and are used forever after.
  **✅ Done 2026-07-13 ([results](docs/M1-RESULTS.md)).**
- **M2 — The ship is a place:** interior deck plan for one ship class; walkable character; sit at
  helm ↔ walk around; zoom transition between views; two players aboard the same ship, one
  flying while the other walks. *This is the milestone that proves the new game feel.*
  **✅ Done 2026-07-14 ([results](docs/M2-RESULTS.md)).**
- **M3 — Trade on foot:** station concourse (reusing interior tech); walk off the ship; buy and
  sell at a broker; cargo transfer with handling times (cranes vs. robots); dynamic prices ported
  from Classic. Playable sandbox from here on.
- **M4 — The run:** world generation from a seed; the debt clock (loan, interest, fees);
  retirement and scoring; lobby flow for creating/joining/resuming runs; universe/run-state
  persistence. Solo-universe only at first, but the universe/run split is built in here so
  shared universes are a capacity flag later, not a rewrite. *This is the milestone that proves
  the game as a game* — it's when "get rich before the bank gets you" first exists.
- **M5 — Small craft:** shuttle berthed in a freighter; launch, fly, recover; shuttle the crew
  in to a congested station while the freighter holds at anchorage.
- **M6 — Living system:** autopilot module, NPC traders as ambient traffic, economy reacts to
  NPC + player trades; factions get teeth (brokers, reputation effects, control map visible in
  concourses); first run events and broker contracts; shared-universe mode opens (multiple
  crews, one world).
- **M7+ — Expansion:** passenger transport (first new career), refit/loadout depth, combat &
  piracy, meta-progression content (hulls, scenarios), boarding, LLM characters — reprioritize
  when we get here.

## Open questions

- **Auth:** with the balancer gone, what's the login story? Simplest viable: server-issued
  accounts with username/password over TLS; or lean on itch.io/Steam identity later.
- **Godot minor version:** take latest stable 4.x at project start and pin it.
- ~~**Interior movement:**~~ **Decided in M2: free movement** within walkable tiles
  (server-integrated at a fixed walk speed, circle-vs-tile collision) — less board-gamey, and
  the walkable grid keeps FTL-style layout simplicity without tile-hop movement.
- ~~**How much ship-system depth at M2:**~~ **Decided in M2: consoles first.** Helm console is
  functional; the cargo console exists on the deck but binds nothing until M3. No
  power/repair/fires — per the seat test, that busywork doesn't earn a crew role anyway.
- **The world outside the window (must-do, milestone TBD):** the interior view currently
  renders the deck against a void, but the simulation isn't the constraint — the client already
  knows the ship's exterior position/heading and every rail, so compositing the system view
  under/around the deck plan is a pure rendering feature. Walking the cargo hold while a
  station slides past "outside" is a huge embodiment win and cheap relative to its payoff.
  Open design choice: how much you see — everything nearby ("sensors/radar" handwave, simplest
  and probably right for our tone), windows-only with occlusion Barotrauma-style (narrow FoV;
  reads creepy/tense, which isn't our default register), or a hybrid (full view dimmed, crisp
  through windows — windows become a deck-plan feature hull authors place). Decide when we
  schedule it; deck-plan schema may want a `windows` layer either way.
- **Run tuning:** target length vs. crew size — does the debt clock scale with number of
  players? (Pause rules are settled: solo universes resume freely, shared universes never
  pause.)
- **Meta-progression scope:** how much unlocks matter without becoming a power grind; is a
  leaderboard enough at launch?
- **Module catalog:** what's the actual module list, tier structure, and per-module config
  surface — and how do we tune for "taste over solvedness" (see Ship customization) in practice?
- **Race/lineage mechanics:** races are different-but-balanced, FTL-base-game style — simple,
  legible tradeoffs, never tiers (see docs/lore.md, Population). What are the actual axes
  (walk speed? EVA tolerance? console affinities?), and how do they interact with the seat
  test and Competence-Not-Power?
- **Event & contract vocabulary:** which events exist at M6 (embargo, accident, strike, boom,
  …), how contracts are generated and priced from run state so they're tempting but fair, and
  how event frequency scales with run length.
- **Congestion tuning:** how often berths should actually be contested (per station size and
  universe traffic level), and how lightering rates and fees compare to berth service so
  "wait, lighter, shuttle in, or divert" stays a real decision instead of a solved one.
- **Death tuning:** what kills you before combat exists (decompression? industrial accidents?
  EVA?), robot pricing relative to the debt curve, and whether robot bodies carry any drawback
  beyond the bill. Also signatory tuning for Senti starts: paper-captain salary, and
  grace-window length so losing your signatory is a real crisis rather than a formality or an
  instant loss.
- **Shared-universe scope:** how do crews interact — visible traffic and shared markets only, or
  also direct trade, crew transfer, and (once combat exists) piracy against each other? Does a
  shared universe have a lifespan of its own (a season that eventually winds down), and how are
  crews matched into one (public browser, friends-only, region)?
- **Combat direction when it comes:** the physics sketch under Careers (delta-v contests,
  high-velocity passes vs. matched-velocity standoffs, submission over destruction) plus piloted
  missiles and boarding pods is a start, not a design. Punt the build, but keep deck plans and
  the autopilot API combat-shaped.
- **Art pipeline:** procedural, parts-based vector art — hulls and station exteriors assembled
  from a drawn parts vocabulary by data + seed (the station-exterior plan, extended to ships),
  authored and iterated by agents through the screenshot loop, so nobody hand-pixel-arts every
  hull. Image-generation models slot in for concept exploration and possibly parts/texture
  source material, not final sprites. First spike lives in `tools/artspike/` and passed the
  eyeball test; still open: in-game scale (do hulls read at 32–64 px?), and the parts
  vocabulary should be organized by **manufacturer design languages** — Classic already
  established several manufacturers' looks, which carry over, plus a few new ones. A
  manufacturer is then a parts sub-vocabulary + palette, and "who built your ship" becomes
  visible at a glance.
- **Is there an engineering game worth having?** Open challenge to future-us: find a core loop
  for engineer that passes the seat test, or keep the role cut.
