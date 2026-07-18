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
    """tight frame around the flat albedo, padded, in model units"""
    probe = rasterize(flatten(hull, sheet=False), (-200, -200, 400, 400), ss=1)
    ys, xs = np.where(probe[..., 3] > 0.1)
    minx, maxx = xs.min() - 200 - pad, xs.max() - 200 + pad
    miny, maxy = ys.min() - 200 - pad, ys.max() - 200 + pad
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
