#!/usr/bin/env python3
"""Generate first-crack greyscale interior sprites (stdlib-only PNG writer).
Run: python tools/gen_interior_sprites.py [outdir]
Default outdir: client/assets/interior

Design language (so tiles read as OBJECTS, not white squares, and still take the
palette-colour multiply as shading): a dark outline (~G(55)) defines the
silhouette, a mid fill carries the body/colour, and a light highlight (~G(215))
adds a lit edge. Uniform light fills read as blank squares — always give a shape
a dark outline. Art is intentionally crude; replace any PNG in place to retune
(issue #36)."""
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
OL = G(55)    # dark outline
DK = G(90)    # dark accent / recess
MD = G(150)   # mid body
LT = G(215)   # light highlight

def _disc(px, w, h, cx, cy, r, col):
    # A filled circle, stamped as horizontal spans (cheap, stdlib-only).
    for y in range(max(0, cy - r), min(h, cy + r + 1)):
        dx = int((r * r - (y - cy) ** 2) ** 0.5) if abs(y - cy) <= r else 0
        rect(px, w, cx - dx, y, cx + dx + 1, y + 1, col)

def ring(px, w, h, cx, cy, r, col, t=3):
    _disc(px, w, h, cx, cy, r, col)
    _disc(px, w, h, cx, cy, r - t, (0, 0, 0, 0))

def box(px, w, x0, y0, x1, y1, fill, edge=OL, t=3):
    # Filled rect with a t-thick dark border, so it reads as a bordered object.
    rect(px, w, x0, y0, x1, y1, edge)
    rect(px, w, x0 + t, y0 + t, x1 - t, y1 - t, fill)

# ---------------------------------------------------------------- floor decor --

def sprite_rug(w=64, h=64):
    # Bordered rug with a dark medallion, so it reads as a floor piece.
    px = blank(w, h)
    box(px, w, 6, 12, 58, 52, LT, OL, 3)
    box(px, w, 14, 20, 50, 44, MD, OL, 2)     # inner field
    _disc(px, w, h, 32, 32, 7, OL)            # medallion
    _disc(px, w, h, 32, 32, 4, LT)
    return w, h, px

def sprite_seat(w=64, h=64):
    # Top-down chair, front-facing NORTH (quarter==0, interior_view.gd): thick
    # dark backrest on the SOUTH edge, a mid cushion pad in front of it, and two
    # dark arm stubs — a clear chair silhouette, not a pad.
    px = blank(w, h)
    box(px, w, 16, 20, 48, 50, MD, OL, 3)     # cushion body
    rect(px, w, 16, 44, 48, 52, OL)           # backrest (south)
    rect(px, w, 14, 22, 20, 48, OL)           # left arm
    rect(px, w, 44, 22, 50, 48, OL)           # right arm
    rect(px, w, 22, 26, 42, 40, LT)           # lit seat pad
    return w, h, px

# Classic-Minecraft bed palette — baked into the sprite (not greyscale) so a bed
# reads red covers + white pillow by DEFAULT (its glyph carries no default slot,
# so it draws untinted); an NE-corner colour still multiplies over it.
BED_RED = (176, 46, 38, 255)     # colors.json 'red' #B02E26
BED_RED_DK = (120, 30, 26, 255)
BED_WHITE = (240, 244, 243, 255)

def sprite_bed(w=64, h=64):
    px = blank(w, h)
    box(px, w, 10, 8, 54, 58, BED_RED, OL, 3)      # red covers, dark frame
    rect(px, w, 14, 40, 50, 45, BED_RED_DK)        # blanket fold shadow
    rect(px, w, 14, 12, 50, 26, BED_WHITE)         # white pillow
    rect(px, w, 14, 26, 50, 28, (200, 204, 203, 255))  # pillow shadow
    return w, h, px

def sprite_cargo_pallet(w=64, h=64):
    # A crate: dark frame, plank slats, and an X-strap so it reads as cargo.
    px = blank(w, h)
    box(px, w, 8, 8, 56, 56, MD, OL, 3)
    for gx in range(14, 54, 10): rect(px, w, gx, 11, gx + 3, 53, DK)  # slats
    # diagonal X straps
    for i in range(44):
        rect(px, w, 11 + i, 11 + i, 13 + i, 13 + i, OL)
        rect(px, w, 53 - i, 11 + i, 55 - i, 13 + i, OL)
    return w, h, px

