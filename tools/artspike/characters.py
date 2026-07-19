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
    # clamp to 255: a brighten (k > 1) must not overflow into an invalid
    # 7-hex-digit color, which resvg would render as black.
    r = min(255, int(int(hex_color[1:3], 16) * k))
    g = min(255, int(int(hex_color[3:5], 16) * k))
    b = min(255, int(int(hex_color[5:7], 16) * k))
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


def character_back_svg(suit, skin, hair):
    dark = _shade(suit)
    s = ""
    # legs + boots (identical topology to the front view)
    s += rrect(6.5, 23, 4, 8, 1, dark, stroke=INK, sw=1)
    s += rrect(11.5, 23, 4, 8, 1, dark, stroke=INK, sw=1)
    s += rrect(5.5, 30, 5, 3.5, 1, BOOT, stroke=INK, sw=1)
    s += rrect(11.5, 30, 5, 3.5, 1, BOOT, stroke=INK, sw=1)
    # arms
    s += rrect(2.8, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    s += rrect(16, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    # torso — no chest badge on the back
    s += rrect(5, 12.5, 12, 11.5, 3, suit, stroke=INK, sw=1)
    # head: back of the skull is all hair, no face; a nape shadow at the collar
    s += circle(11, 7.4, 5.3, hair, stroke=INK, sw=1)
    s += f'<rect x="9" y="12" width="4" height="1.5" fill="{_shade(hair, 0.7)}"/>'
    return s


def character_side_svg(suit, skin, hair):
    """Profile facing RIGHT. The runtime mirrors it for left. Legs are authored
    adjacent (split at x=11) so the baker separates near/far leg with a vertical
    cut and scissors them fore/aft. Boots stay within their half of the split so
    the cut never tears a foot."""
    dark = _shade(suit)
    deep = _shade(suit, 0.6)          # far-side limbs read darker
    s = ""
    # back (far) leg — left of the split; front (near) leg — right of it
    s += rrect(7.0, 23, 3.5, 8, 1, deep, stroke=INK, sw=1)      # back leg  (x 7.0-10.5)
    s += rrect(6.5, 30, 4.0, 3.5, 1, _shade(BOOT, 0.7), stroke=INK, sw=1)  # back boot (x 6.5-10.5)
    s += rrect(11.0, 23, 3.5, 8, 1, dark, stroke=INK, sw=1)     # front leg (x 11-14.5)
    s += rrect(11.0, 30, 5.0, 3.5, 1, BOOT, stroke=INK, sw=1)   # front boot toe-forward (x 11-16)
    # torso — narrower than the front (seen edge-on)
    s += rrect(6.5, 12.5, 8, 11.5, 3, suit, stroke=INK, sw=1)
    # single near arm over the torso (the far arm is hidden behind it)
    s += rrect(8.5, 14, 3.2, 9, 1.5, dark, stroke=INK, sw=1)
    # head: hair cap at the back (left), face pushed to the forward (right) edge
    s += circle(9.5, 7.0, 5.2, hair, stroke=INK, sw=1)
    s += circle(12.0, 8.4, 3.6, skin, stroke=INK, sw=1)
    s += f'<rect x="14.2" y="8.0" width="1.3" height="1.6" fill="{skin}"/>'  # nose nub
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
    views = {"": character_svg, "_back": character_back_svg, "_side": character_side_svg}
    for name, (suit, skin, hair) in CHARACTERS:
        for suffix, fn in views.items():
            rgba = rasterize(fn(suit, skin, hair), (0, 0, 22, 34), ss=1)
            Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8),
                            "RGBA").save(out / f"{name}{suffix}.png")


def main():
    root = pathlib.Path(__file__).parents[2]
    export_characters(root / "client" / "assets" / "characters")
    print("exported", len(CHARACTERS), "characters x 3 views")
    # contact sheet: front / back / side per character, 1x and 3x
    views = [character_svg, character_back_svg, character_side_svg]
    cell, gap = 22, 6
    cols = len(views)
    sheet = Image.new(
        "RGBA",
        (len(CHARACTERS) * (cols * (cell + gap) + gap),
         cell + 34 * 3 + 36), (10, 13, 19, 255))
    for i, (name, (suit, skin, hair)) in enumerate(CHARACTERS):
        ox = 12 + i * (cols * (cell + gap) + gap)
        for j, fn in enumerate(views):
            rgba = rasterize(fn(suit, skin, hair), (0, 0, 22, 34), ss=1)
            img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA")
            sheet.alpha_composite(img, (ox + j * (cell + gap), 12))
            sheet.alpha_composite(img.resize((66, 102), Image.NEAREST),
                                  (ox + j * (cell + gap), 58))
    out = pathlib.Path(__file__).parent / "sheet_characters.png"
    sheet.convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
