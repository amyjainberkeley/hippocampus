#!/usr/bin/env python3
"""Render the compact installer background using macOS system frameworks only."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=Path(__file__).with_name("background.png"))
    parser.add_argument("--build-note", default="")
    args = parser.parse_args()
    if len(args.build_note) > 72 or not args.build_note.isascii() or any(ord(c) < 32 for c in args.build_note):
        parser.error("build note must be at most 72 printable ASCII characters")
    subprocess.run([
        "/usr/bin/xcrun", "swift", str(Path(__file__).with_name("render-background.swift")),
        str(args.output), args.build_note,
    ], check=True)


if __name__ == "__main__":
    main()
