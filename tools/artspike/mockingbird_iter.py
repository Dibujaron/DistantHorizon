"""mockingbird_iter — spike round 4.2: Mockingbird hull iterations.

Round 4.1 verdict: hybrid (C) head wins; ALL candidates had necks too long,
fins too long, engines too small, and read too slender. The Mockingbird is
slightly fat, slightly overweight — a goose, not a falcon. (Classic agrees:
the original sprite is 21x45 px, width/height ~0.47; round 4.1 ran ~0.28.)

Design brief carried from 4.1 (docs/lore.md + user corrections):
- Republic Cruiser body + Firefly neck AND cockpit (canopy atop the head).
- Engine block of exactly three large engines, on display (Rijay).
- Fins = the atmospheric-landing package, separable part, canon image has them.
- White stripes: dorsal centerline + each side's centerline (flank edges
  top-down); ventral hidden.
- Two docking ports at the WAIST = the narrows between body and engine block.

This round: 4.1 hybrid as baseline vs three plumpness grades of the goose
rebuild (short neck, short fins, big engines). Run: python mockingbird_iter.py
"""
import resvg_py
from shipforge import (poly, rrect, circle, line, group, starfield, label,
                       BG, INK, LABEL, GLOW_CORE)
from manufacturers import (mirrored_path, RIJ_BLUE, RIJ_BLUE_D, RIJ_WHITE,
                           GLASS, PHE_GRAY_D)

RIJ_HI = "#5aa3ea"

# ---------------------------------------------------------- shared parts ----
def feather_fan(root_y, tip_y, root_hw, spread):
    """striped white/blue tail feathers radiating aft from a narrow root.
    Part of the atmo-landing package (aero surfaces)."""
    s = ""
    stripes = [(-1.0, -0.62, RIJ_WHITE), (-0.62, -0.28, RIJ_BLUE),
               (-0.28, 0.28, RIJ_WHITE), (0.28, 0.62, RIJ_BLUE),
               (0.62, 1.0, RIJ_WHITE)]
    for a, b, col in stripes:
        dip = abs((a + b) / 2) * 11   # outer feathers end shorter
        s += poly([(a * root_hw, root_y), (b * root_hw, root_y),
                   (b * spread, tip_y - dip), (a * spread, tip_y - dip)],
                  col, sw=2)
    return s

def aero_fins(y, root_hw, tip_x, f=1.0):
    """the atmo-package fin set: swept aero surfaces radiating from the
    engine block, white with blue heat-shield caps. `f` scales the sweep."""
    s = ""
    for sx in (-1, 1):
        s += poly([(sx * root_hw, y), (sx * tip_x, y + 10 * f),
                   (sx * (tip_x + 4), y + 18 * f), (sx * (tip_x - 3), y + 22 * f),
                   (sx * root_hw, y + 15 * f)], RIJ_WHITE, sw=2)
        s += poly([(sx * tip_x, y + 10 * f), (sx * (tip_x + 4), y + 18 * f),
                   (sx * (tip_x - 3), y + 22 * f)], RIJ_BLUE, sw=1.6)
    return s

def engine_block(y, w, h=20, nd=12):
    """round-4.1 monolithic block — kept only for the baseline column"""
    s = rrect(-w / 2, y, w, h, 3, RIJ_BLUE_D, sw=2.2)
    for i in range(3):
        s += line(-w / 2 + 3, y + 5 + i * 5, w / 2 - 3, y + 5 + i * 5,
                  RIJ_WHITE, 1.5, .8)
    step = w / 3
    for i in range(3):
        cx = -w / 2 + step * (i + .5)
        s += poly([(cx - step * .38, y + h), (cx + step * .38, y + h),
                   (cx + step * .44, y + h + nd), (cx - step * .44, y + h + nd)],
                  PHE_GRAY_D, sw=1.8)
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + h + nd + 7:.1f}" '
              f'rx="{step * .42:.1f}" ry="10" fill="url(#glow)"/>')
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + h + nd + 2:.1f}" '
              f'rx="{step * .26:.1f}" ry="5.5" fill="{GLOW_CORE}" stroke="none"/>')
    return s

