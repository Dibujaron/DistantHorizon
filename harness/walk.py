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
