#!/usr/bin/env python3
"""Generate first-crack greyscale interior sprites (stdlib-only PNG writer).
Run: python tools/gen_interior_sprites.py [outdir]
Default outdir: client/assets/interior
Art is intentionally crude; replace any PNG in place to retune (issue #36)."""
import sys, zlib, struct
from pathlib import Path

def write_png(path, w, h, px):  # px: list of (r,g,b,a) rows-major, len w*h
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: none
        for x in range(w):
            r, g, b, a = px[y * w + x]
            raw += bytes((r, g, b, a))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    Path(path).write_bytes(png)

def blank(w, h, base=(0, 0, 0, 0)):
    return [base] * (w * h)

def rect(px, w, x0, y0, x1, y1, col):
    for y in range(max(0, y0), min(len(px)//w, y1)):
        for x in range(max(0, x0), min(w, x1)):
            px[y * w + x] = col

G = lambda v, a=255: (v, v, v, a)

def sprite_rug(w=64, h=64):
    # A lighter woven border framing a darker central field, so the rug
    # reads as a distinct floor piece (not just a colour wash) at 64px.
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(205)); rect(px, w, 11, 11, 53, 53, G(140)); return w, h, px
def sprite_seat(w=64, h=64):
    # A top-down chair: the seat's quarter==0 art is authored front-facing
    # NORTH (interior_view.gd), so the backrest sits on the SOUTH edge
    # (behind a person facing the table to the north) and the lighter
    # cushion pad occupies the open north-facing area in front of it.
    px = blank(w, h)
    rect(px, w, 14, 40, 50, 54, G(150))  # backrest, south edge
    rect(px, w, 18, 14, 46, 42, G(190))  # cushion pad, north of the back
    return w, h, px
def sprite_bed(w=64, h=64):
    px = blank(w, h); rect(px, w, 8, 12, 56, 56, G(200)); rect(px, w, 12, 16, 52, 26, G(230)); return w, h, px
def sprite_cargo_pallet(w=64, h=64):
    # Base grey brought up from 170 into the 185-205 legibility band (pass-1
    # review) so the palette multiply still reads clearly; slats widened and
    # a cross-strap added so the "pallet" silhouette holds up at 64px.
    px = blank(w, h); rect(px, w, 10, 10, 54, 54, G(195))
    for gx in range(11, 54, 11): rect(px, w, gx, 10, gx + 3, 54, G(125))
    rect(px, w, 10, 30, 54, 34, G(125))  # horizontal cross-strap
    return w, h, px

def _disc(px, w, h, cx, cy, r, col):
    # A filled circle, stamped as horizontal spans (cheap, stdlib-only).
    for y in range(max(0, cy - r), min(h, cy + r + 1)):
        dx = int((r * r - (y - cy) ** 2) ** 0.5)
        rect(px, w, cx - dx, y, cx + dx + 1, y + 1, col)

def sprite_fountain(w=64, h=64):
    # An isolated fountain: round basin rim (light grey) around a darker
    # water disc, with a small ripple highlight so the water itself has a
    # visible surface, not just a flat disc.
    px = blank(w, h); _disc(px, w, h, 32, 32, 28, G(185))
    _disc(px, w, h, 32, 32, 20, G(110))
    _disc(px, w, h, 32, 32, 6, G(145))
    return w, h, px

def sprite_fountain_nesw(w=64, h=64):
    # Fully surrounded by fountain neighbours: the whole tile is water so a
    # block of interior tiles reads seamlessly as one larger pool.
    px = blank(w, h); rect(px, w, 0, 0, w, h, G(110)); return w, h, px

def sprite_flowerbed(w=64, h=64):
    # A soil bed: a dark rectangular plot with a few lighter seedling dots,
    # base grey ~185 so the palette multiply reads clearly.
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(185)); rect(px, w, 10, 10, 54, 54, G(95))
    for cx, cy in [(20, 20), (32, 26), (44, 20), (20, 44), (44, 44), (32, 40)]:
        _disc(px, w, h, cx, cy, 4, G(165))
    return w, h, px

