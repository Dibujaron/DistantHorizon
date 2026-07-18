# M3.5 PR 1 — Part-Composer Asset Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the locked Mockingbird (and the Longhorn, as the anti-overfit test) into
lit-pipeline game assets: flat albedo + authored per-part height maps → normals + c1/c2
livery masks + anchor metadata, exported to `client/assets/ships/`, verified in the Godot
toy scene under one sun and two.

**Architecture:** Ship part functions in `tools/artspike/manufacturers.py` stop returning
one SVG string and start returning a `Hull` — an ordered list of `Layer`s, where each
layer carries its SVG fragment plus an *authored height profile* (`flat`/`cyl_x`/`dome`
— NEVER whole-ship silhouette doming; that was explicitly rejected because it only works
on blob hulls) and a role (`albedo` / `sheet_only` painted-shading / `glow` emissive).
A new `tools/artspike/composer.py` rasterizes layers individually at supersample
resolution, composes heights in painter's order, derives normals mechanically, classifies
c1/c2 livery masks from the strict palette, and writes game-resolution PNGs + `meta.json`
per ship. The existing sheet builders keep working through a flatten adapter, with a
byte-identical regression test protecting the locked Mockingbird render.

**Tech Stack:** Python (resvg_py, numpy, scipy, Pillow, pytest) for the pipeline;
Godot 4.7 gl_compatibility (CanvasTexture + DirectionalLight2D + quantize canvas shader)
for verification in `tools/artspike/godot/`.

## Global Constraints

- Never commit to main — all work on branch `m3.5-vibe-pass`, PR for review (already created, artspike round-4 changes ride it).
- The Mockingbird design is LOCKED (canon block in `manufacturers.py:241-253`) — the refactor must not change its rendered look; the sheet regression test enforces this.
- Height maps are AUTHORED per part; normals are derived from composed authored heights. No "farther from edge = higher" whole-ship rule.
- Lit-pipeline albedo is FLAT: painted-shading overlays (`shrink` highlights, pod shade bands) are `sheet_only` and excluded from export.
- Glow/plume art is excluded from exports — plumes become throttle-driven dynamic art in PR 2; the composer emits nozzle anchors instead.
- Two livery channels: c1/c2 masks + per-ship base colors in meta.json (Mockingbird: c1=RIJ_BLUE, c2=RIJ_WHITE; Longhorn: c1=PHE_POD, c2=PHE_TRUSS). Dark blue / gray / glass / ink are fixed detail, never tinted.
- Normal maps export in OpenGL convention (green = Y-up); background pixels = (128,128,255). LIGHT.a must stay 1.0 in the shader; LIGHT_DIRECTION points toward the light.
- Python runs from repo root or `tools/artspike`; Godot via scoop shims: `$env:PATH = "$env:USERPROFILE\scoop\shims;$env:PATH"`.
- Don't block on user eyeball review: publish sheets to the art-spike artifact, queue questions, keep working.

---

### Task 1: Layer model + Hull refactor of Mockingbird and Longhorn (render-identical)

**Files:**
- Create: `tools/artspike/composer.py` (just the model + flatten adapter for now)
- Create: `tools/artspike/test_composer.py`
- Modify: `tools/artspike/manufacturers.py` (Mockingbird + Longhorn parts → Layers; sheet builder goes through adapter)
- Modify: `tools/artspike/mockingbird_litcheck.py` (adapt to Hull via flatten)

**Interfaces:**
- Produces: `Height` dataclass with constructors `flat(v)`, `cyl_x(lo, hi)`, `dome(lo, hi, blur=6.0)`; `Layer(svg, height=None, role="albedo")`; `Anchor(kind, x, y)`; `Hull(layers, anchors)`; `flatten(hull_or_str, sheet=True) -> str` (sheet=True keeps `sheet_only` + `glow` layers → exact old string; sheet=False drops both = flat albedo fragment list).
- `ship_mockingbird(stock=False) -> Hull`, `ship_longhorn() -> Hull`. All other ships keep returning `str`.

- [ ] **Step 1: Write the failing regression + model tests**

`tools/artspike/test_composer.py`:

