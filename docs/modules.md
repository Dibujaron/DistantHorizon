# Modules, hulls, and loadouts (M4 design)

How a ship's loadout works: swappable **modules** that change the deck and the hull,
matched to a hull by cheap declarative rules, authored as data. This is the design for
M4 ("Modules for real", DESIGN.md Milestones) and the reference for the module content
that lands after it.

**Status:** M4 iteration 1 has shipped, so the shapes and rules below describe code that
exists rather than code we intend. Where something is still ahead of us — exterior part
layering, the refit *loop*, more hulls — this document says so at that point and "The M4
slice" at the end draws the line.

See also: `docs/deckplan-format.md` (the per-cell ASCII format modules reuse), DESIGN.md
"Ship customization" and "Content is data, not code".

## The problem this design solves

A module is meant to be "a stamp on the deck plan and a part on the hull": installing a
cargo rack *is* racks on the deck; swapping the engine shows on the hull. The hard part
is doing that without falling into either trap:

- **Rigid, artificial interiors.** If modules carry fixed shapes and fixed door
  positions, a refit stops feeling like the hand-authored Mockingbird and starts feeling
  like snapped-together boxes. The Mockingbird's current quarters are bespoke — singles,
  doubles, a larger double, a commons, an engineering space, doors placed where flow
  wants them. That quality is the thing to protect.
- **Per-hull variant explosion.** If a module must *match* a hull's exact corridor and
  hull shape, the store needs one variant of everything per hull. That is the thing to
  avoid.