def sprite_plant(w=64, h=64):
    # A single small sprig: a stem plus a leafy tuft, centred on the tile.
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(185))
    rect(px, w, 30, 34, 34, 54, G(120))  # stem
    _disc(px, w, h, 32, 28, 12, G(150))  # leafy tuft
    return w, h, px

def sprite_tree(w=64, h=64):
    # A canopy blob over a trunk -- reads as a small tree when several
    # flowerbed tiles combine into an interior mass.
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(185))
    rect(px, w, 27, 36, 37, 58, G(110))  # trunk
    _disc(px, w, h, 32, 24, 20, G(160))  # canopy
    return w, h, px

def sprite_table(w=64, h=64):
    # An isolated table: a flat rectangular surface (light grey) with a
    # slightly darker border, so a single tile reads as a self-contained
    # tabletop -- mirrors sprite_fountain's isolated-piece shape.
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(150)); rect(px, w, 10, 10, 54, 54, G(190))
    return w, h, px

def sprite_table_nesw(w=64, h=64):
    # Fully surrounded by table neighbours: the whole tile is tabletop so a
    # block of interior tiles reads seamlessly as one larger surface.
    px = blank(w, h); rect(px, w, 0, 0, w, h, G(190)); return w, h, px

def sprite_hydroponic(w=64, h=64):
    # A hydroponic trough/rack: a horizontal channel (light-grey ~185 base,
    # mirrors sprite_flowerbed) holding a darker nutrient-water strip.
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(185)); rect(px, w, 10, 22, 54, 42, G(110))
    return w, h, px

def sprite_hydro_plant(w=64, h=64):
    # A small sprout rising from the trough -- mirrors sprite_plant's
    # stem+tuft shape but seated on the hydroponic channel.
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(185)); rect(px, w, 10, 22, 54, 42, G(110))
    rect(px, w, 30, 24, 34, 32, G(120))  # stem
    _disc(px, w, h, 32, 18, 10, G(150))  # leafy tuft
    return w, h, px

def sprite_window(w=64, h=14):
    px = blank(w, h); rect(px, w, 2, 2, 62, 12, G(210)); rect(px, w, 30, 2, 34, 12, G(120)); return w, h, px
def sprite_viewscreen(w=64, h=14):
    px = blank(w, h); rect(px, w, 2, 2, 62, 12, G(70)); rect(px, w, 2, 2, 62, 4, G(140)); return w, h, px

def sprite_bunk(w=64, h=14):
    # A wall-mounted bunk: frame (light grey ~185 base so the palette multiply
    # reads) with a mattress band. Single frame for now, no up/down variant --
    # stacking (bunk over bed, or bunk over bunk) is convention-only this pass
    # (#36); a future pass could vary this sprite by what's beneath it (#24).
    px = blank(w, h); rect(px, w, 2, 1, 62, 13, G(185)); rect(px, w, 4, 4, 60, 10, G(225))
    return w, h, px

def _chevron_up(px, w, cx, cy, size, col):
    # A hollow up-pointing chevron (^), built from two diagonal strokes.
    for i in range(size):
        rect(px, w, cx - i - 2, cy + i, cx - i, cy + i + 4, col)
        rect(px, w, cx + i, cy + i, cx + i + 2, cy + i + 4, col)

def _chevron_down(px, w, cx, cy, size, col):
    # A hollow down-pointing chevron (v), mirror of _chevron_up.
    for i in range(size):
        rect(px, w, cx - i - 2, cy - i - 4, cx - i, cy - i, col)
        rect(px, w, cx + i, cy - i - 4, cx + i + 2, cy - i, col)

def sprite_stairs_up(w=64, h=64):
    # Light-grey shaft opening with rails either side and chevrons pointing
    # up (out of the shaft) to read "climb up from here".
    px = blank(w, h); rect(px, w, 4, 4, 60, 60, G(185))
    rect(px, w, 4, 4, 12, 60, G(150)); rect(px, w, 52, 4, 60, 60, G(150))  # side rails
    _chevron_up(px, w, 32, 14, 6, G(210))
    _chevron_up(px, w, 32, 30, 6, G(210))
    return w, h, px

