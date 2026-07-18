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