def engine_nacelles(y, spacing=21, r=7.5, ln=28, stock=False):
    """three separate CYLINDRICAL drums, republic-cruiser style: fat
    capsules, fairly separated — center one on the hull axis, two outboard.
    Individually swappable in the fiction (the repossessed starter has a
    Consol drum in the middle). The solid engine support behind them is the
    HULL itself now (4.4 review: one smooth flowing shape, no separate
    apron, no third color) — this draws only the drums, over that hull."""
    s = ""
    for i in (-1, 0, 1):
        cx = i * spacing
        s += rrect(cx - r, y, 2 * r, ln, r * .95, RIJ_BLUE, sw=2.2)
        # ALL drums identical (4.4 review — no flank stripes skewing the
        # outer pair): one center front-to-back stripe each, carried by the
        # dorsal fin ridge on the atmo bird, plain paint on the stock bird
        if stock:
            s += line(cx, y + 2.5, cx, y + ln - 2.5, RIJ_WHITE, 2.6, .95)
        s += rrect(cx - r * .72, y + ln - 2.5, r * 1.44, 5.5, 2.2, RIJ_BLUE_D,
                   sw=1.6)
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + ln + 8:.1f}" rx="{r * .85:.1f}" '
              f'ry="10" fill="url(#glow)"/>')
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + ln + 3.5:.1f}" rx="{r * .5:.1f}" '
              f'ry="5.5" fill="{GLOW_CORE}" stroke="none"/>')
    return s

def nacelle_fins(y, spacing=21, r=7.5, ln=28, fl=1.0):
    """the atmo-package dorsal fins, mounted ON the drums (4.2 review): one
    centered on the top and bottom of each nacelle — from above thin ridges
    with a trailing edge past the drum aft (ventral ones hidden beneath).
    Parts get thin ink outlines (4.3 review: without them the fins vanish;
    runtime normal maps will add height separation, but albedo must read).
    `fl` scales fin length. Drawn OVER the drums."""
    s = ""
    for i in (-1, 0, 1):
        cx = i * spacing
        s += poly([(cx, y + 3), (cx + 1.9, y + 8), (cx + 1.9, y + ln - 2),
                   (cx + 1.2, y + ln + 7 * fl), (cx, y + ln + 9 * fl),
                   (cx - 1.2, y + ln + 7 * fl), (cx - 1.9, y + ln - 2),
                   (cx - 1.9, y + 8)], RIJ_WHITE, stroke=INK, sw=1.0)
    return s

def outboard_fins(y, spacing=21, r=7.5, ln=28, fl=1.0):
    """one fin on the outer side of each outboard drum (8 fins total with
    the dorsal/ventral six). Same fin as the dorsal ones — same chord, seen
    in full planform instead of edge-on (4.4 review: they must NOT read
    smaller): primary blue, white front-to-back stripe across the top.
    Drawn UNDER the drums, root tucked beneath, capsules stay cylindrical."""
    s = ""
    for sx in (-1, 1):
        root = sx * spacing  # start under the drum centerline
        # clean trapezoid; leading edge starts at the SAME fore point as the
        # dorsal fins (4.8 review) and sweeps back; ends AT the drum's aft
        # plane, clear of the exhaust (4.7 review — no singed fins)
        tips = [(root + sx * (r + 8.5 * fl), y + 16),      # tip, leading
                (root + sx * (r + 9.5 * fl), y + ln - 6),  # straight outer edge
                (root + sx * (r + 5.5 * fl), y + ln)]      # short chamfer in
        s += poly([(root, y + 3)] + tips + [(root, y + ln)],
                  RIJ_BLUE, sw=1.8)
        # the white marking TRACKS THE OUTER EDGE (4.5 review: a mid-planform
        # stripe smooshed the fin into the ship)
        edge = " L ".join(
            f"{x - sx * 2.2:.1f},{yy + .8:.1f}" for x, yy in tips)
        s += (f'<path d="M {edge}" fill="none" stroke="{RIJ_WHITE}" '
              f'stroke-width="2" stroke-linecap="round" '
              f'stroke-linejoin="round" opacity=".95"/>')
    return s

def docking_ports(y, hw):
    """round-4.6-and-earlier protruding fixtures — kept for the v42 baseline"""
    s = ""
    for sx in (-1, 1):
        x0 = hw - 1 if sx > 0 else -(hw + 6)
        s += rrect(x0, y, 7, 11, 1.5, RIJ_WHITE, sw=1.8)
        dx = hw + 3.2 if sx > 0 else -(hw + 5.5)
        s += rrect(dx, y + 2.6, 2.3, 5.8, 1, RIJ_BLUE_D, stroke=INK, sw=.9)
        bx = hw + 2.2 if sx > 0 else -(hw + 2.2)
        for by in (y + 2.2, y + 5.5, y + 8.8):
            s += circle(bx, by, .9, GLASS, stroke="none")
    return s

