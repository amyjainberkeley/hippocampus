#!/usr/bin/env python3
"""Render the compact installer background using macOS system frameworks only.

The background carries only the two instructions. Build and source details
belong in the app's build-provenance.json and the release notes.
"""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=Path(__file__).with_name("background.png"))
    args = parser.parse_args()
    subprocess.run([
        "/usr/bin/xcrun", "swift", str(Path(__file__).with_name("render-background.swift")),
        str(args.output),
    ], check=True)


if __name__ == "__main__":
    main()
