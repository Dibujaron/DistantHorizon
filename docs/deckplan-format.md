# Interior deck-plan format (v3)

The canonical, human-authorable format for ship and station interiors. The
ship/station `.json` (e.g. `server/classes/mockingbird.json`) is the **single
source of truth** for a layout: the server parses it into deck plans and sends
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
(N/E/S/W). The four corners are cosmetic — draw `#` there for a tidy-looking
hull, but they carry no data (you never walk through a corner, so they have no
collision meaning). Nothing is ever a syntax error; a blank simply means "no
wall here."

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

## Glyph key

### Center — what the tile *is*

| Glyph | Meaning |
|-------|---------|
| (space) | Open floor — walkable |
| `.` | Void — outside the hull; not a tile |
| `x` | Stairs / ladder — walkable, and connects to the vertically-aligned tile on the adjacent deck |

Consoles and rooms are **not** encoded in the grid — they keep their structured
lists (`rooms`, `consoles`), because they carry ids, names, and kinds a single
glyph can't. The grid owns structure (floor / void / walls / doors / fixtures /
stairs); the lists own labelled metadata, matched to the grid by position.

### Edges (N / E / S / W mid characters) — what's on that side

| Glyph | Meaning | Collision |
|-------|---------|-----------|
| (space) | Open — no wall | passable |
| `#` | Wall | blocks |
| `=` | Door — auto-opens for now | passable |
| letter (e.g. `v`) | Wall-mounted fixture — a wall that also carries a fixture | blocks |

Fixture letters are an extensible legend (start: `v` = viewscreen/screen). A
fixture implies the wall is there, so it blocks like `#` and renders its art.

### Corners

Cosmetic only. Use `#` for a clean hull outline; the renderer also auto-joins
wall corners, so a blank corner between two walls still renders closed.

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
`x` lets you move to the vertically-aligned tile on the adjacent deck. (This
replaces the old `B` between-level tiles.)

The **Mockingbird becomes a three-deck ship**: Upper (cockpit, quarters, mess,
commons, aft passage), a rear Mezzanine (the former docking half-flight, now its
own deck), and Lower (bow ramp, main hold, docking deck).

## JSON shape

```jsonc
{
  "schema": 3,
  "id": "mockingbird",
  "name": "Mockingbird",
  "decks": [
    { "name": "Upper",     "grid": [ /* rows of 3×W chars */ ] },
    { "name": "Mezzanine", "grid": [ /* ... */ ] },
    { "name": "Lower",     "grid": [ /* ... */ ] }
  ],
  "rooms":    [ { "id": "mess", "name": "Mess", "deck": 0, "x": 3, "y": 9, "w": 8, "h": 4 } ],
  "consoles": [ { "id": "helm_main", "kind": "helm", "deck": 0, "x": 6, "y": 4 } ],
  "spawn":    { "deck": 2, "tile": [5, 22] },
  "cargo":    { "capacity": 40, "handling": "breakbulk" },
  "dock_port_orientation": 1.5707963267948966
}
```

- A deck's tile dimensions are derived from its grid: `width = len(row) / 3`,
  `height = len(grid) / 3`. Every row in a deck must be the same length, and row
  count must be a multiple of 3.
- `rooms` and `consoles` gain a `deck` index (which grid they live on),
  replacing the old `"deck": "upper"|"lower"` string.
- `spawn` names a deck + tile.

## Compatibility

This is `schema: 3`. The v2 single-grid `walkable` format (`.`/`#`/`L`/`U`/`2`/`B`)
is superseded. Existing hulls are migrated by re-authoring them as decks; the
Mockingbird is the reference conversion. There is only one authored hull today
(the Mockingbird), so there is no large back-catalog to migrate.

## See also

- Issue #24 — ship/station interior builder UI (reads/writes this format).