def sprite_stairs_down(w=64, h=64):
    # A dark shaft opening (you're looking down into it) with chevrons
    # pointing down (into the shaft) to read "descend from here".
    px = blank(w, h); rect(px, w, 4, 4, 60, 60, G(185))
    rect(px, w, 12, 12, 52, 52, G(90))  # dark shaft opening
    _chevron_down(px, w, 32, 34, 6, G(200))
    _chevron_down(px, w, 32, 50, 6, G(200))
    return w, h, px

def sprite_stairs_updown(w=64, h=64):
    # Both directions available: up chevrons in the top half, down chevrons
    # (over a dark shaft hint) in the bottom half.
    px = blank(w, h); rect(px, w, 4, 4, 60, 60, G(185))
    rect(px, w, 4, 4, 12, 60, G(150)); rect(px, w, 52, 4, 60, 60, G(150))  # side rails
    rect(px, w, 18, 34, 46, 52, G(110))  # dark shaft hint, lower half
    _chevron_up(px, w, 32, 8, 5, G(210))
    _chevron_down(px, w, 32, 56, 5, G(205))
    return w, h, px

def sprite_console_helm(w=64, h=14):
    # Wall-mounted helm console: a panel (light grey ~185 so the palette multiply
    # reads) with a dark screen carrying a bright nav horizon line + heading mark.
    # 64x14 = the wall-strip footprint (#36 moved consoles onto walls).
    px = blank(w, h); rect(px, w, 2, 1, 62, 13, G(185))   # panel body
    rect(px, w, 6, 3, 58, 11, G(80))                      # screen
    rect(px, w, 10, 7, 54, 8, G(195))                     # nav horizon line
    rect(px, w, 27, 4, 37, 6, G(170))                     # heading marker
    return w, h, px

def sprite_console_cargo(w=64, h=14):
    # Wall-mounted cargo console: panel + screen showing a row of crate slats.
    px = blank(w, h); rect(px, w, 2, 1, 62, 13, G(185))
    rect(px, w, 6, 3, 58, 11, G(80))
    for gx in range(10, 56, 8):
        rect(px, w, gx, 4, gx + 4, 10, G(175))            # crate slats
    return w, h, px

def sprite_console_broker(w=64, h=14):
    # Wall-mounted broker console: panel + screen with a small rising bar chart.
    px = blank(w, h); rect(px, w, 2, 1, 62, 13, G(185))
    rect(px, w, 6, 3, 58, 11, G(80))
    rect(px, w, 12, 8, 18, 10, G(175))                    # rising bars (trade)
    rect(px, w, 22, 6, 28, 10, G(190))
    rect(px, w, 32, 4, 38, 10, G(205))
    return w, h, px

SPRITES = {"rug": sprite_rug, "seat": sprite_seat, "bed": sprite_bed,
           "cargo_pallet": sprite_cargo_pallet, "window": sprite_window,
           "viewscreen": sprite_viewscreen, "bunk": sprite_bunk,
           "stairs_up": sprite_stairs_up, "stairs_down": sprite_stairs_down,
           "stairs_updown": sprite_stairs_updown,
           "fountain": sprite_fountain, "fountain_nesw": sprite_fountain_nesw,
           "flowerbed": sprite_flowerbed, "plant": sprite_plant, "tree": sprite_tree,
           "table": sprite_table, "table_nesw": sprite_table_nesw,
           "hydroponic": sprite_hydroponic, "hydro_plant": sprite_hydro_plant,
           "console_helm": sprite_console_helm, "console_cargo": sprite_console_cargo,
           "console_broker": sprite_console_broker}

def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("client/assets/interior")
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in SPRITES.items():
        w, h, px = fn(); write_png(out / f"{name}.png", w, h, px)
        print(f"wrote {name}.png ({w}x{h})")

if __name__ == "__main__":
    main()
