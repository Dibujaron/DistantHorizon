# M4 iteration 2c — exterior part layering

Iterations 1, 2a, 2b and the slot-marker refactor built a refit that changes
everything about a ship *except* what she looks like. A player can swap a Consol
CO-17F for a Rijay Stork, feel the acceleration change, and see nothing: the
client draws `mockingbird` for every hull in the world and bakes the engines into
that one sprite. This iteration closes that gap, and closes DESIGN.md's
"Exterior composition at runtime" question with a shipped answer.

Three things arrive together because none of them is useful alone: **mount
geometry** (where a part sits on a hull), **standalone part sprites** (something
to draw there), and **per-ship appearance on the wire** (knowing which hull and
which parts). The Sparrow and the Goldfinch get their exterior art in the same
iteration, since 2b deferred it here explicitly and both hulls have now been
walked and accepted, so their proportions are settled.

## Scope

**In:**

- A `sprite` key on hull documents; per-ship `hull` and fitted `mounts` on the
  snapshot.
- Named mount anchors exported by `tools/artspike/composer.py`, replacing the
  anonymous `nozzle` anchor list.
- Standalone part sprite exports (`engine_rijay`, `engine_rijay_small`,
  `engine_consol`) under `client/assets/parts/`.
- Client-side layering of part sprites onto hulls — flying, moored at a berth,
  and as the walk-mode interior backdrop.
- The Mockingbird's stern re-cut: drums out of the hull art and into a part,
  blanking plates in, fins reassigned.
- Exterior art for the Sparrow and the Goldfinch.
- Engine plume emitted from fitted mounts rather than one tail point.

**Out, deliberately:**

- **Mount rotation.** Every part in the game is an engine and every engine points
  aft. A `rot_deg` on a mount anchor is a field for turrets, and turrets do not
  exist. Adding it now is authoring bookkeeping for a system that isn't there —
  the same call 2b made about `fuel` and `berths`.
- **A server-side or offline composite bake.** V1 is client-side layering, which
  this iteration proves. The bake stays available if the lighting pipeline ever
  demands one; the choice is isolated to the renderer.
- **Player livery.** `c1_tint`/`c2_tint` still default to the bases. Customisable
  paint is its own feature.
- **Hull layout changes.** Drawing the Goldfinch may prompt one (see Risks); it
  would be a separate iteration.
- **The refit UI.** Iteration 3. This iteration's swap is exercised through the
  existing `refit` message and `DH_SHIP_CLASS`.

---

## The split: server owns capability, renderer owns geometry

`docs/modules.md:110` left mount geometry out of the hull document on purpose —
"it is only needed by the renderer". This iteration keeps that split rather than
walking it back.

A mount stays `{id, kind, size}` on the hull. **Geometry lives in the art meta**,
as a named anchor emitted by the composer:

```json
{"kind": "mount", "id": "engine_port", "x_px": 5.54, "y_px": 42.81}
```

replacing today's `{"kind": "nozzle", "x_px": …, "y_px": …}`, which is an
unordered, unnamed list — three entries that the client can only tell apart by
position in an array.

The reasoning: an anchor is a coordinate in one sprite's pixel frame and means
nothing outside it. `manufacturers.py` already computes those coordinates
(`MB_SP`, `MB_Y + MB_LN`) as a consequence of drawing the ship. Copying them into
`server/shipclasses/*.json` would duplicate derived numbers in a file that has no
use for them, and they would drift the first time the art moves. Naming the
anchors — rather than indexing them — removes the failure mode where reordering a
loop in `mb_drums()` silently swaps two engines.

The cost of the split is that a mount id typo'd in either tree is a part that
silently does not draw. Two guards, and neither of them points `composer.py` at
server data:

- A **harness test** asserts, for every hull with art, that the set of mount ids
  in `server/shipclasses/<id>.json` equals the set of mount anchor ids in
  `client/assets/ships/<sprite>/meta.json` — in both directions. `harness/`
  already reads `server/shipclasses/` (as does `tools/slotmap.py`), so it is the
  natural home for a check that legitimately sees both trees.
