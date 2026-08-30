"""manufacturers — spike round 2: Classic DH manufacturer design languages,
rebuilt as parts vocabularies in the shipforge flat-vector style.

Sources: "Distant Horizon: Ship Manufacturer Design Cues" writeup + Classic
client sprites (client/sprites/ships/{PHE,Rijay,RADI}). Classic sprites are
21-64 px tall and use c1/c2/constant_color layers (two player-tintable livery
channels over fixed detail) — both facts carried into this spike: the sheet
ends with a strip rendered at Classic's in-game scale.

Round 2.1 notes from review: Thumper N = N container bays (24 -> 6x4 grid,
6 -> 3x2), containers seat in the bays; Longhorn is a hammerhead (sprite file
is literally Hammerhead.png); Mockingbird
is Republic-cruiser-plus-Firefly-neck with fins around the engine block;
Swallow is stocky with straight leading-edge wings; RADI hulls are
coke-bottled (bezier paths, not polygons).

Run:  pip install resvg-py && python manufacturers.py
"""
import math
import random
import resvg_py
from composer import Hull, Layer, Anchor, flat, cyl_x, dome, flatten
from shipforge import (poly, mirror, rrect, circle, line, group, shrink,
                       container, starfield, label, BG, INK, LABEL, BOXES,
                       GLOW_CORE)

# ------------------------------------------------- manufacturer palettes ----
# PHE: industrial. White truss, orange blocky pods, gray modules, cyan glass.
PHE_TRUSS = "#dfe3e6"
PHE_POD = "#d97a28"
PHE_POD_D = "#a85a1e"
PHE_GRAY = "#8a8f97"
PHE_GRAY_D = "#686d75"
GLASS = "#5fd8e8"

# Rijay: speed. Bright blue hulls, white dorsal stripe, big visible engines.
RIJ_BLUE = "#3b8de0"
RIJ_BLUE_D = "#2a66a8"
RIJ_WHITE = "#eef2f6"

# RADI: money. Deep red, gray trim, split bow, recessed engines.
RADI_RED = "#c92f2f"
RADI_RED_D = "#8f1f1f"
RADI_RED_HI = "#de4b4b"
RADI_TRIM = "#9aa0a8"

# ------------------------------------------------------------ path helper ----
def mirrored_path(start, segs, fill, stroke=INK, sw=2.5, opacity=1.0):
    """Smooth symmetric hull. `start` on the centerline; `segs` walk the RIGHT
    side top->bottom, each ('L', x, y) or ('Q', cx, cy, x, y), ending on the
    centerline. The left side is emitted mirrored automatically."""
    x0, y0 = start
    d = f"M {x0:.1f},{y0:.1f}"
    ends = [start]
    for seg in segs:
        if seg[0] == "L":
            d += f" L {seg[1]:.1f},{seg[2]:.1f}"
            ends.append((seg[1], seg[2]))
        else:
            d += f" Q {seg[1]:.1f},{seg[2]:.1f} {seg[3]:.1f},{seg[4]:.1f}"
            ends.append((seg[3], seg[4]))
    for i in range(len(segs) - 1, -1, -1):
        seg = segs[i]
        tx, ty = ends[i]
        if seg[0] == "L":
            d += f" L {-tx:.1f},{ty:.1f}"
        else:
            d += f" Q {-seg[1]:.1f},{seg[2]:.1f} {-tx:.1f},{ty:.1f}"
    d += " Z"
    return (f'<path d="{d}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" '
            f'stroke-linejoin="round" opacity="{opacity}"/>')

# ------------------------------------------------------------- PHE parts ----
def phe_rack(top, rows, cols, bw=24, bh=19):
    """container rack, done the Classic way: struts protrude outward from a
    central spine, each with small brackets that grip the containers. The
    row struts do NOT connect to each other — no outer rails, no grid."""
    w = cols * bw
    s = line(0, top - 6, 0, top + rows * bh + 2, PHE_TRUSS, 4)  # single spine
    slots = []
    for j in range(rows):
        y = top + (j + .5) * bh
        s += line(-w / 2 - 6, y, w / 2 + 6, y, PHE_TRUSS, 3)
        for i in range(cols + 1):  # container-gripping brackets
            x = -w / 2 + i * bw
            if abs(x) < 1:  # skip the center one — the spine is there
                continue
            s += line(x, y - 6.5, x, y + 6.5, PHE_TRUSS, 2.5)
        for i in range(cols):
            slots.append((-w / 2 + (i + .5) * bw, y))
    return s, slots

def phe_fill_bays(bays, bw, bh, fill_count, seed):
    """seat containers IN the slots, snug to the rails"""
    rng = random.Random(seed)
    s = ""
    for cx, cy in rng.sample(bays, fill_count):
        s += container(cx - bw / 2 + 2.5, cy - bh / 2 + 2.5, bw - 5, bh - 5,
                       rng.choice(BOXES))
    return s

def phe_mast(y, w):
    """topmast crossbar with orange tips — the Thumper's antenna"""
    s = line(0, y, 0, y + 16, PHE_TRUSS, 3.5)
    s += line(-w / 2, y, w / 2, y, PHE_TRUSS, 3)
    for sx in (-1, 1):
        s += line(sx * w / 2, y - 6, sx * w / 2, y + 6, PHE_POD, 4.5)
    return s

