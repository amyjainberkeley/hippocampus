#!/usr/bin/env python3
"""Headless fixtures only: no Finder, app launch, or mounted user images."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from ds_store import DSStore
from mac_alias import Alias

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "assets/installer"
WRITER = INSTALLER / "dmg-layout.py"
LAYOUT = json.loads((INSTALLER / "layout.json").read_text())
ENV = {key: value for key, value in os.environ.items() if key in (
    "HOME", "TMPDIR", "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "DEVELOPER_DIR",
)}
ENV["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"

# What a person sees below the title bar. Finder's title bar is 32 points on
# macOS 26 and 28 on 14 and 15, so nothing may rely on the last 32 points.
WINDOW_WIDTH = LAYOUT["window"]["width"]
VISIBLE_HEIGHT = LAYOUT["window"]["height"] - LAYOUT["titleBarHeight"]
# Room left around every item, so Finder never shows scroll bars.
EDGE = 12


def disk(*args):
    subprocess.run(["/usr/bin/hdiutil", *map(str, args)], check=True, stdout=subprocess.DEVNULL, env=ENV)


def shipped_dmg_format():
    """The compression build-installer.sh ships, so the layout is proven on it."""
    script = (ROOT / "scripts/build-installer.sh").read_text()
    match = re.search(r'^DMG_FORMAT="([A-Z0-9]+)"$', script, re.MULTILINE)
    assert match, "build-installer.sh names no DMG_FORMAT"
    return match.group(1)


def item_boxes():
    """Every item's icon and name as (left, top, right, bottom) in window points.

    Finder centres the icon on the saved position and writes the name under
    it. The name's width is over-estimated at 0.62 em a character, and its
    line at twice the text size, so a pass here leaves real room."""
    size = LAYOUT["iconSize"]
    text = LAYOUT["textSize"]
    boxes = {}
    for name, (x, y) in LAYOUT["items"].items():
        label = name[:-len(".app")] if name.endswith(".app") else name
        half = len(label) * text * 0.62 / 2
        boxes[name] = [
            (x - size / 2, y - size / 2, x + size / 2, y + size / 2),
            (x - half, y + size / 2, x + half, y + size / 2 + text * 2),
        ]
    return boxes


def overlaps(first, second):
    return first[0] < second[2] and second[0] < first[2] and first[1] < second[3] and second[1] < first[3]


def inside_visible_window(box):
    return box[0] >= EDGE and box[1] >= EDGE and box[2] <= WINDOW_WIDTH - EDGE and box[3] <= VISIBLE_HEIGHT - EDGE


def render_background(path):
    subprocess.run(["/usr/bin/python3", str(INSTALLER / "generate-background.py"), str(path)],
                   check=True, env=ENV, stdout=subprocess.DEVNULL)


def words_with_boxes(image):
    result = subprocess.run(
        ["/usr/bin/xcrun", "swift", str(INSTALLER / "read-background-text.swift"), "--boxes", str(image)],
        check=True, capture_output=True, text=True, env=ENV,
    )
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


class InstallerVolumeNameTests(unittest.TestCase):
    def test_volume_is_named_hippocampus_whatever_the_source_revision(self):
        # A downloader sees the volume name in Finder; the commit belongs in
        # build-provenance.json, not there.
        script = (ROOT / "scripts/build-installer.sh").read_text()
        start = script.index("hdiutil create \\\n")
        create = script[start:script.index("# --- Step 5:", start)]
        for revision in ("abcdef1234567890", "7654321fedcba098"):
            result = subprocess.run(
                ["/bin/bash", "-eu", "-c", 'hdiutil() { printf "%s\\n" "$@"; };\n' + create],
                check=True, capture_output=True, text=True,
                env={**ENV, "VERSION": "0.1.0", "SOURCE_HEAD": revision,
                     "DMG_STAGING": "/synthetic/staging", "DMG_RW_SIZE_MB": "32",
                     "TEMP_DMG": "/synthetic/image.dmg"},
            )
            arguments = result.stdout.splitlines()
            self.assertEqual(arguments[arguments.index("-volname") + 1], "Hippocampus")
            self.assertNotIn(revision[:7], result.stdout)
        self.assertIn('DMG_NAME="Hippocampus-${VERSION}"', script)
        self.assertIn('FINAL_DMG="$DIST_DIR/${DMG_NAME}.dmg"', script)
        self.assertIn('STABLE_DMG="$DIST_DIR/Hippocampus.dmg"', script)


class StableDiskImageTests(unittest.TestCase):
    """Step 9 makes Hippocampus.dmg from the finished, versioned DMG."""

    def run_step(self, dist, *, cp_body=None):
        script = (ROOT / "scripts/build-installer.sh").read_text()
        start = script.index("# --- Step 9:")
        body = script[start:script.index("# --- Done ---", start)]
        prelude = ""
        if cp_body is not None:
            prelude = "cp() { " + cp_body + "; };\n"
        return subprocess.run(
            ["/bin/bash", "-euo", "pipefail", "-c", prelude + body],
            capture_output=True, text=True,
            env={**ENV, "FINAL_DMG": str(dist / "Hippocampus-0.1.0.dmg"),
                 "STABLE_DMG": str(dist / "Hippocampus.dmg"),
                 "STABLE_DMG_PARTIAL": str(dist / ".Hippocampus.dmg.partial"),
                 "FINAL_DMG_PENDING": str(dist / "Hippocampus-0.1.0.dmg")},
        )

    def test_stable_copy_has_the_same_bytes_and_its_own_checksum_file(self):
        with tempfile.TemporaryDirectory(prefix="stable-dmg-") as temporary:
            dist = Path(temporary)
            (dist / "Hippocampus-0.1.0.dmg").write_bytes(b"synthetic disk image bytes")
            result = self.run_step(dist)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((dist / "Hippocampus.dmg").read_bytes(), b"synthetic disk image bytes")
            self.assertFalse((dist / ".Hippocampus.dmg.partial").exists())
            for name in ("Hippocampus-0.1.0.dmg", "Hippocampus.dmg"):
                sidecar = (dist / f"{name}.sha256").read_text().split()
                self.assertEqual(sidecar[1], name)
                check = subprocess.run(["/usr/bin/shasum", "-a", "256", "-c", f"{name}.sha256"],
                                       cwd=dist, capture_output=True, text=True, env=ENV)
                self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_a_copy_that_differs_never_appears_under_the_stable_name(self):
        with tempfile.TemporaryDirectory(prefix="stable-dmg-") as temporary:
            dist = Path(temporary)
            (dist / "Hippocampus-0.1.0.dmg").write_bytes(b"synthetic disk image bytes")
            result = self.run_step(dist, cp_body='printf "torn" > "${@: -1}"')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match", result.stderr)
            self.assertFalse((dist / "Hippocampus.dmg").exists())
            self.assertFalse((dist / "Hippocampus.dmg.sha256").exists())
            self.assertFalse((dist / ".Hippocampus.dmg.partial").exists())


class WindowDesignTests(unittest.TestCase):
    """The window a downloader sees, checked from layout.json and the rendered picture."""

    def test_window_and_icons_are_the_designed_size(self):
        self.assertEqual(LAYOUT["window"], {"x": 420, "y": 270, "width": 640, "height": 432})
        self.assertEqual(LAYOUT["titleBarHeight"], 32)
        self.assertEqual(LAYOUT["iconSize"], 112)
        self.assertEqual(LAYOUT["textSize"], 13)
        self.assertEqual(LAYOUT["items"], {
            "Hippocampus.app": [180, 176], "Applications": [460, 176], "Legal": [568, 300],
        })

    def test_app_and_applications_face_each_other_across_the_middle(self):
        (app_x, app_y), (target_x, target_y) = LAYOUT["items"]["Hippocampus.app"], LAYOUT["items"]["Applications"]
        self.assertEqual(app_y, target_y)
        self.assertLess(app_x, target_x)
        self.assertEqual(app_x + target_x, WINDOW_WIDTH)

    def test_every_icon_and_name_fits_the_window_below_the_title_bar(self):
        for name, boxes in item_boxes().items():
            for box in boxes:
                self.assertTrue(inside_visible_window(box), f"{name} reaches outside the window: {box}")

    def test_no_item_covers_another_or_its_name(self):
        boxes = item_boxes()
        names = sorted(boxes)
        for index, first in enumerate(names):
            for second in names[index + 1:]:
                for one in boxes[first]:
                    for other in boxes[second]:
                        self.assertFalse(overlaps(one, other), f"{first} {one} overlaps {second} {other}")

    def test_background_words_sit_clear_of_every_icon_and_name(self):
        with tempfile.TemporaryDirectory(prefix="hippocampus-background-") as temporary:
            image = Path(temporary) / "background.png"
            render_background(image)
            words = words_with_boxes(image)
        self.assertEqual([word["text"] for word in words],
                         ["Drag to Applications", "Updating? Quit Hippocampus from the menu bar first."])
        for word in words:
            box = (word["x"], word["y"], word["x"] + word["width"], word["y"] + word["height"])
            self.assertTrue(inside_visible_window(box), f"{word['text']!r} reaches outside the window: {box}")
            for name, item in item_boxes().items():
                for other in item:
                    self.assertFalse(overlaps(box, other), f"{word['text']!r} {box} overlaps {name} {other}")
        cue = words[0]
        (app_x, row), (target_x, _) = LAYOUT["items"]["Hippocampus.app"], LAYOUT["items"]["Applications"]
        size = LAYOUT["iconSize"]
        # Between the two icons, just above their centre line, where the arrow is.
        self.assertGreater(cue["x"], app_x + size / 2)
        self.assertLess(cue["x"] + cue["width"], target_x - size / 2)
        self.assertLess(cue["y"] + cue["height"], row)
        self.assertGreater(cue["y"], row - size / 2)

    def test_update_hint_is_quiet_and_sits_at_the_foot_of_the_window(self):
        renderer = (INSTALLER / "render-background.swift").read_text()
        self.assertIn('let updateNote = "Updating? Quit Hippocampus from the menu bar first."', renderer)
        self.assertIn("text(updateNote, size: 11, color: graphite, centerX: width / 2, "
                      "baselineFromTop: visibleHeight - 28)", renderer)
        self.assertIn("let graphite = srgb(0x6E6E73)", renderer)


class InstallerLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Legacy Finder aliases use HFS+ CNIDs. Host APFS fixture paths can
        # exceed that format's integer range; exercise the actual DMG filesystem.
        cls.image_temp = tempfile.TemporaryDirectory(prefix="hippocampus-layout-image-")
        cls.addClassCleanup(cls.image_temp.cleanup)
        cls.image_root = Path(cls.image_temp.name)
        cls.image = cls.image_root / "fixture.dmg"
        cls.mount = cls.image_root / "mount"
        cls.mount.mkdir()
        disk("create", "-size", "32m", "-fs", "HFS+", "-volname", "InstallerFixture", cls.image)
        disk("attach", "-nobrowse", "-noautoopen", "-mountpoint", cls.mount, cls.image)
        cls.addClassCleanup(disk, "detach", cls.mount)

    def setUp(self):
        spec = importlib.util.spec_from_file_location("installer_layout", WRITER)
        self.layout = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.layout)
        self.temp = tempfile.TemporaryDirectory(prefix="fixture-", dir=self.mount)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Hippocampus.app").mkdir()
        (self.root / "Applications").symlink_to("/Applications")
        (self.root / "Legal").mkdir()
        (self.root / "Legal/License.rtf").write_bytes(b"synthetic legal fixture")
        (self.root / ".background").mkdir()
        (self.root / ".background/background.png").write_bytes(b"synthetic image fixture")

    @contextlib.contextmanager
    def compressed_and_remounted(self, label):
        """The fixture image as a downloader gets it: compressed, read-only, mounted elsewhere."""
        compressed = self.image_root / f"{label}.dmg"
        remount = self.image_root / f"{label}-remount"
        remount.mkdir()
        disk("detach", self.mount)
        try:
            disk("convert", self.image, "-format", shipped_dmg_format(), "-o", compressed)
            disk("attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", remount, compressed)
            try:
                yield remount / self.root.name
            finally:
                disk("detach", remount)
        finally:
            disk("attach", "-nobrowse", "-noautoopen", "-mountpoint", self.mount, self.image)

    def test_compact_persisted_layout_and_relative_background(self):
        self.layout.write_layout(self.root)
        with DSStore.open(str(self.root / ".DS_Store"), "r") as store:
            window = store["."]["bwsp"]
            self.assertEqual(window["WindowBounds"], "{{420, 270}, {640, 432}}")
            for key in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
                self.assertFalse(window[key])
            icons = store["."]["icvp"]
            self.assertEqual(icons["iconSize"], 112.0)
            self.assertEqual(icons["textSize"], 13.0)
            self.assertEqual(icons["arrangeBy"], "none")
            self.assertEqual(icons["backgroundType"], 2)
            self.assertEqual(store["."]["icvl"], (b"type", b"icnv"))
            self.assertEqual(store["Hippocampus.app"]["Iloc"], (180, 176))
            self.assertEqual(store["Applications"]["Iloc"], (460, 176))
            self.assertEqual(store["Legal"]["Iloc"], (568, 300))
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            self.assertEqual(alias.target.filename, "background.png")
            self.assertTrue(alias.target.posix_path.endswith("/.background/background.png"))
        self.assertEqual((self.root / "Legal/License.rtf").read_bytes(), b"synthetic legal fixture")

    def test_finder_metadata_comes_from_the_layout_file(self):
        self.layout.write_layout(self.root)
        window = LAYOUT["window"]
        with DSStore.open(str(self.root / ".DS_Store"), "r") as store:
            self.assertEqual(store["."]["bwsp"]["WindowBounds"], "{{%d, %d}, {%d, %d}}" % (
                window["x"], window["y"], window["width"], window["height"]))
            self.assertEqual(store["."]["icvp"]["iconSize"], float(LAYOUT["iconSize"]))
            self.assertEqual(store["."]["icvp"]["textSize"], float(LAYOUT["textSize"]))
            for name, position in LAYOUT["items"].items():
                self.assertEqual(store[name]["Iloc"], tuple(position))

    def test_image_view_includes_complete_neutral_rgb_fields(self):
        self.layout.write_layout(self.root)
        with DSStore.open(str(self.root / ".DS_Store"), "r") as store:
            icons = store["."]["icvp"]
            self.assertEqual(icons["backgroundType"], 2)
            for channel in ("Red", "Green", "Blue"):
                self.assertEqual(icons.get("backgroundColor" + channel), 1.0)

    def test_repeated_generation_has_identical_layout_bytes(self):
        self.layout.write_layout(self.root)
        first = (self.root / ".DS_Store").read_bytes()
        self.layout.write_layout(self.root)
        self.assertEqual((self.root / ".DS_Store").read_bytes(), first)

    def test_layout_and_background_identity_survive_compression_and_remount(self):
        self.layout.write_layout(self.root)
        with DSStore.open(str(self.root / ".DS_Store"), "r") as store:
            original = Alias.from_bytes(store["."]["icvp"]["backgroundImageAlias"])
        with self.compressed_and_remounted("layout") as root:
            current = Alias.from_bytes(Alias.for_file(str((root / ".background/background.png").resolve())).to_bytes())
            self.assertEqual(original.target.cnid, current.target.cnid)
            self.assertEqual(original.target.posix_path, current.target.posix_path)
            self.assertEqual(original.volume.creation_date, current.volume.creation_date)
            self.assertEqual(original.volume.name, current.volume.name)
            self.assertNotEqual(original.volume.posix_path, current.volume.posix_path)
            with DSStore.open(str(root / ".DS_Store"), "r") as store:
                self.assertEqual(store["Applications"]["Iloc"], (460, 176))
                self.assertEqual(store["."]["bwsp"]["WindowBounds"], "{{420, 270}, {640, 432}}")

    def test_missing_required_asset_fails_before_writing_layout(self):
        (self.root / ".background/background.png").unlink()
        with self.assertRaises(ValueError):
            self.layout.write_layout(self.root)
        self.assertFalse((self.root / ".DS_Store").exists())

    def test_installer_requires_layout_and_preserves_visible_legal(self):
        script = (ROOT / "scripts/build-installer.sh").read_text()
        self.assertNotIn("osascript", script)
        self.assertNotIn("/Volumes/Hippocampus", script)
        self.assertIn('hippocampus_installer_mount "$TEMP_DMG"', script)
        self.assertIn('"$INSTALLER_PYTHON" "$DMG_LAYOUT" "$MOUNT_DIR"', script)
        self.assertIn('cp "$EULA_RTF" "$DMG_STAGING/Legal/License.rtf"', script)
        self.assertNotIn('"$DMG_STAGING/License.rtf"', script)
        self.assertIn('BACKGROUND_PNG="$DMG_STAGING/.background/background.png"', script)

    def test_ci_provisions_hashed_build_only_dependencies(self):
        for name in ("swift.yml", "release.yml"):
            workflow = (ROOT / ".github/workflows" / name).read_text()
            self.assertIn("--require-hashes --only-binary=:all:", workflow)
            self.assertIn("-r scripts/installer-requirements.txt", workflow)
            self.assertIn("INSTALLER_PYTHON=", workflow)

    def test_verify_assets_does_not_require_layout_dependencies(self):
        script = (ROOT / "scripts/build-installer.sh").read_text()
        self.assertLess(script.index('if [[ "$VERIFY_ASSETS_ONLY"'), script.index('"$DMG_LAYOUT" --check-dependencies'))

    def test_volume_icon_tool_is_preflighted_before_signing(self):
        script = (ROOT / "scripts/build-installer.sh").read_text()
        self.assertIn("require_cmd SetFile", script)
        self.assertLess(script.index("require_cmd SetFile"), script.index("# --- Detect Developer ID"))

    def test_backing_image_path_is_unique_to_each_build(self):
        script = (ROOT / "scripts/build-installer.sh").read_text()
        self.assertIn('TEMP_DMG_ROOT="$(mktemp -d "$DIST_DIR/.hippocampus-rw.XXXXXX")"', script)
        self.assertIn('TEMP_DMG="$TEMP_DMG_ROOT/image.dmg"', script)

    def test_background_takes_no_build_note(self):
        result = subprocess.run(
            ["/usr/bin/python3", str(INSTALLER / "generate-background.py"),
             str(self.root / "noted.png"), "--build-note", "Build abcdef123456"],
            capture_output=True, text=True, env=ENV,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "noted.png").exists())
        script = (ROOT / "scripts/build-installer.sh").read_text()
        self.assertNotIn("--build-note", script)

    def test_background_fills_the_window_at_retina_scale(self):
        background = self.root / "rendered.png"
        render_background(background)
        result = subprocess.run(
            ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "dpiWidth", "-g", "dpiHeight", str(background)],
            check=True, capture_output=True, text=True, env=ENV,
        ).stdout
        # Twice the window's points at 144 dpi: crisp on Retina, the same size elsewhere.
        window = LAYOUT["window"]
        for expected in (f"pixelWidth: {window['width'] * 2}", f"pixelHeight: {window['height'] * 2}",
                         "pixelWidth: 1280", "pixelHeight: 864", "dpiWidth: 144.000", "dpiHeight: 144.000"):
            self.assertIn(expected, result)


if __name__ == "__main__":
    unittest.main()
