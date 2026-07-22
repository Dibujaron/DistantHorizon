# Pytest Harness schema-3 + Walk-Driver Retraining — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the red pytest integration harness (`harness/test_m2_interior.py`, `test_m31_stitched.py`, `test_m3_trade.py`) green again by restoring a small schema-3 `sparrow` test-fixture ship, porting the layout-robust multi-deck walk driver to Python, and retraining the stale wire-shape and geometry assertions — the pytest half of issue **#33** (the Gleam half shipped in PR #47).

**Architecture:** Decouple the integration tests from the gameplay ship. The server already honours a `DH_SHIP_CLASS` env override, so the harness spawns the server with a tiny, stable **flat single-deck** `sparrow` instead of the 3-deck Mockingbird. Because sparrow is single-deck, the docked-station **composite is single-deck too**, which keeps the Python walk driver simple (no stairs). Tests stop hardcoding routes/geometry: a Python port of the Gleam BFS driver (`harness/walk.py`) reads the exact composite plan off the `space` message and navigates to consoles by id, exactly like `server/test/walk.gleam` does.

**Tech Stack:** Python 3 + pytest 9 + pytest-asyncio + `websockets` (all already in `harness/requirements.txt`); the server is Gleam/BEAM, spawned by `harness/server_fixture.py` via `gleam run`.

## Global Constraints

- **Server spawn model (unchanged):** `harness/server_fixture.py` runs `gleam run` with `cwd=server/`, `DATABASE_URL` pointed at an unreachable address (forces accept-all auth — never touch a real Postgres), and `DH_PORT=8585` (dedicated test port). `gleam` must be on PATH (scoop shims). Do NOT require a database.
- **New env override (this plan adds it):** `DH_SHIP_CLASS=shipclasses/sparrow.json` (path is relative to `server/`, read at `server/src/dh_server.gleam:142`).
- **Current wire is schema 3 / deck-plan v3.** A ship-class doc and the composite `space["plan"]` are both `DeckPlan`s encoded as `{"decks":[{"name":str,"grid":[<3×3-glyph rows>]}], "consoles":[{"id","kind","deck","x","y"}], "spawn":{"deck":int,"tile":[x,y]}}`. A ship-class doc additionally wraps that with `{"schema":3,"id","name", …deckplan fields…, "cargo":{"capacity","handling"}, "dock_port_orientation":<float DEGREES>, "dock_standoff":<float>}`. There is **no** `grid`/`walkable`/`spawn_tile`/`rooms` any more.
- **Walkability rule (deck-plan v3):** a tile `(tx,ty)` on a deck is walkable iff in-bounds and its **center glyph** (grid char at row `3*ty+1`, col `3*tx+1`) is **not** `"."`. (`" "`=floor, `"x"`=stairs, `"Q"`=docking port, decor letters = furniture-on-floor are all walkable; only `"."` is void.) Source of truth: `server/src/dh_server/deckplan.gleam` `is_walkable`/`parse_center` and `server/glyphs.json`.
- **Ships moor side-on, rotated 90° CCW** in the composite (`composite.build` → `rotate_ccw_grid`, always, regardless of `dock_port_orientation`). This is why the old harness's un-rotated `(tx+dx, ty+dy)` geometry and "walk east down row 2" routes are wrong. **Never hardcode composite tile math** — derive everything from the wire (`space["moorings"]`, `space["plan"]`).
- **Console ids change:** the restored sparrow derives console ids from glyphs, so they are `helm`, `cargo`, `dock` (namespaced in the composite as `s{ship}:helm`, `s{ship}:cargo`). The old tests used `helm_main`/`cargo_main`; retrain those literals to `helm`/`cargo`.
- **`heading` stays radians on the ship-snapshot wire** (the degrees refactor only made *authored/config* angles degrees). Harness heading asserts are unchanged/relative ("heading unchanged", `abs=1e-6`), so they are wire-neutral — leave them.
- **Reference implementation:** `server/test/walk.gleam` (pure BFS) and `server/test/sim_test.gleam` (`aim`/`follow`/`drive_to_console`, the center-seeking follower). Port these faithfully; the trim-perpendicular-drift-first rule in `aim` is load-bearing (an off-center arrival clips the radius-0.3 collision circle into a diagonal wall and stalls).
- **Old sparrow geometry reference (schema 2, for tile positions only):** `git show a316cb6^:server/classes/sparrow.json` — helm `(1,2)`, cargo `(6,1)`, a `.########.` corridor. The *shape* is advisory now; only helm/cargo tile positions matter for continuity.