def phe_pod(cx, cy, w, h, nozzled=True):
    """blocky orange engine/equipment pod, sharp corners"""
    s = rrect(cx - w / 2, cy - h / 2, w, h, 2.5, PHE_POD, sw=2.2)
    s += rrect(cx - w / 2 + 3, cy - h / 2 + 3, w - 6, h * .28, 1.5, PHE_POD_D,
               stroke="none")
    if nozzled:
        s += poly([(cx - w * .3, cy + h / 2), (cx + w * .3, cy + h / 2),
                   (cx + w * .38, cy + h / 2 + 8), (cx - w * .38, cy + h / 2 + 8)],
                  PHE_GRAY_D, sw=1.8)
        s += (f'<ellipse cx="{cx}" cy="{cy + h / 2 + 12:.1f}" rx="{w * .3:.1f}" '
              f'ry="6" fill="url(#glow)"/>')
    return s

def phe_strut_cockpit(cy, w, h):
    """glass module with visible struts across the canopy"""
    s = rrect(-w / 2, cy, w, h, 2.5, PHE_GRAY, sw=2)
    s += rrect(-w / 2 + 3, cy + 3, w - 6, h - 6, 1.5, GLASS, stroke=INK, sw=1.2)
    for fx in (-w * .18, 0, w * .18):
        s += line(fx, cy + 2, fx, cy + h - 2, INK, 1.6)
    s += line(-w / 2 + 2, cy + h * .5, w / 2 - 2, cy + h * .5, INK, 1.4)
    return s

def ship_thumper24():
    """24 = 24 bays: a 6x4 rack, containers seated in slots. Part loaded."""
    s = phe_mast(-128, 64)
    rack, bays = phe_rack(-112, 6, 4)
    s += rack
    s += phe_fill_bays(bays, 24, 19, 14, seed=24)
    s += phe_strut_cockpit(8, 34, 24)
    for px, py in [(-38, 58), (0, 64), (38, 58)]:
        s += line(px * .4, 34, px, py - 18, PHE_TRUSS, 2.5)
        s += phe_pod(px, py, 28, 38)
    return s

def ship_thumper6():
    """6 = 6 bays: a 3x2 rack, same language at tug size"""
    s = phe_mast(-76, 40)
    rack, bays = phe_rack(-60, 3, 2)
    s += rack
    s += phe_fill_bays(bays, 26, 19, 4, seed=6)
    s += phe_strut_cockpit(2, 28, 20)
    s += phe_pod(0, 42, 26, 32)
    for sx in (-1, 1):
        s += line(sx * 10, 26, sx * 22, 36, PHE_TRUSS, 2.5)
        s += phe_pod(sx * 26, 42, 14, 20)
    return s

def ship_longhorn():
    """barebones passenger liner, sprite name Hammerhead: wide cephalofoil
    bow with top glass, orange-ribbed neck, big gridded lounge glass aft,
    cross-outrigger engine pods. Returns a Hull (lit-pipeline layers with
    authored heights) — the hammer foil is the pipeline's flat-plate proof:
    a thin wing that must NOT shade as a domed blob."""
    L = []
    A = []
    # stern outriggers first (under body): crossbar + orange-capped pods
    L.append(Layer(rrect(-46, 26, 92, 8, 2, PHE_GRAY_D, sw=2), flat(0.30)))
    for sx in (-1, 1):
        L.append(Layer(rrect(sx * 40 - 7, 18, 14, 24, 3, PHE_GRAY, sw=2),
                       cyl_x(0.32, 0.50)))
        L.append(Layer(rrect(sx * 49 - 3, 16, 6, 28, 2, PHE_POD, sw=1.8),
                       flat(0.45)))
        L.append(Layer(poly([(sx * 40 - 5, 42), (sx * 40 + 5, 42),
                             (sx * 40 + 6, 49), (sx * 40 - 6, 49)],
                            PHE_GRAY_D, sw=1.6), flat(0.28)))
        L.append(Layer(f'<ellipse cx="{sx * 40}" cy="52" rx="6" ry="5" '
                       f'fill="url(#glow)"/>', role="glow"))
        # The Longhorn is decorative parked traffic with no hull document —
        # these ids are documentation, not a cross-tree contract.
        A.append(Anchor("mount", sx * 40, 52,
                        id="engine_port" if sx < 0 else "engine_stbd"))
    # the hammer: thin, winglike, purpose unclear (ask Porter)
    hammer = mirror([(0, -108), (18, -107), (38, -102), (50, -94), (46, -86),
                     (28, -82), (10, -80), (0, -80)])
    L.append(Layer(poly(hammer, PHE_GRAY, sw=2.5), flat(0.40)))
    L.append(Layer(poly(shrink(hammer, .84), "#9aa0a8", stroke="none",
                        opacity=.45), role="sheet_only"))
    for sx in (-1, 1):  # small orange wingtip caps, nothing weirder
        L.append(Layer(rrect(sx * 48 - 4, -96, 8, 9, 1.5, PHE_POD, sw=1.6),
                       flat(0.44)))
    for wx in (-32, -16, 0, 16, 32):  # observation windows along the foil
        L.append(Layer(rrect(wx - 3, -98, 6, 7, 1.5, GLASS, stroke=INK,
                             sw=1.1)))
    for sx in (-1, 1):  # panel seams + vents so the foil isn't a blank
        L.append(Layer(line(sx * 10, -104, sx * 40, -99, INK, 1.2, .5)))
        for vx in (24, 30, 36):
            L.append(Layer(line(sx * vx, -87, sx * (vx + 4), -85, INK, 1.6,
                                .55)))
    # glass block at the hammer's top center
    L.append(Layer(rrect(-11, -120, 22, 15, 3, PHE_GRAY, sw=2), flat(0.46)))
    L.append(Layer(rrect(-8, -117, 16, 9, 1.5, GLASS, stroke=INK, sw=1.2)))
    L.append(Layer(line(0, -117, 0, -108, INK, 1.4)))
    # the neck: ribbed, windows down the middle
    L.append(Layer(rrect(-14, -80, 28, 70, 2, PHE_GRAY, sw=2.2),
                   cyl_x(0.42, 0.58)))
    for i in range(3):
        y = -72 + i * 21
        for rx in (-21, 14):
            L.append(Layer(rrect(rx, y, 7, 10, 1.5, PHE_POD, sw=1.6),
                           flat(0.50)))
        L.append(Layer(rrect(-3.5, y + 2, 7, 8, 1.5, GLASS, stroke=INK,
                             sw=1.1)))
    # lower body: wide oval with the big gridded lounge glass
    lower = mirror([(0, -12), (15, -9), (23, 2), (27, 22), (24, 46), (15, 60),
                    (0, 64)])
    L.append(Layer(poly(lower, PHE_GRAY, sw=2.5), dome(0.36, 0.60, blur=6.0)))
    L.append(Layer(poly(shrink(lower, .84), "#9aa0a8", stroke="none",
                        opacity=.45), role="sheet_only"))
    L.append(Layer(rrect(-14, 2, 28, 48, 11, GLASS, stroke=INK, sw=1.8)))
    for fx in (-4.5, 4.5):
        L.append(Layer(line(fx, 4, fx, 48, INK, 1.3)))
    for i in range(3):
        L.append(Layer(line(-13, 14 + i * 12, 13, 14 + i * 12, INK, 1.3)))
    # stern nub
    L.append(Layer(poly([(-8, 64), (8, 64), (6, 70), (-6, 70)], PHE_GRAY_D,
                        sw=1.8), flat(0.38)))
    return Hull(layers=L, anchors=A)

