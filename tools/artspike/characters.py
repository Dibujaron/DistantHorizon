"""characters — M3.5 PR 3: FTL-scale character sprites.

Upright mini-people (22x34 px) for the deck plan, FTL being the honest
reference for what a person looks like at this scale: boots, jumpsuit,
arms, head, hair cap, a badge tab. One player variant + three crew
variants; the full "no generic NPC" variation-axes system is a later
milestone — this is the minimum cast for the vibe pass.

Run:  python characters.py   (exports to client/assets/characters/)
"""
import pathlib

import numpy as np
from PIL import Image

from composer import rasterize
from shipforge import rrect, circle

INK = "#232833"
BOOT = "#232833"


def _shade(hex_color, k=0.72):
    r = int(int(hex_color[1:3], 16) * k)
    g = int(int(hex_color[3:5], 16) * k)
    b = int(int(hex_color[5:7], 16) * k)
    return f"#{r:02x}{g:02x}{b:02x}"


def character_svg(suit, skin, hair):
    dark = _shade(suit)
    s = ""
    # legs + boots first (under the torso)
    s += rrect(6.5, 23, 4, 8, 1, dark, stroke=INK, sw=1)
    s += rrect(11.5, 23, 4, 8, 1, dark, stroke=INK, sw=1)
    s += rrect(5.5, 30, 5, 3.5, 1, BOOT, stroke=INK, sw=1)
    s += rrect(11.5, 30, 5, 3.5, 1, BOOT, stroke=INK, sw=1)
    # arms
    s += rrect(2.8, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    s += rrect(16, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    # torso
    s += rrect(5, 12.5, 12, 11.5, 3, suit, stroke=INK, sw=1)
    s += f'<rect x="13" y="15" width="2.5" height="3" fill="{_shade(suit, 1.45)}"/>'
    # head: hair cap behind/above, face over it
    s += circle(11, 6.5, 5.4, hair, stroke=INK, sw=1)
    s += circle(11, 8.2, 4.4, skin, stroke=INK, sw=1)
    return s


# (name, (suit, skin, hair))
CHARACTERS = [
    ("player", ("#3b8de0", "#c99b7a", "#3a2e26")),   # Rijay-blue jumpsuit
    ("crew_0", ("#d97a28", "#8d5a3b", "#14100c")),   # PHE orange
    ("crew_1", ("#57755c", "#e0b49a", "#6e6258")),
    ("crew_2", ("#7a6b8e", "#5e3a24", "#2c2c34")),
]


def export_characters(out_dir):
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, (suit, skin, hair) in CHARACTERS:
        rgba = rasterize(character_svg(suit, skin, hair), (0, 0, 22, 34), ss=1)
        Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8),
                        "RGBA").save(out / f"{name}.png")


def main():
    root = pathlib.Path(__file__).parents[2]
    export_characters(root / "client" / "assets" / "characters")
    print("exported", len(CHARACTERS), "characters")
    # contact sheet: 1x and 3x
    sheet = Image.new("RGBA", (4 * 88 + 24, 34 + 34 * 3 + 36),
                      (10, 13, 19, 255))
    for i, (name, (suit, skin, hair)) in enumerate(CHARACTERS):
        rgba = rasterize(character_svg(suit, skin, hair), (0, 0, 22, 34), ss=1)
        img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8),
                              "RGBA")
        sheet.alpha_composite(img, (12 + i * 88, 12))
        sheet.alpha_composite(
            img.resize((66, 102), Image.NEAREST), (12 + i * 88, 58))
    out = pathlib.Path(__file__).parent / "sheet_characters.png"
    sheet.convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
