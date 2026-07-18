"""logo — the D/H mark, reused verbatim from Classic (user call, iteration 3:
recreations kept circling it but "so far less good").

`classic_logo.png` is a vendored copy of DistantHorizonClassic
`client/sprites/logo/logo_big_trans.png`: a 16x16-cell pixel mark at 32 px
per cell (512x512), gold D woven through a blue H. Cells are uniform, so
NEAREST resampling to any divisor size is lossless.

Run:  python logo.py   (exports client/assets/ui/logo.png + client/icon.png)
"""
import pathlib

from PIL import Image

HERE = pathlib.Path(__file__).parent
ROOT = HERE.parents[1]


def main():
    src = Image.open(HERE / "classic_logo.png").convert("RGBA")
    out_logo = ROOT / "client" / "assets" / "ui" / "logo.png"
    out_icon = ROOT / "client" / "icon.png"
    out_logo.parent.mkdir(parents=True, exist_ok=True)
    src.resize((256, 256), Image.NEAREST).save(out_logo)
    src.resize((64, 64), Image.NEAREST).save(out_icon)
    print("wrote", out_logo, "and", out_icon)


if __name__ == "__main__":
    main()
