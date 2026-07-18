"""mockingbird_litcheck — pre-pipeline sanity check: the LOCKED Mockingbird
through the round-3 lightspike, before the part composer exists.

This reuses the spike's silhouette-doming height (acceptable here because the
Mockingbird is blob-shaped; the production composer authors real per-part
profiles instead). Palette offsets are remapped from RADI to Rijay. Output is
an eyeball sheet only — nothing here is a production asset.

Run:  python mockingbird_litcheck.py
Out:  sheet_mockingbird_lit.png
"""
import pathlib

import numpy as np
from PIL import Image, ImageDraw

import lightspike as L
from composer import flatten
from manufacturers import ship_mockingbird

# --- retarget the spike at the Mockingbird -----------------------------------
L.ship_kx6 = lambda: flatten(ship_mockingbird())   # render_frame() draws this
L.CLASSIC_PX = 45                      # Classic Mockingbird sprite height
L.MODEL_UNITS = 195

# Rijay palette: height offsets per color (same scheme as the RADI table).
# The #5aa3ea inner highlight is baked pseudo-lighting -> flattened to hull.
L.FLATTEN = {(90, 163, 234): (59, 141, 224)}   # RIJ highlight -> RIJ_BLUE
L.OFFSETS = {
    (59, 141, 224): 0.00,    # RIJ_BLUE hull
    (90, 163, 234): 0.00,    # highlight (flattened away)
    (42, 102, 168): -0.04,   # RIJ_BLUE_D practical bits, recessed
    (238, 242, 246): 0.01,   # RIJ_WHITE stripes: paint, barely proud
    (95, 216, 232): 0.12,    # GLASS canopy
    (104, 109, 117): -0.08,  # PHE_GRAY_D nozzle throats
    (52, 58, 68): -0.05,     # INK outlines = grooves
}


def main():
    frames = {}
    for rot in L.ROTATIONS:
        rgba = L.render_frame(rot)
        offsets, emissive = L.classify(rgba[..., :3], rgba[..., 3])
        rgba = L.flatten_albedo(rgba, rgba[..., 3])
        height, solid = L.build_height(rgba[..., 3], offsets, emissive)
        normals = L.height_to_normals(height, z_scale=28.0)
        lit = L.light(rgba, normals, solid, emissive)
        frames[rot] = dict(rgba=rgba, lit=lit)
        print(f"rot {rot:3d} done")

    W, H = 1240, 620
    bg = tuple(int(L.BG[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
    sheet = Image.new("RGBA", (W, H), bg)
    draw = ImageDraw.Draw(sheet)
    lab = tuple(int(L.LABEL[i:i + 2], 16) for i in (1, 3, 5))
    draw.text((26, 20), "MOCKINGBIRD — lit sanity check (locked hull through "
              "round-3 spike)", font=L.font(20), fill=(195, 202, 214))
    draw.text((26, 46), "spike doming, NOT the production composer — checking "
              "the locked shape survives quantized lighting",
              font=L.font(12), fill=lab)

    draw.text((40, 80), "LIT, FIXED SUN — 8 SHIP HEADINGS",
              font=L.font(13), fill=lab)
    for i, rot in enumerate(L.ROTATIONS):
        cell = L.to_img(frames[rot]["lit"]).resize((140, 140), Image.LANCZOS)
        sheet.alpha_composite(cell, (40 + i * 148, 102))
        t = f"{rot}°"
        draw.text((40 + i * 148 + 70 -
                   draw.textlength(t, font=L.font(12)) / 2, 246), t,
                  font=L.font(12), fill=lab)

    draw.text((40, 290), f"AT GAME SCALE (hull {L.CLASSIC_PX} px) + 3x blowup",
              font=L.font(13), fill=lab)
    game_px = int(L.FRAME * L.CLASSIC_PX / L.MODEL_UNITS)
    for i, rot in enumerate(L.ROTATIONS):
        small = L.to_img(frames[rot]["lit"]).resize((game_px, game_px),
                                                    Image.BOX)
        sheet.alpha_composite(small, (60 + i * 148, 326))
        big = small.resize((game_px * 3, game_px * 3), Image.NEAREST)
        sheet.alpha_composite(big, (40 + i * 148, 400))

    out = pathlib.Path(__file__).parent / "sheet_mockingbird_lit.png"
    sheet.convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