# ----------------------------------------------------------- Rijay parts ----
def rijay_hull(half, stripe=True):
    """blue hull with white dorsal stripe"""
    outline = mirror(half)
    s = poly(outline, RIJ_BLUE, sw=2.5)
    s += poly(shrink(outline, .8), "#5aa3ea", stroke="none", opacity=.5)
    if stripe:
        top = half[0][1]; bot = half[-1][1]
        s += poly([(-3, top + 8), (3, top + 8), (4.5, bot - 14), (-4.5, bot - 14)],
                  RIJ_WHITE, sw=1.2)
    return s

def rijay_engine_bank(y, w, n):
    """the point of a Rijay: engines you can see from the next orbit over"""
    s = rrect(-w / 2, y, w, 16, 3, RIJ_BLUE_D, sw=2.2)
    for i in range(3):
        s += line(-w / 2 + 3, y + 4 + i * 4, w / 2 - 3, y + 4 + i * 4,
                  RIJ_WHITE, 1.6, .8)
    step = w / n
    for i in range(n):
        cx = -w / 2 + step * (i + .5)
        s += poly([(cx - step * .3, y + 16), (cx + step * .3, y + 16),
                   (cx + step * .38, y + 27), (cx - step * .38, y + 27)],
                  PHE_GRAY_D, sw=1.8)
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + 32:.1f}" rx="{step * .34:.1f}" '
              f'ry="8" fill="url(#glow)"/>')
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + 29:.1f}" rx="{step * .2:.1f}" '
              f'ry="4.5" fill="{GLOW_CORE}" stroke="none"/>')
    return s

def rijay_cockpit(cy, w):
    """forward canopy, right where the writeup says it goes"""
    return rrect(-w / 2, cy, w, 13, 5, GLASS, stroke=INK, sw=1.6)

# --- Mockingbird, locked 2026-07-17 after spike round 4.9 (mockingbird_iter.py).
# Canon: goose proportions (plumpness 1.0 — "a goose, not a falcon"), hybrid head,
# head-tip canopy with struts (Firefly), one smooth flowing hull nose->stern (the
# engine support IS the hull), three separated cylindrical drums (Republic Cruiser
# ref; individually swappable — the repossessed starter has a Consol drum in the
# middle), waist docking-port dormers (hull-colored, seamless inboard, door
# outboard; same top/bottom unseen), white stripes: dorsal (meets center drum) +
# flank centerlines (break at ports, brief reconnect on the flare). The drums
# are a PART now (M4 iteration 2c): the hull carries a faired-over blanking
# plate per mount and the outboard wing pair only; the dorsal ridge (the
# ATMO-LANDING PACKAGE) travels with the Rijay drum part as its fairing. Two
# colors; dark blue only on small practical bits. Blue/white become the c1/c2
# livery channels at composer time.

MB_Y, MB_SP, MB_R, MB_LN, MB_FL = 40, 21, 7.5, 28, 0.8

def rij_mount_plates(centres, y, r, size=1.0):
    """-> (layers, mount anchors). A faired-over hardpoint per mount: plate
    plus bolt ring, drawn by the HULL so an empty mount still reads
    deliberate. `centres` is [(x, mount_id), ...] on the transom at `y`;
    `size` scales the plate for an `s` vs `m` mount, which is a free
    readability win — you can see which hardpoint takes the big engine."""
    layers, anchors = [], []
    for cx, mount_id in centres:
        pr = r * size
        layers.append(Layer(rrect(cx - pr * .82, y - 1.5, pr * 1.64, 6.0, 2.0,
                                  RIJ_BLUE_D, sw=1.6), flat(0.30)))
        for by in (y + 0.6, y + 3.4):   # bolt ring
            layers.append(Layer(circle(cx - pr * .5, by, .7, INK,
                                       stroke="none")))
            layers.append(Layer(circle(cx + pr * .5, by, .7, INK,
                                       stroke="none")))
        anchors.append(Anchor("mount", cx, y, id=mount_id))
    return layers, anchors

