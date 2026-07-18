"""logo — M3.5 PR 4: the D/H mark, rebuilt from Classic's actual logo sprite
(DistantHorizonClassic/client/sprites/logo/logo_big_trans.png) with the
revival palette swap: Classic ran a gold D + blue H; the revival runs a
blue-purple D + golden H (brainstorm 2026-07-17).

Construction is Classic's: equal-size blocky pixel letters. The H's left
post threads the D's counter; the D's bars pass OVER the post; the H's
crossbar passes OVER the D's bowl edge. Authored as a cell map — it IS
pixel art, so it's built from cells, not curves.

Run:  python logo.py   (writes client/assets/ui/logo.png + client/icon.png)
"""
import pathlib

import numpy as np
from PIL import Image

# cell glyphs: D/d = blue-purple bright/shade, H/h = gold bright/shade
_COLORS = {
    "D": "#4a5ad0", "d": "#333f9e",
    "H": "#d9a441", "h": "#b07f2c",
}

# 17 cols x 16 rows, transcribed from logo_big_trans.png (cell ~ 30 px of
# the 512 original). Weave: rows 3-4/11-12 keep D over the H post at cols
# 6-7; rows 8-9 keep the H crossbar over the D bowl at cols 11-12.
_GRID = [
    ".................",
    ".................",
    "......HH.....HH..",
    ".DDDDDDDDDDD.HH..",
    ".ddddddddddDdHH..",
    ".DD...HH...DD.HH.",
    ".DD...HH...DD.HH.",
    ".DD...HH...DD.HH.",
    ".DD...HHHHHHHHHH.",
    ".DD...hhhhhhhhhh.",
    ".DD...HH...DD.HH.",
    ".DDDDDDDDDDdD.HH.",
    ".dddddddddddd.HH.",
    "......HH.....HH..",
    "......HH.....HH..",
    ".................",
]

CELL = 16  # px per cell -> 272x256 canvas, trimmed on save


def logo_svg():
    s = ""
    for ry, row in enumerate(_GRID):
        for cx, ch in enumerate(row):
            if ch == ".":
                continue
            s += (f'<rect x="{cx * CELL}" y="{ry * CELL}" width="{CELL}" '
                  f'height="{CELL}" fill="{_COLORS[ch]}"/>')
    return s


def main():
    from composer import rasterize
    root = pathlib.Path(__file__).parents[2]
    w = len(_GRID[0]) * CELL
    h = len(_GRID) * CELL
    rgba = rasterize(logo_svg(), (0, 0, w, h), ss=1)
    img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA")
    bbox = img.getbbox()
    img = img.crop(bbox)
    # pad to square, centered
    side = max(img.width, img.height) + CELL
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(img, ((side - img.width) // 2, (side - img.height) // 2))
    out_ui = root / "client" / "assets" / "ui"
    out_ui.mkdir(parents=True, exist_ok=True)
    sq.resize((256, 256), Image.NEAREST).save(out_ui / "logo.png")
    sq.resize((64, 64), Image.NEAREST).save(root / "client" / "icon.png")
    print("wrote", out_ui / "logo.png", "and client/icon.png")


if __name__ == "__main__":
    main()