---

### Task 1: Restore the schema-3 `sparrow` fixture and spawn the harness server with it

**Files:**
- Create: `server/shipclasses/sparrow.json`
- Create (throwaway generator, delete after): `server/gen_sparrow.py`
- Modify: `harness/server_fixture.py` (add `DH_SHIP_CLASS` to the spawn env, ~line 117)

**Interfaces:**
- Produces: a bootable flat single-deck ship class `id="sparrow"` with `helm`@(1,2), `cargo`@(6,1), a `Q` docking port whose **west** edge is a door facing void (so `derive_spawn` picks it as the mooring tile — `deckplan.gleam:derive_spawn` wants `edge_in(W)==Door && tile_at(x-1,y)==Void`). Consumed by every later task via the running server.

- [ ] **Step 1: Write the sparrow generator** (reliable > hand-typing 18×30 chars)

Create `server/gen_sparrow.py`:

```python
"""Generate server/shipclasses/sparrow.json: a flat single-deck schema-3 test
ship (helm (1,2), cargo (6,1), a west-facing Q docking port at (1,3))."""
import json

W, H = 10, 6
WALK = {(x, y) for x in range(1, 9) for y in range(1, 5)}  # filled 8x4 interior
Q = (1, 3)                                                  # docking port tile
HELM, CARGO = (1, 2), (6, 1)

def solid(x, y):  # void or out of bounds (a wall lives between floor and this)
    return not (0 <= x < W and 0 <= y < H and ((x, y) in WALK or (x, y) == Q))

def center(x, y):
    if (x, y) == HELM: return "h"
    if (x, y) == CARGO: return "c"
    if (x, y) == Q: return "Q"
    return "." if solid(x, y) else " "

def edge(x, y, dx, dy, side):
    if solid(x, y):            # void tile: edges are cosmetic, keep open
        return " "
    if solid(x + dx, y + dy):  # floor meets void -> wall, except the Q's door
        return "=" if (x, y) == Q and side == "W" else "#"
    return " "

def corner(a, b):
    return "#" if a in "#=" or b in "#=" else " "

rows = []
for y in range(H):
    top = mid = bot = ""
    for x in range(W):
        n = edge(x, y, 0, -1, "N"); s = edge(x, y, 0, 1, "S")
        w = edge(x, y, -1, 0, "W"); e = edge(x, y, 1, 0, "E")
        top += corner(n, w) + n + corner(n, e)
        mid += w + center(x, y) + e
        bot += corner(s, w) + s + corner(s, e)
    rows += [top, mid, bot]

doc = {
    "schema": 3,
    "id": "sparrow",
    "name": "CV-7 Sparrow",
    "decks": [{"name": "Main", "grid": rows}],
    "cargo": {"capacity": 40, "handling": "breakbulk"},
    "dock_port_orientation": 90.0,
    "dock_standoff": 12.0,
}
with open("shipclasses/sparrow.json", "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print("\n".join(rows))
```

- [ ] **Step 2: Generate the file and eyeball it**

Run (from `server/`): `python gen_sparrow.py`
Expected: prints an 18-row hull, `#`-walled, with `h`/`c`/`Q` visible and a `=` on the Q's west side; writes `server/shipclasses/sparrow.json`. Confirm `decks[0].grid` has 18 rows of 30 chars.

- [ ] **Step 3: Wire the fixture to spawn sparrow**

In `harness/server_fixture.py`, in the `server` fixture where env is built (after the `env["DH_PORT"] = ...` line, ~117), add:

```python
    env["DH_SHIP_CLASS"] = "shipclasses/sparrow.json"  # small stable test ship (#33)
```

- [ ] **Step 4: Verify the server boots on sparrow and a client moors**

Add a temporary check test `harness/test_sparrow_boot.py`:

