"""lightspike — spike round 3: dynamic 2D lighting for parts-composed hulls.

Question (docs/visuals.md, The void): ships rotate freely, so baked shading is
out. Can we author sprites unlit + derive height/normal maps mechanically, then
light them at runtime from a fixed sun — and does it still read as pixel art at
20-64 px once the lighting is quantized to a few steps?

This is the offline proof: same math a Godot canvas shader would run
(DirectionalLight2D + normal map + posterize), done in numpy so we can eyeball
a sheet before touching the engine. Height maps come for free because shipforge
draws the parts — here approximated from the rendered art (silhouette doming +
per-palette-color offsets); the real pipeline would emit height per part.

Run:  pip install resvg-py pillow numpy && python lightspike.py
Out:  sheet_light.png
"""
import io
import math
import pathlib

import numpy as np
import resvg_py
from PIL import Image, ImageDraw, ImageFont

from manufacturers import ship_kx6
from shipforge import group, BG, LABEL

# ------------------------------------------------------------------ config ---
SS = 4              # supersample factor (model units -> px)
FRAME = 210         # model units per frame side (fits rotated hull + margin)
CLASSIC_PX = 52     # kx6 XR's Classic in-game sprite height
MODEL_UNITS = 175   # its height in model units
ROTATIONS = [0, 35, 70, 105, 140, 180, 220, 300]

# direction TO the sun, screen coords (y down), fixed for all rotations
SUN = np.array([-0.62, -0.62, 0.48])
SUN = SUN / np.linalg.norm(SUN)

# height offsets per palette color (model-space "how tall is this part")
# glow colors are emissive: excluded from geometry, bypass lighting
GLOW_COLORS = [(255, 227, 176), (255, 157, 77)]
# albedo colors that are baked pseudo-lighting, flattened to their base color
# before lighting: painted highlights contradict the dynamic sun at off-axis
# headings (production rule: lit-pipeline art is authored FLAT)
FLATTEN = {(222, 75, 75): (201, 47, 47)}   # RADI_RED_HI -> RADI_RED

OFFSETS = {
    (201, 47, 47): 0.00,     # RADI_RED base hull
    (222, 75, 75): 0.00,     # RADI_RED_HI (flattened away, no relief)
    (143, 31, 31): -0.04,    # RADI_RED_D recessed
    (154, 160, 168): 0.02,   # RADI_TRIM trim lines, slightly proud
    (95, 216, 232): 0.12,    # GLASS canopy dome
    (58, 32, 32): -0.10,     # recessed engine slot
    (52, 58, 68): -0.05,     # INK outlines/panel lines = grooves
}

# quantized light steps: albedo multipliers, warm key / cool ambient
STEP_LIT = np.array([1.20, 1.10, 0.95])
STEP_MID = np.array([0.74, 0.74, 0.82])
STEP_SHADOW = np.array([0.34, 0.38, 0.58])


# ------------------------------------------------------------- render + math -
def render_frame(rot_deg):
    """render the hull alone, rotated, transparent bg -> RGBA float array"""
    half = FRAME / 2
    body = group(ship_kx6(), rot=rot_deg)
    defs = ('<defs><radialGradient id="glow">'
            '<stop offset="0%" stop-color="#ff9d4d" stop-opacity="0.95"/>'
            '<stop offset="100%" stop-color="#ff9d4d" stop-opacity="0"/>'
            '</radialGradient></defs>')
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{FRAME * SS}" '
           f'height="{FRAME * SS}" viewBox="{-half} {-half} {FRAME} {FRAME}">'
           f'{defs}{body}</svg>')
    png = resvg_py.svg_to_bytes(svg_string=svg, width=FRAME * SS)
    img = Image.open(io.BytesIO(bytes(png))).convert("RGBA")
    return np.asarray(img).astype(np.float64) / 255.0


def gaussian_blur(a, sigma):
    """separable gaussian via np.convolve, edge-padded"""
    r = max(1, int(sigma * 3))
    x = np.arange(-r, r + 1)
    k = np.exp(-0.5 * (x / sigma) ** 2)
    k /= k.sum()
    out = np.apply_along_axis(
        lambda m: np.convolve(np.pad(m, r, mode="edge"), k, "valid"), 0, a)
    out = np.apply_along_axis(
        lambda m: np.convolve(np.pad(m, r, mode="edge"), k, "valid"), 1, out)
    return out