```python
"""Tests for the M3.5 part-composer pipeline. Run: python -m pytest tools/artspike -q"""
import pathlib

import numpy as np
import pytest

HERE = pathlib.Path(__file__).parent


def test_sheet_mfr_render_identical():
    """The locked Mockingbird (and everything else) must render byte-identically
    through the Layer refactor. sheet_mfr.svg on disk is the canon render."""
    import manufacturers
    assert manufacturers.build_sheet() == (HERE / "sheet_mfr.svg").read_text(
        encoding="utf-8")


def test_mockingbird_is_hull_with_heights():
    from manufacturers import ship_mockingbird
    hull = ship_mockingbird()
    kinds = {l.height.kind for l in hull.layers if l.height is not None}
    assert {"cyl_x", "dome", "flat"} <= kinds          # authored variety, not doming
    assert [a for a in hull.anchors if a.kind == "nozzle"]  # 3 drums
    assert len([a for a in hull.anchors if a.kind == "nozzle"]) == 3
    assert any(l.role == "glow" for l in hull.layers)  # glow separated for exclusion
    assert any(l.role == "sheet_only" for l in hull.layers)  # painted highlight split


def test_longhorn_foil_is_flat_plate():
    """The anti-overfit case: the hammer foil authors a thin flat profile."""
    from manufacturers import ship_longhorn
    hull = ship_longhorn()
    foils = [l for l in hull.layers if l.height and l.height.kind == "flat"]
    assert foils, "Longhorn must have flat-plate layers (the hammer foil)"
    assert len([a for a in hull.anchors if a.kind == "nozzle"]) == 2
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m pytest tools/artspike -q` (install pytest first if missing: `python -m pip install pytest`)
Expected: FAIL — `ship_mockingbird` has no `.layers`; imports of composer model fail.
(`test_sheet_mfr_render_identical` should PASS already — confirm by running
`python tools/artspike/manufacturers.py` and checking `git diff --stat tools/artspike/sheet_mfr.svg` is empty first; if the on-disk svg is stale, regenerate and commit it as the baseline BEFORE refactoring.)

- [ ] **Step 3: Add the model to `composer.py`**

```python
"""composer — M3.5 part-composer pipeline (PR 1).

Ships are ordered Layer lists. Each layer carries an SVG fragment plus an
AUTHORED height profile — a drum says "I'm a cylinder", a wing says "I'm a
flat plate", a fuselage says "I'm a rounded solid". Heights compose in
painter's order exactly like albedo. Normals are derived from the composed
authored heights; nothing is inferred from the whole-ship silhouette.
"""
from dataclasses import dataclass, field


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
    layers: list[Layer] = field(default_factory=list)
    anchors: list[Anchor] = field(default_factory=list)


def flatten(hull_or_str, sheet=True):
    """Hull -> single SVG string. sheet=True reproduces the legacy sheet look
    (painted highlights + engine glow); sheet=False is the flat lit-pipeline
    albedo (no painted light, no emissive)."""
    if isinstance(hull_or_str, str):
        return hull_or_str
    keep = ("albedo", "sheet_only", "glow") if sheet else ("albedo",)
    return "".join(l.svg for l in hull_or_str.layers if l.role in keep)
```

- [ ] **Step 4: Refactor `ship_mockingbird` + helpers in `manufacturers.py`**

Import at top: `from composer import Hull, Layer, Anchor, flat, cyl_x, dome, flatten`.
Rules of the refactor — split at existing string-concatenation seams only, preserving
emission order exactly so `flatten(hull)` equals the old string:

- `mb_drums(stock)` → `list[Layer]` + nozzle anchors. Per drum `i in (-1, 0, 1)`:
  body rrect = `Layer(..., cyl_x(0.40, 0.78))`; stock stripe line = paint `Layer(...)`;
  collar rrect = `Layer(..., cyl_x(0.38, 0.60))`; the two glow ellipses =
  `Layer(..., role="glow")` each. Anchor per drum: `Anchor("nozzle", cx, MB_Y + MB_LN + 3.5)`.