def dormer_ports(y, edge=16):
    """docking ports as dormers, take two (4.7 review: no phone booths):
    protrusions OF the hull, hull-colored, merging seamlessly at the inboard
    edge — the bump's inner stroke and the hull outline behind it are erased
    by an unstroked patch, so the outline runs hull → around the bump → hull.
    Door on the outer face, button dots beside it. Same structure top and
    bottom of the hull; from above we see the side pair."""
    s = ""
    for sx in (-1, 1):
        x0 = edge - 2 if sx > 0 else -(edge + 5.2)
        s += rrect(x0, y, 7.2, 10, 2.5, RIJ_BLUE, stroke=INK, sw=1.6)
        # seamless merge: unstroked hull-color patch over the inboard edge
        px = edge - 4.5 if sx > 0 else -(edge + .2)
        s += rrect(px, y + .9, 4.7, 8.2, 0, RIJ_BLUE, stroke="none")
        s += rrect(x0 + (3.6 if sx > 0 else .8), y + 2.8, 2.8, 4.4, 1.1,
                   RIJ_BLUE_D, stroke=INK, sw=.9)
        bx = sx * (edge + .6)
        for by in (y + 2.4, y + 7.6):
            s += circle(bx, by, .8, GLASS, stroke="none")
    return s

def dorsal_stripe(y0, y1, w0=2, w1=3.5):
    """no outline — it's paint on the hull, not a part"""
    return poly([(-w0, y0), (w0, y0), (w1, y1), (-w1, y1)], RIJ_WHITE,
                stroke="none")

def flank_stripes(pts, inset=2.4, w=2.2):
    """white stripe along each side's centerline — which in top-down runs
    right along the visible flank edge. `pts` walk the right flank."""
    s = ""
    for sx in (-1, 1):
        d = "M " + " L ".join(f"{sx * (x - inset):.1f},{y:.1f}" for x, y in pts)
        s += (f'<path d="{d}" fill="none" stroke="{RIJ_WHITE}" '
              f'stroke-width="{w}" stroke-linecap="round" '
              f'stroke-linejoin="round" opacity=".9"/>')
    return s

def firefly_canopy(nose_y):
    """round-4.1 canopy — kept only for the baseline column"""
    return rrect(-4.5, nose_y + 7, 9, 11, 3.5, GLASS, stroke=INK, sw=1.5)

def head_canopy(nose_y):
    """the window IS the head tip: glass across the whole nose from
    top-down, with struts — the Firefly cockpit read (4.1 review)"""
    s = mirrored_path((0, nose_y + 2.5), [
        ("L", 6, nose_y + 9),
        ("Q", 7.5, nose_y + 14, 6.5, nose_y + 19),
        ("L", 0, nose_y + 22)], GLASS, stroke=INK, sw=1.6)
    s += line(0, nose_y + 3, 0, nose_y + 21, INK, 1.4)          # center strut
    s += line(-6.2, nose_y + 13, 6.2, nose_y + 13, INK, 1.3)    # crossbar
    return s

def hull(start, segs):
    s = mirrored_path(start, segs, RIJ_BLUE, sw=2.5)
    hi = mirrored_path(start, segs, RIJ_HI, stroke="none", opacity=.5)
    s += group(hi, ty=-4, scale=.85)
    return s

# ------------------------------------------------------------- candidates ----
def mockingbird_hybrid_41():
    """round 4.1 C, unchanged — this round's baseline"""
    under = feather_fan(48, 102, 13, 38) + aero_fins(38, 15, 40, f=1.2)
    over = engine_block(36, 34, h=16, nd=10) + docking_ports(24, 12)
    s = under
    s += hull((0, -112), [
        ("L", 8, -103), ("Q", 10, -98, 9, -92), ("L", 8, -86),
        ("L", 8, -58), ("L", 19, -26), ("Q", 21, -16, 20, -6),
        ("L", 16, 22), ("Q", 13, 30, 10, 36), ("L", 0, 38)])
    s += dorsal_stripe(-98, 34)
    s += flank_stripes([(8, -82), (8, -58), (19, -26), (20, -6), (16, 22),
                        (11, 34)])
    s += over
    s += firefly_canopy(-112)
    return s

