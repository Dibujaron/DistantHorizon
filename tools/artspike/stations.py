"""stations — M3.5: station exteriors assembled from station data.

Iteration 3 redesign: the terminal bar IS the concourse. Each station's
walkable concourse grid (m1_system.json) maps onto the bar at 3 px/tile
(1 tile = 7.5 model units at px_per_unit 0.4), berth pads on the bar's
TOP edge at the authored berth tile columns, so the interior view can
draw this sprite as a to-scale backdrop under the walkable tiles and
moored ships nest visually into their berth cradles. The PHE hab ring +
hub + spokes hang below the bar — pure exterior, no interior space.

Heights stay authored per part: bar/spokes flat, pads proud, hub the one
deliberate dome, never whole-structure doming.

Run:  python stations.py   (exports to client/assets/stations/ + sheet)
"""
import math
import pathlib
import random

from composer import (Hull, Layer, Anchor, flat, dome, ExportSpec,
                      PHE_PALETTE, export_ship, build_debug_sheet)
from manufacturers import PHE_TRUSS, PHE_POD, PHE_GRAY, PHE_GRAY_D
from shipforge import (rrect, circle, line, group, container, BOXES,
                       INK, GLOW_CORE, WIN)

# 1 concourse tile = 7.5 model units; grid top edge at y = -60. These pin
# the ExportSpec interior blocks below — px_per_tile 3 at px_per_unit 0.4.
UNITS_PER_TILE = 7.5
GRID_Y0 = -60.0


def grid_x0(grid_w):
    """grid origin x: the bar is centered on the station's y axis"""
    return -grid_w * UNITS_PER_TILE / 2.0


