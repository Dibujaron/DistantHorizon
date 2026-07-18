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
