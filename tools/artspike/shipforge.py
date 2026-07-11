"""shipforge — spike: parts-based procedural vector art for DH ships & stations.

Parts are functions returning SVG fragments in local coords (bow = -y, ships point up).
Hulls are mirrored half-profiles. A composer places parts per ship spec; a sheet
assembler lays out labelled cells. Output: sheet.svg + sheet.png (via resvg).

Run:  pip install resvg-py && python shipforge.py
Next: organize parts into manufacturer design languages (carry over Classic's,
add new ones); test readability at in-game scale (32-64 px).
"""
import random
import resvg_py

# ---------------------------------------------------------------- palette ----
BG = "#0a0d13"
INK = "#343a44"          # outline stroke
HULL = "#99a1ac"         # base plate
HULL_D = "#727a85"       # shaded plate
HULL_DD = "#565d68"      # darkest plate / underside
HULL_HI = "#bac1cb"      # highlight ridge
DARKHULL = "#68707a"     # alt hull base (variant)
DARKHULL_HI = "#8b939d"
WIN = "#a8d8ff"
GLOW_CORE = "#ffe3b0"
GLOW_MID = "#ff9d4d"
LABEL = "#8891a0"
ACCENTS = {"rust": "#c96f3b", "teal": "#3fa7a0", "gold": "#d9a441"}
BOXES = ["#a34f3f", "#3f7f8c", "#b08a3e", "#57755c", "#7a6b8e", "#8c5a46"]

# ------------------------------------------------------------- svg helpers ---
def pts(seq):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in seq)

def poly(seq, fill, stroke=INK, sw=2.0, opacity=1.0, join="round"):
    return (f'<polygon points="{pts(seq)}" fill="{fill}" stroke="{stroke}" '
            f'stroke-width="{sw}" stroke-linejoin="{join}" opacity="{opacity}"/>')

def mirror(half):
    """half profile on x>=0 side, top(bow) to bottom(stern) -> closed outline"""
    return half + [(-x, y) for x, y in reversed(half)]

def rrect(x, y, w, h, r, fill, stroke=INK, sw=2.0, opacity=1.0):
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
            f'rx="{r:.1f}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}" '
            f'opacity="{opacity}"/>')

def circle(cx, cy, r, fill, stroke=INK, sw=2.0, opacity=1.0):
    return (f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{fill}" '
            f'stroke="{stroke}" stroke-width="{sw}" opacity="{opacity}"/>')

def line(x1, y1, x2, y2, stroke=INK, sw=1.5, opacity=1.0, cap="round"):
    return (f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}" '
            f'opacity="{opacity}"/>')

def group(inner, tx=0, ty=0, rot=0, scale=1.0):
    t = f"translate({tx:.1f} {ty:.1f})"
    if rot: t += f" rotate({rot:.1f})"
    if scale != 1.0: t += f" scale({scale:.3f})"
    return f'<g transform="{t}">{inner}</g>'

def shrink(outline, k):
    """crude inset toward centroid — good enough for highlight cores"""
    cx = sum(p[0] for p in outline) / len(outline)
    cy = sum(p[1] for p in outline) / len(outline)
    return [(cx + (x - cx) * k, cy + (y - cy) * k) for x, y in outline]

# ------------------------------------------------------------------ parts ----
def nozzle(cx, y, w, ln, glow=True):
    """engine nozzle pointing down (stern), with plume glow"""
    bell = [(cx - w * .32, y), (cx + w * .32, y),
            (cx + w * .5, y + ln), (cx - w * .5, y + ln)]
    s = poly(bell, HULL_DD, sw=2)
    s += line(cx - w * .38, y + ln * .55, cx + w * .38, y + ln * .55, INK, 1.2)
    if glow:
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + ln + 6:.1f}" rx="{w * .42:.1f}" '
              f'ry="9" fill="url(#glow)"/>')
        s += (f'<ellipse cx="{cx:.1f}" cy="{y + ln + 3:.1f}" rx="{w * .26:.1f}" '
              f'ry="5" fill="{GLOW_CORE}" stroke="none"/>')
    return s

def cockpit(cy, w, h):
    """bridge canopy near bow: dark frame, lit windows"""
    s = rrect(-w / 2, cy, w, h, h * .4, HULL_DD, sw=2)
    ww = w * .62
    s += rrect(-ww / 2, cy + h * .22, ww, h * .34, h * .17, WIN, stroke="none")
    return s

def vents(x, y, n, w, gap, vertical=False):
    s = ""
    for i in range(n):
        if vertical:
            s += line(x, y + i * gap, x, y + i * gap + w, INK, 2.2, .7)
        else:
            s += line(x + i * gap, y, x + i * gap + w, y, INK, 2.2, .7)
    return s