- `mb_dorsal_fins()` → one `Layer(poly, flat(0.82))` per ridge (3 layers).
- `mb_outboard_fins()` → per side: fin poly `Layer(..., flat(0.33))`, white edge path = paint.
- `mb_ports()` → per side: dormer rrect `Layer(..., flat(0.52))`, seam-cover rrect +
  door rrect + button circles = paint layers (tiny, ride the dormer's height).
- `mb_canopy()` → glass path `Layer(..., dome(0.58, 0.74, blur=2.0))`, strut lines paint.
- `ship_mockingbird(stock=False)` → `Hull`. Layer order = old draw order:
  outboard fins (not stock), hull path `Layer(..., dome(0.35, 0.62, blur=8.0))`,
  highlight `group(hi, ty=-4, scale=.85)` = `Layer(..., role="sheet_only")`,
  dorsal stripe + flank stripes = paint layers, drums, dorsal fins (not stock),
  ports, canopy.

Then `ship_longhorn()` → `Hull` the same way:
- outrigger crossbar rrect `flat(0.30)`; per side: pod rrect `cyl_x(0.32, 0.50)`,
  orange rail rrect `flat(0.45)`, nozzle poly `flat(0.28)`, glow ellipse `role="glow"`;
  anchors `Anchor("nozzle", ±40, 52)`.
- hammer poly `flat(0.40)` — THE anti-overfit case: a wide thin foil that must not dome;
  shrink-overlay poly `role="sheet_only"`; wingtip caps `flat(0.44)`; windows/seams/vents paint.
- glass block rrect `flat(0.46)` + glass pane/strut paint.
- neck rrect `cyl_x(0.42, 0.58)`; rib rrects `flat(0.50)`; neck windows paint.
- lower body poly `dome(0.36, 0.60, blur=6.0)`; shrink overlay `role="sheet_only"`;
  lounge glass + grid lines paint; stern nub poly `flat(0.38)`.

Adapt callers in `manufacturers.py::build_sheet` — where `fn()` is used:
`body += group(flatten(fn()), x, cy, scale=sc)` (both the display row and the
game-scale strip). In `mockingbird_litcheck.py`:
`L.ship_kx6 = lambda: flatten(ship_mockingbird())`.

- [ ] **Step 5: Run tests + regenerate the sheet to prove render-identity**

Run: `python -m pytest tools/artspike -q` → all PASS.
Run: `python tools/artspike/manufacturers.py; git diff --stat tools/artspike/sheet_mfr.svg`
Expected: empty diff (byte-identical svg).

- [ ] **Step 6: Commit**

```bash
git add tools/artspike/composer.py tools/artspike/test_composer.py tools/artspike/manufacturers.py tools/artspike/mockingbird_litcheck.py
git commit -m "feat(art): Layer/Hull model - Mockingbird and Longhorn author per-part height profiles"
```

---

### Task 2: Rasterizer + height composition + normals in `composer.py`

**Files:**
- Modify: `tools/artspike/composer.py`
- Test: `tools/artspike/test_composer.py`

**Interfaces:**
- Consumes: `Hull`/`Layer`/`Height` from Task 1.
- Produces: `rasterize(svg_fragment, frame, ss=4) -> np.ndarray (H,W,4 float)`;
  `hull_frame(hull, pad=8.0) -> (minx, miny, w, h)` (tight bbox from the flat albedo alpha, padded, centered);
  `compose_height(hull, frame, ss=4) -> (height, covered)` painter's-order authored heights;
  `profile(height_spec, alpha, ss) -> np.ndarray`;
  `height_to_normals(height, z_scale) -> (H,W,3)` (+x right, +y down, +z out; same math as lightspike).

- [ ] **Step 1: Write the failing tests**

Append to `test_composer.py`:

```python
def _rect_alpha(h, w, y0, y1, x0, x1):
    a = np.zeros((h, w), dtype=bool)
    a[y0:y1, x0:x1] = True
    return a


def test_profile_flat():
    from composer import flat, profile
    a = _rect_alpha(40, 40, 10, 30, 5, 35)
    p = profile(flat(0.5), a, ss=1)
    assert np.allclose(p[a], 0.5)
    assert np.allclose(p[~a], 0.0)


def test_profile_cyl_x_is_round_per_row():
    from composer import cyl_x, profile
    a = _rect_alpha(40, 41, 5, 35, 10, 31)          # 21 px wide span
    p = profile(cyl_x(0.2, 0.8), a, ss=1)
    row = p[20, 10:31]
    assert row[10] == pytest.approx(0.8, abs=0.02)   # center = hi
    assert row[0] == pytest.approx(0.2, abs=0.05)    # edges = lo
    assert row[0] == pytest.approx(row[-1], abs=0.02)  # symmetric
    assert row[5] > row[2] > row[0]                  # circular, monotone flank


def test_profile_dome_peaks_center():
    from composer import dome, profile
    a = np.zeros((60, 60), dtype=bool)
    yy, xx = np.mgrid[0:60, 0:60]
    a[(yy - 30) ** 2 + (xx - 30) ** 2 < 24 ** 2] = True
    p = profile(dome(0.3, 0.7, blur=2.0), a, ss=1)
    assert p[30, 30] == pytest.approx(0.7, abs=0.05)
    assert p[30, 8] < 0.45                           # near rim ~ lo


def test_compose_height_painter_order():
    from composer import Hull, Layer, flat, compose_height
    base = '<rect x="-20" y="-20" width="40" height="40" fill="#3b8de0" stroke="none"/>'
    top = '<rect x="-5" y="-5" width="10" height="10" fill="#eef2f6" stroke="none"/>'
    hull = Hull(layers=[Layer(base, flat(0.4)), Layer(top, flat(0.9))])
    h, covered = compose_height(hull, frame=(-25, -25, 50, 50), ss=2)
    assert h[50, 50] == pytest.approx(0.9, abs=0.02)   # center: later layer wins
    assert h[50, 20] == pytest.approx(0.4, abs=0.02)   # off-center: base
    assert covered[50, 50] and not covered[2, 2]


def test_normals_flat_plate_faces_camera():
    from composer import height_to_normals
    h = np.full((30, 30), 0.5)
    n = height_to_normals(h, z_scale=28.0)
    assert np.allclose(n[10:20, 10:20], [0, 0, 1], atol=1e-6)


def test_normals_slope_sign():
    """height rising to the right -> normal tilts LEFT (negative x)."""
    from composer import height_to_normals
    h = np.tile(np.linspace(0, 1, 30), (30, 1))
    n = height_to_normals(h, z_scale=28.0)
    assert n[15, 15, 0] < -0.1
    assert abs(n[15, 15, 1]) < 1e-6
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `python -m pytest tools/artspike -q`
Expected: FAIL with "cannot import name 'profile'" etc.

- [ ] **Step 3: Implement in `composer.py`**

```python
import io
import json
import pathlib

import numpy as np
import resvg_py
from PIL import Image

SS = 4  # supersample: px per model unit at compose time

_DEFS = ('<defs><radialGradient id="glow">'
         '<stop offset="0%" stop-color="#ff9d4d" stop-opacity="0.95"/>'
         '<stop offset="100%" stop-color="#ff9d4d" stop-opacity="0"/>'
         '</radialGradient></defs>')


def rasterize(svg_fragment, frame, ss=SS):
    minx, miny, w, h = frame
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{int(w * ss)}" '
           f'height="{int(h * ss)}" viewBox="{minx} {miny} {w} {h}">'
           f'{_DEFS}{svg_fragment}</svg>')
    png = resvg_py.svg_to_bytes(svg_string=svg, width=int(w * ss))
    img = Image.open(io.BytesIO(bytes(png))).convert("RGBA")
    return np.asarray(img).astype(np.float64) / 255.0