A generative recipe/DSL (a module carries parameterised "subdivide this room, line that
wall" verbs the engine interprets) was explored and **rejected**. To reproduce the
Mockingbird's real layout it would need so many parameters that the JSON becomes a
worse re-encoding of the ASCII deck plan — the inner-platform effect ("any sufficiently
advanced configuration system ends up a worse clone of the language it's implemented
in"). A DSL rich enough to draw the Mockingbird is a worse Mockingbird.

## The model: modules are authored overlays

**An interior module is a per-(hull, slot) hand-authored overlay grid**, written in the
exact same 3×3-per-cell ASCII format hulls use (`docs/deckplan-format.md`). The rule that
makes it an *overlay* rather than a whole deck:

> **`void` cells leave the hull untouched. Non-void cells overwrite the hull's cell at
> that position.**

So a module is a sparse patch. The engine operation is "for each non-void cell in the
overlay, replace the base cell" — a strictly simpler cousin of what `composite.gleam`
already does when it moors a ship's deck plan onto a station concourse. No DSL, no
interpreter to get right, hand-authored quality every time, and authorable by the same
process (drawing a small map) the project has already proven agents can do.

Because the module is drawn *against a specific hull's coordinate space and slot*, the
shape-matching problem doesn't get solved — it **disappears**. Each hull authors its own
cabins; nothing ever adapts a stamp to a taper. The overlay's doors are drawn to line up
with the hull's corridor because a human drew them that way, so connectivity is
guaranteed at authoring time and **loadout validation never does reachability analysis**.

### Where reuse lives

Reuse does not vanish; it moves down a level, from the module *definition* to the
*sprites and parts*:

- **Shared glyphs / sprites.** A bunk, a medbay console, a reactor fixture are shared
  registry glyphs; every hull's modules draw with the same vocabulary.
- **Shared exterior parts.** The Rijay engine nacelle is one sprite the Mockingbird and
  the Finch both mount.

Layout is per-hull because layout is inherently hull-shaped, and there aren't many hulls.
This is the trade the design deliberately accepts: cheap authoring of a few hulls' worth
of little maps, in exchange for hand-quality interiors and zero variant-matching machinery.

## Slots and mounts

A hull declares two kinds of attach point:

- **Slots** — named *interior regions*. A slot is a hull-authored area of the deck plan
  (see "Slot marking" below) that modules may overlay. Slots are **flexible and
  contested**: multiple module types compete for the same physical region. A module
  document is drawn for exactly **one** `(hull, slot)` pair and names it in its `hull`
  and `slot` fields; a medbay that fits both the Mockingbird's `forward_crew` slot and
  her `stern` slot is two documents, because the two overlays share no pixels anyway.
  Constraint: **at most one module per slot**, and every non-void cell of the overlay
  must land on a hull tile carrying that slot's digit (a cheap bounds check, so a module
  can't scribble on hull structure).
- **Mount points** — named *exterior attach points*, currently `{id, kind, size}`:
  `kind` gates what can hang there (`"engine"`), and `size` is the ordered scale
  `s | m | l`, a mount taking any part of its kind up to its size. Mount **geometry** —
  where the part actually sits on the hull sprite — is deliberately absent: it is only
  needed by the renderer, and it arrives with client-side part layering in iteration 2.
  Until then a mount is a capability point, not a position.

The flexibility of slots is what keeps tradeoffs honest rather than artificial: you can
always fit *a* medbay somewhere by giving something else up, instead of being hard-locked
("you can never have a medbay because you installed a fuel tank"). Capability tradeoffs,
not arbitrary limitations.

### Slot marking

Slot membership rides in the tile's **SW corner** character — a hex digit `0`–`f`
selecting the slot id, mirroring how the **NE corner** already carries the colour digit
(`docs/deckplan-format.md`, "Colour"). A non-hex SW corner means "not in a slot" (fixed
hull structure). Slot regions are therefore exactly as fluid as the hull author draws
them — following the taper, non-rectangular, whatever — with no rectangle lists. The hull
JSON adds a `slots` table mapping each digit to a slot id and a human name.

The authoring rules that fall out of this — how to draw the *perimeter* a slot shares
with fixed hull structure, and why a stamp never overwrites the SW corner — are written
up in `docs/deckplan-format.md`, "Slots", and not repeated here. The short version:
because collision and rendering OR the two facing edges, the hull's side of a perimeter
can only ever *add* restriction, so author it **open** and draw that perimeter's walls
and doors on the module side, where the default module rather than the hull decides how
the slot reads.

That page also records the one place we could not follow our own advice. The Mockingbird
was carved into slots out of an existing map she must keep reproducing tile for tile, and
blanking a corridor's slot-facing wall would change that hull tile's own authored edge —
so she keeps her corridor-side walls, which permanently fixes her `forward_crew` doors at
the two positions the corridor already opens. A known, accepted one-hull cost; hulls
authored from scratch should follow the rules instead.

One further consequence of modules owning their slot outright: **a console inside a slot
belongs to whichever module draws it.** The Mockingbird's bare hull has no consoles at
all — her helm comes from the cockpit module and her cargo console from whichever hold
module is fitted. A cockpit module that forgets its `h` glyph makes the fit unresolvable
outright (`invalid_resolved_plan`: a plan with no helm fails validation), and a hold
module that forgets its `c` leaves the crew with nowhere to work cargo. Every hold module
we ship therefore redraws that console.

## Exterior parts

Exterior parts and interior modules are **two orthogonal axes**, installed independently:

- **Exterior parts** are shared across hulls: the Rijay nacelle the Mockingbird mounts is
  the same document the Finch mounts. A part is
  `{id, name, kind, size, mass, provides, requires, thrust, torque, sprite}`, hung on a
  hull mount point of matching `kind` and sufficient `size`. Engines carry the `thrust`
  and `torque` that used to be global constants in `ship.gleam`.
- Some installables **link one of each** — a gun is an exterior turret part *and* a
  per-hull interior gun-room overlay. Some are exterior-only (an atmospheric landing/fin
  package — no interior change). Some are interior-only (a medbay).

Linked parts don't bind to one specific partner. An exterior gun requires *some* interior
gun-room of sufficient capability to be present — expressed as a tag requirement, not a
hardcoded pairing (see the validator).

Exterior composition is **client-side sprite layering** at the mount points (already
fully data-driven). No server-side re-bake in V1; if the lighting pipeline (per-part
normal/height maps) ever demands a baked composite, the client can bake it — the choice
is isolated to the renderer and can change later without touching the data model. None of
this has shipped yet: a part's `sprite` key is authored and decoded but not yet sent over
the wire, and mounts carry no geometry, so the client still draws the whole-hull bake.
Layering is iteration 2's work, and it is why the "Exterior composition at runtime"
question stays open in DESIGN.md.

## The validator: pooled tag sums

Loadout legality is **one rule**, plus three structural checks. The rule:

> **For every tag, `sum(provides) ≥ sum(requires)` pooled across the whole loadout.**

Tags are open strings the engine only compares and sums, so new content invents new tags
with zero code:

- `power` — the reactor `provides`, every powered module `requires`. Power is the
  cross-cutting currency: a big gun costs a cargo rack's worth of power, so loadouts are
  tradeoffs by construction.
- `gun_control` — a gun-room `provides` (say `2`), each gun `requires` (`1`). This *is*
  the gun→gun-room link: a gun needs the hull's total `gun_control` to cover it, from any
  gun-room, not a specific one.
- `berths`, and any future capability, work identically.

The structural checks are equally cheap: **≤1 module per slot**, **every non-void overlay
cell lands on that slot's digit**, and **the mount's kind and size fit the part**. That is
the entire validator — no geometry, no reachability, no walkability analysis. Walkability
is the hull author's responsibility, fixed at class-design time; the module guarantees its
own insides by construction. The bounds check reads the **authored** hull, never the
previously resolved plan, so every refit is validated against the same fixed structure and
a fit can never drift by being stamped on top of itself.

### Two vocabularies of "no"

`loadout.resolve` fails with a machine-readable reason string that the `refit_result` wire
message forwards verbatim, and those reasons split into two groups that a UI must keep
apart, because **a content error is a bug report, not a refit the player can fix**:

- **Loadout refusals** — the engine legally saying no to an illegal fit, all of them
  reachable by a player asking for the wrong combination: `tag_deficit:<tag>`,
  `out_of_slot_bounds:<module>`, `mount_too_small:<mount>`, `duplicate_slot:<slot>`,
  `duplicate_mount:<mount>`, `slot_not_on_hull:<slot>`, `mount_not_on_hull:<mount>`,
  `unknown_module:<module>`, `unknown_part:<part>`, `module_wrong_hull:<module>`,
  `module_wrong_slot:<module>`, `mount_wrong_kind:<mount>`, `loadout_wrong_hull:<hull>`,
  and `zero_mass` (a fit whose total mass is not positive would divide the flight numbers
  by zero). The refit handler adds two of its own: `not_docked` and
  `hold_over_capacity`.
- **Content errors** — a hull, module or part *document* is wrong: `mount_bad_size:<mount>`
  and `part_bad_size:<part>` (a `size` outside `s|m|l`), `patch_bad_deck:<module>` (a patch
  names a deck the hull lacks), `invalid_hull_plan:<detail>` (the authored hull rows do not
  parse) and `invalid_resolved_plan:<detail>` (the *stamped* rows do not — the usual cause
  being a fit that left the ship with no helm console). The refit handler adds `no_fit` and
  `unknown_hull:<id>`, plus `berth_blocked`, `unknown_berth` and `no_concourse_deck` from
  the composite pre-flight, where a refitted ship that would no longer stitch into her
  station gets refused rather than committed. That pre-flight speaks only for the ships
  docked there at that moment, and a fit is durable, so the same three reasons are answers
  to a **dock** (and to a login) too: a hull refitted at one station can arrive at another
  whose berth line has no room for her.

Keeping them distinct is a deliberate cost: reporting a hull whose mount carries a junk
`size` string as `mount_too_small` would disguise a content bug as a legal refusal, which
is strictly worse than a loud unfamiliar reason. The authoritative lists live on `resolve`
in `server/src/dh_server/loadout.gleam` and in the wire block at the top of
`server/src/dh_server/protocol.gleam`.

## Derived numbers, not authored ones

Gameplay numbers derive from the *resolved* (post-overlay) deck plan wherever the map can
be the single source of truth, the same rule that already governs consoles, the mooring
tile and cargo:

- Hold capacity is `pallet_count` over the baked plan — install a cargo module and its
  `p` (cargo-pallet) tiles set the capacity automatically; strip it and the capacity
  falls. No number to keep in sync. (The hull's authored `cargo.capacity` survives only
  as a fallback for a resolved plan that draws no pallets at all.)
- Fuel capacity and berth count are meant to derive the same way, from a tank glyph and a
  bunk count, when that content and the systems consuming it land. Today they ride as
  `provides` tags (`fuel`, `berths`) on the module document, which is honest about the
  fact that nothing yet reads them off the map.

The server bakes each ship's resolved plan at load and on refit; everything downstream
(`pallet_count`, console derivation, the mooring tile, the walked plan the client renders)
runs on the baked plan unchanged, with no derivation logic of its own — install a cockpit
and the helm console exists because the glyph does.

**Flight performance is derived too, and it is the flagship case.** A fit's acceleration
is the pooled `thrust` of its mounted engines divided by the fit's **total mass**, and its
turn rate is pooled `torque` over the same total. Total mass is the hull's dry `mass` plus
every fitted module and every mounted part — so a heavier hold module genuinely makes her
slower and lazier on the helm, and hull choice, interior fit and engine choice all land in
the same number. A hull that `requires` `{"engine": 1}` cannot resolve without one, so a
zero-thrust fit never reaches the sim.

## Data shapes

These are the shipped shapes; the JSON schemas in `server/schemas/` (`module.schema.json`,
`part.schema.json`, `hull.schema.json`) are checked against every document on disk by
`server/test/data_schema_test.gleam`, and the Gleam decoders they mirror are the source of
truth for both.

An **interior module** (`server/modules/<hull>/<id>.json` — filed per hull, because an
overlay drawn against one hull's coordinate space is not portable to another):

```jsonc
{
  "schema": 1,
  "id": "mockingbird.forward_crew.cabins",
  "hull": "mockingbird",
  "slot": "forward_crew",
  "name": "Forward crew cabins",
  "mass": 6.0,
  "provides": { "berths": 4 },
  "requires": { "power": 1 },
  "patches": [
    { "deck": 0, "x": 6, "y": 5,
      "grid": [ /* 3*h rows of 3*w chars; void centre = passthrough */ ] }
  ]
}
```

A module carries **`patches`**, not one whole-deck grid: each patch is a rectangle of
overlay at a **tile** origin (`x`, `y` are tiles, not characters) on deck `deck`. Sparse
patches rather than a deck-sized sheet because a slot is a small part of a deck and a
module has no business declaring anything about the rest of it. A module with no patches
at all is legal, and is pure capability — mass and tags, no map change.

An **exterior part** (`server/parts/<id>.json` — flat, because parts *are* cross-hull):

```jsonc
{
  "schema": 1,
  "id": "rijay.engine.consol_patch",
  "name": "Consol patch engine",
  "kind": "engine",
  "size": "m",
  "mass": 0.0,
  "provides": { "engine": 1 },
  "requires": { "power": 3 },
  "thrust": 4800.0,
  "torque": 21600.0,
  "sprite": "engine_consol"
}
```

`kind` and `size` are what the mount matches against; `thrust` and `torque` are pooled and
divided by total mass (see "Derived numbers"); `sprite` is the client's key for iteration
2's layering. Every field after `size` is optional and defaults to zero/empty, so a
non-engine part simply omits `thrust` and `torque`.

A **hull** (`server/shipclasses/<id>.json`, schema 3) gains `mass`, `provides`, `requires`,
a `slots` table, `mounts`, and a `default_loadout` of `{modules: {slot: module},
parts: {mount: part}}`. Per-instance ships carry a **loadout** of the same shape, and the
server resolves it into the `ShipClass` the sim, the composite and the wire already speak.
The Mockingbird's current deck is expressed as her **default loadout** — the cabins,
commons and hold we ship today became the default-installed modules, and a test asserts
her default fit reproduces the pre-M4 authored deck tile for tile, so nothing about her
out-of-the-box look changed.

## The catalog

Types the *engine* accepts as data regardless of when the content lands. "When" flags the
milestone the content is expected in; the engine is milestone-agnostic.

| Component | Interior | Exterior | When |
|---|---|---|---|
| Engine (the demonstrator) | engineering bay | nacelle | **M4** |
| Cargo hold (pallet fill) | ✓ | — | **M4** |
| Fuel tank (endurance / range) | ✓ | — | **M4** |
| Crew bunks | ✓ | — | **M4** |
| Passenger capability (cabins + galley, one module) | ✓ | — | **M4** |
| Cockpit / bridge (helm) | ✓ | canopy | **M4** |
| Reactor (the power source) | ✓ | — | M4 / later |
| Atmospheric landing package | — | fins | M4 / later |
| Medbay (fits forward, or smaller in the stern) | ✓ | — | later |
| Drone control + drone/repair bay (engineering-officer loop) | ✓ | — | later |
| Sensors / comms / transponder (role classifier; the "window" sensor handwave) | console | dish | later |
| Nav computer / autopilot | console | — | M7 |
| Guns (S / M / L) | gun room | turret | **M5** |
| Missiles + magazine (missiles are big → a real room) | missile room | launcher | **M5** |
| Point defense (weak-auto when unmanned) | — | PD mount | M5 |
| Small-craft hangar / boarding-pod berth (mothership) | berth | hangar door | M5 |
| Boarding / EVA prep (ready room + airlock) | ✓ | — | M5 |
| Security / brig (hold captured crew for ransom) | ✓ | — | M5-adjacent |

**Deliberately excluded:** shields/armor (the damage model is hull integrity only — AA
guns are your shield, and getting hit is bad), and life-support/recycler modules (the
power/repair busywork the seat test already cut). Passenger capability is a **capacity
number**, never a happiness/comfort knob — no "pack them in until they go insane"
optimization loop.

**Later cargo flavor:** specialized cargo variants — refrigerated, liquid
(containerized), and **live** cargo. Live cargo is the fun one: 2D cattle bumping around a
container hold, Firefly-style. A cargo-variant of the existing hold module when
commodities start to care; not needed for the engine.

## The M4 slice (iteration 1)

M4 is a multi-iteration milestone; the first iteration is the vertical slice that carries
all the hard machinery and the minimum content to prove it. **Iteration 1 has landed**, and
what it landed is the whole engine:

- The deck-plan **slot digit** (SW corner, `docs/deckplan-format.md`), the authored **hull
  document** (`hull.gleam`) with its `slots` table, `mounts`, dry `mass` and capability
  tags, and the **module** and **part** documents and registries.
- The **overlay-stamp engine** and the **pooled-tag validator** (`loadout.gleam`): void =
  passthrough, the SW corner never overwritten, `sum(provides) ≥ sum(requires)` per tag,
  and the three structural checks.
- **Per-ship resolved fits** in the sim — the single shared `ShipClass` in `sim.gleam` is
  gone; every ship carries her own resolved class, baked at load and re-baked on refit.
- **Flight stats from data**: no `main_accel`/`turn_rate` constants remain in
  `ship.gleam`; acceleration and turn rate are pooled engine thrust and torque over the
  fit's total mass.
- The **Mockingbird carved into five slots** — cockpit, forward crew, commons, aft crew,
  hold — with seven modules and two engines, her default loadout reproducing her pre-M4
  authored deck tile for tile, at the same capacity and the same flight numbers.
- The **refit verb** (`refit` / `refit_result` / `ship_fit`), whole-loadout so it is
  idempotent, with a composite pre-flight so a refused refit leaves the ship untouched and
  names a machine-readable reason.
- **Harness and schema coverage**: JSON schemas for hull, module and part documents
  validated against everything on disk, plus refit coverage in the Python harness.

**Iteration 2** is the Sparrow and Finch hulls — the anti-overfit test, since every rule
above was written while looking at one hull — and **client-side exterior part layering**:
mount geometry, the part `sprite` on the wire, and a swapped nacelle that actually shows.

**Iteration 3** is the refit *loop* as a game system rather than a verb: shipyard stations,
a refit console you walk to, per-station catalogs of what is actually for sale, and
charging the wallet. The verb that shipped is deliberately smaller than that — **docked
only and free**, refittable by any crew member of a moored ship — because the engine was
the risk and the economy around it is not.

Deferred beyond those (additive data or separable features): the rest of the catalog above,
the fin package, the transponder **role classifier**, and specialized cargo. None of it
touches the core engine.

## What this settles in DESIGN.md

- **"How much interior can a module rewrite?"** — **answered, and DESIGN.md now carries the
  answer rather than the question.** A module rewrites only its slot, marked by the SW
  digit, via the authored overlay (`void` = passthrough); the hull owns all structure
  outside slots and every corridor, so connectivity is guaranteed by authoring and never
  analysed. Modules *may* add walls and doors **within their slot** (that is how passenger
  staterooms get carved out of an open bay) but never move the hull's existing structure.
- **"Exterior composition at runtime"** — **still open, deliberately.** The V1 direction is
  client-side sprite layering at mount points, with a server/offline bake still available
  if the lighting pipeline demands one; none of it is built yet, so nothing is proven and
  the question stays in DESIGN.md until iteration 2 closes it.

DESIGN.md's "Ship customization" section, written before this was hashed out, described a
shape-agnostic "modules rotate and fit any room" model that this supersedes: interior fit
is **authored per hull**, and the surviving cross-hull matching is the pooled tag budget
(power the flagship case). That section has been rewritten to match.
