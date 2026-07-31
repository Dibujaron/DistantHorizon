# M4 Iteration 2b: The Sparrow and the Goldfinch

**Date:** 2026-07-31
**Status:** approved, pending implementation plan
**Predecessor:** iteration 2a (PR #49, merge `b24d626`) — module target lists, multi-slot
targets, the ten-slot Mockingbird.

## Purpose

Every rule in `docs/modules.md` was written while looking at exactly one hull. Iteration 2b
authors two more and finds out which of those rules were design and which were the
Mockingbird's shape wearing a design's clothes.

This is the anti-overfit test the module system rests on. It is a **content** iteration:
new hull documents, new modules, new parts, and the tests that prove the engine
generalises. Nothing renders — exterior art and per-ship sprite selection belong to
iteration 2c, which already owns mount geometry and client-side layering.

## Scope

**In:**

- Three engine parts under a coherent naming convention, replacing the two on disk.
- The Mockingbird's three engine mounts — correcting a standing art/data disagreement.
- The **Sparrow**: a small single-deck hull, two slots, three mounts of which two are filled.
- The **Goldfinch**: a double-decked passenger liner whose regular cabins are served by
  `rijay.cabin.standard`.
- Renaming the Finch to the Goldfinch across lore and design docs.
- Schema, documentation and test updates.

**Out, deliberately:**

- **Exterior art.** No `sparrow/` or `goldfinch/` under `client/assets/ships/`. Both hulls
  are walkable for review via `DH_SHIP_CLASS`, which is the part that needs human eyes;
  a hull that flies wearing the Mockingbird's sprite teaches us nothing. Art depends on
  final hull proportions and shares 2c's pipeline.
- **Per-ship `hull` on the snapshot**, exterior layering, mount geometry — all 2c.
- **Weapons.** The Sparrow's eventual loadout is mostly weapons; none exist. Her slots are
  shaped so weapons land later without rework, and that is the whole of the accommodation.
- **A fuel/range model.** `fuel` is a `provides` tag that nothing consumes. It stays that
  way here; authoring tankage is bookkeeping for a system that does not exist yet, exactly
  as `berths` is.
- **Rebalancing flight feel.** Numbers are placeholders and untested. They must be
  *coherent* — a hull that overdraws its reactor will not resolve — but they are not tuned.

## Delivery

One plan, two PRs. Groundwork plus the Sparrow lands first; the Goldfinch follows, so the
Sparrow's lessons reach her decks before they are drawn rather than after. The Goldfinch is
a Mockingbird-scale authoring job and the Mockingbird took a dedicated iteration with
eyeball-review rounds.

---

## Part naming

Real engine designations are manufacturer-idiosyncratic — `CF6-80C2`, `JT9D-7R4`,
`RB211-524`, `RS-25`, `NK-33`. The digits encode thrust class, block and customer variant,
and the *grammar differs per house* while staying consistent within one. That is usable
worldbuilding: you can tell who built a part from the shape of its number before reading a
word of it.

**Rijay Drive Yards** name engines as their hulls are named — a bird — then a thrust class
in units of ten, then a block designation. Birds used for engines are distinct from birds
used for hulls, so the two namespaces never collide.

**Consolidated Orbital** get no bird and no poetry. A fleet-standard alphanumeric is all a
part gets from the Company.

| id | display name | kind | size | mass | provides | requires | thrust | torque | sprite |
|---|---|---|---|---|---|---|---|---|---|
| `rijay.engine.stork_240c2` | Rijay Stork 240-C2 | engine | m | 12.0 | `engine: 1` | `power: 4` | 2400.0 | 7000.0 | `engine_rijay` |
| `rijay.engine.wren_90b` | Rijay Wren 90-B | engine | s | 4.0 | `engine: 1` | `power: 3` | 900.0 | 3000.0 | `engine_rijay_small` |
| `consol.engine.co17f_2` | Consolidated CO-17F Block 2 | engine | m | 8.0 | `engine: 1` | `power: 3` | 1700.0 | 7500.0 | `engine_consol` |

`rijay.engine.stock` becomes `rijay.engine.stork_240c2`. `rijay.engine.consol_patch`
becomes `consol.engine.co17f_2` — it was **namespaced to the wrong manufacturer**.
Consolidated Orbital is its own house in `docs/lore.md`, its sprite is already
`engine_consol`, and the entire point of the starter Mockingbird is that her centre engine
is *foreign to the hull*. Filing it under `rijay.` erased that.

The Consol part is deliberately the odd one out on its numbers: less thrust than the Rijay
original it displaced, but more torque. It is a fleet part shoved into a hole it was not
drawn for, and it should read that way in the table.

Thrust and torque across all three are roughly a third of the pre-2b figures, because those
were authored against a one-mount hull and were therefore implicitly "the whole ship's
push". Three engines that each push a third of the ship is the honest reading.

---

## The Mockingbird's three engines

`client/assets/ships/mockingbird/meta.json` carries **three** `nozzle` anchors, evenly
spaced across the stern. `server/shipclasses/mockingbird.json` declares **one**
`engine_center` mount. The art and the data have disagreed since iteration 1, and 2c's
mount-geometry work binds mounts to exactly those anchors, so it walks straight into the
contradiction. Fixing it here unblocks that.

It also makes the lore mechanical at no cost. `docs/lore.md` describes a repossessed
starter Mockingbird as "a Consol center engine shoved between two Rijay originals". That
becomes the literal default loadout, inspectable in a JSON file.

**Changes to `server/shipclasses/mockingbird.json`:**

- `mounts` becomes `engine_port`, `engine_center`, `engine_stbd`, all `kind: engine`,
  `size: m`.
- `default_loadout.parts`: `engine_port` and `engine_stbd` → `rijay.engine.stork_240c2`,
  `engine_center` → `consol.engine.co17f_2`.
- `provides.power` rises 18 → **25**.

### The power budget, and why 25 exactly

Her modules draw 14. Three engines draw 4 + 3 + 4 = 11. Total **25**, against a reactor
providing **25** — zero headroom, which is how she already read before 2b, but now it
bites in a way that means something:

**Swap the cheap Consol Mule for a proper Rijay Stork and the draw becomes 26 against 25:
`tag_deficit:power`, refused.** You cannot fix the Company's patch without first fixing
what feeds it.

That is the "putting it right" early game `docs/lore.md` describes, enforced by the
validator rather than by narration, in shipped content. It also restores something 2a took
away: the re-carve made `tag_deficit:power` unreachable through shipped content, forcing
`sim_test`'s refused-refit case to retarget to `tag_deficit:engine`. That test **returns to
`power`**, which is the case it wanted in the first place.

### Resulting flight numbers

Mass 73 (hull) + 47 (modules) + 12 + 8 + 12 (engines) = **152.0**. Thrust
2400 + 1700 + 2400 = 6500 → **42.8 u/s²**. Torque 7000 + 7500 + 7000 = 21500 →
**141.4 deg/s**. Close enough to the pre-2b 39.06 and 171.9 that nothing feels different,
which is the intent — these are placeholders and the goal is coherence, not tuning.

**Her deck does not change.** `default_loadout_reproduces_the_authored_deck_test` and
`server/test/fixtures/mockingbird_authored.json` remain the arbiter, untouched.

---

## The Sparrow

> The Toyota Corolla of space fighters. Definitely a single-seat vehicle. Does not contain
> a bed by default. Basically just a small central cylindrical pod with a cockpit in front,
> with an engine strapped to either side at the back. Two engines instead of three (by
> default); upgradeable to three. — `docs/lore.md`

Deliberately small. The constraint that shapes her drawing: **a constant-width pod**, with
none of the Mockingbird's goose-bellied central bulge. She is a small Mockingbird in her
cockpit and her engines and nowhere else.

### What she tests

Every one of these is a rule nothing on disk has ever exercised:

- **A single-deck hull.** No stairs, no mezzanine. Every deck-linking and stair rule we
  have was written against a three-deck ship.
- **Multiple engine mounts**, and pooled `requires: {engine: 1}` satisfied by 2 ≥ 1.
- **An empty mount.** `engine_center` ships unfitted. No shipped hull has ever had one.
- **`mount size >= part size`.** Both engines on disk today are `m`; a size-`s` mount
  refuses them. The rule has never been checked by content.
- **A slot as a genuine either/or**, enforced by nothing more than a slot holding one
  module.

### Layout

One deck. Two slots:

| slot | shape | occupants |
|---|---|---|
| `cockpit` | small, forward | `rijay.cockpit.sparrow` — helm and seat |
| `bay` | 1×2 pod section, aft of the cockpit | `rijay.bay.packet` **or** `rijay.bay.ranger` |

**Two `Q` dock ports, port and starboard, symmetric.** Not a single side door — that reads
as a work van, and she is not one.

Her helm arrives with her cockpit module, as the Mockingbird's does; a bare Sparrow hull
has no consoles and a fit that omits the cockpit fails `invalid_resolved_plan`.

### Modules

| id | slot | mass | provides | requires |
|---|---|---|---|---|
| `rijay.cockpit.sparrow` | `cockpit` | 3.0 | — | `power: 2` |
| `rijay.bay.packet` | `bay` | 2.0 | cargo pallets, drawn | `power: 1` |
| `rijay.bay.ranger` | `bay` | 4.0 | `berths: 1`, `fuel: 8` | `power: 2` |

`rijay.bay.packet` is default: the lore is explicit that she has no bed unless you fit one.
Her cargo capacity is **derived from the pallet glyphs the packet module draws**, not from
the hull's `cargo.capacity`, which `hull.gleam` uses only as a fallback when the stamped
plan draws no pallets at all.

`rijay.cabin.standard` deliberately does **not** target the Sparrow. Her bunk comes bundled
with tankage as the ER package, which is the tradeoff as specified. The cabin document's
real workout is the Goldfinch.

### Mounts and the power squeeze

Three mounts — `engine_port`, `engine_center`, `engine_stbd` — all `size: s`. Two Wren 90-B
fitted port and starboard; `engine_center` empty, awaiting the lore's third-engine upgrade.

Hull `provides: {power: 12}`, `requires: {engine: 1}`:

| fit | draw | result |
|---|---|---|
| cockpit + packet + 2 engines (**default**) | 2 + 1 + 6 = **9** | 3 to spare |
| cockpit + ranger + 2 engines | 2 + 2 + 6 = **10** | fits |
| cockpit + packet + 3 engines | 2 + 1 + 9 = **12** | fits, exactly |
| cockpit + ranger + 3 engines | 2 + 2 + 9 = **13** | **`tag_deficit:power`** |

**Range or speed, not both.** The third engine and the endurance package each fit alone and
refuse together, which is a real refit decision expressed entirely in numbers the validator
already understands.

Default mass 12 (hull) + 3 + 2 + 4 + 4 = **25.0**; thrust 1800 → **72 u/s²**, torque 6000 →
**240 deg/s**. Nimble, as a fighter should be, and emergent rather than back-solved.

---

## The Goldfinch

> Dedicated passenger carrier. Similar to the mockingbird, especially in cockpit and neck.
> Body is much slimmer than the mockingbird, with two rows of windows on the sides
> (something like an A380 but not as long). Single medium engine centrally mounted on the
> stern. Small engines mounted to the sides of the back, on struts. — `docs/lore.md`

**The A380 is a double-decker, and "two rows of windows" is the second deck seen from
outside.** That reading is what makes the rest of the line consistent: "slimmer than the
Mockingbird" and "carries far more passengers than the Mockingbird" only hold together if
the volume went vertical rather than wide.

So: narrow beam, **two full passenger decks**, plus a Mezzanine carrying symmetric dock
ports on the Mockingbird's pattern. Cockpit and neck lifted from the Mockingbird, as the
lore asks.

### The rename

"Finch" becomes **"Goldfinch"** — a finch is a tiny bird and this hull is Mockingbird-scale
or larger, and the gold carries the luxury connotation a passenger liner wants. Hull id
`goldfinch`. The rename touches `docs/lore.md`, `docs/modules.md` (four references) and
`DESIGN.md` (one).

### What she tests

- **`rijay.cabin.standard` on a hull it was not drawn for** — the headline claim of
  iteration 2a, and the reason the document is namespaced by manufacturer rather than by
  hull. If the Goldfinch needs a bespoke cabin file, the rule is wrong and we have found
  out cheaply.
- **A mixed-size mount table**: `engine_center` at `m`, `engine_port`/`engine_stbd` at `s`.
  Nothing has ever mixed sizes on one hull.
- **Many slots of one shape**, where the Mockingbird has ten slots of nine shapes.

### Cabins

The Mockingbird's five cabins are all different — door and window on different walls,
because she is a hand-carved classic whose rooms were fitted where they would go. Her
cabin targets therefore share a document but not a drawing.

The Goldfinch is a purpose-built liner, so her cabins are **regular**: two distinct
drawings, port and starboard, repeated down both decks. Roughly **twelve targets sharing
two grids**, in one file. That is the payoff stated as plainly as it can be — one concept,
one document, twelve placements — and it is only reachable because a target's patch is
positioned by its own `x`/`y` rather than by the drawing.

### Mounts

`engine_center` (`m`) on the stern taking a Stork 240-C2; `engine_port` and `engine_stbd`
(`s`) on struts taking Wren 90-Bs. Per the lore, a passenger transport needs less thrust
overall — 1G — so her figures should land soft and heavy rather than nimble.

Exact deck dimensions, slot count and the power budget settle during authoring. They follow
the same rules as the Sparrow's and are not re-derived here; the plan will fix them before
any grid is drawn.

---

## Testing

- **Existing goldens hold.** The Mockingbird's default loadout still reproduces her frozen
  authored deck tile for tile. The re-mount and reactor change alter her *parts*, never her
  *rows*.
- **Per hull:** the default loadout resolves; the resolved plan validates (helm present);
  `tools/slotmap.py` paints the intended slot regions and nothing else.
- **The anti-overfit assertion, made explicit:** a test asserts `rijay.cabin.standard`
  carries targets on more than one hull, and fails if a second cabin document ever appears.
  The equivalent Mockingbird-only test from 2a is strengthened rather than duplicated.
- **The refusals are shipped-content tests, not fixtures:** upgrading the Mockingbird's
  centre engine refuses with `tag_deficit:power`; the Sparrow's third engine plus ER
  package refuses with `tag_deficit:power`. `sim_test`'s refused-refit case returns from
  `tag_deficit:engine` to `tag_deficit:power`.
- **Mount rules:** an `m` engine on the Sparrow's `s` mount refuses; her empty
  `engine_center` resolves cleanly.
- **`server/test/data_schema_test.gleam`** validates every shipped document, so both hulls,
  all new modules and all three parts are covered once the schemas accept them.
- **Harness:** `cd harness; python -m pytest -v` stays green. The walk driver's deck-plan
  twin should walk the Sparrow, which is the first single-deck hull it has seen.

## Definition of done

- `cd server; gleam test` and `cd harness; python -m pytest -v` both green.
- The Mockingbird flies on three engines, her deck unchanged, her reactor at exactly zero
  headroom, and a Stork in her centre mount refuses for `power`.
- The Sparrow: one deck, two slots, three `s` mounts with two filled, symmetric dock ports,
  and range-or-speed enforced by the validator.
- The Goldfinch: two passenger decks of regular cabins, every one of them furnished by
  `rijay.cabin.standard`, with no bespoke cabin document anywhere.
- No part id names a manufacturer that did not build it.
- `docs/modules.md` records what 2b proved — and, honestly, anything it disproved.

## Risks

- **The Goldfinch is a large drawing job.** She is the reason for two PRs. If her decks
  fight the rules, that is a finding rather than a failure, and it is the finding this
  iteration exists to produce.
- **A rule may not survive.** The most likely casualty is the assumption that a 1×2 cabin
  drawing is reusable across hulls whose corridors run differently. The slot-perimeter rule
  (`docs/deckplan-format.md`, "Slots") already constrains which side of a slot boundary the
  hull may author — author the hull side *open*, draw the walls and doors on the module
  side — and a liner's back-to-back cabins will press on it harder than the Mockingbird's
  did. Both new hulls are drawn from scratch, so unlike the Mockingbird they can obey it
  from the first row; if they still cannot, the rule is the problem.
