"""Cross-tree consistency for M4 iteration 2c's exterior layering.

The server owns a mount's CAPABILITY (`{id, kind, size}`); the art meta owns
its GEOMETRY (a named anchor). Nothing compiles across that boundary, so
these tests are the whole defence against a mount id typo'd in one tree —
which renders as a part that silently does not draw.
"""
import json
import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHIPCLASSES = ROOT / "server" / "shipclasses"
SHIP_ART = ROOT / "client" / "assets" / "ships"

pytestmark = pytest.mark.xfail(
    not (SHIP_ART / "sparrow").exists(),
    reason="Sparrow and Goldfinch exterior art land in tasks 12-13",
    strict=False)


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
