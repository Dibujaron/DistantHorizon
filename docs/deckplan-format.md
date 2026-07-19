# Interior deck-plan format (v3)

The canonical, human-authorable format for ship and station interiors. The ship
class (`server/shipclasses/mockingbird.json`) and station class
(`server/stationclasses/*.json`) `.json` files are the **single source of
truth** for a layout: the server parses them into deck plans and sends
them to the client, which only renders what it's told. A visual builder is
tracked in issue #24; this ASCII format is what the builder round-trips, and
what you hand-author until it exists.

## Core idea: one fact, one position

A tile holds several **independent** facts — is it floor?, what's installed in
it?, and what's on each of its four edges? Packing those into a single glyph
explodes combinatorially (3⁴ edge states × installs). So we don't. Each fact
gets its own position in the text, and they compose instead of multiply.

**Every tile is a 3×3 block of characters.** The center is the tile itself; the
eight surrounding characters are that tile's own border.

```
NW  N  NE      (0,0)=NW  (0,1)=N   (0,2)=NE
 W  ·   E      (1,0)=W   (1,1)=·   (1,2)=E
SW  S  SE      (2,0)=SW  (2,1)=S   (2,2)=SE
```

The parser reads **five positions**: the center, and the four edge-mids
(N/E/S/W). The four corners carry no collision data (you never walk through a
corner) and never change walkability — but the **NE corner** carries one more
fact: a single hex digit `0`–`f` selects a slot in the 16-colour palette
(`server/colors.json`) that tints the tile's decor. A blank, `#`, or any other
non-hex character means uncoloured. NW/SW/SE remain purely cosmetic — draw `#`
there for a tidy-looking hull, but they carry no data. Nothing is ever a
syntax error; a blank simply means "no wall here."

Each tile owns **all four of its own walls**. A partition between two rooms is
therefore a *double* wall — which is exactly what lets you decorate one room's
side of a wall (a mounted screen, say) without it bleeding into the neighbor.

```
###        ######        ######
# #        # ## #        # #v #     v = a screen on the right room's north wall
###        ######        #=##=#     = = a door in each room's south wall
one        two rooms      two rooms, decorated + doored
room       (double wall
           between them)
```

## Glyph key — see `server/glyphs.json`