def mockingbird_goose(p, fins="v43", fl=1.0):
    """the goose rebuild: hybrid head, SHORT neck, fat breast, big engines.
    `p` grades the plumpness (shoulder/breast width scale). fins="v42" keeps
    the round-4.2 hull-mounted fins + feather fan (baseline); "v43" is the
    corrected 8-fin nacelle-mounted set, length scaled by `fl`."""
    sh, wd = 24 * p, 27 * p          # shoulder, widest half-widths
    nhw = 13                          # narrows half-width
    if fins == "v42":
        under = feather_fan(54, 92, nhw, 28 + 4 * p)
        under += aero_fins(40, nhw + 3, 34 + 4 * p, f=0.85)
        over = engine_nacelles(40) + docking_ports(25, nhw + 2)
    elif fins == "stock":
        # the workaday station-to-station Mockingbird: no atmo package
        under = ""
        over = engine_nacelles(40, stock=True) + dormer_ports(27)
    else:
        # outboard fin roots drawn UNDER, emerging from beneath the drums
        under = outboard_fins(40, fl=fl)
        over = engine_nacelles(40) + nacelle_fins(40, fl=fl) + dormer_ports(27)
    s = under
    # one smooth flowing shape nose to stern (4.4 review): the waist pinch
    # flows straight back out into the engine support — no separate apron.
    # The docking-port dormers straddle this edge at the waist.
    s += hull((0, -104), [
        ("L", 8, -95),                        # hybrid head, kept
        ("Q", 10, -90, 9, -84),
        ("L", 8.5, -78),
        ("L", 9, -62),                        # SHORT thick neck
        ("L", sh, -34),                       # shoulder kink
        ("Q", wd, -18, wd, -4),               # fat breast, widest low
        ("L", 19.5, 22),                      # taper
        ("Q", 15, 30, nhw + 1, 38),           # the narrows — the waist
        ("Q", 16, 44, 24, 47),                # flare into the engine support
        ("L", 26.5, 52),
        ("L", 26.5, 59),                      # solid stern, drums ride on it
        ("Q", 25, 62, 18, 62),
        ("L", 0, 62)])
    # dorsal stripe runs aft to meet the central drum (4.5 review)
    s += dorsal_stripe(-90, 44)
    # flank stripes stop at the docking ports, then resume briefly on the
    # flare to connect to the engines (4.5 review)
    s += flank_stripes([(8.5, -76), (9, -62), (sh, -34), (wd, -18), (wd, -4),
                        (19.5, 22)])
    s += flank_stripes([(17, 41), (22.5, 46.5)])
    s += over
    s += head_canopy(-104)
    return s

# ------------------------------------------------------------------ sheet ----
CANDIDATES = [
    ("STOCK", "no atmo package — the workaday bird",
     lambda: mockingbird_goose(1.0, fins="stock"), 186),
    ("ATMO · FL 0.8", "fins resized up",
     lambda: mockingbird_goose(1.0, fl=0.8), 190),
    ("ATMO · FL 1.0", "longer trailing edges",
     lambda: mockingbird_goose(1.0, fl=1.0), 192),
]
XS = [280, 620, 960]

def build_sheet():
    W, H = 1240, 640
    defs = ('<defs><radialGradient id="glow">'
            '<stop offset="0%" stop-color="#ff9d4d" stop-opacity="0.95"/>'
            '<stop offset="100%" stop-color="#ff9d4d" stop-opacity="0"/>'
            '</radialGradient></defs>')
    body = f'<rect width="{W}" height="{H}" fill="{BG}"/>' + starfield(W, H, 130, seed=44)
    body += ('<text x="26" y="40" font-family="Consolas,monospace" font-size="20" '
             'fill="#c3cad6">MOCKINGBIRD — hull iterations, round 4.9</text>')
    body += (f'<text x="26" y="62" font-family="Consolas,monospace" font-size="12" '
             f'fill="{LABEL}">verdict on 4.8: ports PASS · fin leading edge now '
             f'starts at the dorsal fins\' fore point and sweeps back</text>')
    xs = XS
    for (nm, sub, fn, mu), x in zip(CANDIDATES, xs):
        body += group(fn(), x, 300, scale=.85)
        body += label(x, 480, nm, sub)
    # game-scale strip: 45 px, Classic's Mockingbird height
    sy = 540
    body += rrect(26, sy - 26, W - 52, 100, 4, "#0d1119", stroke="#232a3a", sw=1.5)
    body += (f'<text x="40" y="{sy - 6}" font-family="Consolas,monospace" '
             f'font-size="12" fill="{LABEL}">AT GAME SCALE — 45 px, '
             f'the readability test that matters (Classic sprite was 21×45: '
             f'ratio 0.47 — the goose was always canon)</text>')
    for (nm, sub, fn, mu), x in zip(CANDIDATES, xs):
        body += group(fn(), x, sy + 46, scale=45 / mu)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">{defs}{body}</svg>')
    return svg

if __name__ == "__main__":
    import pathlib
    out = pathlib.Path(__file__).parent
    svg = build_sheet()
    (out / "sheet_mockingbird.svg").write_text(svg, encoding="utf-8")
    png = resvg_py.svg_to_bytes(svg_string=svg, width=1860)
    (out / "sheet_mockingbird.png").write_bytes(bytes(png))
    print("wrote", out / "sheet_mockingbird.svg", "and sheet_mockingbird.png")
