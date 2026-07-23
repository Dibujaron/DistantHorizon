# Modules, hulls, and loadouts (M4 design)

How a ship's loadout works: swappable **modules** that change the deck and the hull,
matched to a hull by cheap declarative rules, authored as data. This is the design for
M4 ("Modules for real", DESIGN.md Milestones) and the reference for the module content
that lands after it.

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
  contested**: multiple module types compete for the same physical region, and a module
  may target several slots. A module lists the `(hull, slot)` pairs it is drawn for and
  carries a separate overlay per pair — e.g. a large medbay drawn for the Mockingbird's
  `forward_crew` slot and a smaller one drawn for its `stern` slot. Constraint:
  **at most one module per slot**, and a module's overlay must stay within its slot's
  region (a cheap bounds check, so a module can't scribble on hull structure).
- **Mount points** — named *exterior points* (`{id, x, y, rot, z, size}`) where an
  exterior part's sprite is posed. Size-tagged (a size-M mount takes a size-M part).

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
JSON adds a `slots` table describing each slot id (its provided tags, human name).

## Exterior parts

Exterior parts and interior modules are **two orthogonal axes**, installed independently:

- **Exterior parts** are shared across hulls. A part is `{id, size, sprite refs, stats,
  provides/requires tags}`, posed at a hull mount point. Engines carry the flight stats
  (thrust, handling) that today live as global constants in `ship.gleam`.
- Some installables **link one of each** — a gun is an exterior turret part *and* a
  per-hull interior gun-room overlay. Some are exterior-only (an atmospheric landing/fin
  package — no interior change). Some are interior-only (a medbay).

Linked parts don't bind to one specific partner. An exterior gun requires *some* interior
gun-room of sufficient capability to be present — expressed as a tag requirement, not a
hardcoded pairing (see the validator).

Exterior composition is **client-side sprite layering** at the mount points (already
fully data-driven). No server-side re-bake in V1; if the lighting pipeline (per-part
normal/height maps) ever demands a baked composite, the client can bake it — the choice
is isolated to the renderer and can change later without touching the data model.

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

The structural checks are equally cheap: **≤1 module per slot**, **overlay within slot
bounds**, and **mount size ≥ part size**. That is the entire validator — no geometry, no
reachability, no walkability analysis. Walkability is the hull author's responsibility,
fixed at class-design time; the module guarantees its own insides by construction.

## Derived numbers, not authored ones

Gameplay numbers derive from the *resolved* (post-overlay) deck plan wherever the map can
be the single source of truth, the same rule that already governs consoles, berths, and
cargo:

- Hold capacity is `pallet_count` over the baked plan — install a cargo module and its
  `p` (cargo-pallet) tiles set the capacity automatically; strip it and the capacity
  falls. No number to keep in sync.
- Fuel capacity derives the same way from a tank glyph.
- Berths derive from a bunk/bed count.

The server bakes each ship's resolved plan at load and on refit; everything downstream
(`pallet_count`, console derivation, the walked plan the client renders) runs on the baked
plan unchanged.

## Data shapes

An **interior module** (`server/modules/<hull>/<id>.json`):

```jsonc
{
  "id": "mockingbird.forward_crew.quarters",
  "hull": "mockingbird",
  "slot": "forward_crew",
  "name": "Crew quarters",
  "provides": { "berths": 4 },
  "requires": { "power": 2 },
  "grid": [ /* overlay in the 3×3-per-cell format; void = passthrough */ ]
}
```

An **exterior part** (`server/parts/<id>.json`):

```jsonc
{
  "id": "rijay.engine.consol_patch",
  "size": "engine_m",
  "sprite": "engine_consol",
  "provides": {},
  "requires": { "power": 0 },
  "flight": { "thrust": 42.0, "handling": 1.1 }
}
```

A **hull** gains a `slots` table and `mounts`, and per-instance ships carry a **loadout**
(a slot→module map plus mounted parts). The Mockingbird's current deck is expressed as its
**default loadout** — the quarters, commons, engineering, and holds we ship today become
the default-installed modules, so nothing about her out-of-the-box look changes.

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

M4 is a multi-PR milestone; the first iteration is the vertical slice that carries all the
hard machinery and the minimum content to hit the Exit test. The engineering breakdown
lives in the implementation plan (`docs/superpowers/plans/`); in scope:

- Hull **registry** (unwind the single shared `ShipClass` in `sim.gleam`) — the Mockingbird
  as the real hull, with real Sparrow and Finch shells (all Rijay; Finch and Mockingbird
  share the engine and cockpit parts).
- Module file format + the **overlay-stamp engine** (`void` = passthrough).
- Deck-plan **slot digit** (SW corner) + hull `slots` table + hull **mount points**.
- **Per-ship loadout** + the server-side **resolved-plan bake** at load and refit.
- **Flight stats from data** (out of `ship.gleam` constants, into hull + engine part).
- **Refit-at-a-dock** verb + a minimal refit UI.
- **Exterior part layered on the hull** at the center engine mount.
- A **starter catalog**: engine, cargo hold, fuel tank, crew bunks, passenger capability —
  enough that the Mockingbird's current deck is her default loadout.
- **Exit demo:** swap the Consol engine for the Rijay original at a dock; the hull's
  center nacelle changes, the engineering bay re-dresses, the flight stats move — and not
  one door on the Mockingbird moves.

Deferred to later iterations (additive data or separable features): the rest of the
catalog above, the fin package, the transponder **role classifier**, and specialized
cargo. None of it touches the core engine.

## Resolves two DESIGN open questions

- **"How much interior can a module rewrite?"** A module rewrites only its slot, via the
  authored overlay (`void` = passthrough); the hull owns all structure outside slots and
  all corridors, guaranteeing connectivity by authoring. Modules *may* add walls and doors
  **within their slot** (that is how passenger cabins carve staterooms out of an open bay)
  but never move the hull's existing structure.
- **"Exterior composition at runtime."** Client-side sprite layering at mount points in
  V1; a server/offline bake stays available if the lighting pipeline needs it.

DESIGN.md's "Ship customization" section, written before this was hashed out, describes a
shape-agnostic "modules rotate and fit any room" model that this supersedes: interior fit
is **authored per hull**, and the surviving cross-hull matching is the pooled tag budget
(power the flagship case). That section should be updated to match.
