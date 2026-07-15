# M2 — The ship is a place: design

**Goal (DESIGN.md):** interior deck plan for one ship class; walkable character; sit at
helm ↔ walk around; zoom transition between views; two players aboard the same ship, one
flying while the other walks.

**Exit criterion:** a harness test proves two clients aboard one ship — one seated at the
helm flying it, the other walking the deck — each seeing both the interior and the moving
exterior.

## Decisions (open questions from DESIGN.md, resolved here)

- **Interior movement: free movement** within walkable tiles, not tile-to-tile hops.
  Client sends normalized move axes (like `helm`); the server integrates position at a
  fixed walk speed at 60 Hz with circle-vs-tile collision. Matches DESIGN.md's lean.
- **Ship-system depth: consoles only.** The helm console is functional (binds
  helm/dock/undock); a cargo console exists on the deck plan but sitting at it does
  nothing yet (M3 will bind it). No power/repair/fires.
- **Login embodiment:** login spawns a ship *and* a character **seated at its helm**.
  This preserves every M1 flow (helm/dock/undock work immediately after login), so M1
  tests pass unchanged. Walking is opt-in via `stand`.
- **Crewing:** new `board` intent. Allowed when your ship and the target ship are both
  docked at the same station. Your character appears standing at the target's spawn tile.
  A ship with zero characters aboard despawns. A ship lives as long as anyone is aboard
  (the pilot disconnecting mid-flight leaves the walker on a drifting ship — fine for M2).

## Ship class doc (`server/classes/sparrow.json`, `schema: 1`)

Ship classes are static config files (DESIGN.md "content is data"). One class for M2.
Interior coordinates are **tile units**, ship-local, y-down; tile `(x,y)` spans
`[x, x+1) × [y, y+1)`, center `(x+0.5, y+0.5)`.

```jsonc
{
  "schema": 1, "id": "sparrow", "name": "CV-7 Sparrow",
  "grid": {"width": 10, "height": 6},
  "walkable": [            // one string per row, '#' walkable, '.' hull/void
    "..........",
    "....###...",
    ".########.",
    ".########.",
    "....###...",
    ".........."
  ],
  "rooms": [               // rects, for rendering/labels only (no door graph in M2)
    {"id": "helm",     "name": "Helm",        "x": 1, "y": 2, "w": 2, "h": 2},
    {"id": "corridor", "name": "Corridor",    "x": 3, "y": 2, "w": 1, "h": 2},
    {"id": "cargo",    "name": "Cargo Hold",  "x": 4, "y": 1, "w": 3, "h": 4},
    {"id": "engine",   "name": "Engine Room", "x": 7, "y": 2, "w": 2, "h": 2}
  ],
  "consoles": [
    {"id": "helm_main",  "kind": "helm",  "x": 1, "y": 2},
    {"id": "cargo_main", "kind": "cargo", "x": 6, "y": 1}
  ],
  "spawn_tile": [5, 4]     // where boarding characters appear (the airlock end)
}
```

Server loads it at startup (path `server/classes/sparrow.json`, overridable via
`DH_SHIP_CLASS`), validates (rows match grid, consoles/spawn on walkable tiles), and
sends the whole doc in `welcome` as `ship_class`. Every ship is a sparrow in M2.

## Character simulation (server)

- `Character`: `id` (sequential int), `name` (username), `ship_id`, `x`, `y` (tile
  units), `seat` (console id or none), move input `(dx, dy)`.
- **Walk:** speed **3.0 tiles/s**, radius **0.3 tiles**. Each tick, if standing:
  normalize input if |v| > 1, step x then y independently; an axis step is rejected if
  any tile overlapped by the character circle at the new position is non-walkable
  (classic per-axis tile collision, so you slide along walls).
- **Sit** (`sit console_id`): requires standing, console exists, unoccupied, and
  character center within **1.2 tiles** of the console tile center. Seated characters
  snap to the console tile center; move input is ignored while seated.
- **Stand:** leaves the seat, character stays at the console tile center.
- **Helm binding:** `helm`, `dock`, `undock` take effect only while seated at a
  `helm`-kind console of your ship. `helm` is silently ignored otherwise (like other
  invalid input); `dock`/`undock` fail with reason `"not_at_helm"`.
- **Interior is decoupled from exterior physics** (artificial gravity handwave): walking
  never cares whether the ship is docked, thrusting, or tumbling.
