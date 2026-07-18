"""composer — M3.5 part-composer pipeline (PR 1).

Ships are ordered Layer lists. Each layer carries an SVG fragment plus an
AUTHORED height profile — a drum says "I'm a cylinder", a wing says "I'm a
flat plate", a fuselage says "I'm a rounded solid". Heights compose in
painter's order exactly like albedo. Normals are derived from the composed
authored heights; nothing is inferred from the whole-ship silhouette (the
round-3 doming rule was spike-only and is rejected for production — it fails
on non-blob hulls like the Thumper).

Roles: "albedo" is real geometry/paint; "sheet_only" is painted pseudo-light
kept for the legacy sheets but dropped from lit-pipeline albedo (which is
authored FLAT); "glow" is engine glow, excluded from exports entirely —
plumes become throttle-driven dynamic art, and the composer emits nozzle
anchors instead.
"""
import io
import json
import pathlib
from dataclasses import dataclass, field

import numpy as np
import resvg_py
from PIL import Image

SS = 4  # supersample: px per model unit at compose time

_DEFS = ('<defs><radialGradient id="glow">'
         '<stop offset="0%" stop-color="#ff9d4d" stop-opacity="0.95"/>'
         '<stop offset="100%" stop-color="#ff9d4d" stop-opacity="0"/>'
         '</radialGradient></defs>')


@dataclass(frozen=True)
class Height:
    kind: str            # "flat" | "cyl_x" | "dome"
    lo: float = 0.0
    hi: float = 0.0
    blur: float = 0.0    # model-unit sigma, dome smoothing only


def flat(v):
    return Height("flat", v, v)


def cyl_x(lo, hi):
    """cylinder profile across the part's x-extent, per pixel row — follows
    the part's own silhouette (capsule ends taper naturally)"""
    return Height("cyl_x", lo, hi)


def dome(lo, hi, blur=6.0):
    """rounded-solid profile from the PART's own footprint (a deliberate,
    authored choice for blobby fuselages — not a default)"""
    return Height("dome", lo, hi, blur)


@dataclass(frozen=True)
class Anchor:
    kind: str            # "nozzle"
    x: float             # model units
    y: float


@dataclass
class Layer:
    svg: str
    height: Height | None = None   # None = paint: no relief contribution
    role: str = "albedo"           # albedo | sheet_only | glow


@dataclass
class Hull:
    layers: list = field(default_factory=list)
    anchors: list = field(default_factory=list)


def flatten(hull_or_str, sheet=True):
    """Hull -> single SVG string. sheet=True reproduces the legacy sheet look
    (painted highlights + engine glow); sheet=False is the flat lit-pipeline
    albedo (no painted light, no emissive)."""
    if isinstance(hull_or_str, str):
        return hull_or_str
    keep = ("albedo", "sheet_only", "glow") if sheet else ("albedo",)
    return "".join(l.svg for l in hull_or_str.layers if l.role in keep)


# ---------------------------------------------------------------- raster ----
def rasterize(svg_fragment, frame, ss=SS):
    """render a fragment in a (minx, miny, w, h) model-unit frame -> RGBA float"""
    minx, miny, w, h = frame
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{int(w * ss)}" '
           f'height="{int(h * ss)}" viewBox="{minx} {miny} {w} {h}">'
           f'{_DEFS}{svg_fragment}</svg>')
    png = resvg_py.svg_to_bytes(svg_string=svg, width=int(w * ss))
    img = Image.open(io.BytesIO(bytes(png))).convert("RGBA")
    return np.asarray(img).astype(np.float64) / 255.0


def hull_frame(hull, pad=8.0):
    """tight frame around the flat albedo, padded, in model units. The
    probe box must exceed any hull's extent — station bars run ~530 units
    wide (a clipped probe silently truncates the frame AND every anchor)."""
    probe = rasterize(flatten(hull, sheet=False), (-400, -400, 800, 800), ss=1)
    ys, xs = np.where(probe[..., 3] > 0.1)
    minx, maxx = xs.min() - 400 - pad, xs.max() - 400 + pad
    miny, maxy = ys.min() - 400 - pad, ys.max() - 400 + pad
    return (float(minx), float(miny), float(maxx - minx), float(maxy - miny))