def hatch(cx, cy, r):
    return circle(cx, cy, r, HULL_D, sw=1.6) + circle(cx, cy, r * .45, HULL_DD, sw=1.2)

def container(x, y, w, h, color):
    s = rrect(x, y, w, h, 2.5, color, sw=1.8)
    s += line(x + w * .3, y + 2, x + w * .3, y + h - 2, INK, 1.2, .55)
    s += line(x + w * .7, y + 2, x + w * .7, y + h - 2, INK, 1.2, .55)
    s += rrect(x + 2, y + 2, w - 4, h * .26, 2, "#ffffff", stroke="none", opacity=.13)
    return s

# ------------------------------------------------------------------ ships ----
def ship_tramp(accent, hull=HULL, hull_hi=HULL_HI, seed=1):
    """~stubby break-bulk tramp freighter, side engine pods (Firefly energy)"""
    rng = random.Random(seed)
    half = [(0, -100), (20, -95), (38, -78), (47, -52), (49, -18),
            (46, 18), (55, 40), (57, 66), (46, 82), (26, 90), (0, 93)]
    outline = mirror(half)
    s = poly(outline, hull, sw=2.5)
    s += poly(shrink(outline, 0.82), hull_hi, stroke="none", opacity=.5)
    # lateral panel seams instead of a center spine
    s += line(-34, -52, -40, 30, INK, 1.4, .55)
    s += line(34, -52, 40, 30, INK, 1.4, .55)
    # engine pods (side nacelles) + nozzles
    for sx in (-1, 1):
        px = sx * 52
        s += rrect(px - 13, 34, 26, 52, 9, HULL_D, sw=2.2)
        s += rrect(px - 8, 40, 16, 18, 5, HULL_DD, sw=1.4)
        s += nozzle(px, 86, 22, 12)
    # main nozzle (small, center)
    s += nozzle(0, 93, 18, 10)
    # cockpit
    s += cockpit(-84, 30, 22)
    # cargo hold door (break-bulk: one big side-loading hatch)
    s += rrect(-30, -30, 60, 46, 6, HULL_D, sw=2)
    s += rrect(-24, -24, 48, 34, 4, hull, sw=1.4)
    s += line(0, -24, 0, 10, INK, 1.4, .8)
    s += vents(-20, 22, 3, 12, 7)
    s += vents(8, 22, 3, 12, 7)
    # accent: nose chevron + pod stripes
    s += poly([(-20, -95), (0, -101), (20, -95), (14, -88), (0, -93), (-14, -88)],
              accent, sw=1.5)
    for sx in (-1, 1):
        s += rrect(sx * 52 - 13, 34, 26, 8, 4, accent, sw=1.5)
    # seeded greebles
    for _ in range(4):
        gx = rng.uniform(-36, 36); gy = rng.uniform(35, 66)
        s += hatch(gx, gy, rng.uniform(3.5, 5.5))
    s += hatch(0, -55, 6)
    return s

def ship_packet(accent):
    """slender fast packet / passenger dart"""
    half = [(0, -120), (11, -108), (19, -76), (23, -30), (23, 22),
            (19, 58), (33, 74), (33, 86), (17, 92), (0, 96)]
    outline = mirror(half)
    s = poly(outline, HULL, sw=2.5)
    s += poly(shrink(outline, 0.8), HULL_HI, stroke="none", opacity=.5)
    # radiator fins
    for sx in (-1, 1):
        s += poly([(sx * 20, -6), (sx * 44, 10), (sx * 44, 34), (sx * 20, 30)],
                  HULL_D, sw=2)
        s += line(sx * 26, 2, sx * 26, 30, INK, 1.2, .6)
        s += line(sx * 34, 7, sx * 34, 32, INK, 1.2, .6)
    # engine: one big nozzle + two verniers
    s += rrect(-16, 62, 32, 30, 6, HULL_D, sw=2.2)
    s += nozzle(0, 92, 30, 16)
    s += nozzle(-26, 88, 12, 8); s += nozzle(26, 88, 12, 8)
    # cockpit slit + cabin portholes along the flanks (passengers!)
    s += cockpit(-102, 22, 18)
    for i in range(5):
        y = -58 + i * 15
        s += circle(-13, y, 2.6, WIN, stroke=INK, sw=0.9)
        s += circle(13, y, 2.6, WIN, stroke=INK, sw=0.9)
    # accent racing stripe: single clean center line, below cockpit to fins
    s += poly([(-2.5, -78), (2.5, -78), (4, -8), (-4, -8)], accent, sw=1.0)
    s += hatch(0, 44, 5)
    return s

