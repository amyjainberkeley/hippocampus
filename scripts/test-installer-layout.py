#!/usr/bin/env python3
"""Headless fixtures only: no Finder, app launch, or mounted user images."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from ds_store import DSStore
from mac_alias import Alias

ROOT = Path(__file__).resolve().parent.parent
WRITER = ROOT / "assets/installer/dmg-layout.py"
ENV = {key: value for key, value in os.environ.items() if key in (
    "HOME", "TMPDIR", "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "DEVELOPER_DIR",
)}
ENV["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"


def disk(*args):
    subprocess.run(["/usr/bin/hdiutil", *map(str, args)], check=True, stdout=subprocess.DEVNULL, env=ENV)


class InstallerVolumeNameTests(unittest.TestCase):
    def test_volume_label_distinguishes_source_revisions_without_renaming_public_dmg(self):
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
            self.assertEqual(arguments[arguments.index("-volname") + 1], f"Hippocampus {revision[:12]}")
        self.assertIn('DMG_NAME="Hippocampus-${VERSION}"', script)
        self.assertIn('FINAL_DMG="$DIST_DIR/${DMG_NAME}.dmg"', script)


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

    def test_compact_persisted_layout_and_relative_background(self):
        self.layout.write_layout(self.root)
        with DSStore.open(str(self.root / ".DS_Store"), "r") as store:
            window = store["."]["bwsp"]
            self.assertEqual(window["WindowBounds"], "{{200, 200}, {640, 420}}")
            for key in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
                self.assertFalse(window[key])
            icons = store["."]["icvp"]
            self.assertEqual(icons["iconSize"], 80.0)
            self.assertEqual(icons["arrangeBy"], "none")
            self.assertEqual(icons["backgroundType"], 2)
            self.assertEqual(store["."]["icvl"], (b"type", b"icnv"))
            self.assertEqual(store["Hippocampus.app"]["Iloc"], (170, 185))
            self.assertEqual(store["Applications"]["Iloc"], (470, 185))
            self.assertEqual(store["Legal"]["Iloc"], (550, 325))
            alias = Alias.from_bytes(icons["backgroundImageAlias"])
            self.assertEqual(alias.target.filename, "background.png")
            self.assertTrue(alias.target.posix_path.endswith("/.background/background.png"))
        self.assertEqual((self.root / "Legal/License.rtf").read_bytes(), b"synthetic legal fixture")

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
        compressed = self.image_root / "compressed.dmg"
        remount = self.image_root / "remount"
        remount.mkdir()
        disk("detach", self.mount)
        try:
            disk("convert", self.image, "-format", "UDZO", "-o", compressed)
            disk("attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", remount, compressed)
            try:
                root = remount / self.root.name
                current = Alias.from_bytes(Alias.for_file(str((root / ".background/background.png").resolve())).to_bytes())
                self.assertEqual(original.target.cnid, current.target.cnid)
                self.assertEqual(original.target.posix_path, current.target.posix_path)
                self.assertEqual(original.volume.creation_date, current.volume.creation_date)
                self.assertEqual(original.volume.name, current.volume.name)
                self.assertNotEqual(original.volume.posix_path, current.volume.posix_path)
                with DSStore.open(str(root / ".DS_Store"), "r") as store:
                    self.assertEqual(store["Applications"]["Iloc"], (470, 185))
                    self.assertEqual(store["."]["bwsp"]["WindowBounds"], "{{200, 200}, {640, 420}}")
            finally:
                disk("detach", remount)
        finally:
            disk("attach", "-nobrowse", "-noautoopen", "-mountpoint", self.mount, self.image)

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

    def test_update_hint_is_quiet_and_clear_of_icon_and_footer_rows(self):
        renderer = (ROOT / "assets/installer/render-background.swift").read_text()
        self.assertIn('text("Updating? Quit Hippocampus from the menu bar first.", size: 12, baselineFromTop: 290, gray: 0.4)', renderer)

    def test_background_has_matching_retina_logical_dimensions(self):
        background = self.root / "rendered.png"
        subprocess.run(
            ["/usr/bin/python3", str(ROOT / "assets/installer/generate-background.py"),
             str(background), "--build-note", "Build abcdef123456 / source 0123456789ab"],
            check=True, env=ENV,
        )
        result = subprocess.run(
            ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "dpiWidth", "-g", "dpiHeight", str(background)],
            check=True, capture_output=True, text=True, env=ENV,
        ).stdout
        for expected in ("pixelWidth: 1280", "pixelHeight: 840", "dpiWidth: 144.000", "dpiHeight: 144.000"):
            self.assertIn(expected, result)


if __name__ == "__main__":
    unittest.main()
