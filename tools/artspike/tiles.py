"""tiles — M3.5 PR 3: interior tile + signage art, authored at final pixel
scale (64 px tiles) through the composer's rasterize path.

The concourse must read as a place, not a grid: deck plates carry their own
seams (grid lines die in the client), bulkhead caps edge the walkable area,
and signage does the cheap vibe work — worn hazard stripes, stencil berth
digits (rect segments, no fonts), Semiotic-Standard-style pictograms.

Run:  python tiles.py   (exports to client/assets/interior/ + sheet_tiles.png)
"""
import json
import pathlib

import numpy as np
from PIL import Image

from composer import rasterize
from shipforge import rrect, circle, line, poly

# palette — interiors are hand-drawn-style art: no normals, never sun-lit
FLOOR_A = "#14161c"
FLOOR_B = "#1a1d25"
FLOOR_C = "#10131a"
SEAM = "#21242e"
SEAM_D = "#0b0d12"
WALL = "#3a3f4a"
WALL_HI = "#4a5160"
WALL_SH = "#232833"
HAZ_Y = "#d9a441"
HAZ_K = "#101010"
DECAL = "#e8ecf2"
HELM_GLOW = "#5fa8e8"
CARGO_GLOW = "#d9a441"
BROKER_GLOW = "#57b06a"
DESK = "#232833"
DESK_D = "#171b22"


def _bg(w, h, color):
    return f'<rect x="0" y="0" width="{w}" height="{h}" fill="{color}"/>'


def floor_0():
    s = _bg(64, 64, FLOOR_A)
    s += rrect(1.5, 1.5, 61, 61, 2, "none", stroke=SEAM_D, sw=1.5)
    s += line(1.5, 1.5, 62.5, 1.5, SEAM, 1, .5)
    return s


def floor_1():
    s = _bg(64, 64, FLOOR_B)
    s += rrect(1.5, 1.5, 61, 61, 2, "none", stroke=SEAM_D, sw=1.5)
    s += line(32, 3, 32, 61, SEAM_D, 1.2, .8)
    for cx, cy in ((6, 6), (58, 58)):
        s += circle(cx, cy, 1.2, SEAM, stroke="none")
    return s


def floor_2():
    s = _bg(64, 64, FLOOR_C)
    s += rrect(1.5, 1.5, 61, 61, 2, "none", stroke=SEAM_D, sw=1.5)
    s += line(12, 50, 30, 44, SEAM, 1.4, .5)          # scuff
    for i in range(4):                                 # vent slots
        s += line(44, 12 + i * 4, 56, 12 + i * 4, SEAM_D, 2, .9, cap="butt")
    return s


def wall_n():
    """bulkhead cap strip. SYMMETRIC on purpose: identical thin edge lines on
    both long sides, so rotated strips meeting at corners read as one welded
    frame instead of directional pieces laid against each other."""
    s = _bg(64, 14, WALL)
    s += line(0, 1.5, 64, 1.5, WALL_SH, 2, 1.0, cap="butt")
    s += line(0, 12.5, 64, 12.5, WALL_SH, 2, 1.0, cap="butt")
    for bx in (8, 32, 56):
        s += circle(bx, 7, 1.3, WALL_SH, stroke="none")
    return s


def wall_corner():
    """corner block: same face, thin dark edge all round — drops into strip
    junctions (concave overlaps and diagonal-void notches) in any rotation."""
    s = _bg(14, 14, WALL)
    s += rrect(0.5, 0.5, 13, 13, 0, "none", stroke=WALL_SH, sw=2)
    return s


def hazard():
    s = _bg(64, 14, HAZ_K)
    for x in range(-16, 72, 16):
        s += poly([(x, 14), (x + 8, 14), (x + 22, 0), (x + 14, 0)], HAZ_Y,
                  stroke="none")
    # worn: two notches knocked back to black
    s += f'<rect x="18" y="4" width="5" height="4" fill="{HAZ_K}"/>'
    s += f'<rect x="47" y="9" width="6" height="5" fill="{HAZ_K}"/>'
    return s


def _console(glow):
    s = rrect(2, 6, 40, 28, 4, DESK, stroke=SEAM_D, sw=1.5)
    s += rrect(8, 10, 28, 12, 2, glow, stroke=SEAM_D, sw=1, opacity=.85)
    s += line(11, 14, 27, 14, DESK_D, 1.2, .7)
    s += line(11, 18, 22, 18, DESK_D, 1.2, .7)
    for i in range(5):                                 # key row
        s += f'<rect x="{9 + i * 5.4:.1f}" y="26" width="4" height="3" fill="{DESK_D}"/>'
    s += rrect(16, 35, 12, 7, 3, DESK_D, stroke=SEAM_D, sw=1)   # seat
    return s


def console_helm():
    return _console(HELM_GLOW)


def console_cargo():
    return _console(CARGO_GLOW)


def console_broker():
    return _console(BROKER_GLOW)