def hull_frame(hull, pad=8.0, ss=SS):
    """tight symmetric frame around the flat albedo, padded, in model units"""
    from composer import flatten  # self-import ok at module level instead
    probe = rasterize(flatten(hull, sheet=False), (-200, -200, 400, 400), ss=1)
    ys, xs = np.where(probe[..., 3] > 0.1)
    minx, maxx = xs.min() - 200 - pad, xs.max() - 200 + pad
    miny, maxy = ys.min() - 200 - pad, ys.max() - 200 + pad
    return (float(minx), float(miny), float(maxx - minx), float(maxy - miny))


def gaussian_blur(a, sigma):
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
    gy, gx = np.gradient(height * z_scale * SS)
    n = np.dstack([-gx, -gy, np.ones_like(height)])
    return n / np.linalg.norm(n, axis=2, keepdims=True)
```

(Note: move the `from composer import flatten` self-import to plain use of the
module-level `flatten` already defined in this file — it's the same module.)

- [ ] **Step 4: Run tests**

Run: `python -m pytest tools/artspike -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/artspike/composer.py tools/artspike/test_composer.py
git commit -m "feat(art): composer rasterizer, authored height profiles, painter-order composition, normals"
```

---

### Task 3: Livery mask classification + flat-albedo integrity

**Files:**
- Modify: `tools/artspike/composer.py`
- Test: `tools/artspike/test_composer.py`

**Interfaces:**
- Produces: `classify_masks(rgb, alpha, c1_colors, c2_colors) -> (H,W,2) float` —
  per-pixel nearest-match against the ship's full palette, 1.0 where the pixel's
  nearest color is a c1 (resp. c2) color; `PALETTES` dict per manufacturer listing
  every color the classifier may see.

- [ ] **Step 1: Write the failing tests**

```python
def test_classify_masks_strict_palette():
    from composer import classify_masks, rasterize
    frag = ('<rect x="-20" y="-20" width="20" height="40" fill="#3b8de0" stroke="none"/>'
            '<rect x="0" y="-20" width="10" height="40" fill="#eef2f6" stroke="none"/>'
            '<rect x="10" y="-20" width="10" height="40" fill="#2a66a8" stroke="none"/>')
    rgba = rasterize(frag, (-25, -25, 50, 50), ss=2)
    m = classify_masks(rgba[..., :3], rgba[..., 3],
                       c1_colors=[(59, 141, 224)], c2_colors=[(238, 242, 246)])
    assert m[50, 20, 0] == 1.0 and m[50, 20, 1] == 0.0    # blue -> c1
    assert m[50, 55, 1] == 1.0 and m[50, 55, 0] == 0.0    # white -> c2
    assert m[50, 75, 0] == 0.0 and m[50, 75, 1] == 0.0    # dark blue -> fixed
    assert m[2, 2].sum() == 0.0                            # background