def mb_mount_plates():
    """-> (layers, mount anchors). Structure stays with the hull, equipment
    goes on the part: each hardpoint is a faired-over plate on the flare's
    shoulder (y=MB_Y, ~18 units fore of the y=62 stern edge — where the
    drums' fore face used to sit, so a fitted part lands where the drums
    were) that a fitted engine covers, so an EMPTY mount still reads
    deliberate. The Sparrow needs this immediately — she ships
    engine_center bare."""
    return rij_mount_plates(
        [(-MB_SP, "engine_port"), (0, "engine_center"), (MB_SP, "engine_stbd")],
        MB_Y, MB_R)

def mb_outboard_fins():
    """It is a wing, not a drive fairing: only the outer two drums ever
    carried one, and it is re-rooted onto the hull's stern flare (inside the
    transom at y=62) now that there is no drum transom for it to overhang."""
    y, r, fl = MB_Y, MB_R, MB_FL
    layers = []
    for sx in (-1, 1):  # rooted on the stern flare, inside the transom
        root = sx * MB_SP
        tips = [(root + sx * (r + 8.5 * fl), y + 7),
                (root + sx * (r + 9.5 * fl), y + 17),
                (root + sx * (r + 5.5 * fl), y + 19)]
        layers.append(Layer(poly([(root, y - 6)] + tips + [(root, y + 19)],
                                 RIJ_BLUE, sw=1.8), flat(0.33)))
        edge = " L ".join(f"{x - sx * 2.2:.1f},{yy + .8:.1f}" for x, yy in tips)
        layers.append(Layer(
            f'<path d="M {edge}" fill="none" stroke="{RIJ_WHITE}" '
            f'stroke-width="2" stroke-linecap="round" '
            f'stroke-linejoin="round" opacity=".95"/>'))
    return layers

def mb_ports(y=27, edge=16):
    layers = []
    for sx in (-1, 1):  # hull-colored dormers, seamless at the inboard edge
        x0 = edge - 2 if sx > 0 else -(edge + 5.2)
        layers.append(Layer(rrect(x0, y, 7.2, 10, 2.5, RIJ_BLUE, stroke=INK,
                                  sw=1.6), flat(0.52)))
        px = edge - 4.5 if sx > 0 else -(edge + .2)
        layers.append(Layer(rrect(px, y + .9, 4.7, 8.2, 0, RIJ_BLUE,
                                  stroke="none")))
        layers.append(Layer(rrect(x0 + (3.6 if sx > 0 else .8), y + 2.8, 2.8,
                                  4.4, 1.1, RIJ_BLUE_D, stroke=INK, sw=.9)))
        for by in (y + 2.4, y + 7.6):
            layers.append(Layer(circle(sx * (edge + .6), by, .8, GLASS,
                                       stroke="none")))
    return layers

def mb_canopy(nose_y=-104):
    """the window IS the head tip, with struts — the Firefly cockpit read"""
    layers = [Layer(mirrored_path((0, nose_y + 2.5), [
        ("L", 6, nose_y + 9),
        ("Q", 7.5, nose_y + 14, 6.5, nose_y + 19),
        ("L", 0, nose_y + 22)], GLASS, stroke=INK, sw=1.6),
        dome(0.58, 0.74, blur=2.0))]
    layers.append(Layer(line(0, nose_y + 3, 0, nose_y + 21, INK, 1.4)))
    layers.append(Layer(line(-6.2, nose_y + 13, 6.2, nose_y + 13, INK, 1.3)))
    return layers

def part_engine_rijay():
    """The Rijay drum — Stork 240-C2. Authored at the ORIGIN with its attach
    point at the drum's fore face, so the composer can place it against any
    hull's mount anchor. The dorsal ridge comes with it: the MB_FL fin is a
    drum fairing, not ship structure, which is why a Consol nacelle reads as
    visibly aftermarket with no extra art."""
    r, ln, fl = MB_R, MB_LN, MB_FL
    layers = [
        Layer(rrect(-r, 0, 2 * r, ln, r * .95, RIJ_BLUE, sw=2.2),
              cyl_x(0.40, 0.78)),
        Layer(rrect(-r * .72, ln - 2.5, r * 1.44, 5.5, 2.2, RIJ_BLUE_D,
                    sw=1.6), cyl_x(0.38, 0.60)),
        # dorsal ridge: thin from above, runs the drum and overhangs aft
        Layer(poly([(0, 3), (1.9, 8), (1.9, ln - 2), (1.2, ln + 7 * fl),
                    (0, ln + 9 * fl), (-1.2, ln + 7 * fl), (-1.9, ln - 2),
                    (-1.9, 8)], RIJ_WHITE, stroke=INK, sw=1.0), flat(0.82)),
        Layer(f'<ellipse cx="0" cy="{ln + 8:.1f}" rx="{r * .85:.1f}" '
              f'ry="10" fill="url(#glow)"/>', role="glow"),
        Layer(f'<ellipse cx="0" cy="{ln + 3.5:.1f}" rx="{r * .5:.1f}" '
              f'ry="5.5" fill="{GLOW_CORE}" stroke="none"/>', role="glow"),
    ]
    # The attach point is the drum's fore face on its centreline — it lands
    # on the hull's mount anchor.
    return Hull(layers=layers, anchors=[Anchor("attach", 0.0, 0.0)])