# stencil digits: 7-segment rect layout, 26x40, no fonts
_SEG_RECTS = {
    "A": (7, 2, 12, 6),
    "B": (18, 3, 6, 14),
    "C": (18, 23, 6, 14),
    "D": (7, 32, 12, 6),
    "E": (2, 23, 6, 14),
    "F": (2, 3, 6, 14),
    "G": (7, 17, 12, 6),
}
_DIGIT_SEGS = {
    0: "ABCDEF", 1: "BC", 2: "ABGED", 3: "ABGCD", 4: "FGBC",
    5: "AFGCD", 6: "AFGECD", 7: "ABC", 8: "ABCDEFG", 9: "ABCDFG",
}


def _digit(n):
    s = ""
    for seg in _DIGIT_SEGS[n]:
        x, y, w, h = _SEG_RECTS[seg]
        s += (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="1" '
              f'fill="{DECAL}" opacity="0.9"/>')
    return s


def _picto(icon):
    s = circle(20, 20, 17, "none", stroke=DECAL, sw=2.5, opacity=.9)
    return s + icon


def picto_airlock():
    """hatch wheel: outer ring + hub + four spokes — reads 'pressure door'"""
    icon = circle(20, 20, 9.5, "none", stroke=DECAL, sw=2.5, opacity=.9)
    icon += circle(20, 20, 3, "none", stroke=DECAL, sw=2, opacity=.9)
    for dx, dy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        icon += line(20 + dx * 2.4, 20 + dy * 2.4, 20 + dx * 6.8,
                     20 + dy * 6.8, DECAL, 2.2, .9)
    return _picto(icon)


def picto_trade():
    icon = line(11, 15, 26, 15, DECAL, 2.5, .9)
    icon += poly([(26, 11), (31, 15), (26, 19)], DECAL, stroke="none",
                 opacity=.9)
    icon += line(14, 25, 29, 25, DECAL, 2.5, .9)
    icon += poly([(14, 21), (9, 25), (14, 29)], DECAL, stroke="none",
                 opacity=.9)
    return _picto(icon)


def picto_cargo():
    icon = rrect(12, 12, 16, 16, 1, "none", stroke=DECAL, sw=2.5, opacity=.9)
    icon += line(12, 12, 28, 28, DECAL, 1.6, .9)
    icon += line(28, 12, 12, 28, DECAL, 1.6, .9)
    return _picto(icon)


def picto_helm():
    icon = (f'<path d="M 12,24 L 20,13 L 28,24" fill="none" stroke="{DECAL}" '
            f'stroke-width="2.5" stroke-linecap="round" '
            f'stroke-linejoin="round" opacity="0.9"/>')
    icon += circle(20, 28, 2.2, DECAL, stroke="none", opacity=.9)
    return _picto(icon)


TILE_SPRITES = (
    [("floor_0", 64, 64, floor_0), ("floor_1", 64, 64, floor_1),
     ("floor_2", 64, 64, floor_2), ("wall_n", 64, 14, wall_n),
     ("wall_corner", 14, 14, wall_corner), ("hazard", 64, 14, hazard),
     ("console_helm", 44, 44, console_helm),
     ("console_cargo", 44, 44, console_cargo),
     ("console_broker", 44, 44, console_broker),
     ("picto_airlock", 40, 40, picto_airlock),
     ("picto_trade", 40, 40, picto_trade),
     ("picto_cargo", 40, 40, picto_cargo),
     ("picto_helm", 40, 40, picto_helm)]
    + [("digit_%d" % n, 26, 40, (lambda n=n: _digit(n))) for n in range(10)]
)


def export_tiles(out_dir):
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, w, h, fn in TILE_SPRITES:
        rgba = rasterize(fn(), (0, 0, w, h), ss=1)
        Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8),
                        "RGBA").save(out / f"{name}.png")
    (out / "meta.json").write_text(json.dumps(
        {"tile_px": 64, "wall_px": 14,
         "files": [n for n, _, _, _ in TILE_SPRITES]}, indent=2),
        encoding="utf-8")


def main():
    root = pathlib.Path(__file__).parents[2]
    export_tiles(root / "client" / "assets" / "interior")
    print("exported", len(TILE_SPRITES), "interior sprites")
    # contact sheet at 2x for eyeballing
    pad, scale = 8, 2
    W = 720
    sheet = Image.new("RGBA", (W, 340), (10, 13, 19, 255))
    x, y, row_h = pad, pad, 0
    for name, w, h, fn in TILE_SPRITES:
        rgba = rasterize(fn(), (0, 0, w, h), ss=1)
        img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8),
                              "RGBA").resize((w * scale, h * scale),
                                             Image.NEAREST)
        if x + img.width + pad > W:
            x = pad
            y += row_h + pad
            row_h = 0
        sheet.alpha_composite(img, (x, y))
        x += img.width + pad
        row_h = max(row_h, img.height)
    out = pathlib.Path(__file__).parent / "sheet_tiles.png"
    sheet.convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