def station_hull(grid_w, grid_h, berth_tiles, crane, seed):
    """grid_w/grid_h: the station's concourse grid (m1_system.json);
    berth_tiles: the berth stub tile columns (e.g. (6, 16, 26))"""
    rng = random.Random(seed)
    L, A = [], []
    x0 = grid_x0(grid_w)
    bar_w = grid_w * UNITS_PER_TILE
    bar_top = GRID_Y0 + 1.0 * UNITS_PER_TILE      # pads own rows 0-1
    bar_bot = GRID_Y0 + grid_h * UNITS_PER_TILE

    def tile_cx(tile_x):
        return x0 + (tile_x + 0.5) * UNITS_PER_TILE

    # spoke from bar down to the ring (drawn first: sits behind everything)
    L.append(Layer(rrect(-7, bar_bot - 4, 14, 44, 3, PHE_GRAY_D, sw=2),
                   flat(0.36)))
    # hab ring below: flat annulus, proud truss rims, portholes (paint)
    ring_cy = bar_bot + 82.0
    ring_r = min(52.0, bar_w * 0.42)
    L.append(Layer(circle(0, ring_cy, ring_r, "none", stroke=PHE_GRAY, sw=13),
                   flat(0.42)))
    L.append(Layer(circle(0, ring_cy, ring_r, "none", stroke=INK, sw=1.6)))
    L.append(Layer(circle(0, ring_cy, ring_r - 6.5, "none", stroke=PHE_TRUSS,
                          sw=2), flat(0.46)))
    L.append(Layer(circle(0, ring_cy, ring_r + 6.5, "none", stroke=PHE_TRUSS,
                          sw=2), flat(0.46)))
    ring_windows = ""
    for i in range(22):
        a = math.radians(i * 360 / 22)
        ring_windows += circle(ring_r * math.cos(a),
                               ring_cy + ring_r * math.sin(a), 1.7, WIN,
                               stroke="none", opacity=.9)
    L.append(Layer(ring_windows))
    # ring spokes + hub (the one deliberate dome). Spokes authored in ring-
    # local coords, rotated about the ring center via translate-then-rotate.
    for a in (0, 90, 180, 270):
        L.append(Layer(group(rrect(-4.5, -ring_r, 9, ring_r, 3, PHE_GRAY_D,
                                   sw=1.8), ty=ring_cy, rot=a), flat(0.38)))
    L.append(Layer(circle(0, ring_cy, 24, PHE_GRAY, sw=2.2),
                   dome(0.44, 0.58)))
    L.append(Layer(circle(0, ring_cy, 14, PHE_GRAY_D, sw=1.8)))
    hub_ticks = ""
    for i in range(8):
        hub_ticks += group(line(0, -17, 0, -22, INK, 1.4, .7),
                           ty=ring_cy, rot=i * 45 + 22.5)
    L.append(Layer(hub_ticks))
    # fuel tank cluster off the ring's lower-left
    L.append(Layer(line(-ring_r * 0.7, ring_cy + ring_r * 0.7,
                        -ring_r * 0.7 - 22, ring_cy + ring_r * 0.7 + 18,
                        PHE_GRAY_D, 4), flat(0.32)))
    tank_bx = -ring_r * 0.7 - 22
    tank_by = ring_cy + ring_r * 0.7 + 18
    for tx, ty in ((tank_bx + 4, tank_by - 3), (tank_bx - 8, tank_by + 9),
                   (tank_bx + 10, tank_by + 12)):
        L.append(Layer(circle(tx, ty, 10, PHE_GRAY, sw=1.8),
                       dome(0.34, 0.44, blur=2.0)))
    # comm mast off the bar's left end
    L.append(Layer(line(x0, bar_top + 10, x0 - 22, bar_top - 12, PHE_GRAY_D,
                        3), flat(0.30)))
    L.append(Layer(circle(x0 - 22, bar_top - 12, 7, PHE_GRAY, sw=1.8),
                   flat(0.36)))

    # THE TERMINAL BAR — the concourse lives in here (grid rows 2+)
    L.append(Layer(rrect(x0 - 5, bar_top, bar_w + 10, bar_bot - bar_top, 5,
                         PHE_GRAY, sw=2.5), flat(0.44)))
    # inner deck stripe (paint): the walkable rows below the pad row
    L.append(Layer(rrect(x0 + 2, GRID_Y0 + 2 * UNITS_PER_TILE, bar_w - 4,
                         (grid_h - 3) * UNITS_PER_TILE, 3, PHE_GRAY_D,
                         sw=1.4)))
    # window strip along the bar's south face (paint)
    bar_windows = ""
    for i in range(0, grid_w, 2):
        bar_windows += circle(x0 + (i + 1.0) * UNITS_PER_TILE, bar_bot - 5,
                              1.6, WIN, stroke="none", opacity=.85)
    L.append(Layer(bar_windows))

    # berth pads: proud cradles on the bar's TOP edge at the berth columns
    for b in berth_tiles:
        px = tile_cx(b)
        L.append(Layer(rrect(px - 9, GRID_Y0 - 2, 18, UNITS_PER_TILE + 6, 3,
                             PHE_POD, sw=1.8), flat(0.50)))
        L.append(Layer(rrect(px - 6.5, GRID_Y0 + 0.5, 13, UNITS_PER_TILE + 1,
                             2, PHE_GRAY_D, sw=1.2)))
        L.append(Layer(circle(px, GRID_Y0 + UNITS_PER_TILE * 0.5, 2.2,
                              GLOW_CORE, stroke="none"), role="glow"))
        # moored Mockingbird sprite center: the gangway meets the ship's
        # PORT dormer (ship col 2 of 7), so the hull center rides ONE TILE
        # EAST of the berth column; the grid hangs 9 tiles above the berth
        # row, sprite center 22.5 ship-px below sprite top -> 11.25 units
        # above the concourse top edge.
        A.append(Anchor("berth", px + UNITS_PER_TILE, GRID_Y0 - 11.25))

    # crane gantries flanking the outer pads: vertical booms + trolley + a
    # container mid-lift — the "crane-ness" seller, reaching up alongside
    # the moored ships
    if crane:
        crane_bs = ([berth_tiles[0], berth_tiles[-1]]
                    if len(berth_tiles) > 1 else [berth_tiles[0]])
        for b in crane_bs:
            px = tile_cx(b)
            ext = 46 if b <= grid_w // 2 else 38
            for side in (-13, 13):
                L.append(Layer(rrect(px + side - 2.5, GRID_Y0 - ext, 5, ext,
                                     2, PHE_GRAY_D, sw=1.4), flat(0.52)))
            ticks = ""
            for by in range(int(GRID_Y0 - ext) + 6, int(GRID_Y0) - 4, 9):
                ticks += line(px - 12, by, px - 8, by + 5, INK, 1.0, .55)
                ticks += line(px + 12, by, px + 8, by + 5, INK, 1.0, .55)
            L.append(Layer(ticks))
            ty = GRID_Y0 - ext + 6
            L.append(Layer(rrect(px - 11, ty - 5, 22, 10, 3, PHE_GRAY_D,
                                 sw=1.4), flat(0.54)))
            L.append(Layer(rrect(px - 4, ty - 3.5, 8, 7, 2, PHE_POD, sw=1.2),
                           flat(0.56)))
            L.append(Layer(line(px, ty + 5, px, ty + 16, "#9aa3ae", 1.2)))
            L.append(Layer(container(px - 6, ty + 16, 12, 9,
                                     rng.choice(BOXES)), flat(0.50)))

    # waiting containers on the bar deck (paint-height props)
    deck_y = GRID_Y0 + 2.2 * UNITS_PER_TILE
    for fx in (0.12, 0.34, 0.55, 0.72, 0.88):
        if grid_w < 20 and fx in (0.34, 0.72):
            continue  # the short bar takes fewer props
        L.append(Layer(container(x0 + fx * bar_w, deck_y, 11, 8,
                                 rng.choice(BOXES)), flat(0.48)))

    # PHE orange accent along the bar's south edge (paint) — thin: at the
    # interior's 21x backdrop scale every unit is ~8.5 screen px
    L.append(Layer(line(x0 + 14, bar_bot - 1.0, x0 + bar_w * 0.36,
                        bar_bot - 1.0, PHE_POD, 1.4, .8)))
    return Hull(layers=L, anchors=A)