```python
import pytest
from dh_client import DHClient
pytestmark = pytest.mark.asyncio

async def test_sparrow_boots_and_moors(server):
    async with DHClient(name="boot") as client:
        welcome = await client.login("boot_user", "pw")
        assert welcome["ship_class"]["id"] == "sparrow"
        assert welcome["ship_class"]["schema"] == 3
        space = await client.next_space()
        ship_id = welcome["ship_id"]
        assert space["space"] == "station:meridian_highport"
        assert space["you"]["seat"] == f"s{ship_id}:helm"
        ids = [c["id"] for c in space["plan"]["consoles"]]
        assert f"s{ship_id}:helm" in ids
```

Run (from `harness/`): `python -m pytest test_sparrow_boot.py -x -q`
Expected: PASS. If it fails on server startup, read `server/.test_server.log` — a `berth_blocked`/`no door facing void`/`console not on a walkable tile` error means the Q placement or a wall is wrong; compare the Q rows against `server/shipclasses/mockingbird.json`'s `Q` (known-good) and adjust `gen_sparrow.py`, then regenerate.

- [ ] **Step 5: Commit** (remove the throwaway generator and boot test once green)

```bash
rm server/gen_sparrow.py harness/test_sparrow_boot.py
git add server/shipclasses/sparrow.json harness/server_fixture.py
git commit -m "test(harness): restore schema-3 sparrow fixture; spawn via DH_SHIP_CLASS (#33)"
```

---

### Task 2: Port the deck-plan-v3 walkability parser to Python

**Files:**
- Create: `harness/deckplan.py`
- Test: `harness/test_deckplan.py`

**Interfaces:**
- Produces: `tile_walkable(plan: dict, tx: int, ty: int, deck: int = 0) -> bool` and `circle_walkable(plan: dict, cx: float, cy: float, deck: int = 0) -> bool`, where `plan` is a v3 `DeckPlan` dict (`{"decks":[{"grid":[rows]}], …}`). Consumed by `harness/walk.py` and by the retrained collision assertions in Tasks 5–7. `CHAR_RADIUS = 0.3`.

- [ ] **Step 1: Write the failing test**

Create `harness/test_deckplan.py`:

```python
from deckplan import tile_walkable, circle_walkable

# One deck: 3x3 tiles, middle row walkable, everything else void.
#   tile (0,1),(1,1),(2,1) are floor; the rest void.
PLAN = {"decks": [{"name": "t", "grid": [
    ".........",
    ".........",
    ".........",
    "   #  #  ",   # y=1 row: three floor tiles, walls between (cosmetic here)
    "         ",
    "         ",
    ".........",
    ".........",
    ".........",
]}]}

def test_tile_walkable_center_glyph():
    assert tile_walkable(PLAN, 0, 1) is True
    assert tile_walkable(PLAN, 1, 1) is True
    assert tile_walkable(PLAN, 0, 0) is False   # void
    assert tile_walkable(PLAN, 9, 9) is False   # out of bounds

def test_circle_walkable_center_is_clear():
    assert circle_walkable(PLAN, 1.5, 1.5) is True   # dead center of a floor tile
    assert circle_walkable(PLAN, 1.5, 0.9) is False  # circle pokes into void row 0
```

- [ ] **Step 2: Run it, verify it fails**

Run (from `harness/`): `python -m pytest test_deckplan.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'deckplan'`.

- [ ] **Step 3: Implement `harness/deckplan.py`**