- The **client** `push_error`s on a fitted mount with no matching anchor and
  draws nothing, rather than guessing a position.

---

## Wire

### Hull `sprite`

Hull documents gain an optional `"sprite"` naming the art directory under
`client/assets/ships/`, defaulting to the hull id when absent. The three shipped
hulls author it explicitly; `dock_testbed` and `refit_testbed` omit it and never
reach a client.

The walk-mode backdrop key stays the existing `<sprite>_interior` convention
(`mockingbird` → `mockingbird_interior`) rather than a second field. One
convention, already load-bearing in `asset_library.gd`.

### Snapshot appearance

Each entry in a `snapshot` message's `ships` array gains two fields:

```json
{"id": 7, "x": …, "y": …, "vx": …, "vy": …, "heading": …, "thrust": …,
 "docked": null, "berth": null,
 "hull": "mockingbird",
 "mounts": {"engine_port": "engine_rijay",
            "engine_center": "engine_consol",
            "engine_stbd": "engine_rijay"}}
```

Only fitted mounts appear. **Values are part `sprite` keys, never part ids** —
the client has no parts catalog (part documents are server-side only, and
`ship_class` on the wire carries no parts), so shipping ids would mean shipping
the catalog. A part with no `sprite` is omitted and draws nothing.

Appearance rides the snapshot rather than a separate low-frequency message. It
costs roughly 120 bytes per ship per tick for data that changes only on refit,
against single-digit ship counts. What it buys is that a client which can see a
ship can always draw it correctly: no join-ordering problem, no missed-message
state, no new message lifecycle. The failure mode of the low-frequency
alternative — a ship rendered as the wrong hull — is exactly the bug class this
iteration exists to remove. If snapshot size ever becomes a real constraint,
moving to a push message later is contained, because the client's appearance
state is keyed by ship id either way.

### Types

`encode_ship` takes only a `Ship`, which carries no fit, so the encoder gains a
typed companion rather than a threaded dict:

```gleam
pub type Appearance {
  Appearance(hull_sprite: String, mounts: List(#(String, String)))
}

pub fn encode_snapshot(tick: Int, ships: List(#(Ship, Appearance))) -> String
```

The sim builds each `Appearance` from `state.fits` — the hull's `sprite` and each
fitted part's `sprite`. A ship with no fit should be unreachable (spawn resolves
or refuses; `prune_fits` only drops dead ships), so the sim logs and emits
`Appearance("", [])`, which the client treats as unknown and does not draw. The
ship still appears in the snapshot; a missing fit must not make a hull vanish
from the world.

Client-side, `ShipState` parses both fields at decode into typed members, so the
renderer never touches raw JSON.

---

## The Mockingbird's stern

`mb_drums()` in `manufacturers.py:275` contributes the drum layers *and* returns
the three nozzle anchors. Pulling it out of the hull is not a clean cut, because
both fin sets are geometrically attached to the drums:

- Dorsal ridges (`mb_dorsal_fins`) run `y+3 → y+ln+9·fl` — the full length of
  each drum and past its aft end.
- Outboard fins (`mb_outboard_fins`) are rooted at the drum centre `sx·MB_SP` and
  span `y+16 → y+ln`, past the hull's own stern at `y=62`.

Leave either on the hull and it floats aft of the transom with nothing under it.

**The dorsal ridge travels with the engine part.** The MB_FL fins are the
atmo-landing package — a drum fairing, which is what the geometry already says.
Three consequences:

- A Mockingbird wearing three Rijay drums looks exactly as she does today.
- The lore default — `docs/lore.md`'s "a Consol center engine shoved between two
  Rijay originals", which is literally her `default_loadout` — renders as a
  centre nacelle with **no fin ridge**. The aftermarket part visibly reads as
  aftermarket, at no art cost.
- `mockingbird_stock`, the finless variant, becomes redundant: finned vs finless
  is now a part distinction, not a hull-art one. It is already dead art — listed
  in `asset_library.gd`'s `SHIP_KINDS` and referenced by no renderer — so its
  export, its asset directory and its `SHIP_KINDS` entry go.

