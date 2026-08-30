"""Composite a hull's exported sprite with the parts its default_loadout fits,
the way the CLIENT layers them: each part's `attach_px` lands on the hull's
named mount anchor of the same id, parts drawn over the hull.

This is the only way to see what a ship actually looks like in flight without
launching the game, and it is what catches mount anchors spaced too closely for
the parts they carry (the Goldfinch shipped with her starboard engine drawn
entirely inside her centre one, which no test and no bare-hull render showed).

    python tools/artspike/preview_fitted.py                # every hull
    python tools/artspike/preview_fitted.py sparrow        # one hull
    python tools/artspike/preview_fitted.py --scale 16 sparrow

Writes PNGs to tools/artspike/preview/ (gitignored).
"""
import argparse
import json
import pathlib

from PIL import Image

ROOT = pathlib.Path(__file__).parents[2]
SHIPCLASSES = ROOT / "server" / "shipclasses"
PARTS_DOCS = ROOT / "server" / "parts"
SHIP_ART = ROOT / "client" / "assets" / "ships"
PART_ART = ROOT / "client" / "assets" / "parts"
OUT = pathlib.Path(__file__).parent / "preview"


def _meta(d):
    return json.loads((d / "meta.json").read_text(encoding="utf-8"))


def _part_sprites():
    """part id -> sprite key, from the part documents the server loads."""
    out = {}
    for f in sorted(PARTS_DOCS.glob("*.json")):
        doc = json.loads(f.read_text(encoding="utf-8"))
        out[doc["id"]] = doc.get("sprite")
    return out


def load_hull(hull_id):
    doc = json.loads((SHIPCLASSES / f"{hull_id}.json").read_text(encoding="utf-8"))
    art = SHIP_ART / doc.get("sprite", doc["id"])
    meta = _meta(art)
    return dict(
        doc=doc,
        art=art,
        meta=meta,
        anchors={a["id"]: (a["x_px"], a["y_px"])
                 for a in meta.get("anchors", []) if a.get("kind") == "mount"},
        fit=doc.get("default_loadout", {}).get("parts", {}),
    )


def composite(hull_id, scale=10, bare=False, pad=24):
    """-> (PIL.Image, list of warnings). Warnings name parts that overlap."""
    h = load_hull(hull_id)
    sprites = _part_sprites()
    hull_img = Image.open(h["art"] / "albedo.png").convert("RGBA")
    canvas = Image.new("RGBA",
                       (hull_img.width + pad * 2, hull_img.height + pad * 2),
                       (0, 0, 0, 0))
    canvas.alpha_composite(hull_img, (pad, pad))

    warnings, boxes = [], {}
    if not bare:
        for mount, part_id in sorted(h["fit"].items()):
            key = sprites.get(part_id)
            pdir = PART_ART / key if key else None
            if not key or not pdir.exists():
                warnings.append(f"{mount}: no art for {part_id}")
                continue
            if mount not in h["anchors"]:
                warnings.append(f"{mount}: no anchor on {hull_id}")
                continue
            pm = _meta(pdir)
            pimg = Image.open(pdir / "albedo.png").convert("RGBA")
            ax, ay = h["anchors"][mount]
            attx, atty = pm["attach_px"]
            x = int(round(pad + ax - attx))
            y = int(round(pad + ay - atty))
            canvas.alpha_composite(pimg, (x, y))
            boxes[mount] = (x, y, x + pimg.width, y + pimg.height)

    # Overlap is the failure this script exists to catch: two parts sharing
    # most of their footprint render as one indistinct lump.
    names = sorted(boxes)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            ax0, ay0, ax1, ay1 = boxes[a]
            bx0, by0, bx1, by1 = boxes[b]
            ox = max(0, min(ax1, bx1) - max(ax0, bx0))
            oy = max(0, min(ay1, by1) - max(ay0, by0))
            if ox and oy:
                area = ox * oy
                smaller = min((ax1 - ax0) * (ay1 - ay0), (bx1 - bx0) * (by1 - by0))
                warnings.append(
                    f"{a} and {b} overlap by {area} px^2 "
                    f"({100.0 * area / smaller:.0f}% of the smaller part)")

    return canvas.resize((canvas.width * scale, canvas.height * scale),
                         Image.NEAREST), warnings


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("hulls", nargs="*", help="hull ids; default every shipclass")
    ap.add_argument("--scale", type=int, default=10, help="nearest-neighbour zoom")
    args = ap.parse_args()

    hulls = args.hulls or sorted(p.stem for p in SHIPCLASSES.glob("*.json"))
    OUT.mkdir(exist_ok=True)
    for hull_id in hulls:
        for bare in (False, True):
            img, warns = composite(hull_id, args.scale, bare=bare)
            name = f"{hull_id}_{'bare' if bare else 'fitted'}.png"
            img.save(OUT / name)
            print(f"wrote {OUT / name}  {img.width}x{img.height}")
            for w in warns:
                print(f"  ! {hull_id}: {w}")


if __name__ == "__main__":
    main()