```python
"""Client-side deck-plan v3 walkability, mirroring server is_walkable
(server/src/dh_server/deckplan.gleam). A tile is walkable iff its center
glyph (grid[3*ty+1][3*tx+1]) is not '.'. Only '.' is void; ' ', 'x', 'Q'
and decor letters are all walkable floor."""
from __future__ import annotations
import math

CHAR_RADIUS = 0.3  # tiles, matches server/src/dh_server/character.gleam

def _grid(plan: dict, deck: int) -> list[str]:
    return plan["decks"][deck]["grid"]

def tile_walkable(plan: dict, tx: int, ty: int, deck: int = 0) -> bool:
    grid = _grid(plan, deck)
    height = len(grid) // 3
    width = (len(grid[0]) // 3) if grid else 0
    if not (0 <= tx < width and 0 <= ty < height):
        return False
    return grid[3 * ty + 1][3 * tx + 1] != "."

def circle_walkable(plan: dict, cx: float, cy: float, deck: int = 0) -> bool:
    """Every tile the radius-0.3 collision circle at (cx,cy) overlaps must be
    walkable — the server's standing-position invariant, recomputed here."""
    tx0 = math.floor(cx - CHAR_RADIUS); tx1 = math.floor(cx + CHAR_RADIUS)
    ty0 = math.floor(cy - CHAR_RADIUS); ty1 = math.floor(cy + CHAR_RADIUS)
    for tx in range(tx0, tx1 + 1):
        for ty in range(ty0, ty1 + 1):
            closest_x = min(max(cx, float(tx)), float(tx) + 1.0)
            closest_y = min(max(cy, float(ty)), float(ty) + 1.0)
            dx, dy = cx - closest_x, cy - closest_y
            if dx * dx + dy * dy <= CHAR_RADIUS * CHAR_RADIUS and not tile_walkable(plan, tx, ty, deck):
                return False
    return True
```

- [ ] **Step 4: Run it, verify it passes**

Run: `python -m pytest test_deckplan.py -q`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add harness/deckplan.py harness/test_deckplan.py
git commit -m "test(harness): deck-plan v3 walkability parser (#33)"
```

---

### Task 3: Port the BFS walk driver to Python

**Files:**
- Create: `harness/walk.py`
- Test: `harness/test_walk.py`

**Interfaces:**
- Consumes: `deckplan.tile_walkable`; a `DHClient` (its `next_walkers(space)`, `character_in(walkers, id)`, `move(dx,dy)`, `character_id`).
- Produces:
  - `find_path(plan, start, goal) -> list[tuple[int,int]] | None` — pure BFS over deck 0 (single-deck composite), start/goal are `(tx,ty)`, returns tiles to move onto (excludes start), or `None` if unreachable.
  - `console_tile(plan, console_id) -> tuple[int,int]` — a namespaced console's `(x,y)` from `plan["consoles"]`.
  - `async def walk_to_console(client, space, plan, console_id)` — stand-agnostic; drives the character to `console_id`'s tile and stops. Center-seeking follower ported from `sim_test.gleam:aim/follow` (trim smaller-axis drift first, tolerance 0.15, target tile centers).

**Note on single-deck:** the sparrow composite has one deck, so this port omits stairs/`deck` tracking. If a multi-deck test ship is ever introduced, extend `find_path` with the stairs rule and add `deck` to `CharacterView`, mirroring `server/test/walk.gleam`.

- [ ] **Step 1: Write the failing test (pure BFS only — the follower is integration-tested by Tasks 4–7)**

Create `harness/test_walk.py`:

```python
from walk import find_path, console_tile

PLAN = {  # L-shaped single-deck corridor: (0,0)->(0,1)->(1,1)->(2,1)
    "decks": [{"name": "t", "grid": [
        "     ....",
        "         ",
        "     ....",
        "         ",
        "         ",
        "         ",
        ".........",
        ".........",
        ".........",
    ]}],
    "consoles": [{"id": "s1:helm", "kind": "helm", "deck": 0, "x": 2, "y": 1}],
}

def test_find_path_reaches_goal():
    path = find_path(PLAN, (0, 0), (2, 1))
    assert path is not None
    assert path[-1] == (2, 1)
    # every hop is one orthogonal step onto a walkable tile
    prev = (0, 0)
    for tile in path:
        assert abs(tile[0] - prev[0]) + abs(tile[1] - prev[1]) == 1
        prev = tile

def test_console_tile_lookup():
    assert console_tile(PLAN, "s1:helm") == (2, 1)

def test_unreachable_is_none():
    assert find_path(PLAN, (0, 0), (8, 8)) is None
```

- [ ] **Step 2: Run it, verify it fails**

Run: `python -m pytest test_walk.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'walk'`.

- [ ] **Step 3: Implement `harness/walk.py`**

```python
"""Layout-robust single-deck walk driver for the pytest harness (#33), the
Python twin of server/test/walk.gleam + the sim_test follower. BFS a route over
the composite plan the server handed us (the `space` message's `plan`), then
drive to it with move input, steering toward tile centres and trimming
perpendicular drift first so the radius-0.3 collision circle never clips a
diagonal wall on a turn."""
from __future__ import annotations
from collections import deque

