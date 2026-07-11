"""manufacturers — spike round 2: Classic DH manufacturer design languages,
rebuilt as parts vocabularies in the shipforge flat-vector style.

Sources: "Distant Horizon: Ship Manufacturer Design Cues" writeup + Classic
client sprites (client/sprites/ships/{PHE,Rijay,RADI}). Classic sprites are
21-64 px tall and use c1/c2/constant_color layers (two player-tintable livery
channels over fixed detail) — both facts carried into this spike: the sheet
ends with a strip rendered at Classic's in-game scale.

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
RADI_TRIM = "#9aa0a8"

# ------------------------------------------------------------- PHE parts ----
def phe_truss(y0, y1, w, rungs, rail_gap=8):
    """skeletal cargo rack: twin rails, capped crossbar rungs (pylon-style)"""
    s = line(-rail_gap, y0, -rail_gap, y1, PHE_TRUSS, 3.5)
    s += line(rail_gap, y0, rail_gap, y1, PHE_TRUSS, 3.5)
    for i in range(rungs):
        y = y0 + (y1 - y0) * i / (rungs - 1)
        s += line(-w / 2, y, w / 2, y, PHE_TRUSS, 3)
        for sx in (-1, 1):
            s += line(sx * w / 2, y - 5, sx * w / 2, y + 5, PHE_TRUSS, 3)
    return s

def phe_mast(y, w):
    """topmast crossbar with orange tips — the Thumper's antlers"""
    s = line(0, y, 0, y + 16, PHE_TRUSS, 3.5)
    s += line(-w / 2, y, w / 2, y, PHE_TRUSS, 3)
    for sx in (-1, 1):
        s += line(sx * w / 2, y - 6, sx * w / 2, y + 6, PHE_POD, 4.5)
    return s

def phe_pod(cx, cy, w, h, nozzled=True):
    """blocky orange engine/equipment pod, sharp corners, skeletal mounts"""
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
    """large container freighter: tall rack, clamped boxes, 3 engine pods"""
    s = phe_mast(-172, 56)
    s += phe_truss(-156, 76, 96, 9)
    rng = random.Random(24)
    for row, col in [(1, -1), (1, 0), (3, 0), (4, -1), (6, -1), (6, 0)]:
        y = -156 + (76 + 156) * row / 8 - 10
        x = -34 if col == -1 else 4
        s += container(x, y, 30, 21, rng.choice(BOXES))
    s += phe_strut_cockpit(80, 34, 24)
    for px, py in [(-38, 122), (0, 128), (38, 122)]:
        s += line(px * .4, 104, px, py - 18, PHE_TRUSS, 2.5)
        s += phe_pod(px, py, 28, 38)
    return s

def ship_thumper6():
    """small container freighter: same language, half the rack"""
    s = phe_mast(-92, 40)
    s += phe_truss(-78, 22, 70, 5)
    rng = random.Random(6)
    s += container(-27, -52, 24, 17, rng.choice(BOXES))
    s += container(3, -22, 24, 17, rng.choice(BOXES))
    s += phe_strut_cockpit(26, 28, 20)
    s += phe_pod(0, 62, 26, 32)
    for sx in (-1, 1):
        s += line(sx * 10, 46, sx * 22, 56, PHE_TRUSS, 2.5)
        s += phe_pod(sx * 26, 62, 14, 20)
    return s

def ship_longhorn():
    """barebones passenger liner: blocky slab, window strip, bow outriggers"""
    s = ""
    for sx in (-1, 1):  # bow horns
        s += line(sx * 12, -96, sx * 34, -116, PHE_TRUSS, 3)
        s += line(sx * 34, -122, sx * 34, -110, PHE_POD, 4.5)
    hull = mirror([(0, -104), (16, -98), (24, -80), (28, -30), (28, 40),
                   (24, 78), (14, 92), (0, 96)])
    s += poly(hull, PHE_GRAY, sw=2.5)
    s += poly(shrink(hull, .82), "#9aa0a8", stroke="none", opacity=.45)
    s += phe_strut_cockpit(-96, 26, 18)
    for i in range(7):  # passenger glass, the Longhorn's spine
        s += rrect(-5, -66 + i * 19, 10, 11, 2, GLASS, stroke=INK, sw=1.2)
    for sx in (-1, 1):  # blocky side pods
        s += rrect(sx * 28 - 7, -12, 14, 52, 2, PHE_POD, sw=2)
        s += rrect(sx * 28 - 4, -8, 8, 12, 1.5, PHE_POD_D, stroke="none")
    s += phe_pod(-16, 104, 24, 28)
    s += phe_pod(16, 104, 24, 28)
    return s