def part_engine_consol():
    """Consolidated CO-17F Block 2 — the aftermarket nacelle in the starter
    Mockingbird's centre mount. Consol grey-orange, squarer than a Rijay drum,
    and NO dorsal ridge: that ridge is a Rijay fairing, so a mixed fit reads
    as mixed on sight. Keeps its maker's colours rather than taking the
    ship's livery.

    The nozzle-mouth trapezoid is deliberately left paint-only (no authored
    height): it renders better this way — compose_ship's paint-fringe
    handling hands it the drum's own cyl_x cross-section, so it reads as a
    rounded bell instead of the flat ledge an authored flat(...) height
    would produce. This is unrelated to the dorsal-ridge distinction; a
    future Consol part is free to author a flat panel of its own without
    breaking any test's assumptions (see test_consol_engine_has_no_dorsal_ridge,
    which looks for the RIJ_WHITE ridge layer specifically, not for flat
    layers in general)."""
    w, ln = MB_R * 1.75, MB_LN * 0.92
    layers = [
        Layer(rrect(-w / 2, 0, w, ln, 2.5, PHE_POD, sw=2.2), cyl_x(0.36, 0.70)),
        Layer(rrect(-w / 2 + 3, 3, w - 6, ln * .26, 1.5, PHE_POD_D,
                    stroke="none")),
        Layer(poly([(-w * .3, ln), (w * .3, ln), (w * .38, ln + 7),
                    (-w * .38, ln + 7)], PHE_GRAY_D, sw=1.8)),
        Layer(f'<ellipse cx="0" cy="{ln + 9:.1f}" rx="{w * .42:.1f}" '
              f'ry="9" fill="url(#glow)"/>', role="glow"),
        Layer(f'<ellipse cx="0" cy="{ln + 5:.1f}" rx="{w * .26:.1f}" '
              f'ry="5" fill="{GLOW_CORE}" stroke="none"/>', role="glow"),
    ]
    return Hull(layers=layers, anchors=[Anchor("attach", 0.0, 0.0)])

def part_engine_wren():
    """Rijay Wren 90-B — size `s`, the Sparrow's engine. The Stork's drum at
    two-thirds scale with a shorter ridge: same family, smaller sister."""
    r, ln, fl = MB_R * 0.68, MB_LN * 0.62, MB_FL * 0.7
    layers = [
        Layer(rrect(-r, 0, 2 * r, ln, r * .95, RIJ_BLUE, sw=2.0),
              cyl_x(0.34, 0.66)),
        Layer(rrect(-r * .72, ln - 2.0, r * 1.44, 4.0, 1.8, RIJ_BLUE_D,
                    sw=1.4), cyl_x(0.32, 0.52)),
        Layer(poly([(0, 2), (1.5, 6), (1.5, ln - 2), (1.0, ln + 5 * fl),
                    (0, ln + 6 * fl), (-1.0, ln + 5 * fl), (-1.5, ln - 2),
                    (-1.5, 6)], RIJ_WHITE, stroke=INK, sw=0.9), flat(0.72)),
        Layer(f'<ellipse cx="0" cy="{ln + 6:.1f}" rx="{r * .85:.1f}" '
              f'ry="7" fill="url(#glow)"/>', role="glow"),
        Layer(f'<ellipse cx="0" cy="{ln + 2.5:.1f}" rx="{r * .5:.1f}" '
              f'ry="4" fill="{GLOW_CORE}" stroke="none"/>', role="glow"),
    ]
    return Hull(layers=layers, anchors=[Anchor("attach", 0.0, 0.0)])


def ship_mockingbird():
    """Rijay's flagship and the game's starter ship. See canon block above.
    Returns a Hull: ordered lit-pipeline layers with authored heights. Her
    ENGINES are not here — they are parts, layered at her mount anchors by
    the client (M4 iteration 2c). `stock` is gone with them: finned vs
    finless is a part distinction now."""
    layers = mb_outboard_fins()
    segs = [("L", 8, -95),                    # hybrid head
            ("Q", 10, -90, 9, -84),
            ("L", 8.5, -78),
            ("L", 9, -62),                    # short thick neck
            ("L", 24, -34),                   # shoulder kink
            ("Q", 27, -18, 27, -4),           # fat breast, widest low
            ("L", 19.5, 22),                  # taper
            ("Q", 15, 30, 14, 38),            # the narrows — the waist
            ("Q", 16, 44, 24, 47),            # flare into the engine support
            ("L", 26.5, 52),
            ("L", 26.5, 59),                  # solid stern, drums ride on it
            ("Q", 25, 62, 18, 62),
            ("L", 0, 62)]
    layers.append(Layer(mirrored_path((0, -104), segs, RIJ_BLUE, sw=2.5),
                        dome(0.35, 0.62, blur=8.0)))
    hi = mirrored_path((0, -104), segs, "#5aa3ea", stroke="none", opacity=.5)
    layers.append(Layer(group(hi, ty=-4, scale=.85), role="sheet_only"))
    # dorsal stripe runs aft to meet the center drum; no outline — it's paint
    layers.append(Layer(poly([(-2, -90), (2, -90), (3.5, 44), (-3.5, 44)],
                             RIJ_WHITE, stroke="none")))
    # flank stripes: break at the ports, brief reconnect on the flare
    for pts in ([(8.5, -76), (9, -62), (24, -34), (27, -18), (27, -4),
                 (19.5, 22)], [(17, 41), (22.5, 46.5)]):
        for sx in (-1, 1):
            d = "M " + " L ".join(f"{sx * (x - 2.4):.1f},{y:.1f}" for x, y in pts)
            layers.append(Layer(
                f'<path d="{d}" fill="none" stroke="{RIJ_WHITE}" '
                f'stroke-width="2.2" stroke-linecap="round" '
                f'stroke-linejoin="round" opacity=".9"/>'))
    plate_layers, anchors = mb_mount_plates()
    layers += plate_layers
    layers += mb_ports()
    layers += mb_canopy()
    return Hull(layers=layers, anchors=anchors)