The glyph vocabulary is **data, not prose**: `server/glyphs.json` is the single
source of truth, loaded at startup so the server's parser and this document can
never drift (issue #32). Each entry gives a glyph its long-form `id` (the
client's sprite key), its role, and flags. The prose below is rationale; the
registry is the list.

- **Center glyphs** (what a tile *is*) carry a `tile` kind — `floor` (walkable),
  `void` (outside the hull; not a tile), or `stairs` (walkable; connects decks)
  — plus optional flags: a `console` kind (`h`=helm, `c`=cargo, `b`=broker), a
  `dock` port (`Q`), or a `spawn` tile (`s`). Consoles/dock/spawn are all
  `floor`-kind. A letter in the **center** is a console/marker; the same letter
  on an **edge-mid** is a fixture — position disambiguates. Pass-1 decor adds
  four more `floor`-kind center glyphs that are purely cosmetic (no console/
  dock/spawn flag, still walkable): `r`=rug, `e`=seat, `d`=bed, and `p`=cargo
  pallet — the last one doubles as the unit a hull's breakbulk capacity is
  derived from (see "Derived cargo capacity" below).
- **Edge glyphs** (N/E/S/W mid characters, what's on that side) carry an
  edge kind: `open` (space, passable), `wall` (`#`, blocks), `door` (`=`,
  passable, auto-opens), or `fixture` (a named wall decoration — blocks like a
  wall and renders its art). `v`=viewscreen is the single wall-screen glyph:
  it stands for either a bridge viewscreen or a domestic TV, there's no
  separate TV glyph — context (which room it's in) tells them apart, not the
  character. `w`=window is a wall that carries a view instead of a screen.
  Any edge char not in the registry parses as a generic fixture, so nothing
  is ever a syntax error.
- **Corners**: NW/SW/SE are cosmetic — use `#` for a clean hull outline; the
  renderer auto-joins wall corners, so a blank corner between two walls still
  renders closed. **NE is not cosmetic**: it's the tile's colour digit (see
  "Colour" below). Corners never carry collision data and decor never changes
  walkability — `r`/`e`/`d`/`p` are walkable floor exactly like plain floor,
  while `v`/`w` block like any other wall-fixture.

### Colour

`server/colors.json` is a 16-slot palette (index 0-9 = `'0'`-`'9'`, index 10-15
= `'a'`-`'f'`) that the NE corner digit indexes into. Sprites are authored
**greyscale** and multiplied by the slot's colour at render time, so retuning
a hex value in `colors.json` recolours every tile using that slot across every
map, with no re-authoring of the maps themselves — authors reference a slot
(the digit), never a colour value. A tile with no NE digit (blank, `#`, or any
non-hex character) renders its decor untinted. The palette rides the wire on
the `welcome` message, the same way the glyph registry does, and the client
applies the tint at render — colour is transport, not gameplay: it never
affects walkability or collision.

Console/dock/spawn glyphs are an **authoring** convenience: **the map is the
single source of truth**, so a position can't drift from a separate list. At
load the server derives a structured console list (ids auto-generated from the
kind — `helm`, or `broker0`/`broker1` when repeated) and the spawn/mooring tile
from these glyphs. The wire form carries the derived, **namespaced** console
list explicitly (`s3:helm`) — the composite needs ids that glyphs can't express
— so when `consoles`/`spawn` are present on an object they win; otherwise
they're derived from the glyphs. Hand-authored docs omit them. There is no
`rooms` list.

### Docking ports and berths (`Q`)

A **docking port** (`Q`) is a full tile that moors to a station or another hull.
It must have **at least one door (`=`) on an edge that faces void** — the *outer*
door the gangway connects through (a `Q` with no void-facing door is an authoring
error, rejected at load). Other doors/shape are free (an L-bend, three doors,
whatever). That void-facing edge is the port's **outward normal**.

The same `Q` rule is the single source of docking geometry for both ships and
stations (issue #31):

- A **ship's** mooring/spawn tile is the docking port whose outer door faces
  void on the **port (west)** side (the side that meets the gangway under side-on
  mooring).
- A **station's berths** are its concourse `Q` ports whose door faces void on the
  **north** side (the mouth opening to the space above the concourse). Each `Q`
  is one berth — there is no separate `berths` list. A ship's moored world
  position is the berth tile plus its class's `dock_standoff` (tiles/metres)
  along the outward normal; the standoff is authored **per ship class** because
  a tiny shuttle and a wide freighter stand off differently.

## Collision

Movement is per-axis (a walker sliding into a wall keeps moving along it). A
step from tile A into adjacent tile B crosses the A|B boundary:

- **Blocked** if *either* A's facing edge or B's facing edge is a wall or
  wall-fixture.
- **Passable** if the boundary is a door, or both facing edges are open.
- A one-side-door / other-side-wall boundary is contradictory: the wall wins
  (blocked), and it should be flagged as an authoring mistake.
- **Void** is never walkable, and floor→void is always blocked.

Doors auto-open (they're just passable openings) for now; a future gated-door
behavior can layer on without changing the format.

## Decks

Each deck is its own independent grid — a separate ASCII block. There are **no
sightlines between decks** (you can't see the floor above/below), which deletes
the old single-grid split-level alphabet (`2`/`L`/`U`/`B`) and all of its
cross-deck rendering logic.

Decks connect only through **stairs/ladders** (`x` center tiles): standing on an
`x` lets you move to the nearest deck (searching down first, then up) with an
`x` at the same tile. (This replaces the old `B` between-level tiles.) The shaft
**passes through intermediate levels that are void at that tile** but a solid
floor blocks it — so a stair can bypass a level the column doesn't exist on
(e.g. the Mockingbird's forward stairs skipping the void mezzanine).

The **Mockingbird becomes a three-deck ship**: Upper (cockpit, quarters, mess,
commons, aft passage), a rear Mezzanine (the former docking half-flight, now its
own deck), and Lower (bow ramp, main hold, docking deck).

## JSON shape

A **ship class** (`server/shipclasses/*.json`):

```jsonc
{
  "schema": 3,
  "id": "mockingbird",
  "name": "Mockingbird",
  "decks": [
    { "name": "Upper",     "grid": [ /* rows of 3×W chars; `h` marks the helm */ ] },
    { "name": "Mezzanine", "grid": [ /* ... `Q` marks the docking ports ... */ ] },
    { "name": "Lower",     "grid": [ /* ... `c` marks the cargo console ... */ ] }
  ],
  "cargo":    { "capacity": 40, "handling": "breakbulk" },
  "dock_port_orientation": 1.5707963267948966,
  "dock_standoff": 20.0
}
```

A **station class** (`server/stationclasses/*.json`) is the same deck-plan shape
plus `dock_radius` and `crane`, minus the ship-only `cargo`/`dock_*` fields:

```jsonc
{
  "schema": 1,
  "id": "highport",
  "name": "Highport",
  "dock_radius": 150.0,
  "crane": true,
  "decks": [ { "name": "Concourse", "grid": [ /* `b` brokers, `s` spawn, `Q` berths */ ] } ]
}
```

A world (`server/worlds/*.json`) references a station class by id and carries
only per-instance data (`id`, `name`, `class`, `parent`, `orbit`, `market`);
the class supplies the concourse/`dock_radius`/`crane`, and berths derive from
its `Q` glyphs (issue #30/#31).

No `rooms`, `consoles`, or `spawn` lists — those are read from the grid glyphs.
(`cargo` is the hold's capacity/handling block, not the cargo console;
`dock_standoff` is the hull's moored standoff in tiles/metres.)

- A deck's tile dimensions are derived from its grid: `width = len(row) / 3`,
  `height = len(grid) / 3`. Every row in a deck must be the same length, and row
  count must be a multiple of 3.
- `rooms` and `consoles` gain a `deck` index (which grid they live on),
  replacing the old `"deck": "upper"|"lower"` string.
- `spawn` names a deck + tile.

### Derived cargo capacity

The same "the map is the single source of truth" rule that derives consoles
and berths from glyphs also applies to breakbulk hold capacity: at load, the
server counts a hull's `p` (cargo-pallet) tiles across all of its decks and
uses that count as `cargo.capacity`, so the number in the JSON can't drift
from what's actually drawn on the deck plan. The Mockingbird draws 60 `p`
tiles across its holds, so its capacity derives to **60** and the authored
`"capacity"` is ignored. The authored value is used only as a **fallback**,
for a hull that draws zero pallet tiles. `handling` (e.g. `"breakbulk"`) is
still hand-authored; only the numeric capacity is derived.

## Compatibility

This is `schema: 3`. The v2 single-grid `walkable` format (`.`/`#`/`L`/`U`/`2`/`B`)
is superseded. Existing hulls are migrated by re-authoring them as decks; the
Mockingbird is the reference conversion. There is only one authored hull today
(the Mockingbird), so there is no large back-catalog to migrate.

## See also

- Issue #24 — ship/station interior builder UI (reads/writes this format).
