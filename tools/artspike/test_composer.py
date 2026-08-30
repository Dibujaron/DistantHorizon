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
    """The drums (cyl_x, glow) moved to part_engine_rijay(); the hull itself
    now authors only flat/dome relief (body, canopy, fins, mount plates)."""
    from manufacturers import ship_mockingbird
    hull = ship_mockingbird()
    kinds = {l.height.kind for l in hull.layers if l.height is not None}
    assert {"dome", "flat"} <= kinds                   # authored variety, not doming
    mounts = {a.id for a in hull.anchors if a.kind == "mount"}
    assert mounts == {"engine_port", "engine_center", "engine_stbd"}
    assert any(l.role == "sheet_only" for l in hull.layers)  # painted highlight split


def test_longhorn_foil_is_flat_plate():
    """The anti-overfit case: the hammer foil authors a thin flat profile."""
    from manufacturers import ship_longhorn
    hull = ship_longhorn()
    foils = [l for l in hull.layers if l.height and l.height.kind == "flat"]
    assert foils, "Longhorn must have flat-plate layers (the hammer foil)"
    assert len([a for a in hull.anchors if a.kind == "mount"]) == 2


def test_mount_anchors_are_ordered_port_to_starboard():
    """Ids are the contract, but a reader should still be able to trust the
    left-to-right order in the file."""
    from manufacturers import ship_mockingbird
    ids = [a.id for a in ship_mockingbird().anchors if a.kind == "mount"]
    assert ids == ["engine_port", "engine_center", "engine_stbd"]


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
        assert a["y_px"] > meta["px_h"] * 0.7              # mounts sit aft
    # interior fit contract (scale canon: 1 tile ~ 1 m): the 14x23 deckplan
    # sits at 1.5 px/tile on the SPACE sprite — if the sprite ever drifts
    # off 21x43 the deckplan no longer fits the hull, so pin EXACT
    # dimensions here. (M4 iteration 2c: the drums moved off the hull to a
    # part, shrinking the hull's own bounding box aft from 45 to 43 px —
    # the engine part's own bulk restores the full profile once layered on.)
    assert (meta["px_w"], meta["px_h"]) == (21, 43)
    assert abs(meta["interior"]["px_per_tile"] - 1.5) < 1e-9
    assert meta["interior"]["origin_px"] == [0.0, 0.0]


def test_export_mockingbird_interior_backdrop(tmp_path):
    """the 2x walk-mode render: same hull, 42x86 px, 3 px/tile"""
    from composer import SHIP_EXPORTS, export_ship
    spec = next(s for s in SHIP_EXPORTS if s.name == "mockingbird_interior")
    meta = export_ship(spec, tmp_path)
    assert (meta["px_w"], meta["px_h"]) == (42, 86)
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


def test_baked_walk_sheets_have_no_interior_holes():
    """A swinging arm must not expose a transparent column over the torso -- the
    dark deck would show through the body as a flickering black strip. On every
    frame of the front/back walk sheets, no fully-transparent pixel may sit
    between the leftmost and rightmost opaque pixels of a row."""
    from PIL import Image
    import numpy as np
    root = HERE.parents[1] / "client" / "assets" / "characters"
    sheet_cells = 5
    for name in ("player", "crew_0", "crew_1", "crew_2"):
        for suffix in ("_walk", "_back_walk"):
            im = np.asarray(Image.open(root / f"{name}{suffix}.png").convert("RGBA"))
            cw = im.shape[1] // sheet_cells
            for fi in range(sheet_cells):
                a = im[:, fi * cw:(fi + 1) * cw, 3] > 20
                for y in range(a.shape[0]):
                    xs = np.where(a[y])[0]
                    if len(xs) < 2:
                        continue
                    assert a[y, xs.min():xs.max() + 1].all(), \
                        f"{name}{suffix} frame {fi} row {y}: interior transparent hole"


def test_shade_never_overflows_to_invalid_hex():
    """_shade must clamp channels to 255 so a brighten (k>1) can't overflow into
    an invalid 7-hex-digit color. resvg renders an invalid fill as black, which
    is exactly the black chest-badge bug on bright suits (#3b8de0, #d97a28)."""
    from characters import _shade, CHARACTERS
    for _name, (suit, _skin, _hair) in CHARACTERS:
        out = _shade(suit, 1.45)
        assert len(out) == 7 and out[0] == "#", f"{suit} -> {out}"
        int(out[1:], 16)  # parses as a real #rrggbb


def test_characters_export(tmp_path):
    """Each character exports the full front sprite plus the baker's body/arm
    layers, all 22x34 with a transparent background and real content."""
    from characters import CHARACTERS, LAYERS, export_characters
    export_characters(tmp_path)
    from PIL import Image
    import numpy as np
    for name, _ in CHARACTERS:
        for suffix in LAYERS:
            img = Image.open(tmp_path / f"{name}{suffix}.png")
            assert img.size == (22, 34)
            assert img.getpixel((0, 0))[3] == 0        # transparent background
            assert np.asarray(img)[..., 3].max() > 0   # not a blank cell
        # the armless body must actually differ from the full sprite (arms gone)
        full = np.asarray(Image.open(tmp_path / f"{name}.png"))
        body = np.asarray(Image.open(tmp_path / f"{name}_body.png"))
        assert not np.array_equal(full, body)
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