# --- Sparrow, iteration 2c Task 12. Rijay's packet courier and the game's
# smallest hull: lore.md calls her "visually like a small mockingbird
# without the central bulging cargo section" -- so the goose's fat-breast
# waist is gone on purpose; her body runs nearly parallel-sided from the
# cockpit straight through the pod bay, only flaring at the very stern where
# her three `s` mounts sit. Her cockpit slot (`rijay.cockpit.solo_3x1`) is
# one full-width row, not a narrow needle nose like the Mockingbird's hybrid
# head, so the bow is drawn blunt and nearly as wide as the body from the
# start -- "the Toyota Corolla of space fighters," not a dart.
# Her shipclass document (server/shipclasses/sparrow.json) authors a 5 x 7
# tile deck grid (32.5 x 45.5 model units at the 6.5-units-per-tile canon)
# and NO MORE -- unlike the Mockingbird's own grid, which reserves extra
# void rows past her walkable footprint for the drum bay, the Sparrow's grid
# ends at her dock-port row plus one closing void row. The client's walk
# backdrop scales her exported sprite so ITS tile pitch matches 64 px/tile
# and pins deckplan tile (0,0) -- the grid's own TOP-LEFT corner, void
# columns included -- to the sprite's own top-left corner (see
# interior_view.gd's `_update_backdrops`). That "top-left, not centre" pin
# is the trap for a LEFT-RIGHT SYMMETRIC hull: `hull_frame` centres the
# frame on whatever the art's own widest point is, so if the hull is
# authored any wider than (grid_width/2 - hull_frame's 8-unit pad =
# 16.25-8 = 8.25 half-width here), the frame grows symmetrically about the
# hull's centreline while the grid stays pinned to the frame's LEFT edge --
# and the excess width lands entirely on the right, so the ship reads
# noticeably off-centre from the tile floor it is supposed to frame (an
# earlier draft at half-width ~13 put a full extra tile of hull on the
# right and none on the left; confirmed with debug prints of the exact
# on-screen sprite/tile rects, not by eye alone). The Mockingbird avoids
# this because her actual half-width (~36, from the outboard fins) already
# lands close to HER equivalent target (45.5-8=37.5) -- this hull needs the
# same discipline deliberately: stay close to 8.25 half-width, uniform, and
# accept the ~1.5-unit residual (pad 8 vs one void row's 6.5) the
# convention leaves no way to close. A second in-engine screenshot (before
# this width fix) also caught a too-gradual nose taper leaving the cockpit
# row's first few units narrower than the hull below it; fixed the same
# way as the length -- blunt, not tapered.
SP_SPACING, SP_R, SP_MOUNT_Y = 5.3, MB_R * 0.6, 29.0   # mount spread/scale/y

def ship_sparrow():
    """Rijay's smallest hull. Engines are parts; the transom carries three
    `s` blanking plates, and she ships with the centre one bare -- the first
    hull in the game with a visibly empty hardpoint."""
    segs = [("Q", 6.5, 0.3, 7.8, 2.0),      # near-instant blunt cap -- the
                                             # cockpit row needs full width
                                             # almost immediately, not a
                                             # gradual taper
            ("L", 8.0, 26.0),               # constant-width body: cockpit
                                             # through the dock row -- no
                                             # waist, no bulge, kept close to
                                             # the grid-centring half-width
                                             # (see note above)
            ("Q", 8.3, 27.5, 8.6, 29.0),    # a whisper of flare for the
                                             # mount plates, nothing more
            ("L", 8.6, 31.5),
            ("L", 0.0, 31.5)]               # stern cap, at her grid's edge
    layers = [Layer(mirrored_path((0, 0), segs, RIJ_BLUE, sw=2.0),
                    dome(0.35, 0.60, blur=3.0))]
    hi = mirrored_path((0, 0), segs, "#5aa3ea", stroke="none", opacity=.5)
    layers.append(Layer(group(hi, ty=-1.5, scale=.85), role="sheet_only"))
    # dorsal stripe, nose to the flare -- paint only, same idiom as the MB
    layers.append(Layer(poly([(-1.1, 2), (1.1, 2), (1.4, 27), (-1.4, 27)],
                             RIJ_WHITE, stroke="none")))
    # flank stripe: breaks at the port-side dormers near the stern
    for pts in ([(6.5, 0.3), (7.8, 2), (8.0, 24)], [(8.3, 27.5), (8.6, 29)]):
        for sx in (-1, 1):
            d = "M " + " L ".join(f"{sx * (x - 1.1):.1f},{y:.1f}" for x, y in pts)
            layers.append(Layer(
                f'<path d="{d}" fill="none" stroke="{RIJ_WHITE}" '
                f'stroke-width="1.4" stroke-linecap="round" '
                f'stroke-linejoin="round" opacity=".9"/>'))
    # the packet's cargo door: a double-hatch outline in the pod bay, paint
    # only -- "all cockpit and cargo door" per the design brief
    layers.append(Layer(
        f'<rect x="-4.6" y="12.0" width="9.2" height="9.0" rx="1.4" '
        f'fill="none" stroke="{INK}" stroke-width="1.0" opacity="0.55"/>'))
    layers.append(Layer(line(0, 12, 0, 21, INK, 0.9, .5)))
    # compact mb_canopy-style nose glass -- the head-tip window IS the
    # cockpit, just at her scale (mb_canopy's absolute size reads oversize
    # on a hull this small)
    layers.append(Layer(mirrored_path((0, 1.0), [
        ("L", 2.8, 4.0),
        ("Q", 3.6, 6.5, 3.1, 9.0),
        ("L", 0, 10.5)], GLASS, stroke=INK, sw=1.2),
        dome(0.58, 0.74, blur=1.5)))
    layers.append(Layer(line(0, 1.5, 0, 10.0, INK, 0.9)))
    layers.append(Layer(line(-2.9, 6.0, 2.9, 6.0, INK, 0.8)))
    # dock-port dormers, mb_ports-style but sized down and moved aft to her
    # sternmost interior row rather than a mid-ship waist
    for sx in (-1, 1):
        x0 = 5.9 if sx > 0 else -8.7
        layers.append(Layer(rrect(x0, 24.0, 2.8, 4.2, 1.1, RIJ_BLUE,
                                  stroke=INK, sw=1.0), flat(0.50)))
        layers.append(Layer(rrect(x0 + (0.3 if sx > 0 else 2.2), 24.5, 1.9,
                                  3.2, 0, RIJ_BLUE_D, stroke="none")))
        for by in (24.8, 27.3):
            layers.append(Layer(circle(sx * 7.3, by, .35, GLASS,
                                       stroke="none")))
    plates, anchors = rij_mount_plates(
        [(-SP_SPACING, "engine_port"), (0, "engine_center"),
         (SP_SPACING, "engine_stbd")], SP_MOUNT_Y, SP_R, size=0.85)
    layers += plates
    return Hull(layers=layers, anchors=anchors)