def gaussian_blur(a, sigma):
    """separable gaussian via np.convolve, edge-padded (lightspike's)"""
    if sigma <= 0:
        return a
    r = max(1, int(sigma * 3))
    x = np.arange(-r, r + 1)
    k = np.exp(-0.5 * (x / sigma) ** 2)
    k /= k.sum()
    out = np.apply_along_axis(
        lambda m: np.convolve(np.pad(m, r, mode="edge"), k, "valid"), 0, a)
    return np.apply_along_axis(
        lambda m: np.convolve(np.pad(m, r, mode="edge"), k, "valid"), 1, out)


# --------------------------------------------------------------- heights ----
def profile(spec, alpha, ss=SS):
    """authored height field over one part's own footprint"""
    h = np.zeros(alpha.shape, dtype=np.float64)
    if spec.kind == "flat":
        h[alpha] = spec.lo
    elif spec.kind == "cyl_x":
        for y in np.where(alpha.any(axis=1))[0]:
            xs = np.where(alpha[y])[0]
            x0, x1 = xs[0], xs[-1]
            span = max(x1 - x0, 1)
            t = (xs - x0) / span
            h[y, xs] = spec.lo + (spec.hi - spec.lo) * np.sqrt(
                np.clip(1 - (2 * t - 1) ** 2, 0, 1))
    elif spec.kind == "dome":
        from scipy.ndimage import distance_transform_edt
        d = distance_transform_edt(alpha)
        d = np.sqrt(d / max(d.max(), 1e-6))
        d = gaussian_blur(d, spec.blur * ss)
        d /= max(d[alpha].max(), 1e-6)
        h[alpha] = spec.lo + (spec.hi - spec.lo) * d[alpha]
    else:
        raise ValueError(spec.kind)
    return h


def compose_height(hull, frame, ss=SS):
    """painter's-order composition of authored per-part heights"""
    shape = (int(frame[3] * ss), int(frame[2] * ss))
    height = np.zeros(shape)
    covered = np.zeros(shape, dtype=bool)
    for layer in hull.layers:
        if layer.height is None or layer.role != "albedo":
            continue
        a = rasterize(layer.svg, frame, ss)[..., 3] > 0.5
        if not a.any():
            continue
        p = profile(layer.height, a, ss)
        height[a] = p[a]
        covered |= a
    return height, covered


def height_to_normals(height, z_scale):
    """+x right, +y down (image space), +z out of screen — same as lightspike"""
    gy, gx = np.gradient(height * z_scale * SS)
    n = np.dstack([-gx, -gy, np.ones_like(height)])
    return n / np.linalg.norm(n, axis=2, keepdims=True)


# ----------------------------------------------------------------- masks ----
# every color a ship's flat albedo may contain, per manufacturer — the
# classification universe; nearest-match needs the full set so AA pixels
# snap to their true parent color
RIJAY_PALETTE = [(59, 141, 224), (42, 102, 168), (238, 242, 246),
                 (95, 216, 232), (104, 109, 117), (52, 58, 68)]
PHE_PALETTE = [(223, 227, 230), (217, 122, 40), (168, 90, 30),
               (138, 143, 151), (104, 109, 117), (95, 216, 232),
               (154, 160, 168), (52, 58, 68)]


def classify_masks(rgb, alpha, c1_colors, c2_colors, palette):
    """(H,W,2) float: 1.0 where the pixel's nearest palette color is a c1
    (resp. c2) livery color. Fixed detail colors map to neither channel."""
    keys = list(palette)
    for c in list(c1_colors) + list(c2_colors):
        if c not in keys:
            keys.append(c)
    keys_a = np.array(keys, dtype=np.float64)
    px = (rgb * 255).reshape(-1, 3)
    nearest = ((px[:, None, :] - keys_a[None, :, :]) ** 2).sum(axis=2)
    nearest = nearest.argmin(axis=1).reshape(rgb.shape[:2])
    c1_idx = [keys.index(c) for c in c1_colors]
    c2_idx = [keys.index(c) for c in c2_colors]
    solid = alpha > 0.5
    m = np.zeros(rgb.shape[:2] + (2,))
    m[..., 0] = np.isin(nearest, c1_idx) & solid
    m[..., 1] = np.isin(nearest, c2_idx) & solid
    return m


