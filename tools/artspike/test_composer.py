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


def test_classify_masks_strict_palette():
    from composer import classify_masks, rasterize
    frag = ('<rect x="-20" y="-20" width="20" height="40" fill="#3b8de0" stroke="none"/>'
            '<rect x="0" y="-20" width="10" height="40" fill="#eef2f6" stroke="none"/>'
            '<rect x="10" y="-20" width="10" height="40" fill="#2a66a8" stroke="none"/>')
    rgba = rasterize(frag, (-25, -25, 50, 50), ss=2)
    m = classify_masks(rgba[..., :3], rgba[..., 3],
                       c1_colors=[(59, 141, 224)], c2_colors=[(238, 242, 246)],
                       palette=[(59, 141, 224), (238, 242, 246), (42, 102, 168)])
    assert m[50, 20, 0] == 1.0 and m[50, 20, 1] == 0.0    # blue -> c1
    assert m[50, 55, 1] == 1.0 and m[50, 55, 0] == 0.0    # white -> c2
    assert m[50, 75, 0] == 0.0 and m[50, 75, 1] == 0.0    # dark blue -> fixed
    assert m[2, 2].sum() == 0.0                            # background


def test_flat_albedo_has_no_glow_or_highlight():
    from composer import rasterize, flatten
    from manufacturers import ship_mockingbird
    frag = flatten(ship_mockingbird(), sheet=False)
    # no painted highlight, no emissive glow in the lit-pipeline albedo
    assert "#5aa3ea" not in frag
    assert "url(#glow)" not in frag and "#ffe3b0" not in frag
    rgba = rasterize(frag, (-40, -115, 80, 190))
    px = (rgba[..., :3] * 255)[rgba[..., 3] > 0.9]
    assert not ((np.abs(px - (255, 157, 77)).max(axis=1)) < 12).any()


def test_export_mockingbird(tmp_path):
    from composer import SHIP_EXPORTS, export_ship
    spec = next(s for s in SHIP_EXPORTS if s.name == "mockingbird")
    meta = export_ship(spec, tmp_path)
    d = tmp_path / "mockingbird"
    for f in ("albedo.png", "normal.png", "mask.png", "meta.json"):
        assert (d / f).exists()
    assert abs(meta["px_h"] - 45) <= 3                     # Classic game scale
    assert len(meta["anchors"]) == 3
    for a in meta["anchors"]:
        assert 0 <= a["x_px"] < meta["px_w"] and 0 <= a["y_px"] < meta["px_h"]
        assert a["y_px"] > meta["px_h"] * 0.7              # nozzles aft
    # interior fit contract (scale canon: 1 tile ~ 1 m): the 14x20 deckplan
    # sits at 1.5 px/tile on the SPACE sprite — if the sprite ever drifts
    # off 21x45 the deckplan no longer fits the hull, so pin EXACT
    # dimensions here.
    assert (meta["px_w"], meta["px_h"]) == (21, 45)
    assert abs(meta["interior"]["px_per_tile"] - 1.5) < 1e-9
    assert meta["interior"]["origin_px"] == [0.0, 0.0]


def test_export_mockingbird_interior_backdrop(tmp_path):
    """the 2x walk-mode render: same hull, 42x90 px, 3 px/tile"""
    from composer import SHIP_EXPORTS, export_ship
    spec = next(s for s in SHIP_EXPORTS if s.name == "mockingbird_interior")
    meta = export_ship(spec, tmp_path)
    assert (meta["px_w"], meta["px_h"]) == (42, 90)
    assert abs(meta["interior"]["px_per_tile"] - 3.0) < 1e-9
    assert meta["interior"]["origin_px"] == [0.0, 0.0]
    from PIL import Image
    n = np.asarray(Image.open(tmp_path / "mockingbird_interior" / "normal.png"))
    assert tuple(n[0, 0][:3]) == (128, 128, 255)           # background flat, GL


