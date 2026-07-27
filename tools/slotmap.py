"""Print a hull's slot map: which parts of a ship a refit can change.

Slot membership lives in each tile's SW corner as a hex digit
(`docs/deckplan-format.md`, "Slots"), which is unreadable in the raw JSON
because it is buried in a 3x3 block per tile. This paints that digit into the
middle of each tile so you can see the regions against the ship's own walls
and doors.

    python tools/slotmap.py server/shipclasses/mockingbird.json

By default the walls shown are the HULL's own — so slot regions read as empty
floor, which is what an unfitted ship actually is. To see the ship as she
flies, with her default modules stamped in, pass a resolved map:

    python tools/slotmap.py server/shipclasses/mockingbird.json \
        --structure server/test/fixtures/mockingbird_authored.json

Anything that is not a digit is fixed hull no module can touch.
"""

import argparse
import json
import sys

VOID = "."


def load_decks(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)["decks"]


def slot_digit(grid, x, y):
    """The SW-corner hex digit of tile (x, y), or None if it is not in a slot."""
    ch = grid[3 * y + 2][3 * x]
    return ch if ch in "0123456789abcdef" else None


def paint(hull_grid, structure_grid):
    """Structure's rows with each slotted tile's centre replaced by its digit."""
    out = [list(row) for row in structure_grid]
    height, width = len(structure_grid) // 3, len(structure_grid[0]) // 3
    for y in range(height):
        for x in range(width):
            digit = slot_digit(hull_grid, x, y)
            if digit is None:
                continue
            # Always the digit, never the furniture that happens to sit there:
            # the question this tool answers is "what can a refit change?", and
            # keeping decor would hide precisely the most furnished slots. The
            # walls and doors around it still read as rooms.
            out[3 * y + 1][3 * x + 1] = digit
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
    slots = {s["digit"]: s for s in hull.get("slots", [])}
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
                d = slot_digit(hd["grid"], x, y)
                if d:
                    counts[d] = counts.get(d, 0) + 1

    print("slots (a refit may rewrite these; everything else is fixed hull):")
    for digit, slot in sorted(slots.items(), key=lambda kv: str(kv[0])):
        key = f"{digit:x}" if isinstance(digit, int) else str(digit)
        print(f"  {key}  {slot['id']:<14} {slot['name']:<22} "
              f"{counts.get(key, 0):3} tiles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