# ----------------------------------------------------------- Rijay parts ----
def rijay_hull(half, stripe=True):
    """teardrop hull, white dorsal stripe: speed with its shirt tucked in"""
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
    """medium fast freighter: bullet with a cargo waist and a big skirt"""
    s = rijay_hull([(0, -112), (12, -100), (22, -68), (26, -10), (25, 45),
                    (28, 72), (25, 88), (0, 92)])
    s += rijay_cockpit(-96, 20)
    for sx in (-1, 1):  # practicality over sleekness: external cargo blisters
        s += rrect(sx * 26 - 6, -30, 12, 46, 4, RIJ_BLUE_D, sw=2)
        s += line(sx * 26, -22, sx * 26, 8, RIJ_WHITE, 1.4, .7)
    s += rijay_engine_bank(88, 46, 3)
    return s

def ship_swallow():
    """interceptor: mostly engine, wings as an afterthought of the wings"""
    s = ""
    for sx in (-1, 1):  # swept wings first (under hull)
        s += poly([(sx * 8, 8), (sx * 40, 34), (sx * 40, 46), (sx * 8, 36)],
                  RIJ_BLUE_D, sw=2)
        s += line(sx * 30, 30, sx * 30, 42, RIJ_WHITE, 1.4, .8)
    s += rijay_hull([(0, -52), (8, -42), (12, -14), (12, 22), (10, 40), (0, 44)])
    s += rijay_cockpit(-40, 12)
    s += rijay_engine_bank(42, 22, 1)
    return s

# ------------------------------------------------------------ RADI parts ----
def radi_hull(half, notch_depth):
    """split-bow sleek hull with gray trim line — the price tag is visible"""
    outline = mirror(half)
    s = poly(outline, RADI_RED, sw=2.5)
    s += poly(shrink(outline, .84), "#de4b4b", stroke="none", opacity=.5)
    s += poly(shrink(outline, .97), "none", stroke=RADI_TRIM, sw=1.6, opacity=.8)
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
    """kx6 XR: long-haul yacht. Split bow, mid-ship canopy, hidden drive."""
    s = radi_hull([(0, -86), (5, -104), (10, -126), (17, -116), (23, -84),
                   (27, -28), (27, 36), (23, 84), (15, 108), (0, 114)], 40)
    s += radi_canopy(-6, 26)
    s += line(0, -86, 0, -30, RADI_TRIM, 1.4, .6)  # bow part line
    for sx in (-1, 1):  # stern fins, folded tight
        s += poly([(sx * 24, 70), (sx * 34, 96), (sx * 32, 106), (sx * 20, 92)],
                  RADI_RED_D, sw=2)
    s += radi_stern(112, 34)
    return s

def ship_y_interceptor():
    """y-series: long-range interceptor, popular with exactly who you'd think"""
    s = ""
    for sx in (-1, 1):  # forward-swept prong wings make the split bow the wing
        s += poly([(sx * 6, -20), (sx * 30, -62), (sx * 38, -54), (sx * 34, 22),
                   (sx * 10, 34)], RADI_RED, sw=2.2)
        s += poly([(sx * 30, -56), (sx * 33, 14), (sx * 14, 26)], "#de4b4b",
                  stroke="none", opacity=.5)
    s += radi_hull([(0, -34), (7, -44), (11, -20), (12, 18), (9, 46), (0, 52)], 0)
    s += radi_canopy(-2, 20)
    s += radi_stern(50, 20)
    return s

# ------------------------------------------------------------------ sheet ----
SHIPS = [  # (mfr, name, sub, fn, display_scale, classic_px_height, model_units)
    ("PHE", "THUMPER 24", "large container freighter", ship_thumper24, .78, 64, 320),
    ("PHE", "THUMPER 6", "small container freighter", ship_thumper6, .78, 32, 170),
    ("PHE", "LONGHORN", "barebones passenger liner", ship_longhorn, .78, 41, 230),
    ("RIJAY", "MOCKINGBIRD", "medium fast freighter", ship_mockingbird, .85, 45, 230),
    ("RIJAY", "SWALLOW", "interceptor", ship_swallow, .85, 20, 100),
    ("RADI", "KX6 XR", "long-haul yacht", ship_kx6, .85, 52, 240),
    ("RADI", "Y-SERIES", "interceptor, ask no questions", ship_y_interceptor, .85, 30, 110),
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
    xstarts = {"PHE": 250, "RIJAY": 250, "RADI": 250}
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
