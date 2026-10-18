#!/usr/bin/env python3
"""Render the installer window's background using macOS system frameworks only.

The picture is drawn from layout.json, the same file the Finder layout comes
from, so the arrow and the words always sit where the icons are. It carries
only two lines of words. Build and source details belong in the app's
build-provenance.json and the release notes.
"""
import argparse
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=HERE / "background.png")
    args = parser.parse_args()
    subprocess.run([
        "/usr/bin/xcrun", "swift", str(HERE / "render-background.swift"),
        str(args.output), str(HERE / "layout.json"),
    ], check=True)


if __name__ == "__main__":
    main()