# ---------------------------------------------------------------- export ----
@dataclass(frozen=True)
class ExportSpec:
    name: str
    build: object                 # () -> Hull
    classic_px: int               # Classic in-game sprite height
    model_units: int              # model-unit height the classic_px maps to
    c1: tuple                     # livery channel 1 colors (rgb tuples)
    c2: tuple                     # livery channel 2 colors
    palette: tuple                # full classification universe
    c1_base: tuple                # shader base color for tint math
    c2_base: tuple
    # Interior fit (M3.5 iteration 3): where the hull's deckplan tile grid
    # sits inside the exported sprite, so the client can draw the exterior
    # as a to-scale backdrop under the walkable tiles. Authored in MODEL
    # units — units_per_tile is the tile pitch; origin_units is the model
    # coordinate of deckplan tile (0,0)'s top-left corner, or None for the
    # sprite's own top-left (frame origin). export_ship converts to px and
    # writes meta["interior"] = {"px_per_tile", "origin_px"}. None = hull
    # has no walkable interior fit (e.g. the stock variant sheet).
    interior: object = None
    # Output px = (base render dims) * px_scale, where the base dims round
    # at classic_px/px_scale — so a *_interior export at px_scale 2 is
    # EXACTLY double its space twin (independent rounding would drift a
    # pixel and break the tile fit).
    px_scale: int = 1


RIJ_C1, RIJ_C2 = (59, 141, 224), (238, 242, 246)
PHE_C1, PHE_C2 = (217, 122, 40), (223, 227, 230)


def _mb(stock):
    from manufacturers import ship_mockingbird
    return ship_mockingbird(stock=stock)


def _lh():
    from manufacturers import ship_longhorn
    return ship_longhorn()


# Mockingbird interior fit (iteration 4 scale canon): ONE TILE ~ 1 m.
# The hull is 14 tiles wide x 30 long -> 6.5 model units per tile. The
# SPACE export stays Classic 21x45 px (1.5 px/tile — every hull renders at
# 1.5 px/tile in space so relative sizes read true); the *_interior export
# renders the same hull at 2x (42x90 px, 3 px/tile) for the walk-mode
# backdrop. The deckplan grid (14x20) covers sprite rows 0-19 of 30; the
# drums/engines behind the docking corridor are exterior-only sprite.
MB_INTERIOR = {"units_per_tile": 6.5, "origin_units": None}

SHIP_EXPORTS = [
    ExportSpec("mockingbird", lambda: _mb(False), 45, 195,
               ((59, 141, 224),), ((238, 242, 246),), tuple(RIJAY_PALETTE),
               RIJ_C1, RIJ_C2, interior=MB_INTERIOR),
    ExportSpec("mockingbird_interior", lambda: _mb(False), 90, 195,
               ((59, 141, 224),), ((238, 242, 246),), tuple(RIJAY_PALETTE),
               RIJ_C1, RIJ_C2, interior=MB_INTERIOR, px_scale=2),
    ExportSpec("mockingbird_stock", lambda: _mb(True), 45, 195,
               ((59, 141, 224),), ((238, 242, 246),), tuple(RIJAY_PALETTE),
               RIJ_C1, RIJ_C2, interior=MB_INTERIOR),
    # Longhorn livery: c1 = the orange trim, c2 = the gray body (it has no
    # truss white — the body IS the paintable surface on a liner)
    ExportSpec("longhorn", _lh, 41, 195,
               ((217, 122, 40), (168, 90, 30)),
               ((138, 143, 151), (223, 227, 230)),
               tuple(PHE_PALETTE), PHE_C1, (138, 143, 151)),
]


def _downsample(arr, size, mode):
    """PIL-based BOX resize; mode 'rgba' for color, 'f' for float fields"""
    if mode == "rgba":
        img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8),
                              "RGBA")
        return np.asarray(img.resize(size, Image.BOX)).astype(np.float64) / 255.0
    img = Image.fromarray(arr.astype(np.float32), "F")
    return np.asarray(img.resize(size, Image.BOX)).astype(np.float64)


