#!/usr/bin/env python3
"""Render the installer window for review, headlessly, from current source.

Writes three pictures to OUT_DIR:
  background.png   the window's background, exactly as a build renders it
  legal-icon.png   the Legal folder's icon
  window.png       a mock-up of the whole window, laid out from layout.json

Nothing is mounted and nothing opens in Finder. The mock-up stages the disk
image's top level in a temporary folder (an Applications link and a Legal
folder given its icon, as a build does) and asks macOS for each item's icon.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
APP_ICON = HERE.parent / "branding/AppIcon.icns"


def swift(script, *arguments):
    subprocess.run(["/usr/bin/xcrun", "swift", str(HERE / script), *map(str, arguments)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out_dir", type=Path)
    args = parser.parse_args()
    out = args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)

    swift("render-background.swift", out / "background.png", HERE / "layout.json")
    swift("render-legal-icon.swift", "png", out / "legal-icon.png")
    with tempfile.TemporaryDirectory(prefix="hippocampus-installer-preview-") as temporary:
        staging = Path(temporary)
        (staging / "Applications").symlink_to("/Applications")
        (staging / "Legal").mkdir()
        swift("render-legal-icon.swift", "apply", staging / "Legal")
        swift("render-window-preview.swift", HERE / "layout.json", out / "background.png", staging,
              APP_ICON, out / "window.png")
    for name in ("background.png", "legal-icon.png", "window.png"):
        print(out / name)


if __name__ == "__main__":
    main()
