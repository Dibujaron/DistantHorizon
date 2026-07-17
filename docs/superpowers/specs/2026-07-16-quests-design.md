# Quest System Design — JSON Templates, Schema, and Stock Quests

**Date:** 2026-07-16
**Status:** Approved (brainstorming session with dibujaron)
**Scope:** Quest definition format and content only. No Gleam runtime/loader — the deliverable
is a JSON Schema, a set of stock quests, and a Gleam test that validates the quests against
the schema. The quest *engine* (resolver, monitors, offer flow) is a later milestone; this
spec is its contract.

## Context

DESIGN.md commits to "quests are contracts": broker-offered faction business, generated from
run state, first-come in shared universes, bound by the citizen rule (open faction business,
never a chosen-one arc). The world regenerates per seed (lore.md: recurring cast, procedural
stage), so quests cannot reference map entities by fixed id — with the deliberate exception of
canonical *anchors* (lore.md's "anchor institutions"), which occur in some seeds and can be
referenced directly.

## Decisions

1. **Quests are heavily templatized.** A quest file declares named **slots** (station, broker,
   faction, commodity, npc) with constraints; the resolver binds them against the generated
   world at world-gen or trigger time. If a slot can't bind, the quest doesn't exist this run.
2. **Constraint language is a JSON AST, mongo-query style** — not a JQL-like string DSL.
   Object keys are implicit AND; `any` / `all` / `not` give explicit logic. Rationale: parses
   with the server's existing decoder-into-named-types pattern, fails structurally with a
   path at decode time, stays machine-manipulable. A string DSL frontend could compile to
   this AST later; the AST is the canonical stored form.
3. **Quests are single-shot; chains are triggers.** No internal stages. Completion, failure,
   or expiry can trigger other quests, with bindings carried forward.
4. **Follow-ups are not always open-market.** Triggers carry an offer mode: `first_refusal`
   (offered privately to the completing crew for a window, then falls to `open` or `expire`)
   or `open` (posted at a broker, first-come). Right of first refusal is the broker-relationship
   payoff DESIGN.md already promises; the citizen rule guards against arcs that exist only
   for you, not against relationships paying off.
5. **Three condition slots plus explicit fails** — same constraint vocabulary, different
   evaluation timing (precondition / invariant / postcondition):
   - `eligibility` — snapshot check at offer/accept (rep gates, ship fit).
   - `conduct` — latched invariants while active ("never exceed 1G while X aboard",
     "no flying on the Sabbath while X aboard"). Violations latch; default effect is
     quest-failed, softenable to a reward penalty.
   - `completion` — turn-in check (docked at ${dest}, cargo aboard, hand to ${broker}).
   - `fail_when` — author-listed conditions (named NPC dies, settlement dies). Authors
     should list these generously.
   - **Implicit universal fails** the engine always enforces, never authored: destination no
     longer exists, quest item destroyed or sold, quest passenger dead.
6. **Deadlines are optional.** `deadline_s` counts from acceptance. No deadline = the
   opportunity flavor (rumors, "whenever you're passing Sanctum").
7. **Acquisition modes:** `broker` (default — offered at a faction broker's console),
   `rumor` (ambient, no contract, no penalty for ignoring), `triggered` (only via another
   quest's triggers).
8. **Quest items are defined inline** in the introducing quest, namespaced by quest id, not
   in a global registry. `space: hold` (cargo units) or `space: berth` (passengers — named,
   mortal, otherwise "a special more annoying kind of cargo"). Not sellable on the open
   market. Chained quests reference `parent.item.<id>` via binding inheritance.
9. **Rewards:** `credits`; `rep` deltas (positive and negative, in the same quest) whose
   targets are factions *or* manufacturers (a part unlock or a price discount is modeled as
   a manufacturer/faction rep bump); rare `meta_unlock` (e.g. `senti_start`) — the only
   reward that outlives the run; plus triggers.
10. **JSON Schema is the format's definition.** `server/schemas/quest.schema.json` starts a
    `server/schemas/` folder (worlds/classes schemas to follow eventually, out of scope now).
11. **A Gleam test validates all quest files** against the schema, plus cross-file checks the
    schema can't express. Implementation rides an Erlang JSON Schema validator via FFI
    (`jesse` or `jsv` — verify at planning time and pin the schema draft to what it supports).

## File layout

```
server/
  schemas/
    quest.schema.json      # JSON Schema for quest files
  quests/
    account_closure_1.json # one quest per file; id == filename (sans .json)
    account_closure_2.json
    ...
```

- One quest per file. `id` field MUST equal the filename minus extension (test-enforced).
- Chains share a filename prefix by convention (`freehold_water_run_1`, `_2a`, `_2b`).
- Every quest file carries `"schema": 1` (mirrors the worlds format's version field).

## Quest file shape

Illustrative example (field-complete; predicate vocabulary below):

```json
{
  "schema": 1,
  "id": "freehold_water_run_1",
  "name": "Water for Cradle's End",
  "flavor": "The condensers at Cradle's End are down and the Compact's nearest help is weeks out. Somebody with a hold full of water gets there first, or nobody does.",
  "acquisition": "broker",
  "slots": {
    "patron": { "kind": "faction", "constraints": { "id": "freehold" } },
    "dest": {
      "kind": "station",
      "constraints": {
        "faction_is": "${patron}",
        "imports": "water",
        "settlement_class": "outpost"
      }
    },
    "offer_broker": {
      "kind": "broker",
      "constraints": { "faction_is": "${patron}", "not": { "station_is": "${dest}" } }
    }
  },
  "eligibility": {
    "rep_at_least": { "target": "${patron}", "value": 0 },
    "ship": { "any": [
      { "min_cargo_units": 40 },
      { "min_container_slots": 2 }
    ] }
  },
  "conduct": {},
  "completion": {
    "docked_at": "${dest}",
    "deliver_commodity": { "commodity": "water", "units": 40 }
  },
  "fail_when": {
    "settlement_dead": "${dest}"
  },
  "deadline_s": 1800,
  "items": [],
  "rewards": {
    "credits": 900,
    "rep": [ { "target": "${patron}", "delta": 15 } ]
  },
  "on_complete": [
    { "quest": "freehold_water_run_2a", "offer": { "mode": "open" } }
  ],
  "on_failed": [
    { "quest": "freehold_water_run_2b", "offer": { "mode": "open" } }
  ],
  "on_expired": []
}
```

### Slots and binding

- `slots` maps slot names to `{ kind, constraints }`. Kinds: `station`, `broker`, `faction`,
  `commodity`, `npc`.
- `${slotName}` interpolates a bound slot anywhere a constraint value appears.
- **Anchors:** a slot constraining `{ "id": "cathedral_of_the_wake" }` binds only in seeds
  where that anchor spawned; otherwise the quest doesn't occur this run. This is intended —
  anchor quests are occasional by nature.
- **Binding inheritance (triggered quests only):** a slot may be
  `{ "from": "parent.<slotName>" }` to inherit the parent quest's resolved binding, or
  `parent.item.<itemId>` to reference a parent's quest item (e.g. part 2 moves the same
  artifact onward; the trigger fired from a state where it was aboard — if it's gone by
  accept time, eligibility catches it).

### Constraint language

Mongo-style AST used uniformly in `slots[].constraints`, `eligibility`, `conduct`,
`completion`, and `fail_when`:

- An object is an implicit AND of its keys.
- `any: [ ... ]` — OR of sub-constraints. `all: [ ... ]` — explicit AND (for nesting inside
  `any`). `not: { ... }` — negation.
- Leaf predicates are a flat, schema-enumerated vocabulary. Initial set (grows as content
  demands):
  - Slot/world: `id`, `faction_is`, `station_is`, `imports`, `exports`, `settlement_class`,
    `has_crane`, `anchor_present`
  - Ship: `min_cargo_units`, `min_container_slots`, `can_land_atmo`, `manufacturer_is`
  - Crew/state: `rep_at_least`, `rep_below`, `aboard` (item), `docked_at`,
    `deliver_commodity`, `deliver_item`, `credits_at_least`
  - Conduct/temporal: `max_burn_g`, `no_flight_on_holy_days`, `no_inspection` — each conduct
    predicate takes an optional scope `{ "while_aboard": "<itemId>" }`
  - Fail: `npc_dead`, `settlement_dead`
- The schema validates AST *structure* everywhere and enumerates the predicate names; deep
  per-predicate argument validation beyond structure is the engine's job later.

### Conduct semantics

Conduct constraints are temporal invariants: the engine monitors while the quest is active
and **latches** violations — you can't un-violate by behaving afterward. Default effect of a
latched violation is quest failure; an author can soften it:

```json
"conduct": {
  "max_burn_g": { "value": 1.0, "while_aboard": "vip",
                  "on_violation": { "reward_multiplier": 0.5 } }
}
```

(The VIP arrives rattled and pays half. Quests where breaking conduct is the profitable
choice are encouraged — see themes.md, Moral Ambiguity.)

### Items

```json
"items": [
  { "id": "remains", "name": "Sealed Remains — J. Okafor", "space": "hold", "units": 1 },
  { "id": "vip", "name": "Mx. Adechike Voss", "space": "berth" }
]
```

- Namespaced by quest id (wire id is `<questId>.<itemId>`).
- `space: berth` items are passengers: named, mortal, can die (implicit fail). If `name` is
  omitted the resolver generates one from the seed.
- Injected when the quest is accepted (or as authored); removed when the quest resolves.

### Triggers and offers

```json
"on_complete": [
  { "quest": "find_the_mother",
    "offer": { "mode": "first_refusal", "window_s": 600, "then": "open" } }
]
```

- Trigger lists on `on_complete`, `on_failed`, `on_expired`.
- `offer.mode`: `first_refusal` (private to the completing crew for `window_s`, then `then`:
  `open` or `expire`) or `open` (posted at an appropriate broker, first-come).
- Triggered quests re-run slot resolution with `parent.*` bindings available.

## Validation test (Gleam)

A test in `server/test/` that:

1. Globs `server/quests/*.json`, validates each against `server/schemas/quest.schema.json`
   via an Erlang JSON Schema validator over FFI (`jesse` or `jsv`; pick at planning time,
   pin the schema's `$schema` draft to what the library supports).
2. Cross-file checks the schema can't express:
   - `id` equals filename.
   - Every trigger's `quest` id exists in the folder.
   - `parent.*` references appear only in quests some other quest triggers
     (`acquisition: "triggered"` ⇔ referenced by a trigger; both directions checked).

The stock quests thereby double as the fixture set for the eventual engine.

## Stock quests (the content deliverable)

Six quests, each stressing schema features, all lore-honest, written to be compelling rather
than throwaway:

1. **Account Closure** (`account_closure_1..3`, Company, chain, first-refusal, moral
   staircase): deliver sealed repossession orders to a Company factor — clean money, small
   bad thing. Success triggers first-refusal follow-ups that escalate: haul the repo crew to
   the seizure, then the evicted family's auctioned belongings. Credits rise and Freehold
   rep falls at each step. (themes.md: the salary staircase, built from triggers.)
2. **Keep the Wake** (`keep_the_wake`, Wake, conduct + anchor + undated): carry a dead
   spacer's remains home to the Cathedral of the Wake, whenever you're passing. Conduct:
   no burns on holy days while the remains are aboard. Modest credits, real Wake rep.
3. **Water for Cradle's End** (`freehold_water_run_1, _2a, _2b`, Freehold, chain with
   failure branch): rush water to a settlement dying without it. Success → open follow-up
   hauling machinery as it rebuilds. Failure → the settlement dies; a salvage contract
   posts, and so does a bounty on the crew that failed. (themes.md: Consequences.)
4. **The Void, Abolished** (`void_abolished`, VIP + softened conduct, Aratori niche): haul a
   core-world passenger who must never feel space. Conduct: max 1.0G while aboard, violation
   softened to half fee. Eligibility favors smooth hulls.
5. **Overboard** (`overboard_rumor`, rumor, opportunity): a Guild dockhand three drinks deep
   mentions a container that went over the side of a manifest that never existed. No
   deadline, no contract, no penalty; the cargo is real, and so is the question of whose it
   is. Delivering it to different brokers is the choice.
6. **A Body That Can Die** (`a_body_that_can_die`, Senti + signatory law + meta-unlock):
   transport a Senti — a passenger who is legally cargo — to a port where a sympathetic
   notary will paper a captaincy. Conduct: no station inspections en route. Completing it
   unlocks the Senti start (`meta_unlock: "senti_start"`).

## Out of scope

- The quest engine: slot resolver, conduct monitors, offer/first-refusal flow, rumor
  delivery, rep bookkeeping. This spec is the data contract for that work.
- Events. Events are a separate system (DESIGN.md); when built, an event becoming a contract
  is just another trigger source pointing at these same templates.
- JSON Schemas for `worlds/` and `classes/` (planned for `server/schemas/`, not now).
- Client UI for offers/rumors.

## Amendments (planning, 2026-07-16)

Resolved or refined while writing the implementation plan:

- **Validator: `jesse`** (pure Erlang hex package, dev dependency); schema pinned to
  **draft-06**. `jsv` rejected — Elixir/Mix build would drag the Elixir toolchain into a
  pure Gleam/Erlang project.
- **`deliver_item` and `deliver_commodity` are objects** with an optional `to` naming the
  receiving broker slot (`{"item": "remains", "to": "${congregation}"}`); `to` absent means
  offload/disembark at the current dock (e.g. a passenger disembarking needs no broker).
- **Items gain optional `pickup_at`** (a station slot ref): the item is injected when the
  crew docks there, instead of at acceptance. This is the spec's "or as authored" injection
  point, and is how salvage/retrieval quests work within the single-shot model.
- **`min_passenger_berths`** added to the predicate vocabulary (content demanded it).

## Design principles honored

- **Citizen rule:** every quest is faction business somebody would post or ask of a capable
  crew; first refusal is relationship payoff, not destiny.
- **No quest markers / no handed-down solutions** (themes.md, Self-Sufficiency): contracts
  state problems — the JSON has no waypoint or route fields at all.
- **Typed boundaries:** the AST decodes into named Gleam types with the server's existing
  decoder pattern when the engine lands; no dict-happy plumbing.
- **Taste over solvedness:** anchors make some quests seed-occasional; scarcity is the charm.