def ship_hauler(accent):
    """container hauler: bow tug + open truss spine + containers + big engine"""
    s = ""
    # --- truss spine (under containers)
    s += rrect(-8, -95, 16, 195, 3, HULL_DD, sw=2)
    for i in range(9):
        y = -86 + i * 22
        s += line(-34, y, 34, y, HULL_DD, 5, 1.0, cap="butt")
        s += line(-34, y, 34, y, INK, 1.2, .5, cap="butt")
    s += line(-36, -90, -36, 102, INK, 2.2)
    s += line(36, -90, 36, 102, INK, 2.2)
    # --- bow command module
    bow = mirror([(0, -152), (16, -146), (26, -130), (28, -108), (20, -96), (0, -94)])
    s += poly(bow, HULL, sw=2.5)
    s += poly(shrink(bow, .78), HULL_HI, stroke="none", opacity=.5)
    s += cockpit(-140, 24, 18)
    s += poly([(-16, -100), (16, -100), (12, -93), (-12, -93)], accent, sw=1.4)
    # --- containers, 2 x 5, seeded muted colors
    rng = random.Random(7)
    cw, ch, gap = 33, 25.5, 4
    for row in range(5):
        for col in (-1, 0):
            x = col * (cw + gap) + gap / 2 if col == 0 else -(cw + gap / 2)
            y = -88 + row * (ch + gap * 1.6)
            s += container(x, y, cw, ch, rng.choice(BOXES))
    # --- engine block
    s += poly(mirror([(0, 100), (40, 100), (46, 112), (44, 138), (30, 148), (0, 152)]),
              HULL_D, sw=2.5)
    s += rrect(-34, 106, 68, 14, 4, HULL_DD, sw=1.6)
    s += vents(-24, 110, 5, 8, 11, vertical=True)
    for nx in (-26, 0, 26):
        s += nozzle(nx, 148, 24, 14)
    s += rrect(-40, 98, 80, 7, 3, accent, sw=1.4)
    return s

# ---------------------------------------------------------------- station ----
def station_crane_terminal(accent):
    s = ""
    # comm mast (behind)
    s += line(-38, -38, -78, -78, HULL_DD, 3)
    s += circle(-78, -78, 9, HULL_D, sw=2)
    s += line(-78, -78, -90, -90, HULL_D, 2)
    # habitat ring
    s += circle(0, 0, 96, "none", stroke=HULL_D, sw=15)
    s += circle(0, 0, 96, "none", stroke=INK, sw=1.8)
    s += circle(0, 0, 88.5, "none", stroke=INK, sw=1.8)
    s += circle(0, 0, 103.5, "none", stroke=INK, sw=1.8)
    # ring windows
    for i in range(28):
        a = i * 360 / 28
        import math
        x = 96 * math.cos(math.radians(a)); y = 96 * math.sin(math.radians(a))
        s += circle(x, y, 1.8, WIN, stroke="none", opacity=.9)
    # spokes
    for a in (30, 150, 210, 330):
        s += group(rrect(-5, -92, 10, 92, 3, HULL_DD, sw=2), rot=a)
    # hub
    s += circle(0, 0, 42, HULL, sw=2.5)
    s += circle(0, 0, 42, "none", stroke=HULL_HI, sw=5, opacity=.4)
    s += circle(0, 0, 26, HULL_D, sw=2)
    s += circle(0, 0, 9, HULL_DD, sw=1.8)
    for i in range(8):
        a = i * 45 + 22.5
        s += group(line(0, -30, 0, -40, INK, 1.6, .7), rot=a)
    # fuel tank cluster (bottom-left)
    s += line(-70, 70, -100, 100, HULL_DD, 5)
    for i, (tx, ty) in enumerate([(-96, 88), (-112, 104), (-90, 112)]):
        s += circle(tx, ty, 13, HULL_D, sw=2)
        s += circle(tx - 3, ty - 3, 5, HULL_HI, stroke="none", opacity=.5)
    # --- container terminal arm (right side): bar + berths + cranes
    s += rrect(96, -16, 34, 32, 4, HULL_DD, sw=2)          # spoke to terminal
    s += rrect(128, -78, 26, 156, 6, HULL, sw=2.5)          # terminal bar
    s += rrect(133, -70, 16, 140, 4, HULL_D, sw=1.4)
    # berth pads
    for by in (-58, 0, 58):
        s += rrect(152, by - 13, 10, 26, 3, accent, sw=1.6)
        s += circle(157, by, 2.6, GLOW_CORE, stroke="none")
    # crane gantries: booms reaching out over the berth approach, trolley +
    # a container mid-lift on a cable — the "crane-ness" seller
    rngc = random.Random(5)
    for by, ext in ((-58, 62), (58, 48)):
        s += rrect(148, by - 20, ext, 6, 2, HULL_D, sw=1.6)   # boom top
        s += rrect(148, by + 14, ext, 6, 2, HULL_D, sw=1.6)   # boom bottom
        for bx in range(156, 148 + int(ext) - 4, 12):          # truss ticks
            s += line(bx, by - 19, bx + 6, by - 15, INK, 1.1, .55)
            s += line(bx, by + 15, bx + 6, by + 19, INK, 1.1, .55)
        tx = 148 + ext - 10
        s += rrect(tx - 7, by - 22, 14, 44, 3, HULL_DD, sw=1.6)  # trolley bridge
        s += rrect(tx - 5, by - 8, 10, 16, 2, accent, sw=1.4)    # trolley car
        s += line(tx, by + 8, tx, by + 26, "#9aa3ae", 1.4)       # cable
        s += container(tx - 8, by + 26, 16, 12, rngc.choice(BOXES))  # mid-lift
    # a couple of waiting containers on the bar
    rng = random.Random(3)
    s += container(134, -34, 14, 11, rng.choice(BOXES))
    s += container(134, -20, 14, 11, rng.choice(BOXES))
    s += container(134, 24, 14, 11, rng.choice(BOXES))
    # accent ring stripe
    import math
    s += f'<path d="M {103.5*math.cos(math.radians(200)):.1f} {103.5*math.sin(math.radians(200)):.1f} A 103.5 103.5 0 0 1 {103.5*math.cos(math.radians(250)):.1f} {103.5*math.sin(math.radians(250)):.1f}" fill="none" stroke="{accent}" stroke-width="6"/>'
    return s