def compose_ship(spec):
    """full-res compose: returns dict of working arrays + frame"""
    hull = spec.build()
    frame = hull_frame(hull)
    albedo = rasterize(flatten(hull, sheet=False), frame)
    height, covered = compose_height(hull, frame)
    solid = albedo[..., 3] > 0.5
    # paint-only fringes (stripes/strokes overhanging every height layer):
    # take the nearest covered part's height so they don't punch cliffs
    if (~covered & solid).any():
        from scipy.ndimage import distance_transform_edt
        _, (iy, ix) = distance_transform_edt(~covered, return_indices=True)
        height = np.where(~covered & solid, height[iy, ix], height)
    height = gaussian_blur(height, SS * 0.6) * solid
    masks = classify_masks(albedo[..., :3], albedo[..., 3],
                           spec.c1, spec.c2, spec.palette)
    return dict(hull=hull, frame=frame, albedo=albedo, height=height,
                solid=solid, masks=masks)


def export_ship(spec, out_root, z_scale=6.5):
    c = compose_ship(spec)
    frame, hull = c["frame"], c["hull"]
    px_per_unit = spec.classic_px / spec.model_units
    base_ppu = px_per_unit / spec.px_scale
    pw = max(1, round(frame[2] * base_ppu)) * spec.px_scale
    ph = max(1, round(frame[3] * base_ppu)) * spec.px_scale
    albedo_g = _downsample(c["albedo"], (pw, ph), "rgba")
    height_g = _downsample(c["height"], (pw, ph), "f")
    solid_g = _downsample(c["solid"].astype(np.float64), (pw, ph), "f") > 0.5
    normals = height_to_normals(height_g, z_scale=z_scale / SS)
    normals[~solid_g] = [0.0, 0.0, 1.0]
    mask_g = np.dstack([_downsample(c["masks"][..., i], (pw, ph), "f")
                        for i in (0, 1)] + [np.zeros((ph, pw))])
    out = pathlib.Path(out_root) / spec.name
    out.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(albedo_g, 0, 1) * 255).astype(np.uint8),
                    "RGBA").save(out / "albedo.png")
    n = normals.copy()
    n[..., 1] *= -1.0                                  # image Y-down -> GL Y-up
    Image.fromarray(np.round((n + 1) / 2 * 255).astype(np.uint8), "RGB").save(
        out / "normal.png")
    Image.fromarray((np.clip(mask_g, 0, 1) * 255).astype(np.uint8),
                    "RGB").save(out / "mask.png")
    meta = {
        "name": spec.name, "px_w": pw, "px_h": ph,
        "px_per_unit": px_per_unit, "frame": list(frame),
        "classic_px": spec.classic_px,
        "c1_base": list(spec.c1_base), "c2_base": list(spec.c2_base),
        "anchors": [{"kind": a.kind,
                     "x_px": (a.x - frame[0]) * px_per_unit,
                     "y_px": (a.y - frame[1]) * px_per_unit}
                    for a in hull.anchors],
    }
    if spec.interior is not None:
        origin = spec.interior["origin_units"]
        if origin is None:
            origin = (frame[0], frame[1])
        ox, oy = origin
        meta["interior"] = {
            "px_per_tile": spec.interior["units_per_tile"] * px_per_unit,
            "origin_px": [(ox - frame[0]) * px_per_unit,
                          (oy - frame[1]) * px_per_unit],
        }
    (out / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return meta


# ----------------------------------------------------------- debug sheet ----
STEP_LIT = np.array([1.20, 1.10, 0.95])
STEP_MID = np.array([0.74, 0.74, 0.82])
STEP_SHADOW = np.array([0.34, 0.38, 0.58])


def lit_preview(albedo, normals, solid, sun_deg):
    """quantized 3-step lighting, sun direction given as screen angle"""
    a = np.radians(sun_deg)
    sun = np.array([np.cos(a), np.sin(a), 0.75])
    sun /= np.linalg.norm(sun)
    d = np.clip((normals * sun).sum(axis=2), 0.0, 1.0)
    mult = np.where(d[..., None] >= 0.62, STEP_LIT,
                    np.where(d[..., None] >= 0.32, STEP_MID, STEP_SHADOW))
    out = albedo.copy()
    lit = np.clip(albedo[..., :3] * mult, 0, 1)
    out[..., :3] = np.where(solid[..., None], lit, albedo[..., :3])
    return out


def _cell(img_arr, box):
    img = Image.fromarray((np.clip(img_arr, 0, 1) * 255).astype(np.uint8),
                          "RGBA")
    img.thumbnail(box, Image.LANCZOS)
    return img


def build_debug_sheet(out_path, exports=None):
    from lightspike import font, BG, LABEL
    from PIL import ImageDraw
    exports = SHIP_EXPORTS if exports is None else exports
    W, row_h, top = 1540, 320, 70
    H = top + row_h * len(exports) + 20
    bg = tuple(int(BG[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
    lab = tuple(int(LABEL[i:i + 2], 16) for i in (1, 3, 5))
    sheet = Image.new("RGBA", (W, H), bg)
    draw = ImageDraw.Draw(sheet)
    draw.text((26, 16), "DISTANT HORIZON — part-composer pipeline (M3.5 PR 1)",
              font=font(20), fill=(195, 202, 214))
    draw.text((26, 42), "authored per-part heights (flat/cyl/dome), derived "
              "normals, c1/c2 masks, quantized lit previews (sun sweep), "
              "game-res export", font=font(12), fill=lab)
    cols = ["ALBEDO (flat)", "HEIGHT", "NORMALS", "MASKS c1=R c2=G",
            "LIT -45", "LIT 200", "LIT 90", "GAME 1x/3x"]
    for i, name in enumerate(cols):
        draw.text((30 + i * 180, top - 4), name, font=font(11), fill=lab)
    for r, spec in enumerate(exports):
        c = compose_ship(spec)
        y0 = top + 18 + r * row_h
        # z=28 at SS res is slope-equivalent to the export's z=6.5 at game res
        normals_hi = height_to_normals(c["height"], z_scale=28.0)
        box = (170, row_h - 50)
        sheet.alpha_composite(_cell(c["albedo"], box), (30, y0))
        hh = c["height"] / max(c["height"].max(), 1e-6)
        sheet.alpha_composite(_cell(np.dstack([hh] * 3 +
                                              [np.ones_like(hh)]), box),
                              (30 + 180, y0))
        nviz = (normals_hi + 1) / 2
        nviz[~c["solid"]] = (0.5, 0.5, 1.0)
        sheet.alpha_composite(_cell(np.dstack([nviz,
                                               np.ones(hh.shape + (1,))]),
                                    box), (30 + 360, y0))
        mviz = np.dstack([c["masks"][..., 0], c["masks"][..., 1],
                          np.zeros_like(hh), c["albedo"][..., 3]])
        sheet.alpha_composite(_cell(mviz, box), (30 + 540, y0))
        for j, sd in enumerate((-45, 200, 90)):
            lit = lit_preview(c["albedo"], normals_hi, c["solid"], sd)
            sheet.alpha_composite(_cell(lit, box), (30 + 720 + j * 180, y0))
        # game-res: what actually ships
        px_per_unit = spec.classic_px / spec.model_units
        pw = max(1, round(c["frame"][2] * px_per_unit))
        ph = max(1, round(c["frame"][3] * px_per_unit))
        albedo_g = _downsample(c["albedo"], (pw, ph), "rgba")
        height_g = _downsample(c["height"], (pw, ph), "f")
        solid_g = _downsample(c["solid"].astype(np.float64),
                              (pw, ph), "f") > 0.5
        normals_g = height_to_normals(height_g, z_scale=6.5 / SS)
        normals_g[~solid_g] = [0.0, 0.0, 1.0]
        lit_g = lit_preview(albedo_g, normals_g, solid_g, -45)
        one = Image.fromarray((np.clip(lit_g, 0, 1) * 255).astype(np.uint8),
                              "RGBA")
        sheet.alpha_composite(one, (30 + 1260, y0))
        # 3x nearest blowup only when it fits the sheet (ships yes, stations no)
        if 1260 + pw + 12 + pw * 3 < W - 40:
            three = one.resize((pw * 3, ph * 3), Image.NEAREST)
            sheet.alpha_composite(three, (30 + 1260 + pw + 12, y0))
        draw.text((30, y0 + row_h - 28), spec.name.upper(), font=font(13),
                  fill=lab)
    sheet.convert("RGB").save(out_path)
    print("wrote", out_path)


def main():
    root = pathlib.Path(__file__).parents[2]
    out_root = root / "client" / "assets" / "ships"
    for spec in SHIP_EXPORTS:
        meta = export_ship(spec, out_root)
        print(f"exported {spec.name}: {meta['px_w']}x{meta['px_h']} px, "
              f"{len(meta['anchors'])} anchors")
    build_debug_sheet(pathlib.Path(__file__).parent / "sheet_composer.png")


if __name__ == "__main__":
    main()