def _interior(grid_w):
    return {"units_per_tile": UNITS_PER_TILE,
            "origin_units": (grid_x0(grid_w), GRID_Y0)}


STATION_EXPORTS = [
    # px_per_unit = 132/330 = 0.4 -> 3 px per 7.5-unit tile.
    # Meridian Highport: 34x6 concourse, berths at cols 6/16/26, crane.
    ExportSpec("ring_3berth_crane",
               lambda: station_hull(34, 6, (6, 16, 26), True, 11),
               132, 330, (), (), tuple(PHE_PALETTE), (0, 0, 0), (0, 0, 0),
               interior=_interior(34)),
    # Solis Ring: 12x5 concourse, one berth at col 5, no crane.
    ExportSpec("ring_1berth",
               lambda: station_hull(12, 5, (5,), False, 12),
               132, 330, (), (), tuple(PHE_PALETTE), (0, 0, 0), (0, 0, 0),
               interior=_interior(12)),
]


def main():
    root = pathlib.Path(__file__).parents[2]
    out_root = root / "client" / "assets" / "stations"
    for spec in STATION_EXPORTS:
        meta = export_ship(spec, out_root)
        print(f"exported {spec.name}: {meta['px_w']}x{meta['px_h']} px, "
              f"{len(meta['anchors'])} anchors, interior {meta['interior']}")
    build_debug_sheet(pathlib.Path(__file__).parent / "sheet_stations.png",
                      exports=STATION_EXPORTS)


if __name__ == "__main__":
    main()
