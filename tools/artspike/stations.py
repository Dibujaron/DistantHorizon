"""stations — M3.5 PR 2: station exteriors assembled from station data.

One archetype for now: the PHE ring station (hab ring + spokes + hub +
terminal bar), parameterized by berth count and crane flag, seeded greebles.
Geometry follows shipforge.station_crane_terminal; heights are authored per
part like ships — ring = flat annulus with a proud rim, spokes/bars flat,
hub a small dome, never whole-structure doming. Berth pads emit "berth"
anchors the client uses to park docked ships outboard of the pad.

Run:  python stations.py   (exports to client/assets/stations/ + sheet)
"""
import math
import pathlib
import random

from composer import (Hull, Layer, Anchor, flat, cyl_x, dome, ExportSpec,
                      PHE_PALETTE, export_ship, build_debug_sheet)
from manufacturers import PHE_TRUSS, PHE_POD, PHE_GRAY, PHE_GRAY_D, GLASS
from shipforge import (poly, rrect, circle, line, group, container, BOXES,
                       INK, GLOW_CORE, WIN)


def _berth_ys(berths):
    """pad centers, evenly spread over the terminal bar (y -78..78)"""
    if berths <= 1:
        return [0.0]
    span = 116.0
    step = span / (berths - 1)
    return [-span / 2 + i * step for i in range(berths)]