from deckplan import tile_walkable

WAYPOINT_TOLERANCE = 0.15  # tiles; matches sim_test.gleam waypoint_tolerance

def console_tile(plan: dict, console_id: str) -> tuple[int, int]:
    for c in plan["consoles"]:
        if c["id"] == console_id:
            return (c["x"], c["y"])
    raise AssertionError(f"console {console_id!r} not in plan")

def find_path(plan: dict, start: tuple[int, int], goal: tuple[int, int]):
    if start == goal:
        return []
    frontier = deque([start])
    came_from = {start: None}
    while frontier:
        x, y = frontier.popleft()
        for nx, ny in ((x, y - 1), (x + 1, y), (x, y + 1), (x - 1, y)):
            if (nx, ny) in came_from or not tile_walkable(plan, nx, ny):
                continue
            came_from[(nx, ny)] = (x, y)
            if (nx, ny) == goal:
                path = [goal]
                cur = (x, y)
                while cur != start:
                    path.append(cur)
                    cur = came_from[cur]
                path.reverse()
                return path
            frontier.append((nx, ny))
    return None

def _sign(v: float) -> float:
    return 1.0 if v >= 0.0 else -1.0

def _aim(dx: float, dy: float) -> tuple[float, float]:
    """One cardinal move toward a tile centre, trimming the SMALLER off-centre
    error first (mirrors sim_test.gleam:aim)."""
    ax, ay = abs(dx), abs(dy)
    if ax < ay:
        return (_sign(dx), 0.0) if ax > WAYPOINT_TOLERANCE else (0.0, _sign(dy))
    return (0.0, _sign(dy)) if ay > WAYPOINT_TOLERANCE else (_sign(dx), 0.0)

async def _follow(client, space: str, path: list[tuple[int, int]], max_frames: int = 2000) -> None:
    i = 0
    frames = 0
    while i < len(path):
        walkers = await client.next_walkers(space)
        me = client.character_in(walkers, client.character_id)
        if me is None:
            continue
        tx, ty = path[i]
        dx = tx + 0.5 - me.x
        dy = ty + 0.5 - me.y
        if abs(dx) < WAYPOINT_TOLERANCE and abs(dy) < WAYPOINT_TOLERANCE:
            i += 1
            continue
        frames += 1
        if frames > max_frames:
            raise AssertionError(f"walk driver stalled before waypoint {path[i]} (at {me.x:.2f},{me.y:.2f})")
        mx, my = _aim(dx, dy)
        await client.move(mx, my)
    await client.move(0.0, 0.0)