def test_flat_albedo_has_no_glow_or_highlight():
    from composer import rasterize, flatten
    from manufacturers import ship_mockingbird
    rgba = rasterize(flatten(ship_mockingbird(), sheet=False), (-40, -115, 80, 190))
    px = (rgba[..., :3] * 255)[rgba[..., 3] > 0.9]
    # no engine-glow orange, no painted highlight blue
    assert not ((abs(px - (255, 157, 77)).max(axis=1)) < 12).any()
    assert not ((abs(px - (90, 163, 234)).max(axis=1)) < 6).any()
```

- [ ] **Step 2: Run to verify failure**

Run: `python -m pytest tools/artspike -q` → new tests FAIL (no `classify_masks`).

- [ ] **Step 3: Implement**

```python
# every color a ship's flat albedo may contain, per manufacturer (classification
# universe — nearest-match needs the full set so AA pixels snap correctly)
RIJAY_PALETTE = [(59, 141, 224), (42, 102, 168), (238, 242, 246),
                 (95, 216, 232), (104, 109, 117), (52, 58, 68)]
PHE_PALETTE = [(223, 227, 230), (217, 122, 40), (168, 90, 30),
               (138, 143, 151), (104, 109, 117), (95, 216, 232),
               (154, 160, 168), (52, 58, 68)]


def classify_masks(rgb, alpha, c1_colors, c2_colors, palette=None):
    keys = list(palette or (list(c1_colors) + list(c2_colors)))
    for c in list(c1_colors) + list(c2_colors):
        if c not in keys:
            keys.append(c)
    keys_a = np.array(keys, dtype=np.float64)
    px = (rgb * 255).reshape(-1, 3)
    nearest = ((px[:, None, :] - keys_a[None, :, :]) ** 2).sum(axis=2).argmin(axis=1)
    nearest = nearest.reshape(rgb.shape[:2])
    c1_idx = {keys.index(c) for c in c1_colors}
    c2_idx = {keys.index(c) for c in c2_colors}
    m = np.zeros(rgb.shape[:2] + (2,))
    solid = alpha > 0.5
    m[..., 0] = np.isin(nearest, list(c1_idx)) & solid
    m[..., 1] = np.isin(nearest, list(c2_idx)) & solid
    return m
```

- [ ] **Step 4: Run tests** → PASS. If `test_flat_albedo_has_no_glow_or_highlight`
fails, the leak is a glow/highlight fragment not split into its own
`role="glow"`/`role="sheet_only"` layer in Task 1 — fix the layer split, not the test.

- [ ] **Step 5: Commit**

```bash
git add tools/artspike/composer.py tools/artspike/test_composer.py
git commit -m "feat(art): c1/c2 livery mask classification against strict palettes"
```

---

### Task 4: Export — game-res textures + meta.json into `client/assets/ships/`

**Files:**
- Modify: `tools/artspike/composer.py` (export entry point + debug sheet)
- Test: `tools/artspike/test_composer.py`
- Output (committed): `client/assets/ships/{mockingbird,mockingbird_stock,longhorn}/{albedo.png,normal.png,mask.png,meta.json}` + `tools/artspike/sheet_composer.png`

**Interfaces:**
- Produces: `ExportSpec(name, build, classic_px, model_units, c1, c2, palette, c1_base, c2_base)`;
  `SHIP_EXPORTS` registry; `export_ship(spec, out_root) -> dict` (the meta);
  `main()` exporting all + writing `sheet_composer.png` debug sheet.
  meta.json schema:
  `{"name", "px_w", "px_h", "px_per_unit", "frame": [minx,miny,w,h], "classic_px",
    "c1_base": [r,g,b], "c2_base": [r,g,b], "anchors": [{"kind","x_px","y_px"}, ...]}`
  where `x_px,y_px` are texture pixel coords of each nozzle.
- Consumes: everything above; `lightspike.light()`/step constants for the debug sheet's offline-lit column.

- [ ] **Step 1: Write the failing integration test**

```python
def test_export_mockingbird(tmp_path):
    from composer import SHIP_EXPORTS, export_ship
    spec = next(s for s in SHIP_EXPORTS if s.name == "mockingbird")
    meta = export_ship(spec, tmp_path)
    d = tmp_path / "mockingbird"
    assert (d / "albedo.png").exists() and (d / "normal.png").exists()
    assert (d / "mask.png").exists() and (d / "meta.json").exists()
    assert abs(meta["px_h"] - 45) <= 2                     # Classic game scale
    assert len(meta["anchors"]) == 3
    for a in meta["anchors"]:
        assert 0 <= a["x_px"] < meta["px_w"] and 0 <= a["y_px"] < meta["px_h"]
        assert a["y_px"] > meta["px_h"] * 0.7              # nozzles aft
    from PIL import Image
    n = np.asarray(Image.open(d / "normal.png"))
    assert tuple(n[0, 0][:3]) == (128, 128, 255)           # background flat, GL-encoded