**The outboard fin stays with the hull**, re-rooted on the hull's flare
(`y+47 → y+59`, inside the transom) instead of on the drum. It is a wing, not a
drive fairing, and only the outer two drums ever carried one — a single Rijay
engine sprite cannot be both winged and not.

The transom keeps a **blanking plate** per mount: a faired-over hardpoint drawn
by the hull that a fitted part covers. Structure belongs to the hull, equipment
to the part, and both an empty mount and a full one then read as deliberate with
no extra rules. This matters immediately — the Sparrow's `default_loadout` fits
`engine_port` and `engine_stbd` and leaves `engine_center` bare on purpose.

This changes the silhouette where the fins meet the drums, so it needs an eyeball
round before the art half is called done.

---

## Part sprites

Parts export through the same pipeline as hulls: authored SVG layers with
heights, rasterised, downsampled, albedo + normal + mask + `meta.json`. A part's
`Hull` carries one `Anchor("attach", x, y)` — the point that coincides with the
hull's mount anchor when drawn.

`composer.py` gains a `PART_EXPORTS` list beside `SHIP_EXPORTS`, writing to
`client/assets/parts/<sprite>/`. Part meta carries `px_w`, `px_h`,
`px_per_unit` and `attach_px`. **Every export shares one `px_per_unit`**
(`classic_px / model_units`, 45/195 today), so parts and hulls sit on the same
scale canon and the client needs no per-part scale correction.

Three parts, matching the `sprite` keys already authored in `server/parts/`:

| sprite | part | size | note |
| --- | --- | --- | --- |
| `engine_rijay` | Rijay Stork 240-C2 | m | the drum, with its dorsal ridge |
| `engine_rijay_small` | Rijay Wren 90-B | s | the Sparrow's engine |
| `engine_consol` | Consolidated CO-17F Block 2 | m | Consol livery, no ridge |

The Consol engine keeps its own maker's colours rather than taking the ship's
livery, so a mixed fit reads as mixed on sight.

The **Longhorn** is decorative parked traffic with no hull document and no server
ship. Her engines stay baked into her sprite; she gains no mounts and does not
change.

---

## Client rendering

One helper does the layering, used by all three draw paths so it exists in
exactly one place:

```
_dress_hull(hull_sprite: Sprite2D, hull_key: String, mounts: Dictionary) -> void
```

Part sprites are children of the hull sprite in hull-texture px — the same recipe
`_park_sprite` already uses for ships parked at berths — positioned so the part's
`attach_px` lands on the hull's named mount anchor. `light_mask = 1` (pipeline
art, sun-lit), the part's own `ShaderMaterial`, drawn over the hull so the part
covers its blanking plate. Untouched children are hidden, not freed, matching the
existing pooling.

Changes by file:

- **`asset_library.gd`** — `SHIP_KINDS` stops being a hand-maintained constant
  and enumerates `assets/ships/*`; a parallel pass loads `assets/parts/*`.
  `SpriteSet` gains `mount_anchor(id) -> Vector2` and `attach_px()`; the existing
  `anchors(kind)` stays for station berths.
- **`world_view.gd`** — `_update_ship_sprites` looks up `_lib.ship(ship.hull_sprite)`
  instead of the hardcoded `"mockingbird"` at line 414, then calls `_dress_hull`.
  `_park_sprite` takes the moored ship's hull key and mounts instead of a literal.
  Both are already per-ship loops; only the key changes.
- **`main.gd`** — `_interior_backdrops` resolves each moored ship's hull from
  snapshot state by `ship_id` (`_space.moorings` already carries the ids),
  removing the three hardcoded `"mockingbird_interior"` strings at lines 565, 578
  and 582.
- **`interior_view.gd`** — `Backdrop` carries the fitting list so the walk-mode
  backdrop layers parts through the same helper. The Mockingbird's drums are
  visible past her docking corridor, so a swapped nacelle shows from inside too.