- **Lifecycle:** disconnect removes the character; any ship with zero characters aboard
  despawns. `board` moves the character between docked ships (see Decisions).

## Protocol (v1 additions — no version bump; existing messages unchanged unless noted)

Client → server:

| type | payload | notes |
|---|---|---|
| `move` | `dx`, `dy` ∈ [−1,1] | walk intent; ignored while seated; +y is down (tile coords) |
| `sit` | `console` (id) | reply: `seat_result` |
| `stand` | — | reply: `seat_result` |
| `board` | `ship_id` (int) | reply: `board_result` |

Server → client:

| type | payload |
|---|---|
| `seat_result` | `ok`, `reason` (`null` \| `unknown_console` \| `occupied` \| `too_far` \| `already_seated` \| `not_seated`), `seat` (console id \| `null` — the seat after the attempt) |
| `board_result` | `ok`, `reason` (`null` \| `unknown_ship` \| `not_docked_together` \| `same_ship`), `ship_id` (your ship after the attempt) |
| `interior` | `tick`, `ship_id`, `characters: [{id, name, x, y, seat}]` — sent at 15 Hz, **only to clients aboard `ship_id`** (one serialization per crewed ship, fanned to its crew) |

Changed messages:

- `welcome` gains `character_id` (int) and `ship_class` (the full class doc).
- `dock_result` gains reason `"not_at_helm"`.
- `snapshot` is unchanged (exterior only, still one shared broadcast) — interiors ride
  the new `interior` message, which is the interest-management boundary from DESIGN.md.

Server internals: session state in `server.gleam` holds `character_id` (stable across
boarding); the sim routes `helm`/`dock`/`undock`/`move`/`sit`/`stand`/`board` by
character id and resolves the character's current ship itself.

## Client (Godot)

- **Two view modes** driven by seat state: **INTERIOR** (standing/walking, camera in
  ship-local frame over the deck plan) and **SYSTEM** (seated at helm — the M1 view).
  Sitting at the helm zooms smoothly out to the system view; standing zooms back into
  the deck. The transition is an animated camera zoom + crossfade (~0.6 s), per
  DESIGN.md ("'zoom' is really a view/control mode switch, presented as a smooth
  camera zoom").
- **Interior rendering** (`interior_view.gd`, sibling of `world_view.gd`): floor tiles
  from `walkable`, room tints + name labels, consoles as marked tiles, characters as
  circles (own character highlighted), other crew interpolated from `interior` messages
  the same way ships are from snapshots.
- **Input:** WASD = move intent (sent on change, like helm input); `E` = sit at the
  nearest in-range console / stand if seated; SPACE = dock/undock (only meaningful at
  helm; server enforces); `B` = board the other ship when both are docked at the same
  station (client picks the first eligible ship from the snapshot).
- **Automation hook:** state dump gains `view_mode`, `character {id, x, y, seat}`, and
  current `ship_id` so harness/automation can assert interior state textually.

## Harness (Python)

- `dh_client.py` helpers: `move(dx, dy)`, `sit(console_id)`, `stand()`,
  `board(ship_id)`, `next_interior()` / interior message capture, plus `welcome`
  exposure of `character_id` and `ship_class`.
- `test_m2_interior.py`:
  1. **Spawn state:** welcome carries `character_id` + valid `ship_class`; first
     `interior` shows own character seated at `helm_main`.
  2. **Stand/walk/collide:** stand, walk east across the corridor into the cargo hold;
     position advances, never enters a non-walkable tile; walk into a wall and stay put.
  3. **Seat rules:** sit at `cargo_main` from across the ship → `too_far`; sit while
     seated → `already_seated`; helm gating: `undock` while standing →
     `dock_result` `not_at_helm`.
  4. **Boarding:** two clients docked at spawn; B boards A's ship → `board_result` ok,
     B's old ship gone from snapshots, both characters in A's `interior`.
  5. **Exit criterion (two crew, one flies, one walks):** after (4), A undocks and
     thrusts; B walks the cargo hold. Assert ship A moves in snapshots, B's character
     coordinates change while the ship flies, B's `helm` input is ignored (heading
     unaffected), and both clients receive the same interior crew list.
- M1 tests must keep passing unchanged (spawn-seated-at-helm guarantees this).

## Out of scope for M2

Door graph / pathfinding, cargo console function, concourses, ship persistence,
multiple ship classes, interior art beyond debug-quality shapes, boarding while
undocked, character customization.