def test_station_hull_berth_anchors(tmp_path):
    from stations import STATION_EXPORTS
    from composer import export_ship
    spec = next(s for s in STATION_EXPORTS if s.name == "ring_3berth_crane")
    meta = export_ship(spec, tmp_path)
    berths = [a for a in meta["anchors"] if a["kind"] == "berth"]
    assert len(berths) == 3
    for a in berths:
        assert 0 <= a["x_px"] < meta["px_w"] and 0 <= a["y_px"] < meta["px_h"]
    # interior fit contract: ships moor SIDE-ON at the end of a 3-tile
    # docking tube — the sprite center rides 4.5 tiles WEST and 5 tiles
    # NORTH of each authored berth tile (22, 54, 86) of the 94-wide
    # concourse, at exactly 1.5 px/tile on the space render.
    fit = meta["interior"]
    ppt = fit["px_per_tile"]
    assert abs(ppt - 1.5) < 1e-9
    for a, b in zip(sorted(berths, key=lambda a: a["x_px"]), (22, 54, 86)):
        assert abs(a["x_px"] - (fit["origin_px"][0] + (b + 0.5 - 4.5) * ppt)) < 0.5
        assert abs(a["y_px"] - (fit["origin_px"][1] + (0.5 - 5.5) * ppt)) < 0.5
    # no livery on stations: masks are all zero
    from PIL import Image
    m = np.asarray(Image.open(tmp_path / "ring_3berth_crane" / "mask.png"))
    assert m[..., 0].max() == 0 and m[..., 1].max() == 0


def test_station_ring_is_not_a_dome():
    """the structure authors flat plates/annuli — no whole-station doming"""
    from stations import station_hull
    from composer import hull_frame, compose_height
    hull = station_hull(12, 5, (5,), crane=False, seed=7)
    frame = hull_frame(hull)
    h, covered = compose_height(hull, frame)
    assert h[covered].max() < 0.75


def test_tiles_export(tmp_path):
    from tiles import TILE_SPRITES, export_tiles
    import json
    export_tiles(tmp_path)
    meta = json.loads((tmp_path / "meta.json").read_text())
    assert meta["tile_px"] == 64
    names = {n for n, _, _, _ in TILE_SPRITES}
    assert {"floor_0", "floor_1", "floor_2", "wall_n", "wall_corner", "hazard",
            "console_helm", "console_cargo", "console_broker",
            "picto_airlock", "picto_trade", "picto_cargo",
            "picto_helm"} <= names
    assert all((tmp_path / f"digit_{d}.png").exists() for d in range(10))
    from PIL import Image
    f = Image.open(tmp_path / "floor_0.png")
    assert f.size == (64, 64)
    assert f.getpixel((0, 0))[3] == 255          # floors are opaque
    d = Image.open(tmp_path / "digit_7.png")
    assert d.getpixel((0, 0))[3] == 0            # decals are transparent


def test_characters_export(tmp_path):
    from characters import CHARACTERS, export_characters
    export_characters(tmp_path)
    from PIL import Image
    for name, _ in CHARACTERS:
        img = Image.open(tmp_path / f"{name}.png")
        assert img.size == (22, 34)
        assert img.getpixel((0, 0))[3] == 0      # transparent background
    assert {n for n, _ in CHARACTERS} == {"player", "crew_0", "crew_1", "crew_2"}


def test_export_longhorn_foil_shades_flat(tmp_path):
    """anti-overfit proof at export level: foil interior normals face camera"""
    from composer import SHIP_EXPORTS, export_ship
    spec = next(s for s in SHIP_EXPORTS if s.name == "longhorn")
    meta = export_ship(spec, tmp_path)
    from PIL import Image
    n = np.asarray(Image.open(tmp_path / "longhorn" / "normal.png")).astype(float)
    n = n / 127.5 - 1.0
    # foil interior sample: model (+-28, -95) -> px via meta frame/px_per_unit
    for mx in (-28, 28):
        fx = int((mx - meta["frame"][0]) * meta["px_per_unit"])
        fy = int((-95 - meta["frame"][1]) * meta["px_per_unit"])
        assert n[fy, fx, 2] > 0.9, "hammer foil must shade as a thin flat plate"
