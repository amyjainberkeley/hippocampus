#!/usr/bin/env python3
"""Generate the light Hippocampus DMG background (1280x800 Retina-ready).

Brand colors from assets/branding/colors.json. Renders a quiet snow-to-white
surface, the layered-memory watermark, and a cobalt drag arrow.
Pure Python stdlib (struct + zlib). No Pillow.

Regenerate:
    python3 assets/installer/generate-background.py [output_path]
"""

import math
import os
import struct
import sys
import zlib

W, H = 1280, 800

# Brand palette (assets/branding/colors.json)
BG = (0xF6, 0xF8, 0xFB)
BG2 = (0xFF, 0xFF, 0xFF)
ACCENT_DIM = (0x6F, 0x89, 0xC8)
BORDER = (0xC8, 0xD2, 0xDE)
INK = (0x18, 0x21, 0x2B)
GRAPHITE = (0x5F, 0x69, 0x75)

# Layout (2x image coords; AppleScript window is 640x400 at 1x)
APP_POS = (340, 460)
APPS_POS = (940, 460)
buf = bytearray(W * H * 3)


def blend(x, y, color, alpha):
    if 0 <= x < W and 0 <= y < H:
        i = (y * W + x) * 3
        inv = 1.0 - alpha
        buf[i] = min(255, int(buf[i] * inv + color[0] * alpha))
        buf[i + 1] = min(255, int(buf[i + 1] * inv + color[1] * alpha))
        buf[i + 2] = min(255, int(buf[i + 2] * inv + color[2] * alpha))


def draw_gradient():
    for y in range(H):
        t = y / H
        r = int(BG[0] + (BG2[0] - BG[0]) * t)
        g = int(BG[1] + (BG2[1] - BG[1]) * t)
        b = int(BG[2] + (BG2[2] - BG[2]) * t)
        row = bytes([r, g, b]) * W
        buf[y * W * 3:(y + 1) * W * 3] = row


def draw_rounded_rect(x, y, width, height, radius, color, alpha):
    for py in range(y, y + height):
        for px in range(x, x + width):
            dx = max(x + radius - px, 0, px - (x + width - radius - 1))
            dy = max(y + radius - py, 0, py - (y + height - radius - 1))
            if dx * dx + dy * dy <= radius * radius:
                blend(px, py, color, alpha)


def draw_watermark():
    # Three quiet evidence sheets mirror the app icon without turning the
    # installer into a billboard.
    draw_rounded_rect(485, 82, 250, 300, 48, BORDER, 0.22)
    draw_rounded_rect(515, 66, 250, 300, 48, GRAPHITE, 0.13)
    draw_rounded_rect(545, 86, 250, 300, 48, INK, 0.10)
    for y, width, opacity in [(160, 138, 0.16), (216, 122, 0.13), (272, 96, 0.10)]:
        draw_rounded_rect(600, y, width, 14, 7, INK, opacity)


def draw_ring(cx, cy, r, color, alpha=0.2, thickness=2):
    steps = max(360, int(r * 6))
    for i in range(steps):
        a = 2 * math.pi * i / steps
        cos_a, sin_a = math.cos(a), math.sin(a)
        for t in range(thickness):
            rr = r + t - thickness / 2
            blend(int(cx + rr * cos_a), int(cy + rr * sin_a), color, alpha)


def draw_arrow():
    x1 = APP_POS[0] + 75
    x2 = APPS_POS[0] - 75
    y = APP_POS[1]
    for dy in range(-1, 2):
        for x in range(x1, x2 + 1):
            blend(x, y + dy, ACCENT_DIM, 0.48)
    head = 24
    for i in range(head):
        w = int(10 * (1 - i / head))
        for j in range(-w, w + 1):
            blend(x2 - i, y + j, ACCENT_DIM, 0.48)


def draw_accent_line():
    y = 560
    for x in range(280, 1001):
        t = 1.0 - abs(x - 640) / 360
        blend(x, y, BORDER, 0.18 * max(0, t))


def make_png():
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = bytearray()
    for y in range(H):
        raw.append(0)
        raw.extend(buf[y * W * 3:(y + 1) * W * 3])

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def main():
    print("Generating DMG background (1280x800 Retina)...")
    draw_gradient()
    draw_watermark()
    draw_ring(APP_POS[0], APP_POS[1], 58, BORDER, 0.55, 2)
    draw_ring(APPS_POS[0], APPS_POS[1], 58, BORDER, 0.55, 2)
    draw_arrow()
    draw_accent_line()
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "background.png")
    out = sys.argv[1] if len(sys.argv) > 1 else default
    data = make_png()
    with open(out, "wb") as f:
        f.write(data)
    print(f"  {out} ({len(data):,} bytes, {W}x{H})")


if __name__ == "__main__":
    main()