def ship_swallow():
    """stocky little fighter: wings straight out on the leading edge,
    trailing edge widening back toward the hull"""
    s = ""
    for sx in (-1, 1):
        s += poly([(sx * 11, -14), (sx * 40, -14), (sx * 40, -4), (sx * 11, 22)],
                  RIJ_BLUE_D, sw=2)
        s += line(sx * 34, -12, sx * 34, -1, RIJ_WHITE, 1.4, .8)
    s += rijay_hull([(0, -42), (10, -37), (14, -16), (14, 14), (12, 30), (0, 34)])
    s += rijay_cockpit(-33, 14)
    s += rijay_engine_bank(32, 26, 1)
    return s

# ------------------------------------------------------------ RADI parts ----
def radi_hull(start, segs, span_center=0):
    """coke-bottle hull: base, inner highlight, trim line — all one path"""
    s = mirrored_path(start, segs, RADI_RED, sw=2.5)
    hi = mirrored_path(start, segs, RADI_RED_HI, stroke="none", opacity=.5)
    s += group(hi, ty=span_center * .14, scale=.86)
    trim = mirrored_path(start, segs, "none", stroke=RADI_TRIM, sw=1.5, opacity=.8)
    s += group(trim, ty=span_center * .035, scale=.965)
    return s

def radi_canopy(cy, w):
    """central, set back: the owner sits in the middle of the ship"""
    return (f'<ellipse cx="0" cy="{cy}" rx="{w / 2}" ry="{w * .36:.1f}" '
            f'fill="{GLASS}" stroke="{INK}" stroke-width="1.8"/>'
            + line(-w * .28, cy - w * .1, w * .28, cy - w * .1, INK, 1.2, .7))

def radi_stern(y, w):
    """recessed engines: a dark slot and a glow, no bells on display"""
    s = rrect(-w / 2, y, w, 7, 3, "#3a2020", stroke=INK, sw=1.6)
    s += (f'<ellipse cx="0" cy="{y + 9:.1f}" rx="{w * .42:.1f}" ry="6" '
          f'fill="url(#glow)"/>')
    return s

def ship_kx6():
    """kx6 XR: split bow, coke-bottle waist, mid-ship canopy, hidden drive.
    Same shape as round 2.1 but 2/3 the length — per review."""
    s = radi_hull((0, -61), [
        ("L", 5, -75), ("L", 11, -87),            # prong
        ("Q", 17, -79, 20, -64),                  # prong shoulder
        ("Q", 27, -47, 27, -31),                  # wide: the bottle
        ("Q", 21, -7, 21, 9),                     # narrow: the waist
        ("Q", 21, 28, 28, 44),                    # wide again: the hips
        ("Q", 31, 61, 22, 72),                    # taper
        ("Q", 12, 80, 0, 83)], span_center=-2)    # stern
    s += line(0, -61, 0, -23, RADI_TRIM, 1.4, .6)  # bow part line
    s += radi_canopy(-3, 26)
    s += radi_stern(72, 32)
    return s

def ship_y_interceptor():
    """y-series: forward-swept prong wings, now coke-bottled on the outer edge"""
    s = ""
    for sx in (-1, 1):
        d = (f"M {sx * 6},-18 L {sx * 30},-60 L {sx * 38},-52 "
             f"Q {sx * 27},-12 {sx * 33},20 L {sx * 10},32 Z")
        s += (f'<path d="{d}" fill="{RADI_RED}" stroke="{INK}" '
              f'stroke-width="2.2" stroke-linejoin="round"/>')
        d2 = (f"M {sx * 29},-52 Q {sx * 24},-12 {sx * 29},14 L {sx * 14},24 "
              f"L {sx * 13},-34 Z")
        s += (f'<path d="{d2}" fill="{RADI_RED_HI}" stroke="none" '
              f'opacity="0.45"/>')
    s += radi_hull((0, -38), [
        ("L", 5, -48),
        ("Q", 11, -32, 10, -8),                   # shoulder
        ("Q", 8, 8, 10, 26),                      # waist
        ("Q", 12, 42, 0, 50)], span_center=2)     # stern
    s += radi_canopy(-2, 18)
    s += radi_stern(48, 18)
    return s