**Plume.** `_emit_plume_trail` currently spits motes from a single point aft of
the ship's centre. It instead emits from each fitted engine mount anchor,
transformed hull-texture-px → world. Same anchor data, no new authoring, and a
Sparrow with an empty centre mount then visibly burns on two.

The pip regime (#17) is unchanged: below `SHIP_PIP_SCREEN_PX` the hull sprite
hides and takes its part children with it.

---

## The Sparrow and the Goldfinch

`ship_sparrow()` and `ship_goldfinch()` in `manufacturers.py`, both Rijay livery
(`RIJAY_PALETTE`, `RIJ_C1`/`RIJ_C2`), each returning a `Hull` with authored
heights, three named mount anchors and a blanking plate per mount.

Walkable footprints, from the deck grids at the 1 m/tile canon:

| hull | walkable | decks | mounts |
| --- | --- | --- | --- |
| Sparrow | 5 × 7 tiles | 1 (Main) | 3 × `s`, centre ships empty |
| Goldfinch | 5 × 14 tiles | 3 (Upper, Mezzanine, Lower) | `s`, `m`, `s` |
| Mockingbird | 14 × 23 tiles | 3 | 3 × `m` |

Each hull gets a space export and a 2× `*_interior` twin, both carrying an
`interior` fit block at `units_per_tile: 6.5` so the walk-mode backdrop lands on
the tile grid. As with the Mockingbird — whose sprite runs 30 tiles long against
a 23-tile walkable grid — both hulls carry exterior-only structure aft of the
walkable grid for their engines to sit on. (`composer.py`'s `MB_INTERIOR` comment
still says "14x20", stale since the 2a carve; correcting it is part of this
work.)

Art review runs the same way it has since M3.5: rendered through
`build_debug_sheet` for a sheet eyeball, then walked in-engine
(`DH_SHIP_CLASS=shipclasses/<hull>.json gleam run`, then the Godot client).

---

## Verification

**Gleam** — hull `sprite` decodes and defaults to the id; `encode_snapshot`
carries `hull` and fitted `mounts`; a ship's appearance follows a refit; a ship
with no fit still appears with an empty appearance.

**Harness (pytest)** — for every hull with art, mount ids and sprite mount-anchor
ids match in both directions; every part document's `sprite` resolves to an asset
directory with the four expected files; every `interior` fit still lands inside
its sprite's frame.

**artspike (pytest)** — part exports carry an `attach` anchor and share
`px_per_unit` with the hull exports; the Mockingbird's hull export no longer
contains drum geometry and does contain three mount anchors.

**Walks** — the Mockingbird's re-cut stern; a centre-engine swap that visibly
changes the sprite; the Sparrow's empty centre mount and her two-engine plume;
both new hulls in space, parked at a berth, and as walk backdrops.

---

## Sequencing

Two halves in one iteration and one PR, per the usual batching preference:

1. **Machinery** — hull `sprite`, snapshot appearance, named mount anchors, part
   exports, client layering, plume. Proven end-to-end on the Mockingbird with a
   visible engine swap.
2. **Art** — the Mockingbird's stern re-cut and the two new hulls.

Ordering machinery first means an art review round never blocks a mergeable
engine change.

---

## Risks

- **The Goldfinch will read small.** She is 5 tiles across against the
  Mockingbird's 14, and the 2b walk already left the impression that she reads
  smaller than intended. Drawing her and parking her at the same berth line makes
  that concrete, and the eyeball round may produce a "she should be wider"
  verdict. That would be a layout revision — a separate iteration, not a change
  of scope here.
- **The stern re-cut is a silhouette change.** The fin split is a judgement call
  about where a drum ends and a ship begins; it is cheap to revise, but only
  after someone looks at it.
- **Two trees must agree on mount ids** with no compiler to enforce it. The
  harness check and the client `push_error` are the whole defence; both must land
  with the feature, not after it.

---

## What comes after

**Iteration 3** — the refit loop as a game system: shipyard stations, a refit
console you walk to, per-station catalogs of what is actually for sale, charging
the wallet, and the Godot refit UI. Exterior layering is what makes that UI worth
building: a refit you can see is a refit worth paying for.
