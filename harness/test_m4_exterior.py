"""Cross-tree consistency for M4 iteration 2c's exterior layering.

The server owns a mount's CAPABILITY (`{id, kind, size}`); the art meta owns
its GEOMETRY (a named anchor). Nothing compiles across that boundary, so
these tests are the whole defence against a mount id typo'd in one tree —
which renders as a part that silently does not draw.

All three hulls (Mockingbird, Sparrow, Goldfinch) now have shipped exterior
art, so every check in this file is enforced STRICTLY — no xfail guards
remain. `test_mount_ids_match_anchor_ids` runs for all three hull ids and
`test_every_shipped_hull_has_art` requires all three; a mismatch or a
missing art directory fails the suite outright, the same live safety net
`test_mount_ids_match_anchor_ids[mockingbird]` and
`test_every_part_sprite_key_has_art` have always been.

There is deliberately NO module-level guard: a blanket skip/xfail keyed on
one hull's art would swallow every other hull's check along with it.
"""
import json
import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHIPCLASSES = ROOT / "server" / "shipclasses"
SHIP_ART = ROOT / "client" / "assets" / "ships"
PARTS = ROOT / "server" / "parts"
PART_ART = ROOT / "client" / "assets" / "parts"


def _hulls_with_art():
    for path in sorted(SHIPCLASSES.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        sprite = doc.get("sprite", doc["id"])
        meta = SHIP_ART / sprite / "meta.json"
        if meta.exists():
            yield doc["id"], doc, json.loads(meta.read_text(encoding="utf-8"))


def test_every_shipped_hull_has_art():
    ids = {h for h, _, _ in _hulls_with_art()}
    assert ids == {"mockingbird", "sparrow", "goldfinch"}


@pytest.mark.parametrize("hull_id", ["mockingbird", "sparrow", "goldfinch"])
def test_mount_ids_match_anchor_ids(hull_id):
    hulls = {h: (doc, meta) for h, doc, meta in _hulls_with_art()}
    doc, meta = hulls[hull_id]
    declared = {m["id"] for m in doc.get("mounts", [])}
    drawn = {a["id"] for a in meta.get("anchors", []) if a.get("kind") == "mount"}
    assert declared == drawn, (
        f"{hull_id}: hull document declares {sorted(declared)}, "
        f"sprite meta draws {sorted(drawn)}")


def test_every_part_sprite_key_has_art():
    """A part document's `sprite` is what rides the wire; if the directory is
    missing the client draws nothing and the mount looks unfitted."""
    missing = []
    for path in sorted(PARTS.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        sprite = doc.get("sprite")
        if sprite is None:
            continue
        art = PART_ART / sprite
        for f in ("albedo.png", "normal.png", "mask.png", "meta.json"):
            if not (art / f).exists():
                missing.append(f"{doc['id']} -> {sprite}/{f}")
    assert not missing, "part art missing: " + ", ".join(missing)