# ------------------------------------------------------------------ sheet ----
SHIPS = [  # (mfr, name, sub, fn, display_scale, classic_px_height, model_units)
    ("PHE", "THUMPER 24", "container freighter · 6×4 bays", ship_thumper24, .78, 64, 235),
    ("PHE", "THUMPER 6", "container freighter · 3×2 bays", ship_thumper6, .78, 32, 150),
    ("PHE", "LONGHORN", "passenger liner · sprite name: Hammerhead", ship_longhorn, .78, 41, 195),
    ("RIJAY", "MOCKINGBIRD", "medium fast freighter", ship_mockingbird, .85, 45, 195),
    ("RIJAY", "SPARROW", "packet courier · smallest hull in the game", ship_sparrow, .85, 45, 195),
    ("RIJAY", "SWALLOW", "interceptor", ship_swallow, .85, 20, 115),
    ("RADI", "KX6 XR", "long-haul yacht", ship_kx6, .85, 52, 175),
    ("RADI", "Y-SERIES", "interceptor, ask no questions", ship_y_interceptor, .85, 30, 125),
]
MFR_HEAD = {
    "PHE": ("PORTER HEAVY ENGINEERING", "blocky pods · skeletal truss · strut glass",
            PHE_POD, [PHE_TRUSS, PHE_POD, PHE_GRAY]),
    "RIJAY": ("RIJAY DRIVE YARDS", "speed above all · engines on display",
              RIJ_BLUE, [RIJ_BLUE, RIJ_WHITE, RIJ_BLUE_D]),
    "RADI": ("ROYAL ARATORI DESIGN INSTITUTE", "split bow · hidden drives · money",
             RADI_RED, [RADI_RED, RADI_TRIM, GLASS]),
}

def build_sheet():
    W, H = 1240, 1300
    defs = ('<defs><radialGradient id="glow">'
            '<stop offset="0%" stop-color="#ff9d4d" stop-opacity="0.95"/>'
            '<stop offset="100%" stop-color="#ff9d4d" stop-opacity="0"/>'
            '</radialGradient></defs>')
    body = f'<rect width="{W}" height="{H}" fill="{BG}"/>' + starfield(W, H, 210, seed=45)
    body += ('<text x="26" y="40" font-family="Consolas,monospace" font-size="20" '
             'fill="#c3cad6">DISTANT HORIZON — manufacturer design languages</text>')
    body += (f'<text x="26" y="62" font-family="Consolas,monospace" font-size="12" '
             f'fill="{LABEL}">Classic\'s three yards, rebuilt as parts vocabularies · '
             f'cues from the original writeup + sprites</text>')
    rows = {"PHE": 105, "RIJAY": 450, "RADI": 790}
    for mfr, y in rows.items():
        name, cue, color, swatches = MFR_HEAD[mfr]
        body += (f'<text x="26" y="{y + 30}" font-family="Consolas,monospace" '
                 f'font-size="14" fill="{color}">{name}</text>')
        body += (f'<text x="26" y="{y + 50}" font-family="Consolas,monospace" '
                 f'font-size="11" fill="{LABEL}">{cue}</text>')
        for i, sw in enumerate(swatches):
            body += rrect(26 + i * 22, y + 62, 16, 10, 2, sw, stroke=INK, sw=1.2)
    slot_x = {"PHE": [330, 610, 880], "RIJAY": [330, 610, 880], "RADI": [330, 610]}
    counters = {"PHE": 0, "RIJAY": 0, "RADI": 0}
    for mfr, nm, sub, fn, sc, px, mu in SHIPS:
        x = slot_x[mfr][counters[mfr]]; counters[mfr] += 1
        ry = rows[mfr]
        cy = ry + 145
        body += group(flatten(fn()), x, cy, scale=sc)
        body += label(x, ry + 290, nm, sub)
    # ------- game-scale strip: rendered at Classic's actual sprite heights
    sy = 1160
    body += rrect(26, sy - 32, W - 52, 120, 4, "#0d1119", stroke="#232a3a", sw=1.5)
    body += (f'<text x="40" y="{sy - 10}" font-family="Consolas,monospace" '
             f'font-size="12" fill="{LABEL}">AT CLASSIC IN-GAME SCALE '
             f'(sprite heights 20–64 px) — the readability test that matters</text>')
    sx = 120
    for mfr, nm, sub, fn, sc, px, mu in SHIPS:
        scale = px / mu
        body += group(flatten(fn()), sx, sy + 42, scale=scale)
        sx += 150
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">{defs}{body}</svg>')
    return svg

if __name__ == "__main__":
    import pathlib
    out = pathlib.Path(__file__).parent
    svg = build_sheet()
    (out / "sheet_mfr.svg").write_text(svg, encoding="utf-8")
    png = resvg_py.svg_to_bytes(svg_string=svg, width=1860)
    (out / "sheet_mfr.png").write_bytes(bytes(png))
    print("wrote", out / "sheet_mfr.svg", "and sheet_mfr.png")
