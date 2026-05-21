#!/usr/bin/env python3
"""Generate polished DMG background (1280x800 Retina-ready).

Brand colors from assets/branding/colors.json. Renders: dark gradient,
hippocampus glyph watermark, mint drag arrow, instructional text.
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
BG = (0x0D, 0x0D, 0x0D)
BG2 = (0x1A, 0x1A, 0x1A)
MINT = (0x7A, 0xFF, 0xC1)
MINT_DIM = (0x3D, 0x80, 0x60)
MINT_SUB = (0x1A, 0x3D, 0x2E)
FG2 = (0x99, 0x99, 0x99)

# Layout (2x image coords; AppleScript window is 640x400 at 1x)
APP_POS = (340, 460)
APPS_POS = (940, 460)
TEXT_Y = 620

# Hippocampus outer path — cubic beziers from hippocampus-icon.svg (viewBox 0 0 64 64)
HIPP_OUTER = [
    ((32, 4), (24, 4), (18, 10), (18, 18)),
    ((18, 18), (18, 22), (20, 25.5), (23, 28)),
    ((23, 28), (21, 29.5), (19, 32), (19, 35)),
    ((19, 35), (19, 38), (20.5, 40.5), (23, 42.5)),
    ((23, 42.5), (22, 44.5), (21.5, 46.5), (22, 49)),
    ((22, 49), (22.8, 53), (25.5, 56), (29, 57.5)),
    ((29, 57.5), (31.5, 58.5), (34, 59), (36.5, 58.5)),
    ((36.5, 58.5), (39.5, 58), (42, 56.5), (44, 54.5)),
    ((44, 54.5), (46.5, 52), (48, 49), (48, 45.5)),
    ((48, 45.5), (48, 43.5), (47.5, 41.5), (46.5, 40)),
    ((46.5, 40), (48.5, 38), (49.5, 35.5), (49.5, 32.5)),
    ((49.5, 32.5), (49.5, 30.5), (49, 29), (48, 27.5)),
    ((48, 27.5), (51, 24.5), (53, 20.5), (53, 16)),
    ((53, 16), (48, 12), (41, 4), (32, 4)),
]

HIPP_INNER = [
    ((32, 12), (37, 12), (40, 16), (40, 20)),
    ((40, 20), (40, 24), (37, 27), (34, 29)),
    ((34, 29), (33, 29.7), (32, 30.5), (31.5, 31.5)),
    ((31.5, 31.5), (31.2, 32), (31, 32.7), (31, 33.5)),
    ((31, 33.5), (31, 35.5), (32.5, 37), (34, 38)),
    ((34, 38), (35, 38.7), (35.5, 39.5), (35.5, 40.5)),
    ((35.5, 40.5), (35.5, 42.5), (34, 44.5), (32, 46)),
    ((32, 46), (30.5, 47), (29.5, 48.5), (29.5, 50.5)),
    ((29.5, 50.5), (29.5, 51.5), (29.8, 52.5), (30.3, 53.3)),
    ((30.3, 53.3), (28.8, 52.5), (28, 51), (28, 49.3)),
    ((28, 49.3), (28, 47.3), (29, 45.8), (30.5, 44.3)),
    ((30.5, 44.3), (32.5, 42.8), (34, 40.8), (34, 38.3)),
    ((34, 38.3), (34, 36.8), (33.3, 35.3), (32, 34.3)),
    ((32, 34.3), (30, 32.8), (29, 30.8), (29, 28.3)),
    ((29, 28.3), (29, 26.8), (29.5, 25.3), (30.5, 24.3)),
    ((30.5, 24.3), (27, 22), (24, 18), (24, 14)),
    ((24, 14), (24, 11), (27.5, 8), (32, 8)),
]

GLYPHS = {
    ' ': ['00000'] * 7,
    'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
    'D': ['11110', '10001', '10001', '10001', '10001', '10001', '11110'],
    'H': ['10001', '10001', '10001', '11111', '10001', '10001', '10001'],
    'a': ['00000', '00000', '01110', '00001', '01111', '10001', '01111'],
    'c': ['00000', '00000', '01110', '10000', '10000', '10000', '01110'],
    'g': ['00000', '00000', '01111', '10001', '01111', '00001', '01110'],
    'i': ['00100', '00000', '01100', '00100', '00100', '00100', '01110'],
    'l': ['01100', '00100', '00100', '00100', '00100', '00100', '01110'],
    'm': ['00000', '00000', '11010', '10101', '10101', '10001', '10001'],
    'n': ['00000', '00000', '10110', '11001', '10001', '10001', '10001'],
    'o': ['00000', '00000', '01110', '10001', '10001', '10001', '01110'],
    'p': ['00000', '00000', '11110', '10001', '11110', '10000', '10000'],
    'r': ['00000', '00000', '10110', '11001', '10000', '10000', '10000'],
    's': ['00000', '00000', '01111', '10000', '01110', '00001', '11110'],
    't': ['00100', '00100', '01110', '00100', '00100', '00100', '00011'],
    'u': ['00000', '00000', '10001', '10001', '10001', '10011', '01101'],
}

buf = bytearray(W * H * 3)


def blend(x, y, color, alpha):
    if 0 <= x < W and 0 <= y < H:
        i = (y * W + x) * 3
        inv = 1.0 - alpha
        buf[i] = min(255, int(buf[i] * inv + color[0] * alpha))
        buf[i + 1] = min(255, int(buf[i + 1] * inv + color[1] * alpha))
        buf[i + 2] = min(255, int(buf[i + 2] * inv + color[2] * alpha))


def cubic_pts(p0, p1, p2, p3, n=25):
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        yield (
            u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
        )


def flatten_beziers(beziers, n=25):
    pts = []
    for b in beziers:
        pts.extend(cubic_pts(b[0], b[1], b[2], b[3], n))
    return pts


def build_edges(pts):
    edges = []
    n = len(pts)
    for i in range(n):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % n]
        if abs(y1 - y0) < 0.001:
            continue
        if y0 > y1:
            x0, y0, x1, y1 = x1, y1, x0, y0
        edges.append((y0, y1, x0, (x1 - x0) / (y1 - y0)))
    return edges


def scanfill(edges, color, alpha):
    if not edges:
        return
    y_lo = max(0, int(min(e[0] for e in edges)))
    y_hi = min(H - 1, int(max(e[1] for e in edges)))
    for y in range(y_lo, y_hi + 1):
        xs = []
        for y0, y1, x0, slope in edges:
            if y0 <= y < y1:
                xs.append(x0 + slope * (y - y0))
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            xa = max(0, int(math.ceil(xs[i])))
            xb = min(W - 1, int(xs[i + 1]))
            for x in range(xa, xb + 1):
                blend(x, y, color, alpha)


def draw_gradient():
    for y in range(H):
        t = y / H
        r = int(BG[0] + (BG2[0] - BG[0]) * t)
        g = int(BG[1] + (BG2[1] - BG[1]) * t)
        b = int(BG[2] + (BG2[2] - BG[2]) * t)
        row = bytes([r, g, b]) * W
        buf[y * W * 3:(y + 1) * W * 3] = row


def draw_watermark():
    scale = 5.5
    cx_img, cy_img = W // 2, 230
    ox = cx_img - 35.5 * scale
    oy = cy_img - 31.5 * scale

    def xform(beziers):
        return [
            tuple((p[0] * scale + ox, p[1] * scale + oy) for p in b)
            for b in beziers
        ]

    outer_pts = flatten_beziers(xform(HIPP_OUTER), n=30)
    inner_pts = flatten_beziers(xform(HIPP_INNER), n=30)
    edges = build_edges(outer_pts) + build_edges(inner_pts)
    scanfill(edges, MINT, 0.06)


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
            blend(x, y + dy, MINT_DIM, 0.45)
    head = 24
    for i in range(head):
        w = int(10 * (1 - i / head))
        for j in range(-w, w + 1):
            blend(x2 - i, y + j, MINT_DIM, 0.45)


def draw_text(text, cx, y, color, scale=4):
    cw = 5 * scale + scale
    total = len(text) * cw - scale
    sx = cx - total // 2
    for ci, ch in enumerate(text):
        glyph = GLYPHS.get(ch, GLYPHS[' '])
        gx = sx + ci * cw
        for gy, row in enumerate(glyph):
            for gxx, bit in enumerate(row):
                if bit == '1':
                    for dy in range(scale):
                        for dx in range(scale):
                            blend(gx + gxx * scale + dx, y + gy * scale + dy,
                                  color, 0.8)


def draw_accent_line():
    y = 560
    for x in range(280, 1001):
        t = 1.0 - abs(x - 640) / 360
        blend(x, y, MINT_SUB, 0.12 * max(0, t))


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
    draw_ring(APP_POS[0], APP_POS[1], 58, MINT_SUB, 0.2, 2)
    draw_ring(APPS_POS[0], APPS_POS[1], 58, MINT_SUB, 0.2, 2)
    draw_arrow()
    draw_accent_line()
    draw_text("Drag Hippocampus to Applications", W // 2, TEXT_Y, FG2, scale=4)

    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "background.png")
    out = sys.argv[1] if len(sys.argv) > 1 else default
    data = make_png()
    with open(out, "wb") as f:
        f.write(data)
    print(f"  {out} ({len(data):,} bytes, {W}x{H})")


if __name__ == "__main__":
    main()