async def walk_to_console(client, space: str, plan: dict, console_id: str) -> None:
    """Drive the (already-standing) character to console_id's tile, then stop.
    `plan` is the composite the server handed this client via `space`."""
    walkers = await client.next_walkers(space)
    me = client.character_in(walkers, client.character_id)
    start = (int(me.x // 1), int(me.y // 1))
    goal = console_tile(plan, console_id)
    path = find_path(plan, start, goal)
    assert path is not None, f"no walkable path {start} -> {goal} ({console_id})"
    await _follow(client, space, path)
```

- [ ] **Step 4: Run it, verify it passes**

Run: `python -m pytest test_walk.py -q`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add harness/walk.py harness/test_walk.py
git commit -m "test(harness): Python BFS walk driver, twin of walk.gleam (#33)"
```

---

### Task 4: Retrain `test_spawn_state` to the schema-3 wire shape

**Files:**
- Modify: `harness/test_m2_interior.py` (`test_spawn_state`, ~207–251; and the `tile_walkable`/`circle_walkable`/`_helm_center` helpers at the top)

**Interfaces:**
- Consumes: `deckplan.tile_walkable`, `deckplan.circle_walkable`, `walk.walk_to_console`, `walk.console_tile`.
- Produces: a green `test_spawn_state` and top-of-file helpers other tests in this file reuse — `_helm_center(space, ship_id)` now derived from the composite plan's `s{ship}:helm` console, not un-rotated math.

- [ ] **Step 1: Replace the schema-2 helpers at the top of the file**

Delete the local `tile_walkable`/`circle_walkable` defs (they read `plan["grid"]`/`plan["walkable"]`) and the un-rotated `_airlock_center_x`/`_helm_center`. Add at the top:

```python
from deckplan import circle_walkable, tile_walkable  # v3 (decks/glyph rows)
from walk import console_tile, walk_to_console

def _helm_center(space: dict, ship_id: int) -> tuple[float, float]:
    """Composite centre of ship_id's helm, from the plan the server sent —
    correct under the current CCW side-on mooring (no hardcoded rotation)."""
    tx, ty = console_tile(space["plan"], f"s{ship_id}:helm")
    return (tx + 0.5, ty + 0.5)
```

- [ ] **Step 2: Rewrite the `ship_class` assertions in `test_spawn_state`**

Replace the schema-2 block (`assert ship_class["schema"] == 2` … `spawn_tile == [5,4]` … `helm_main`/`cargo_main`) with the schema-3 shape:

```python
        ship_class = welcome["ship_class"]
        assert client.ship_class == ship_class
        assert ship_class["schema"] == 3
        assert ship_class["id"] == "sparrow"

        # v3: one flat deck of 3x3-glyph rows; consoles carry a deck index;
        # spawn is {deck, tile}. helm (1,2) and cargo (6,1) are the fixture's.
        assert len(ship_class["decks"]) == 1
        consoles = {c["id"]: c for c in ship_class["consoles"]}
        assert consoles["helm"]["kind"] == "helm"
        assert (consoles["helm"]["x"], consoles["helm"]["y"]) == (1, 2)
        assert consoles["cargo"]["kind"] == "cargo"
        assert (consoles["cargo"]["x"], consoles["cargo"]["y"]) == (6, 1)
        for c in ship_class["consoles"]:
            assert tile_walkable(ship_class, c["x"], c["y"], c.get("deck", 0))
        sd, (stx, sty) = ship_class["spawn"]["deck"], ship_class["spawn"]["tile"]
        assert tile_walkable(ship_class, stx, sty, sd)
```

Then update the seat assertion literals in the same test: `s{ship_id}:helm_main` → `s{ship_id}:helm`. The `_helm_center(space, ship_id)` call and the walkers position asserts below it stay as-is (now correct via the new helper).

- [ ] **Step 3: Run it**

Run (from `harness/`): `python -m pytest test_m2_interior.py::test_spawn_state -x -q`
Expected: PASS. (If the helm-centre asserts fail, print `space["plan"]["consoles"]` and confirm the driver/helper reads `s{ship}:helm`.)

- [ ] **Step 4: Commit**

```bash
git add harness/test_m2_interior.py
git commit -m "test(harness): retrain test_spawn_state to schema-3 wire (#33)"
```

---

### Task 5: Retrain the remaining `test_m2_interior.py` tests (walk/collide, seat rules, fly-with-crew)

**Files:**
- Modify: `harness/test_m2_interior.py` (`test_stand_walk_collide`, `test_seat_rules`, `test_one_flies_one_walks`)

**Interfaces:**
- Consumes: `walk.walk_to_console`, `walk.console_tile`, `deckplan.circle_walkable`.

- [ ] **Step 1: `test_seat_rules` — rename ids only**

`helm_main` → `helm`, `cargo_main` → `cargo` throughout this test (the `s{ship}:…` seat/console literals and the plain `helm`/`cargo` where it sits). No route logic here. Run:
`python -m pytest test_m2_interior.py::test_seat_rules -x -q` → PASS.

- [ ] **Step 2: `test_stand_walk_collide` — collision test, bespoke (not a route)**

This asserts physics (advance, pin against a wall, circle never leaves walkable). Rewrite it to: capture the composite plan, walk to the `cargo` console with the driver, then push further in the same direction until pinned, asserting `circle_walkable` on the composite plan throughout. Replace the body's walk/collision section with:

```python
        space = await client.next_space()
        plan = space["plan"]
        assert (await client.stand())["ok"] is True

        # Drive onto the cargo tile via the plan the server sent, then keep
        # pushing toward the far hull wall in the cargo->helm direction's
        # opposite until the position pins (bit-for-bit equal across samples).
        cargo_tx, cargo_ty = console_tile(plan, f"s{welcome['ship_id']}:cargo")
        await walk_to_console(client, SPAWN_STATION_SPACE, plan, f"s{welcome['ship_id']}:cargo")

        # Push toward increasing x until pinned; sample positions to assert the
        # collision circle stays walkable and x is monotonic then frozen.
        await client.move(1.0, 0.0)
        samples = []
        me = await walk_until_own(client, SPAWN_STATION_SPACE, lambda m: True)
        samples.append(me)
        prev = me
        for _ in range(40):
            later = await walkers_after_ticks(client, SPAWN_STATION_SPACE, 0, TICK_RATE // 2)
            m = client.character_in(later, char_id)
            samples.append(m)
            if m.x == prev.x:
                break
            prev = m
        await client.move(0.0, 0.0)
        assert len(samples) >= 2
        for s in samples:
            assert circle_walkable(plan, s.x, s.y), s
            assert s.seat is None
        xs = [s.x for s in samples]
        assert xs == sorted(xs)   # x only advanced (pushed +x)
```

Delete the now-unused `cargo_x`/`wall_x`/`near_wall_x`/`contact_x` un-rotated math and the `y == 2.5` row asserts (the corridor is rotated now; walkability is the invariant, not a fixed row). Run:
`python -m pytest test_m2_interior.py::test_stand_walk_collide -x -q` → PASS. If it never pins (open floor in +x), switch the push direction to `-1,0` or `0,±1` — pick whichever axis the plan shows a wall on from the cargo tile; keep the assertion set identical.

- [ ] **Step 3: `test_one_flies_one_walks` — replace the hardcoded aboard route with the driver**

Replace the whole "B stands and walks … onto A's deck (composite y <= 3.6)" block (the `stand`/`move`/`walk_until_own` ladder) with:

```python
        assert (await client_b.stand())["ok"] is True
        await walk_to_console(client_b, SPAWN_STATION_SPACE, space_b["plan"], f"s{ship_a}:helm")
```

Everything after (A undocks, B carried as crew, ship flies, B walks the hold, matched walkers) stays — but change the two seat literals `pilot.seat == "helm_main"` → `"helm"` and keep `walker.seat is None`. The `circle_walkable(ship_class, …)` calls now use the v3 parser (ship-local ship_class doc, deck 0). Run:
`python -m pytest test_m2_interior.py::test_one_flies_one_walks -x -q` → PASS.

- [ ] **Step 4: Full file green + commit**

Run: `python -m pytest test_m2_interior.py -q` → all PASS.
```bash
git add harness/test_m2_interior.py
git commit -m "test(harness): retrain test_m2_interior walk/collide/fly to v3 driver (#33)"
```

---

### Task 6: Retrain `test_m31_stitched.py`

**Files:**
- Modify: `harness/test_m31_stitched.py`

**Interfaces:** Consumes `walk.walk_to_console`, `walk.console_tile`, `deckplan.*`.

- [ ] **Step 1: Swap helpers and ids**

At the top, delete `_airlock_center_x` and the un-rotated math; import `from walk import walk_to_console, console_tile` and `from deckplan import circle_walkable, tile_walkable`. Rename all `helm_main`→`helm`, `cargo_main`→`cargo` (incl. `s{ship}:…` literals in `test_login_space_is_the_station_composite` and elsewhere). Keep `_mooring_dx` (it reads the wire — still valid).

- [ ] **Step 2: Replace the `test_undock_splits_by_tile` walk-aboard route**

Its manual "east to clear the airlock pinch, then north onto tiles" ladder (the `stayer.move(...)` / `walk_until` sequence, ~118–133) becomes a single driver call to the target ship's helm:

```python
        await walk_to_console(stayer, STATION_SPACE, stayer_login_space["plan"], f"s{pilot_ship_id}:helm")
```

Use whichever ship-id variable the test binds for the ship being boarded; if it isn't bound, bind it from that client's `welcome["ship_id"]`. Update the post-undock seat literal `helm_main`→`helm`.

- [ ] **Step 3: Run + commit**

Run: `python -m pytest test_m31_stitched.py -q` → all PASS.
```bash
git add harness/test_m31_stitched.py
git commit -m "test(harness): retrain test_m31_stitched to v3 driver (#33)"
```

---

### Task 7: Retrain `test_m3_trade.py`

**Files:**
- Modify: `harness/test_m3_trade.py`

**Interfaces:** Consumes `walk.walk_to_console`, `walk.console_tile`.

- [ ] **Step 1: Replace the route helpers with driver calls**

Delete `_airlock_center_x`, `_descend_to_broker`, `_walk_to_broker`, `_walk_broker_to_helm`, and the `BROKER_CENTER` constant. Their two call sites become:
- "walk to broker": `await walk_to_console(client, SPAWN_STATION_SPACE, space["plan"], "broker0")` (concourse broker id is `broker0` — confirm via `[c["id"] for c in space["plan"]["consoles"] if c["kind"]=="broker"]`; use that id).
- "walk back to helm": `await walk_to_console(client, SPAWN_STATION_SPACE, space["plan"], f"s{ship_id}:helm")`.

Capture `space = await client.next_space()` once after login and thread `space["plan"]` into the driver calls. Rename `helm_main`→`helm` in seat literals (e.g. `test_walk_ashore_and_back_is_just_walking`, `test_market_visible_while_docked_aboard`).

- [ ] **Step 2: Run + commit**

Run: `python -m pytest test_m3_trade.py -q` → all PASS.
```bash
git add harness/test_m3_trade.py
git commit -m "test(harness): retrain test_m3_trade to v3 driver (#33)"
```

---

### Task 8: Full harness green + PR

**Files:** none (verification + PR).

- [ ] **Step 1: Run the whole pytest harness**

Run (from `harness/`): `python -m pytest -q`
Expected: all pass, including the pre-existing `test_m1_flight.py` and `test_automation_smoke.py` (they don't touch interiors; if `test_automation_smoke` or `shot_m35_interior.py` reference a flat route, note them — the ticket lists `shot_m35_interior.py`'s route as stale too; fix any that break the run the same way, driver-first, or skip-with-reason if out of scope and say so explicitly).

- [ ] **Step 2: Sanity re-run the Gleam suite** (nothing here touches it, but confirm no accidental server-dir edits)

Run (from `server/`): `gleam test 2>&1 | tail -3`
Expected: `N passed, no failures`.

- [ ] **Step 3: Open the PR**

```bash
git push -u origin fix/issue-33-pytest-sparrow-fixture
gh pr create --base main --title "Retrain pytest harness: schema-3 sparrow fixture + Python walk driver (#33)" \
  --body "Completes the pytest half of #33. Restores a flat schema-3 \`sparrow\` test fixture (spawned via DH_SHIP_CLASS), ports the layout-robust walk driver to Python (harness/walk.py + harness/deckplan.py), and retrains the schema-2 wire-shape asserts and hardcoded un-rotated walk routes across test_m2_interior/test_m31_stitched/test_m3_trade. Console ids helm_main/cargo_main -> helm/cargo. Verified: full pytest harness green; Gleam suite unaffected."
```

---

## Self-Review Notes (for the executor)

- **Spec coverage:** Task 1 = restore sparrow + fixture (ticket option A). Tasks 2–3 = the walk-driver port (ticket option B, "applies to the walk portions"). Tasks 4–7 = the drifted asserts across all three named files. Task 8 flags `shot_m35_interior.py` / `test_automation_smoke.py` explicitly rather than silently skipping.
- **Biggest risk = Task 1's Q placement.** If mooring fails, diff your `Q`/wall rows against `server/shipclasses/mockingbird.json` (known-good) and iterate; the boot test catches it before anything downstream depends on it.
- **Do not** re-introduce hardcoded composite geometry anywhere — every position comes from `space["plan"]` / `space["moorings"]`. That is the whole point of the retraining and the reason the Gleam half needed the same driver.
- **If a test genuinely can't be expressed via the driver** (pure physics like the collision test), keep it directional but assert the *invariant* (`circle_walkable`) rather than a fixed row/column.
