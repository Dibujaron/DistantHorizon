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
def phe_rack(top, rows, cols, bw=26, bh=19):
    """container rack: a real bay grid. Returns (svg, bay-center list)."""
    w = cols * bw
    xs = [-w / 2 + i * bw for i in range(cols + 1)]
    ys = [top + j * bh for j in range(rows + 1)]
    s = ""
    for x in xs:
        s += line(x, top, x, top + rows * bh, PHE_TRUSS, 2.5)
    for y in ys:
        s += line(xs[0] - 6, y, xs[-1] + 6, y, PHE_TRUSS, 3)
        for cap_x in (xs[0] - 6, xs[-1] + 6):
            s += line(cap_x, y - 4, cap_x, y + 4, PHE_TRUSS, 3)
    bays = [(xs[i] + bw / 2, ys[j] + bh / 2)
            for j in range(rows) for i in range(cols)]
    return s, bays

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
    rack, bays = phe_rack(-112, 6, 4, bw=24)
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
    cross-outrigger engine pods"""
    s = ""
    # stern outriggers first (under body): crossbar + orange-capped pods
    s += rrect(-46, 26, 92, 8, 2, PHE_GRAY_D, sw=2)
    for sx in (-1, 1):
        s += rrect(sx * 40 - 7, 18, 14, 24, 3, PHE_GRAY, sw=2)
        s += rrect(sx * 49 - 3, 16, 6, 28, 2, PHE_POD, sw=1.8)
        s += poly([(sx * 40 - 5, 42), (sx * 40 + 5, 42),
                   (sx * 40 + 6, 49), (sx * 40 - 6, 49)], PHE_GRAY_D, sw=1.6)
        s += f'<ellipse cx="{sx * 40}" cy="52" rx="6" ry="5" fill="url(#glow)"/>'
    # the hammer: wide lobed bow, substantial hull
    hammer = mirror([(0, -116), (16, -114), (34, -108), (46, -98), (46, -86),
                     (36, -78), (18, -74), (0, -72)])
    s += poly(hammer, PHE_GRAY, sw=2.5)
    s += poly(shrink(hammer, .84), "#9aa0a8", stroke="none", opacity=.45)
    for sx in (-1, 1):  # orange diagonal accents on the lobes
        s += line(sx * 20, -108, sx * 36, -96, PHE_POD, 4.5)
        s += line(sx * 26, -84, sx * 38, -90, PHE_POD, 4)
    # glass block at the hammer's top center
    s += rrect(-11, -128, 22, 15, 3, PHE_GRAY, sw=2)
    s += rrect(-8, -125, 16, 9, 1.5, GLASS, stroke=INK, sw=1.2)
    s += line(0, -125, 0, -116, INK, 1.4)
    # the neck: ribbed, windows down the middle
    s += rrect(-14, -72, 28, 62, 2, PHE_GRAY, sw=2.2)
    for i in range(3):
        y = -66 + i * 19
        for rx in (-21, 14):
            s += rrect(rx, y, 7, 10, 1.5, PHE_POD, sw=1.6)
        s += rrect(-3.5, y + 2, 7, 8, 1.5, GLASS, stroke=INK, sw=1.1)
    # lower body: wide oval with the big gridded lounge glass
    lower = mirror([(0, -12), (15, -9), (23, 2), (27, 22), (24, 46), (15, 60),
                    (0, 64)])
    s += poly(lower, PHE_GRAY, sw=2.5)
    s += poly(shrink(lower, .84), "#9aa0a8", stroke="none", opacity=.45)
    s += rrect(-14, 2, 28, 48, 11, GLASS, stroke=INK, sw=1.8)
    for fx in (-4.5, 4.5):
        s += line(fx, 4, fx, 48, INK, 1.3)
    for i in range(3):
        s += line(-13, 14 + i * 12, 13, 14 + i * 12, INK, 1.3)
    # stern nub
    s += poly([(-8, 64), (8, 64), (6, 70), (-6, 70)], PHE_GRAY_D, sw=1.8)
    return s

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

def ship_mockingbird():
    """Republic cruiser energy, more birdlike: Firefly neck up front, big
    engine block aft with tail fins around it"""
    s = ""
    for sx in (-1, 1):  # tail fins radiating around the engine block (under)
        s += poly([(sx * 16, 46), (sx * 42, 60), (sx * 46, 82), (sx * 22, 74)],
                  RIJ_BLUE_D, sw=2)
        s += poly([(sx * 10, 56), (sx * 28, 90), (sx * 24, 100), (sx * 8, 82)],
                  RIJ_BLUE, sw=2)
    head = mirror([(0, -116), (9, -112), (13, -102), (12, -92), (8, -86), (0, -84)])
    s += poly(head, RIJ_BLUE, sw=2.2)  # the Firefly head
    s += rijay_cockpit(-110, 15)
    s += rrect(-6, -86, 12, 34, 3, RIJ_BLUE, sw=2.2)  # the neck
    s += line(0, -82, 0, -54, RIJ_WHITE, 3, .9)
    body = mirror([(0, -54), (10, -50), (18, -30), (23, 0), (25, 30), (24, 50),
                   (0, 54)])
    s += poly(body, RIJ_BLUE, sw=2.5)
    s += poly(shrink(body, .8), "#5aa3ea", stroke="none", opacity=.5)
    s += poly([(-3, -48), (3, -48), (4.5, 46), (-4.5, 46)], RIJ_WHITE, sw=1.2)
    for sx in (-1, 1):  # cargo blisters: practicality over sleekness
        s += rrect(sx * 24 - 5, -16, 10, 36, 4, RIJ_BLUE_D, sw=2)
    s += rijay_engine_bank(52, 44, 3)  # the big block the fins surround
    return s

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
    """kx6 XR: split bow, coke-bottle waist, mid-ship canopy, hidden drive"""
    s = radi_hull((0, -92), [
        ("L", 5, -112), ("L", 11, -130),          # prong
        ("Q", 17, -118, 20, -96),                 # prong shoulder
        ("Q", 27, -70, 27, -46),                  # wide: the bottle
        ("Q", 21, -10, 21, 14),                   # narrow: the waist
        ("Q", 21, 42, 28, 66),                    # wide again: the hips
        ("Q", 31, 92, 22, 108),                   # taper
        ("Q", 12, 120, 0, 124)], span_center=-3)  # stern
    s += line(0, -92, 0, -34, RADI_TRIM, 1.4, .6)  # bow part line
    s += radi_canopy(-4, 26)
    s += radi_stern(112, 32)
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
    ("PHE", "LONGHORN", "passenger liner · sprite name: Hammerhead", ship_longhorn, .78, 41, 200),
    ("RIJAY", "MOCKINGBIRD", "medium fast freighter", ship_mockingbird, .85, 45, 220),
    ("RIJAY", "SWALLOW", "interceptor", ship_swallow, .85, 20, 115),
    ("RADI", "KX6 XR", "long-haul yacht", ship_kx6, .85, 52, 255),
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
    slot_x = {"PHE": [330, 610, 880], "RIJAY": [330, 610], "RADI": [330, 610]}
    counters = {"PHE": 0, "RIJAY": 0, "RADI": 0}
    for mfr, nm, sub, fn, sc, px, mu in SHIPS:
        x = slot_x[mfr][counters[mfr]]; counters[mfr] += 1
        ry = rows[mfr]
        cy = ry + 145
        body += group(fn(), x, cy, scale=sc)
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
        body += group(fn(), sx, sy + 42, scale=scale)
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