def classify(rgb, alpha):
    """nearest-palette-color offset per pixel + emissive mask"""
    h, w, _ = rgb.shape
    px = (rgb * 255).reshape(-1, 3)
    keys = np.array(list(OFFSETS.keys()) + GLOW_COLORS, dtype=np.float64)
    vals = np.array(list(OFFSETS.values()) + [0.0] * len(GLOW_COLORS))
    d = ((px[:, None, :] - keys[None, :, :]) ** 2).sum(axis=2)
    nearest = d.argmin(axis=1)
    offs = vals[nearest].reshape(h, w)
    emissive = (nearest >= len(OFFSETS)).reshape(h, w) & (alpha > 0.1)
    offs[emissive] = 0.0
    return offs, emissive


def distance_inside(solid):
    """EXACT Euclidean distance to the silhouette edge. Approximate DTs
    (city-block, chamfer) are not good enough here: their iso-contours are
    diamonds/octagons, so the height gradient quantizes into 4/8 directions
    and the hull shades as planar facets at off-axis headings. (Spike-only
    code anyway — the real pipeline gets height from the part composer, not
    from a distance transform.)"""
    from scipy.ndimage import distance_transform_edt
    return distance_transform_edt(solid > 0.5)


def build_height(alpha, offsets, emissive):
    """silhouette doming (rounded-cylinder profile from a distance transform)
    + detail offsets = height field"""
    solid = ((alpha > 0.55) & ~emissive).astype(np.float64)
    dt = distance_inside(solid)
    dome = np.sqrt(np.clip(dt / max(dt.max(), 1e-6), 0, 1))
    # a distance dome is a TENT: straight outline stretches give planar
    # constant-gradient flanks with creases along the hull skeleton, and the
    # quantizer renders those as facets. A heavy blur melts creases into
    # actual curvature (and softens the silhouette falloff, which reads nicer)
    dome = gaussian_blur(dome, SS * 7.0) * solid
    dome /= max(dome.max(), 1e-6)
    detail = gaussian_blur(offsets * solid, SS * 1.6)      # soften plateaus
    # detail stays well under the dome: painted-on highlight/trim shapes have
    # hard polygon edges, and at full strength those edges put ridges in the
    # normals that the quantizer turns into facets at off-axis headings
    height = dome * 1.0 + detail * 0.35
    return gaussian_blur(height, SS * 0.35), solid


def height_to_normals(height, z_scale):
    gy, gx = np.gradient(height * z_scale * SS)
    n = np.dstack([-gx, -gy, np.ones_like(height)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    return n


def flatten_albedo(rgba, alpha):
    """replace baked-highlight colors with their base color (nearest-match)"""
    out = rgba.copy()
    px = (rgba[..., :3] * 255).reshape(-1, 3)
    for src, dst in FLATTEN.items():
        d = ((px - np.array(src, dtype=np.float64)) ** 2).sum(axis=1)
        hit = (d < 900).reshape(rgba.shape[:2]) & (alpha > 0.1)
        out[..., :3][hit] = np.array(dst, dtype=np.float64) / 255.0
    return out


def light(rgba, normals, solid, emissive):
    """fixed-sun diffuse, quantized to 3 steps, warm lit / cool shadow"""
    albedo = rgba[..., :3]
    d = np.clip((normals * SUN).sum(axis=2), 0.0, 1.0)
    mult = np.where(d[..., None] >= 0.62, STEP_LIT,
                    np.where(d[..., None] >= 0.32, STEP_MID, STEP_SHADOW))
    lit = albedo * mult
    keep = (solid < 0.5)[..., None] | emissive[..., None]
    out = rgba.copy()
    out[..., :3] = np.clip(np.where(keep, albedo, lit), 0, 1)
    return out


# ------------------------------------------------------------------- sheet ---
def to_img(a):
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8), "RGBA")


def viz_gray(a):
    g = (np.clip(a / max(a.max(), 1e-6), 0, 1) * 255).astype(np.uint8)
    return Image.merge("RGBA", [Image.fromarray(g)] * 3 +
                       [Image.fromarray(np.full_like(g, 255))])


def viz_normals(n, solid):
    v = ((n + 1) / 2 * 255).astype(np.uint8)
    v[solid < 0.5] = (128, 128, 255)
    rgb = Image.fromarray(v, "RGB").convert("RGBA")
    return rgb


