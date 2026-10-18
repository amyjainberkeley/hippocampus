#!/usr/bin/env python3
"""Write Finder metadata headlessly on the build's mounted writable image.

The window's size and position, the icon size and every item's position come
from layout.json, the file the background is drawn from, so the picture and
the icons cannot drift apart.
"""
import argparse
from importlib.metadata import PackageNotFoundError, version
import json
from pathlib import Path

LAYOUT = Path(__file__).resolve().with_name("layout.json")


def check_dependencies():
    for package, expected in (("ds-store", "1.3.3"), ("mac-alias", "2.2.3")):
        try:
            actual = version(package)
        except PackageNotFoundError:
            actual = "missing"
        if actual != expected:
            raise RuntimeError(
                f"Installer requires {package}=={expected} (found {actual}). "
                "Use an isolated Python >=3.10 environment with "
                "scripts/installer-requirements.txt (--require-hashes --only-binary=:all:) "
                "and set INSTALLER_PYTHON to its Python. No automatic installs."
            )


def load_layout(path=LAYOUT):
    layout = json.loads(Path(path).read_text())
    window = layout["window"]
    return {
        # Finder's "{{x, y}, {width, height}}": the whole window, title bar
        # included. The background is drawn at this size.
        "bounds": "{{%d, %d}, {%d, %d}}" % (window["x"], window["y"], window["width"], window["height"]),
        "icon_size": float(layout["iconSize"]),
        "text_size": float(layout["textSize"]),
        "locations": {name: tuple(position) for name, position in layout["items"].items()},
    }


def write_layout(mount):
    check_dependencies()
    from ds_store import DSStore
    from mac_alias import Alias

    mount = Path(mount).resolve()
    background = mount / ".background/background.png"
    if not (mount / "Hippocampus.app").is_dir() or not (mount / "Applications").is_symlink():
        raise ValueError("Installer requires its app and Applications link")
    if not background.is_file() or not (mount / "Legal/License.rtf").is_file():
        raise ValueError("Installer requires its background and visible Legal/License.rtf")
    layout = load_layout()

    # Follow dmgbuild's public DSStore/Alias API, never serialize these formats
    # ourselves. Resolve the alias on the image, not the host staging volume.
    # https://github.com/dmgbuild/dmgbuild/blob/main/src/dmgbuild/core.py
    window = {
        "WindowBounds": layout["bounds"],
        "ShowToolbar": False, "ShowSidebar": False, "ShowStatusBar": False,
        "ShowPathbar": False, "ShowTabView": False,
        "ContainerShowSidebar": False, "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
    }
    # Finder ignores this whole view unless all three colour fields are
    # present (docs/audits/2026-09-09-installer-experience.md).
    icons = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "arrangeBy": "none", "showIconPreview": False, "showItemInfo": False,
        "labelOnBottom": True, "textSize": layout["text_size"], "iconSize": layout["icon_size"],
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    locations = layout["locations"]
    with DSStore.open(str(mount / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = window
        store["."]["icvp"] = icons
        store["."]["icvl"] = ("type", b"icnv")
        for name, position in locations.items():
            store[name]["Iloc"] = position
    # Fail packaging if persisted metadata cannot be read back intact.
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        if store["."]["bwsp"] != window or store["."]["icvp"] != icons:
            raise RuntimeError("Installer layout did not persist")
        for name, position in locations.items():
            if store[name]["Iloc"] != position:
                raise RuntimeError(f"Installer icon position did not persist: {name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mount", nargs="?", type=Path)
    parser.add_argument("--check-dependencies", action="store_true")
    args = parser.parse_args()
    try:
        if args.check_dependencies:
            check_dependencies()
        elif args.mount is not None:
            write_layout(args.mount)
        else:
            parser.error("mount is required")
    except (RuntimeError, ValueError, OSError, KeyError) as error:
        parser.exit(1, f"ERROR: {error}\n")