def sprite_fountain(w=64, h=64):
    # A round basin: dark stone rim, dark water pool, a light central jet — an
    # isolated fountain (merged interiors use fountain_nesw).
    px = blank(w, h)
    ring(px, w, h, 32, 32, 28, OL, 4)         # rim
    _disc(px, w, h, 32, 32, 23, DK)           # water
    _disc(px, w, h, 32, 32, 8, LT)            # jet / spray
    _disc(px, w, h, 32, 32, 3, G(240))
    return w, h, px

def sprite_fountain_nesw(w=64, h=64):
    # Seamless water interior (fills the tile edge-to-edge, no margin) so a block
    # of fountains reads as one continuous pool; darker than the rim with a
    # ripple so it still reads when untinted.
    px = blank(w, h, DK)
    for ry in range(6, 64, 14):
        rect(px, w, 0, ry, 64, ry + 2, G(120))   # ripples
    _disc(px, w, h, 32, 32, 6, LT)
    return w, h, px

def sprite_flowerbed(w=64, h=64):
    # A dark soil bed with scattered light/dark sprigs.
    px = blank(w, h)
    box(px, w, 8, 10, 56, 54, G(105), OL, 3)   # soil
    for (sx, sy) in ((18, 22), (32, 18), (46, 24), (22, 40), (40, 42), (30, 34)):
        rect(px, w, sx - 1, sy, sx + 1, sy + 8, G(70))   # stem
        _disc(px, w, h, sx, sy, 4, LT)                   # bloom
    return w, h, px

def sprite_plant(w=64, h=64):
    # A single small sprig: dark stem + two leaf discs, centred with margin so
    # it reads as one plant on the floor.
    px = blank(w, h)
    rect(px, w, 30, 30, 34, 52, OL)            # stem
    _disc(px, w, h, 24, 30, 8, MD); _disc(px, w, h, 24, 30, 8 - 3, LT)
    _disc(px, w, h, 40, 26, 9, MD); _disc(px, w, h, 40, 26, 9 - 3, LT)
    return w, h, px

def sprite_tree(w=64, h=64):
    # A trunk + a big round canopy (dark outline, mid fill, lit crown).
    px = blank(w, h)
    rect(px, w, 28, 40, 36, 60, OL)            # trunk
    ring(px, w, h, 32, 26, 22, OL, 3)
    _disc(px, w, h, 32, 26, 18, MD)
    _disc(px, w, h, 27, 21, 8, LT)             # lit crown
    return w, h, px

def sprite_table(w=64, h=64):
    # A surface slab with a dark frame and four dark legs at the corners.
    px = blank(w, h)
    for (lx, ly) in ((12, 12), (46, 12), (12, 46), (46, 46)):
        rect(px, w, lx, ly, lx + 6, ly + 6, OL)   # legs
    box(px, w, 10, 14, 54, 50, MD, OL, 3)         # top
    rect(px, w, 16, 20, 48, 26, LT)               # lit edge
    return w, h, px

def sprite_table_nesw(w=64, h=64):
    # Seamless table top (edge-to-edge) with dark seams so a run of tables reads
    # as one surface.
    px = blank(w, h, MD)
    rect(px, w, 0, 0, 64, 3, OL); rect(px, w, 0, 61, 64, 64, OL)
    rect(px, w, 0, 0, 3, 64, OL); rect(px, w, 61, 0, 64, 64, OL)
    rect(px, w, 8, 10, 56, 16, LT)
    return w, h, px

def sprite_hydroponic(w=64, h=64):
    # A planter trough: dark frame, a recessed channel, sprigs along it.
    px = blank(w, h)
    box(px, w, 8, 18, 56, 46, G(120), OL, 3)   # trough body
    rect(px, w, 14, 26, 50, 38, DK)            # water channel
    for sx in (20, 30, 40):
        rect(px, w, sx - 1, 22, sx + 1, 30, G(70)); _disc(px, w, h, sx, 22, 3, LT)
    return w, h, px

def sprite_hydro_plant(w=64, h=64):
    # A sprout rising from the trough channel.
    px = blank(w, h)
    box(px, w, 8, 34, 56, 50, G(120), OL, 3)   # trough base
    rect(px, w, 30, 14, 34, 38, OL)            # stem
    _disc(px, w, h, 32, 14, 9, MD); _disc(px, w, h, 32, 14, 6, LT)
    return w, h, px

