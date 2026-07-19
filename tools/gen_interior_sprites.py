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

SPRITES = {"rug": sprite_rug, "seat": sprite_seat, "bed": sprite_bed,
           "cargo_pallet": sprite_cargo_pallet, "window": sprite_window,
           "viewscreen": sprite_viewscreen}

def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("client/assets/interior")
    out.mkdir(parents=True, exist_ok=True)
    for name, fn in SPRITES.items():
        w, h, px = fn(); write_png(out / f"{name}.png", w, h, px)
        print(f"wrote {name}.png ({w}x{h})")

if __name__ == "__main__":
    main()
