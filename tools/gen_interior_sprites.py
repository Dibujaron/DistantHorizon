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
    px = blank(w, h); rect(px, w, 6, 6, 58, 58, G(200)); rect(px, w, 10, 10, 54, 54, G(150)); return w, h, px
def sprite_seat(w=64, h=64):
    px = blank(w, h); rect(px, w, 16, 40, 48, 54, G(190)); rect(px, w, 16, 14, 22, 54, G(150)); return w, h, px
def sprite_bed(w=64, h=64):
    px = blank(w, h); rect(px, w, 8, 12, 56, 56, G(200)); rect(px, w, 12, 16, 52, 26, G(230)); return w, h, px
def sprite_cargo_pallet(w=64, h=64):
    px = blank(w, h); rect(px, w, 10, 10, 54, 54, G(170))
    for gx in range(10, 54, 8): rect(px, w, gx, 10, gx + 2, 54, G(120))
    return w, h, px
def sprite_window(w=64, h=14):
    px = blank(w, h); rect(px, w, 2, 2, 62, 12, G(210)); rect(px, w, 30, 2, 34, 12, G(120)); return w, h, px
def sprite_viewscreen(w=64, h=14):
    px = blank(w, h); rect(px, w, 2, 2, 62, 12, G(70)); rect(px, w, 2, 2, 62, 4, G(140)); return w, h, px

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

SPRITES = {"rug": sprite_rug, "seat": sprite_seat, "bed": sprite_bed,
           "cargo_pallet": sprite_cargo_pallet, "window": sprite_window,
           "viewscreen": sprite_viewscreen,
           "stairs_up": sprite_stairs_up, "stairs_down": sprite_stairs_down,
           "stairs_updown": sprite_stairs_updown}

def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("client/assets/interior")
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in SPRITES.items():
        w, h, px = fn(); write_png(out / f"{name}.png", w, h, px)
        print(f"wrote {name}.png ({w}x{h})")

if __name__ == "__main__":
    main()