# ------------------------------------------------------------- wall fixtures --
# 64x14 strips (they render on the wall edge, not the tile centre).

def sprite_window(w=64, h=14):
    # A framed window: dark frame, two light panes split by a dark mullion.
    px = blank(w, h)
    box(px, w, 1, 1, 63, 13, LT, OL, 2)
    rect(px, w, 31, 1, 33, 13, OL)             # mullion
    return w, h, px

def sprite_viewscreen(w=64, h=14):
    # A wall screen: dark screen behind a light frame, with a scanline glow.
    px = blank(w, h)
    box(px, w, 1, 1, 63, 13, DK, OL, 2)
    rect(px, w, 4, 4, 60, 6, G(130))           # scanline glow
    return w, h, px

def sprite_bunk(w=64, h=14):
    # Wall-mounted bunk: same red-covers/white-pillow bedding as the floor bed.
    px = blank(w, h)
    box(px, w, 1, 1, 63, 13, BED_RED, OL, 2)   # red mattress, dark frame
    rect(px, w, 4, 4, 16, 10, BED_WHITE)       # white pillow
    rect(px, w, 18, 6, 60, 8, BED_RED_DK)      # blanket line
    return w, h, px

def _console(px, w):
    # Shared console panel: dark frame + dark screen (callers add the per-kind mark).
    box(px, w, 1, 1, 63, 13, G(140), OL, 2)
    rect(px, w, 6, 3, 58, 11, G(60))

def sprite_console_helm(w=64, h=14):
    px = blank(w, h); _console(px, w)
    rect(px, w, 10, 7, 54, 8, LT)              # nav horizon
    rect(px, w, 27, 4, 37, 6, G(170))          # heading marker
    return w, h, px

def sprite_console_cargo(w=64, h=14):
    px = blank(w, h); _console(px, w)
    for gx in range(10, 56, 8): rect(px, w, gx, 4, gx + 4, 10, G(175))  # crate slats
    return w, h, px

def sprite_console_broker(w=64, h=14):
    px = blank(w, h); _console(px, w)
    rect(px, w, 12, 8, 18, 10, G(150))         # rising bars
    rect(px, w, 22, 6, 28, 10, G(185))
    rect(px, w, 32, 4, 38, 10, LT)
    return w, h, px

# -------------------------------------------------------------------- stairs --

def _chevron_up(px, w, cx, cy, size, col):
    for i in range(size):
        rect(px, w, cx - i - 2, cy + i, cx - i, cy + i + 4, col)
        rect(px, w, cx + i, cy + i, cx + i + 2, cy + i + 4, col)

def _chevron_down(px, w, cx, cy, size, col):
    for i in range(size):
        rect(px, w, cx - i - 2, cy - i - 4, cx - i, cy - i, col)
        rect(px, w, cx + i, cy - i - 4, cx + i + 2, cy - i, col)

def sprite_stairs_up(w=64, h=64):
    # A raised light panel with three bold dark up-chevrons — the light-on-panel
    # inverse of the dark down-shaft, so "ascend" reads as strongly as "descend".
    px = blank(w, h)
    box(px, w, 8, 8, 56, 56, LT, OL, 3)
    for cy in (16, 30, 44):
        _chevron_up(px, w, 32, cy, 8, OL)
    return w, h, px

def sprite_stairs_down(w=64, h=64):
    # A dark shaft you look down into, with down-chevrons — reads "descend".
    px = blank(w, h)
    box(px, w, 8, 8, 56, 56, G(130), OL, 3)
    box(px, w, 16, 16, 48, 48, G(45), OL, 2)   # dark opening
    _chevron_down(px, w, 32, 30, 6, LT)
    _chevron_down(px, w, 32, 44, 6, MD)
    return w, h, px

def sprite_stairs_updown(w=64, h=64):
    # Split panel: light upper half with dark up-chevrons, dark lower shaft with
    # light down-chevrons — both directions read at a glance.
    px = blank(w, h)
    box(px, w, 8, 8, 56, 32, LT, OL, 3)        # upper: light (up)
    box(px, w, 8, 32, 56, 56, G(45), OL, 3)    # lower: dark shaft (down)
    _chevron_up(px, w, 32, 14, 6, OL)
    _chevron_up(px, w, 32, 24, 6, OL)
    _chevron_down(px, w, 32, 40, 6, LT)
    _chevron_down(px, w, 32, 50, 6, LT)
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