# ------------------------------------------------------------------ sheet ----
def starfield(w, h, n, seed=42):
    rng = random.Random(seed)
    s = ""
    for _ in range(n):
        x, y = rng.uniform(0, w), rng.uniform(0, h)
        r = rng.choice([0.7, 0.9, 1.1, 1.5])
        op = rng.uniform(0.25, 0.85)
        s += f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{r}" fill="#cdd6e4" opacity="{op:.2f}" stroke="none"/>'
    return s

def label(x, y, text, sub=""):
    s = (f'<text x="{x}" y="{y}" font-family="Consolas,monospace" font-size="15" '
         f'fill="{LABEL}" text-anchor="middle">{text}</text>')
    if sub:
        s += (f'<text x="{x}" y="{y + 18}" font-family="Consolas,monospace" '
              f'font-size="12" fill="{LABEL}" opacity="0.7" '
              f'text-anchor="middle">{sub}</text>')
    return s

def build_sheet():
    W, H = 1240, 860
    defs = f'''<defs>
      <radialGradient id="glow"><stop offset="0%" stop-color="{GLOW_MID}" stop-opacity="0.95"/>
      <stop offset="100%" stop-color="{GLOW_MID}" stop-opacity="0"/></radialGradient>
    </defs>'''
    body = f'<rect width="{W}" height="{H}" fill="{BG}"/>' + starfield(W, H, 190, seed=45)
    body += (f'<text x="26" y="40" font-family="Consolas,monospace" font-size="20" '
             f'fill="#c3cad6">DISTANT HORIZON — parts-composed hull spike</text>')
    body += (f'<text x="26" y="62" font-family="Consolas,monospace" font-size="12" '
             f'fill="{LABEL}">same parts library, different hull specs + accents; '
             f'nothing hand-drawn per ship</text>')
    # row 1
    body += group(ship_tramp(ACCENTS["rust"], seed=11), 170, 260)
    body += label(170, 415, "SPARROW-CLASS TRAMP", "break-bulk · rust livery · seed 11")
    body += group(ship_tramp(ACCENTS["teal"], hull=DARKHULL, hull_hi=DARKHULL_HI, seed=94),
                  470, 260)
    body += label(470, 415, "SPARROW-CLASS TRAMP", "same hull · corporate livery · seed 94")
    body += group(ship_packet(ACCENTS["gold"]), 760, 258)
    body += label(760, 415, "KESTREL-CLASS PACKET", "passenger dart · gold stripes")
    # row 2
    body += group(ship_hauler(ACCENTS["teal"]), 220, 630)
    body += label(220, 812, "MULE-CLASS HAULER", "containerized · crane service only")
    body += group(station_crane_terminal(ACCENTS["gold"]), 800, 610)
    body += label(800, 812, "HIGHDOCK TERMINAL", "crane berths ×3 · hab ring · gold control")
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">{defs}{body}</svg>')
    return svg

if __name__ == "__main__":
    import pathlib
    out = pathlib.Path(__file__).parent
    svg = build_sheet()
    (out / "sheet.svg").write_text(svg, encoding="utf-8")
    png = resvg_py.svg_to_bytes(svg_string=svg, width=1860)
    (out / "sheet.png").write_bytes(bytes(png))
    print("wrote", out / "sheet.svg", "and sheet.png")