def font(size):
    try:
        return ImageFont.truetype("C:/Windows/Fonts/consola.ttf", size)
    except OSError:
        return ImageFont.load_default()


def main():
    frames = {}
    for rot in ROTATIONS:
        rgba = render_frame(rot)
        offsets, emissive = classify(rgba[..., :3], rgba[..., 3])
        rgba = flatten_albedo(rgba, rgba[..., 3])
        height, solid = build_height(rgba[..., 3], offsets, emissive)
        normals = height_to_normals(height, z_scale=28.0)
        lit = light(rgba, normals, solid, emissive)
        frames[rot] = dict(rgba=rgba, height=height, solid=solid,
                           normals=normals, lit=lit)
        print(f"rot {rot:3d} done")

    W, H = 1240, 1000
    bg = tuple(int(BG[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
    sheet = Image.new("RGBA", (W, H), bg)
    draw = ImageDraw.Draw(sheet)
    lab = tuple(int(LABEL[i:i + 2], 16) for i in (1, 3, 5))
    draw.text((26, 20), "DISTANT HORIZON — dynamic lighting spike (round 3)",
              font=font(20), fill=(195, 202, 214))
    draw.text((26, 46), "unlit albedo + derived height/normals, fixed sun, "
              "quantized 3-step shading — the ship rotates, the light doesn't",
              font=font(12), fill=lab)

    # row 1: the maps (rot 35 so doming is visibly rotation-independent)
    f = frames[35]
    row1 = [("ALBEDO (authored)", to_img(f["rgba"])),
            ("HEIGHT (derived)", viz_gray(f["height"])),
            ("NORMALS (derived)", viz_normals(f["normals"], f["solid"]))]
    for i, (name, img) in enumerate(row1):
        cell = img.resize((250, 250), Image.LANCZOS)
        sheet.alpha_composite(cell, (40 + i * 290, 80))
        draw.text((40 + i * 290 + 125 - draw.textlength(name, font=font(13)) / 2,
                   338), name, font=font(13), fill=lab)
    sun_px = (1000, 130)
    draw.text((950, 90), "SUN", font=font(13), fill=(255, 227, 176))
    draw.line([sun_px, (sun_px[0] + 90, sun_px[1] + 90)],
              fill=(255, 227, 176), width=2)
    draw.polygon([(sun_px[0] + 90, sun_px[1] + 90),
                  (sun_px[0] + 74, sun_px[1] + 84),
                  (sun_px[0] + 84, sun_px[1] + 74)], fill=(255, 227, 176))
    draw.text((950, 240), "fixed for\nall frames", font=font(12), fill=lab)

    # row 2: lit hull under fixed sun, 8 rotations
    draw.text((40, 380), "LIT, FIXED SUN — 8 SHIP HEADINGS",
              font=font(13), fill=lab)
    for i, rot in enumerate(ROTATIONS):
        cell = to_img(frames[rot]["lit"]).resize((140, 140), Image.LANCZOS)
        sheet.alpha_composite(cell, (40 + i * 148, 402))
        t = f"{rot}°"
        draw.text((40 + i * 148 + 70 - draw.textlength(t, font=font(12)) / 2,
                   546), t, font=font(12), fill=lab)

    # row 3: game scale (Classic sprite height) + 3x nearest blowup
    draw.text((40, 590), f"AT GAME SCALE (hull {CLASSIC_PX} px) — "
              "the readability test that matters", font=font(13), fill=lab)
    game_px = int(FRAME * CLASSIC_PX / MODEL_UNITS)   # frame px at game scale
    for i, rot in enumerate(ROTATIONS):
        small = to_img(frames[rot]["lit"]).resize((game_px, game_px),
                                                  Image.BOX)
        sheet.alpha_composite(small, (60 + i * 148, 626))
        big = small.resize((game_px * 3, game_px * 3), Image.NEAREST)
        sheet.alpha_composite(big, (40 + i * 148, 700))
    draw.text((40, 604 + 16), "1x", font=font(11), fill=lab)
    draw.text((40, 700 + game_px * 3 + 4), "same, 3x nearest-neighbor",
              font=font(11), fill=lab)

    out = pathlib.Path(__file__).parent / "sheet_light.png"
    sheet.convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
