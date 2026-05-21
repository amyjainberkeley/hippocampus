#!/usr/bin/env python3
"""Generate the DMG background image (640x480) using only Python stdlib.

Produces a dark-themed background with brand colors and an arrow indicating
"Drag Hippocampus to Applications". Works without Pillow/PIL — writes raw PNG
using struct + zlib.

Usage:
    python3 generate-background.py [output_path]
    python3 generate-background.py           # writes to assets/installer/background.png
"""

import struct
import sys
import zlib

WIDTH = 640
HEIGHT = 480

BG_R, BG_G, BG_B = 0x0D, 0x0D, 0x0D
MINT_R, MINT_G, MINT_B = 0x7A, 0xFF, 0xC1
DIM_R, DIM_G, DIM_B = 0x3D, 0x80, 0x60
SECONDARY_R, SECONDARY_G, SECONDARY_B = 0x99, 0x99, 0x99


def make_png(width, height, rows):
    """Create a PNG file from raw pixel rows (each row = bytes of R,G,B per pixel)."""

    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))

    raw = b""
    for row in rows:
        raw += b"\x00" + row

    idat = chunk(b"IDAT", zlib.compress(raw, 9))
    iend = chunk(b"IEND", b"")

    return sig + ihdr + idat + iend


def lerp(a, b, t):
    return int(a + (b - a) * t)


def draw_background():
    """Render the DMG background: dark gradient + mint arrow + label area."""
    rows = []

    arrow_cx = WIDTH // 2
    arrow_cy = HEIGHT // 2 + 40
    arrow_len = 80
    arrow_head = 20

    for y in range(HEIGHT):
        row = bytearray()
        grad_t = y / HEIGHT
        r0 = lerp(BG_R, BG_R + 8, grad_t)
        g0 = lerp(BG_G, BG_G + 8, grad_t)
        b0 = lerp(BG_B, BG_B + 8, grad_t)

        for x in range(WIDTH):
            pr, pg, pb = r0, g0, b0

            # Arrow shaft: horizontal line 3px thick
            shaft_y = arrow_cy
            shaft_x_start = arrow_cx - arrow_len
            shaft_x_end = arrow_cx + arrow_len
            if abs(y - shaft_y) <= 1 and shaft_x_start <= x <= shaft_x_end:
                pr, pg, pb = MINT_R, MINT_G, MINT_B

            # Arrow head: right-pointing triangle
            head_x = arrow_cx + arrow_len
            dx = head_x - x
            dy = abs(y - shaft_y)
            if 0 <= dx <= arrow_head and dy <= dx * 0.6:
                if dx <= arrow_head:
                    pr, pg, pb = MINT_R, MINT_G, MINT_B

            # Subtle guide circles where icons should sit (app left, Applications right)
            for cx, cy, radius in [(190, 260, 50), (450, 260, 50)]:
                dist_sq = (x - cx) ** 2 + (y - cy) ** 2
                ring_outer = (radius + 2) ** 2
                ring_inner = (radius - 2) ** 2
                if ring_inner <= dist_sq <= ring_outer:
                    pr, pg, pb = DIM_R, DIM_G, DIM_B

            row.extend([pr, pg, pb])

        rows.append(bytes(row))

    return rows


def main():
    output = sys.argv[1] if len(sys.argv) > 1 else "assets/installer/background.png"

    rows = draw_background()
    png_data = make_png(WIDTH, HEIGHT, rows)

    with open(output, "wb") as f:
        f.write(png_data)

    print(f"Generated DMG background: {output} ({len(png_data)} bytes)")


if __name__ == "__main__":
    main()