def test_export_longhorn_foil_shades_flat(tmp_path):
    """anti-overfit proof at export level: foil interior normals face the camera"""
    from composer import SHIP_EXPORTS, export_ship
    spec = next(s for s in SHIP_EXPORTS if s.name == "longhorn")
    meta = export_ship(spec, tmp_path)
    from PIL import Image
    n = np.asarray(Image.open(tmp_path / "longhorn" / "normal.png")).astype(float)
    n = n / 127.5 - 1.0
    # foil interior sample: model (±28, -95) -> px via meta frame/px_per_unit
    fx = int((28 - meta["frame"][0]) * meta["px_per_unit"])
    fy = int((-95 - meta["frame"][1]) * meta["px_per_unit"])
    assert n[fy, fx, 2] > 0.9, "hammer foil must shade as a thin flat plate"
```

- [ ] **Step 2: Run to verify failure** → FAIL (`SHIP_EXPORTS` missing).

- [ ] **Step 3: Implement export**

```python
@dataclass(frozen=True)
class ExportSpec:
    name: str
    build: object                 # () -> Hull
    classic_px: int
    model_units: int
    c1: tuple
    c2: tuple
    palette: tuple
    c1_base: tuple                # shader base color for tint math
    c2_base: tuple


RIJ_C1, RIJ_C2 = (59, 141, 224), (238, 242, 246)
PHE_C1, PHE_C2 = (217, 122, 40), (223, 227, 230)

SHIP_EXPORTS = [
    ExportSpec("mockingbird", lambda: _mb(False), 45, 195,
               ((59, 141, 224),), ((238, 242, 246),), tuple(RIJAY_PALETTE),
               RIJ_C1, RIJ_C2),
    ExportSpec("mockingbird_stock", lambda: _mb(True), 45, 195,
               ((59, 141, 224),), ((238, 242, 246),), tuple(RIJAY_PALETTE),
               RIJ_C1, RIJ_C2),
    ExportSpec("longhorn", lambda: _lh(), 41, 195,
               ((217, 122, 40), (168, 90, 30)), ((223, 227, 230),),
               tuple(PHE_PALETTE), PHE_C1, PHE_C2),
]


def _mb(stock):
    from manufacturers import ship_mockingbird
    return ship_mockingbird(stock=stock)


def _lh():
    from manufacturers import ship_longhorn
    return ship_longhorn()


def _downsample(arr, size, mode):
    """PIL-based resize for float arrays; mode 'rgba' or 'f'"""
    if mode == "rgba":
        img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), "RGBA")
        return np.asarray(img.resize(size, Image.BOX)).astype(np.float64) / 255.0
    img = Image.fromarray(arr.astype(np.float32), "F")
    return np.asarray(img.resize(size, Image.BOX)).astype(np.float64)


