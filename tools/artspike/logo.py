"""logo — M3.5 PR 4: the D/H mark, revived from Classic's direction:
a blue-purple D interlocked with a golden H (the H's left post threads the
D's counter — D over H above the crossbar, H over D below).

Run:  python logo.py   (writes client/assets/ui/logo.png + client/icon.png)
"""
import pathlib

import numpy as np
from PIL import Image

from composer import rasterize

D_FILL = "#4a5ad0"
D_EDGE = "#2c3690"
H_FILL = "#d9a441"
H_EDGE = "#8a6626"

# D as an evenodd ring: outer slab + inner counter
_D_PATH = ("M 44,36 L 112,36 Q 196,36 196,128 Q 196,220 112,220 L 44,220 Z "
           "M 82,74 L 108,74 Q 152,74 152,128 Q 152,182 108,182 L 82,182 Z")


def _d(stroke_w=7):
    return (f'<path d="{_D_PATH}" fill="{D_FILL}" fill-rule="evenodd" '
            f'stroke="{D_EDGE}" stroke-width="{stroke_w}" '
            f'stroke-linejoin="round"/>')


def _h(stroke_w=6):
    s = ""
    for x in (104, 186):
        s += (f'<rect x="{x}" y="64" width="26" height="156" rx="4" '
              f'fill="{H_FILL}" stroke="{H_EDGE}" stroke-width="{stroke_w}"/>')
    s += (f'<rect x="104" y="141" width="108" height="26" rx="4" '
          f'fill="{H_FILL}" stroke="{H_EDGE}" stroke-width="{stroke_w}"/>')
    return s


def logo_svg():
    s = _d()
    s += _h()
    # the weave: D re-drawn over the H's left post ABOVE the crossbar
    s += (f'<clipPath id="weave"><rect x="0" y="0" width="256" height="141"/>'
          f'</clipPath>'
          f'<g clip-path="url(#weave)">{_d()}</g>')
    return s


def main():
    root = pathlib.Path(__file__).parents[2]
    rgba = rasterize(logo_svg(), (0, 0, 256, 256), ss=1)
    img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA")
    out_ui = root / "client" / "assets" / "ui"
    out_ui.mkdir(parents=True, exist_ok=True)
    img.save(out_ui / "logo.png")
    img.resize((64, 64), Image.LANCZOS).save(root / "client" / "icon.png")
    print("wrote", out_ui / "logo.png", "and client/icon.png")


if __name__ == "__main__":
    main()
