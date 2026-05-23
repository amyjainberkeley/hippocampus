#!/usr/bin/env python3
"""Generate browser-extension toolbar icons from the canonical AppIcon source.

Downsamples assets/branding/AppIcon.iconset/icon_512x512.png with LANCZOS to the
sizes Safari and Chromium toolbars consume, then writes identical PNG sets into
both extensions/safari/icons/ and extensions/chromium/icons/ so the two browsers
present visually identical brand marks.

Run from the repo root:

    python3 scripts/generate-extension-toolbar-icons.py
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("Pillow is required: pip install Pillow\n")
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCE = REPO_ROOT / "assets" / "branding" / "AppIcon.iconset" / "icon_512x512.png"

TARGETS = [
    REPO_ROOT / "extensions" / "safari" / "icons",
    REPO_ROOT / "extensions" / "chromium" / "icons",
]

SIZES = [16, 19, 32, 38, 48, 72, 96, 128]


def main() -> int:
    if not SOURCE.exists():
        sys.stderr.write(f"missing source PNG: {SOURCE}\n")
        return 1

    src = Image.open(SOURCE).convert("RGBA")
    for out_dir in TARGETS:
        out_dir.mkdir(parents=True, exist_ok=True)
        for size in SIZES:
            scaled = src.resize((size, size), Image.LANCZOS)
            dst = out_dir / f"toolbar-{size}.png"
            scaled.save(dst, format="PNG", optimize=True)
            print(f"wrote {dst.relative_to(REPO_ROOT)} ({size}x{size})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