def export_ship(spec, out_root, z_scale=6.5):
    hull = spec.build()
    frame = hull_frame(hull)
    albedo = rasterize(flatten(hull, sheet=False), frame)
    height, covered = compose_height(hull, frame)
    # paint-only fringes (stripes overhanging a height layer's silhouette):
    # take the nearest covered part's height so they don't punch cliffs
    from scipy.ndimage import distance_transform_edt
    solid = albedo[..., 3] > 0.5
    if (~covered & solid).any():
        _, (iy, ix) = distance_transform_edt(~covered, return_indices=True)
        height = np.where(~covered & solid, height[iy, ix], height)
    height = gaussian_blur(height, SS * 0.6) * solid
    masks = classify_masks(albedo[..., :3], albedo[..., 3],
                           spec.c1, spec.c2, spec.palette)
    px_per_unit = spec.classic_px / spec.model_units
    pw = max(1, round(frame[2] * px_per_unit))
    ph = max(1, round(frame[3] * px_per_unit))
    albedo_g = _downsample(albedo, (pw, ph), "rgba")
    height_g = _downsample(height, (pw, ph), "f")
    solid_g = _downsample(solid.astype(np.float64), (pw, ph), "f") > 0.5
    normals = height_to_normals(height_g, z_scale=z_scale / SS)  # game-res gradient
    normals[~solid_g] = [0.0, 0.0, 1.0]
    mask_g = np.dstack([_downsample(masks[..., i], (pw, ph), "f")
                        for i in (0, 1)] + [np.zeros((ph, pw))])
    out = pathlib.Path(out_root) / spec.name
    out.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(albedo_g, 0, 1) * 255).astype(np.uint8),
                    "RGBA").save(out / "albedo.png")
    n = normals.copy()
    n[..., 1] *= -1.0                                  # image Y-down -> GL Y-up
    Image.fromarray(((n + 1) / 2 * 255).astype(np.uint8), "RGB").save(
        out / "normal.png")
    Image.fromarray((np.clip(mask_g, 0, 1) * 255).astype(np.uint8), "RGB").save(
        out / "mask.png")
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
    (out / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return meta
```

`main()` runs all three exports into `client/assets/ships/` (path:
`pathlib.Path(__file__).parents[2] / "client" / "assets" / "ships"`), then builds
`sheet_composer.png`: one row per ship — flat albedo, height (gray), normals
(RGB), mask viz (c1→red, c2→green), offline-lit at 3 headings (reuse the
`STEP_*` quantize math from `lightspike.light` on supersampled maps), and the
game-res sprite at 1x/3x nearest. Follow `mockingbird_litcheck.py`'s sheet code
shape; label each cell.

- [ ] **Step 4: Run tests + the export**

Run: `python -m pytest tools/artspike -q` → PASS.
Run: `cd tools/artspike; python composer.py` → writes 3 asset dirs + `sheet_composer.png`.
Read `sheet_composer.png` and self-check with the canon eyeball list: three drums
read as three separate cylinders (the litcheck's doming melted them — the composer
must not); foil flat; fins thin; stripes tint-free in mask viz (stripes are c2 → green).
Iterate the height-ladder numbers in Task 1's layer annotations if a part reads wrong.
This is the eyeball loop — self-judge against canon, queue the sheet for the user, don't block.

- [ ] **Step 5: Commit (assets included)**

```bash
git add tools/artspike/composer.py tools/artspike/test_composer.py client/assets/ships tools/artspike/.gitignore
git commit -m "feat(art): export lit-pipeline ship assets (albedo/normal/mask/meta) at game res"
```

(Check `tools/artspike/.gitignore` first — it ignores `*.png` sheets; make sure it does
NOT apply to `client/assets`, and add `sheet_composer.png` to the sheet-ignore pattern
only if the other sheets are ignored too — follow the existing pattern.)

---

### Task 5: Godot toy-scene verification — livery tints, one sun, two suns

**Files:**
- Modify: `tools/artspike/godot/lit_ship.gdshader` (mask + tint uniforms)
- Modify: `tools/artspike/godot/main.gd` (load exported ships, tint test, 2-sun config, screenshots)
- Output: `tools/artspike/godot/shot_1sun.png`, `shot_2sun.png`

**Interfaces:**
- Consumes: `client/assets/ships/*/{albedo,normal,mask}.png`, `meta.json` (c1_base/c2_base).
- Produces: shader uniforms `mask_tex`, `c1_tint`, `c2_tint`, `c1_base`, `c2_base`.

- [ ] **Step 1: Extend the shader**

`lit_ship.gdshader` — replace `fragment()` and add uniforms (light() unchanged; it
recovers the tinted albedo by dividing by STEP_SHADOW, so tinting in fragment() is
automatically consistent):

```glsl
uniform sampler2D mask_tex : filter_nearest;
uniform vec3 c1_tint : source_color = vec3(0.231, 0.553, 0.878);
uniform vec3 c2_tint : source_color = vec3(0.933, 0.949, 0.965);
uniform vec3 c1_base : source_color = vec3(0.231, 0.553, 0.878);
uniform vec3 c2_base : source_color = vec3(0.933, 0.949, 0.965);

void fragment() {
	vec2 m = texture(mask_tex, UV).rg;
	vec3 albedo = COLOR.rgb;
	albedo = mix(albedo, albedo * c1_tint / max(c1_base, vec3(1e-3)), m.r);
	albedo = mix(albedo, albedo * c2_tint / max(c2_base, vec3(1e-3)), m.g);
	COLOR.rgb = albedo * STEP_SHADOW;
}
```

- [ ] **Step 2: Rewrite `main.gd`**

Layout: 3 ship rows (mockingbird, mockingbird_stock, longhorn) × 8 headings at 3×
nearest-neighbor scale, plus a 9th column with `c1_tint` overridden to green
(0.3, 0.75, 0.35) proving mask-driven livery. Load per ship from
`client/assets/ships/<name>/` via
`ProjectSettings.globalize_path("res://").path_join("../../../client/assets/ships")`
(normalize with `simplify_path`). Per sprite: `CanvasTexture` (albedo+normal),
`ShaderMaterial` with per-ship `mask_tex` (`ImageTexture`, and set
`texture_filter = TEXTURE_FILTER_NEAREST` on the sprite; scale 3.0), bases from
meta.json (`JSON.parse_string(FileAccess.get_file_as_string(...))`). Suns:

```gdscript
var sun := DirectionalLight2D.new()
sun.rotation_degrees = -45.0
sun.height = 0.55
sun.blend_mode = Light2D.BLEND_MODE_ADD
add_child(sun)
if OS.get_environment("DH_TWO_SUNS") == "1":
	var sun2 := DirectionalLight2D.new()
	sun2.rotation_degrees = 150.0
	sun2.height = 0.45
	sun2.color = Color(0.75, 0.8, 1.0)      # cool secondary key
	sun2.energy = 0.7
	sun2.blend_mode = Light2D.BLEND_MODE_ADD
	add_child(sun2)
var shot := "res://shot_2sun.png" if OS.get_environment("DH_TWO_SUNS") == "1" else "res://shot_1sun.png"
```

Keep the existing await-frame → `save_png(shot)` → quit flow. Remember the round-3
gotchas: `LIGHT.a` scales the whole contribution, and each light's pass adds
`albedo * (step - shadow)` — with two suns overlaps go brighter, which is the
physically right read for a double-key.

- [ ] **Step 3: Run both configs and eyeball**

```powershell
$env:PATH = "$env:USERPROFILE\scoop\shims;$env:PATH"
cd tools\artspike\godot
godot --path . ; # writes shot_1sun.png
$env:DH_TWO_SUNS = "1"; godot --path . ; $env:DH_TWO_SUNS = ""
```

Read both PNGs. Check: three-drum separation under light; foil shades flat (single
step across it, no fake dome); tint column is green where blue was, stripes stay
white; two-sun frame shows both keys without blowout. Tune `z_scale` /
height-ladder and re-export if a read fails; re-run.

- [ ] **Step 4: Commit**

```bash
git add tools/artspike/godot
git commit -m "feat(art): toy scene verifies exported ships - livery tints, one sun, two suns"
```

---

### Task 6: Publish eyeball round + docs + PR

**Files:**
- Modify: art-spike artifact (in place, `url` param): https://claude.ai/code/artifact/b2b0e22a-2a34-45d5-9307-f333d9233d46
- Modify: `docs/visuals.md` (one line: composer pipeline landed, pointer to assets)
- Create: PR `m3.5-vibe-pass` → main (stays open for the whole milestone; later layers stack on it)

- [ ] **Step 1: Build the round-5 artifact page** — load `artifact-design` skill first;
embed `sheet_mockingbird_lit.png` (pre-pipeline sanity), `sheet_composer.png`,
`shot_1sun.png`, `shot_2sun.png` as data URIs on the existing artifact (keep prior
rounds; same URL). Note per review-cadence agreement: FYI round, not blocking; queue
= {composer sheet, toy shots}.

- [ ] **Step 2: Verify full test suite + sheets clean**

Run: `python -m pytest tools/artspike -q` → all PASS.
Run: `python tools/artspike/manufacturers.py; git diff --stat tools/artspike/sheet_mfr.svg` → empty.

- [ ] **Step 3: Push + open PR**

```bash
git push -u origin m3.5-vibe-pass
gh pr create --title "M3.5: vibe pass — asset pipeline (PR 1 scope)" --body "..."
```

PR body: pipeline summary, canon constraints honored, eyeball-queue note, plan link.

---

## Self-Review

- Spec coverage: handoff step 1 (lit preview) = litcheck (done pre-plan); step 2
  (composer: albedo + heights per part, normals, c1/c2 masks, Godot 1+2 suns) =
  Tasks 1–5; "each layer PR-sized" = Task 6 opens the PR. Longhorn generality per
  user answer = Tasks 1/4/5 foil checks. ✓
- Placeholders: none — all code inline. ✓
- Type consistency: `Height.kind` strings match `profile()` branches;
  `flatten(sheet=False)` used consistently for flat albedo; meta keys used by
  test + main.gd match `export_ship`. ✓
