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