def test_mockingbird_hull_no_longer_draws_her_drums():
    """The drums are a PART now. What stays on the hull is a blanking plate
    per mount, which a fitted part covers."""
    from manufacturers import ship_mockingbird
    hull = ship_mockingbird()
    # The drums were the only cyl_x layers on the hull.
    assert not [l for l in hull.layers if l.height and l.height.kind == "cyl_x"]
    assert not [l for l in hull.layers if l.role == "glow"], \
        "engine glow belongs to the engine part"
    mounts = {a.id for a in hull.anchors if a.kind == "mount"}
    assert mounts == {"engine_port", "engine_center", "engine_stbd"}


def test_consol_engine_has_no_dorsal_ridge():
    """The lore default renders as visibly aftermarket for free: the ridge is
    a Rijay drum fairing (the atmo-landing package), so the Consol nacelle
    simply lacks one. Asserted by looking for the ridge itself -- a white
    flat-height layer -- not by counting flat layers, which would couple this
    to unrelated decisions like whether a nozzle bell carries relief."""
    from manufacturers import RIJ_WHITE, part_engine_consol, part_engine_rijay

    def ridges(hull):
        return [l for l in hull.layers
                if l.height and l.height.kind == "flat" and RIJ_WHITE in l.svg]

    assert len(ridges(part_engine_rijay())) == 1
    assert ridges(part_engine_consol()) == []


def test_rijay_engine_part_has_one_attach_anchor():
    from manufacturers import part_engine_rijay
    part = part_engine_rijay()
    attach = [a for a in part.anchors if a.kind == "attach"]
    assert len(attach) == 1, "a part attaches at exactly one point"
    assert any(l.height is not None for l in part.layers), "authored relief"


def test_consol_engine_part_has_one_attach_anchor():
    from manufacturers import part_engine_consol
    part = part_engine_consol()
    attach = [a for a in part.anchors if a.kind == "attach"]
    assert len(attach) == 1, "a part attaches at exactly one point"
    assert any(l.height is not None for l in part.layers), "authored relief"


def test_wren_is_a_smaller_rijay_drum():
    """Same design language, size `s`: a Wren must read as the family's
    little sister, not as a different manufacturer."""
    from composer import hull_frame
    from manufacturers import part_engine_rijay, part_engine_wren
    big = hull_frame(part_engine_rijay())
    small = hull_frame(part_engine_wren())
    assert small[3] < big[3], "the Wren is shorter than the Stork"
    assert small[2] < big[2], "and narrower"


def test_parts_and_hulls_share_one_base_px_per_unit():
    """The scale canon: a part drawn on a hull must not need rescaling. The
    2x `*_interior` renders double classic_px AND px_scale, so it is the BASE
    ratio (classic_px / model_units / px_scale) that must be universal —
    exactly the quantity export_ship calls base_ppu.

    The Longhorn is excluded by name: she is a known pre-existing scale
    outlier (see test_longhorn_is_the_one_known_scale_outlier) with no hull
    document and no mounts, so no part will ever hang on her and her ratio
    is irrelevant to this canon. Every other ship export and every part
    export must still share exactly one ratio."""
    from composer import PART_EXPORTS, SHIP_EXPORTS

    def base(s):
        return s.classic_px / s.model_units / s.px_scale

    ratios = ({base(s) for s in SHIP_EXPORTS if s.name != "longhorn"}
              | {base(p) for p in PART_EXPORTS})
    assert len(ratios) == 1, f"multiple scales in play: {ratios}"


def test_sparrow_is_a_rijay_hull_with_three_small_mounts():
    from manufacturers import ship_sparrow
    hull = ship_sparrow()
    mounts = {a.id for a in hull.anchors if a.kind == "mount"}
    assert mounts == {"engine_port", "engine_center", "engine_stbd"}
    assert any(l.height is not None for l in hull.layers), "authored relief"


def test_sparrow_interior_fit_covers_her_deck_grid():
    """The walk backdrop must reach every walkable tile: 5 wide x 7 long."""
    from composer import SHIP_EXPORTS, hull_frame
    spec = next(s for s in SHIP_EXPORTS if s.name == "sparrow")
    frame = hull_frame(spec.build())
    units_per_tile = spec.interior["units_per_tile"]
    assert frame[2] >= 5 * units_per_tile - 1e-6
    assert frame[3] >= 7 * units_per_tile - 1e-6


def test_longhorn_is_the_one_known_scale_outlier():
    """The Longhorn renders at 41/195, not the 45/195 every other export
    shares, so she draws about 9% small relative to true scale. That's safe
    today: she is decorative parked traffic with no hull document and no
    mounts, so nothing layers onto her and nothing else reads her ratio.
    The discrepancy predates the M4 art pipeline and nobody has ruled on
    whether 41 was a deliberate choice or drift from the Classic game's
    original sprite height. Pinned here so touching it is a decision made
    on purpose, not an accidental side effect of some other change."""
    from composer import SHIP_EXPORTS
    longhorn = next(s for s in SHIP_EXPORTS if s.name == "longhorn")
    assert (longhorn.classic_px, longhorn.model_units) == (41, 195)