def station_hull(berths, crane, seed):
    rng = random.Random(seed)
    L, A = [], []
    # comm mast (behind the ring)
    L.append(Layer(line(-38, -38, -78, -78, PHE_GRAY_D, 3), flat(0.30)))
    L.append(Layer(circle(-78, -78, 9, PHE_GRAY, sw=2), flat(0.36)))
    L.append(Layer(line(-78, -78, -90, -90, PHE_GRAY, 2), flat(0.30)))
    # hab ring: flat annulus; ink rims are paint, truss edge rings sit proud
    L.append(Layer(circle(0, 0, 96, "none", stroke=PHE_GRAY, sw=15),
                   flat(0.42)))
    L.append(Layer(circle(0, 0, 96, "none", stroke=INK, sw=1.8)))
    L.append(Layer(circle(0, 0, 88.5, "none", stroke=PHE_TRUSS, sw=2),
                   flat(0.46)))
    L.append(Layer(circle(0, 0, 103.5, "none", stroke=PHE_TRUSS, sw=2),
                   flat(0.46)))
    ring_windows = ""
    for i in range(28):  # lit portholes around the ring (paint)
        a = math.radians(i * 360 / 28)
        ring_windows += circle(96 * math.cos(a), 96 * math.sin(a), 1.8, WIN,
                               stroke="none", opacity=.9)
    L.append(Layer(ring_windows))
    # spokes
    for a in (30, 150, 210, 330):
        L.append(Layer(group(rrect(-5, -92, 10, 92, 3, PHE_GRAY_D, sw=2),
                             rot=a), flat(0.38)))
    # hub: the one deliberate dome on the structure
    L.append(Layer(circle(0, 0, 42, PHE_GRAY, sw=2.5), dome(0.44, 0.58)))
    L.append(Layer(circle(0, 0, 26, PHE_GRAY_D, sw=2)))
    L.append(Layer(circle(0, 0, 9, PHE_GRAY_D, sw=1.8)))
    hub_ticks = ""
    for i in range(8):
        hub_ticks += group(line(0, -30, 0, -40, INK, 1.6, .7),
                           rot=i * 45 + 22.5)
    L.append(Layer(hub_ticks))
    # fuel tank cluster (lower-left)
    L.append(Layer(line(-70, 70, -100, 100, PHE_GRAY_D, 5), flat(0.32)))
    for tx, ty in ((-96, 88), (-112, 104), (-90, 112)):
        L.append(Layer(circle(tx, ty, 13, PHE_GRAY, sw=2),
                       dome(0.34, 0.44, blur=2.0)))
    # terminal: spoke out to the bar, bar, inner deck (paint), berth pads
    L.append(Layer(rrect(96, -16, 34, 32, 4, PHE_GRAY_D, sw=2), flat(0.40)))
    L.append(Layer(rrect(128, -78, 26, 156, 6, PHE_GRAY, sw=2.5), flat(0.44)))
    L.append(Layer(rrect(133, -70, 16, 140, 4, PHE_GRAY_D, sw=1.4)))
    pad_ys = _berth_ys(berths)
    for by in pad_ys:
        L.append(Layer(rrect(152, by - 13, 10, 26, 3, PHE_POD, sw=1.6),
                       flat(0.50)))
        L.append(Layer(circle(157, by, 2.6, GLOW_CORE, stroke="none"),
                       role="glow"))
        A.append(Anchor("berth", 172, by))
    # crane gantries over the outermost pads: boom pair + trolley + a
    # container mid-lift on a cable — the "crane-ness" seller
    if crane:
        crane_ys = [pad_ys[0], pad_ys[-1]] if len(pad_ys) > 1 else [pad_ys[0]]
        for by in crane_ys:
            ext = 62 if by <= 0 else 48
            L.append(Layer(rrect(148, by - 20, ext, 6, 2, PHE_GRAY_D, sw=1.6),
                           flat(0.52)))
            L.append(Layer(rrect(148, by + 14, ext, 6, 2, PHE_GRAY_D, sw=1.6),
                           flat(0.52)))
            ticks = ""
            for bx in range(156, 148 + int(ext) - 4, 12):
                ticks += line(bx, by - 19, bx + 6, by - 15, INK, 1.1, .55)
                ticks += line(bx, by + 15, bx + 6, by + 19, INK, 1.1, .55)
            L.append(Layer(ticks))
            tx = 148 + ext - 10
            L.append(Layer(rrect(tx - 7, by - 22, 14, 44, 3, PHE_GRAY_D,
                                 sw=1.6), flat(0.54)))
            L.append(Layer(rrect(tx - 5, by - 8, 10, 16, 2, PHE_POD, sw=1.4),
                           flat(0.56)))
            L.append(Layer(line(tx, by + 8, tx, by + 26, "#9aa3ae", 1.4)))
            L.append(Layer(container(tx - 8, by + 26, 16, 12,
                                     rng.choice(BOXES)), flat(0.50)))
    # waiting containers on the bar deck
    for cy in (-34, -20, 24):
        L.append(Layer(container(134, cy, 14, 11, rng.choice(BOXES)),
                       flat(0.48)))
    # PHE orange ring accent (paint)
    a0, a1 = math.radians(200), math.radians(250)
    L.append(Layer(
        f'<path d="M {103.5 * math.cos(a0):.1f} {103.5 * math.sin(a0):.1f} '
        f'A 103.5 103.5 0 0 1 {103.5 * math.cos(a1):.1f} '
        f'{103.5 * math.sin(a1):.1f}" fill="none" stroke="{PHE_POD}" '
        f'stroke-width="6"/>'))
    return Hull(layers=L, anchors=A)


STATION_EXPORTS = [
    ExportSpec("ring_3berth_crane", lambda: station_hull(3, True, 11),
               132, 330, (), (), tuple(PHE_PALETTE), (0, 0, 0), (0, 0, 0)),
    ExportSpec("ring_1berth", lambda: station_hull(1, False, 12),
               132, 330, (), (), tuple(PHE_PALETTE), (0, 0, 0), (0, 0, 0)),
]


def main():
    root = pathlib.Path(__file__).parents[2]
    out_root = root / "client" / "assets" / "stations"
    for spec in STATION_EXPORTS:
        meta = export_ship(spec, out_root)
        print(f"exported {spec.name}: {meta['px_w']}x{meta['px_h']} px, "
              f"{len(meta['anchors'])} anchors")
    build_debug_sheet(pathlib.Path(__file__).parent / "sheet_stations.png",
                      exports=STATION_EXPORTS)


if __name__ == "__main__":
    main()
