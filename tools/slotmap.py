"""Print a hull's slot map: which parts of a ship a refit can change.

Slot membership lives in each tile's CENTRE as an uppercase letter
(`docs/deckplan-format.md`, "Slots"). On a BARE hull that already makes the
raw JSON legible on its own -- the marker sits right there in the middle of
each tile's 3x3 block -- so running this tool with no `--structure` is close
to an identity render of the hull's own grid; it earns its keep mainly for
the per-slot tile-count summary and, more importantly, for `--structure`.

    python tools/slotmap.py server/shipclasses/mockingbird.json

A RESOLVED map is a different story: once a module is stamped in, its own
glyphs (furniture, consoles, the module's own centre character) overwrite
the slot marker at every tile it touches, so the marker is gone from the
fitted ship's own grid even though the tile still belongs to that slot. This
tool re-paints the hull's markers onto the resolved geometry so you can see
where slot regions actually landed once the ship is flying:

    python tools/slotmap.py server/shipclasses/mockingbird.json \
        --structure server/test/fixtures/mockingbird_authored.json

Anything without a marker is fixed hull no module can touch.
"""

import argparse
import json
import sys

VOID = "."


def load_decks(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)["decks"]


def slot_key(grid, x, y):
    """Tile (x, y)'s slot-membership key: its centre marker letter, or None
    if it is not in a slot at all."""
    centre = grid[3 * y + 1][3 * x + 1]
    return centre if centre.isalpha() and centre.isupper() else None


def paint(hull_grid, structure_grid):
    """Structure's rows with each slotted tile's centre replaced by its
    marker letter."""
    out = [list(row) for row in structure_grid]
    height, width = len(structure_grid) // 3, len(structure_grid[0]) // 3
    for y in range(height):
        for x in range(width):
            marker = slot_key(hull_grid, x, y)
            if marker is None:
                continue
            # Always the marker, never the furniture that happens to sit
            # there: the question this tool answers is "what can a refit
            # change?", and keeping decor would hide precisely the most
            # furnished slots. The walls and doors around it still read as
            # rooms.
            out[3 * y + 1][3 * x + 1] = marker
    return ["".join(row) for row in out]


def occupied_rows(rows):
    """Index of the first and last row that is not entirely void/blank."""
    live = [i for i, r in enumerate(rows) if r.strip(" " + VOID)]
    return (live[0], live[-1]) if live else (0, -1)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hull", help="hull document (server/shipclasses/*.json)")
    ap.add_argument("--structure", help="a resolved map to draw walls from "
                                        "(defaults to the hull's own)")
    args = ap.parse_args()

    with open(args.hull, encoding="utf-8") as fh:
        hull = json.load(fh)
    slots = {s["marker"]: s for s in hull.get("slots", [])}
    if not slots:
        print(f"{hull['id']}: no slots -- nothing on this hull is modular.")
        return 0

    hull_decks = hull["decks"]
    structure_decks = load_decks(args.structure) if args.structure else hull_decks
    if len(structure_decks) != len(hull_decks):
        print("hull and structure have different deck counts", file=sys.stderr)
        return 1

    counts = {}
    for hd, sd in zip(hull_decks, structure_decks):
        rows = paint(hd["grid"], sd["grid"])
        lo, hi = occupied_rows(rows)
        print(f"=== {hull['name']} -- {hd['name']} ===")
        for row in rows[lo:hi + 1]:
            print("  " + row.replace(VOID, " "))
        print()
        for y in range(len(hd["grid"]) // 3):
            for x in range(len(hd["grid"][0]) // 3):
                marker = slot_key(hd["grid"], x, y)
                if marker:
                    counts[marker] = counts.get(marker, 0) + 1

    print("slots (a refit may rewrite these; everything else is fixed hull):")
    for marker, slot in sorted(slots.items()):
        print(f"  {marker}  {slot['id']:<14} {slot['name']:<22} "
              f"{counts.get(marker, 0):3} tiles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
