#!/usr/bin/env python3
"""Synthetic macOS-only tests; never invoke against an installed application.

Run with env -i HOME=/tmp PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp
python3 scripts/lib/test_atomic_bundle_swap.py. An optional --second-device-root
must name an explicitly supplied writable scratch directory on another device.
"""

import argparse
import errno
import json
import mmap
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest


OLD_HEAD = "0123456789abcdef0123456789abcdef01234567"
NEW_HEAD = "abcdef0123456789abcdef0123456789abcdef01"
MANIFEST = "Contents/Resources/build-provenance.json"
SECOND_DEVICE_ROOT = None


def environment(home):
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": str(home),
    }


def make_bundle(path, head, payload):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Resources").mkdir()
    info = {
        "CFBundleIdentifier": "ai.hippocampus",
        "CFBundleExecutable": "Hippocampus",
        "CFBundlePackageType": "APPL",
    }
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    executable = path / "Contents/MacOS/Hippocampus"
    executable.write_bytes(payload)
    executable.chmod(0o700)
    manifest = {
        "schema_version": 1,
        "source_head": head,
        "source_digest": "a" * 64,
        "current_source_qualification": False,
        "binary_digest_kind": "codesign-stripped-sha256-v1",
        "binaries": {"Hippocampus": "b" * 64},
        "payload_digest": "c" * 64,
    }
    (path / MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")
    return path


def snapshot(root):
    """Capture identities and bytes so rejection cannot hide a partial move."""
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        content = None
        if stat.S_ISLNK(info.st_mode):
            content = os.readlink(path)
        elif stat.S_ISREG(info.st_mode):
            content = path.read_bytes()
        result[str(path.relative_to(root))] = (
            info.st_dev, info.st_ino, info.st_mode, content
        )
    return result


class AtomicBundleSwapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise RuntimeError("These tests require macOS renamex_np; no substitute is tested")
        cls.build_temp = tempfile.TemporaryDirectory(prefix="hippocampus-swap-build-")
        cls.addClassCleanup(cls.build_temp.cleanup)
        cls.build = Path(cls.build_temp.name).resolve()
        cls.binary = cls.build / "atomic-bundle-swap"
        source = Path(__file__).with_name("atomic-bundle-swap.swift").resolve()
        result = subprocess.run(
            ["/usr/bin/xcrun", "swiftc", "-warnings-as-errors", "-module-cache-path",
             str(cls.build / "modules"), str(source), "-o", str(cls.binary)],
            env=environment(cls.build), capture_output=True, text=True, timeout=180,
        )
        if result.returncode:
            raise RuntimeError("Helper compilation failed:\n" + result.stderr)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hippocampus-swap-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.old = make_bundle(self.root / "Hippocampus.app", OLD_HEAD, b"old executable data")
        self.new = make_bundle(self.root / "Staged Hippocampus.app", NEW_HEAD, b"new executable data")

    def invoke(self, *, old=None, new=None, old_head=OLD_HEAD, new_head=NEW_HEAD, extra=()):
        return subprocess.run(
            [str(self.binary), "--old", str(self.old if old is None else old),
             "--new", str(self.new if new is None else new),
             "--expected-old-head", old_head, "--expected-new-head", new_head, *extra],
            env=environment(self.build), capture_output=True, text=True, timeout=10,
        )

    def refused(self, code, **kwargs):
        before = snapshot(self.root)
        result = self.invoke(**kwargs)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, f"bundle swap refused: {code}\n")
        self.assertEqual(snapshot(self.root), before)

    def edit_info(self, bundle, **changes):
        path = bundle / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(changes)
        path.write_bytes(plistlib.dumps(info))

    def test_swap_preserves_open_descriptor_and_mapping_and_exchanges_both_directories(self):
        before_old = snapshot(self.old)
        before_new = snapshot(self.new)
        with (self.old / "Contents/MacOS/Hippocampus").open("rb") as held:
            with mmap.mmap(held.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                result = self.invoke()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "bundle swap complete\n")
                self.assertEqual(result.stderr, "")
                self.assertEqual(held.read(), b"old executable data")
                self.assertEqual(mapped[:], b"old executable data")
                self.assertEqual(os.fstat(held.fileno()).st_ino,
                                 (self.new / "Contents/MacOS/Hippocampus").stat().st_ino)
        self.assertEqual(snapshot(self.old), before_new)
        self.assertEqual(snapshot(self.new), before_old)
        self.assertEqual(set(self.root.iterdir()), {self.old, self.new})

    def test_repeated_command_cannot_swap_back(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.refused("source_head_mismatch")

    def test_same_head_different_builds_refuse_initial_swap_and_replay(self):
        path = self.new / MANIFEST
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["source_head"] = OLD_HEAD
        manifest["source_digest"] = "d" * 64
        path.write_text(json.dumps(manifest), encoding="utf-8")
        before = snapshot(self.root)
        attempts = []
        for _ in range(2):
            result = self.invoke(new_head=OLD_HEAD)
            attempts.append((result, snapshot(self.root)))
        for attempt, (result, after) in enumerate(attempts):
            with self.subTest(attempt=attempt):
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "bundle swap refused: distinct_source_heads_required\n")
                self.assertEqual(after, before)
        self.refused("distinct_source_heads_required", new_head=OLD_HEAD,
                     old=self.root / "Missing.app")

    def test_wrong_old_or_new_source_head_refuses(self):
        self.refused("source_head_mismatch", old_head="f" * 40)
        self.refused("source_head_mismatch", new_head="f" * 40)

    def test_expected_heads_require_full_canonical_hex_not_prefix_or_timestamp(self):
        for head in ("", "fe90a3d", "g" * 40, "A" * 40, "a" * 39, "a" * 41,
                     "2026-09-09T12:00:00Z", "a" * 40 + "\n"):
            with self.subTest(head=head):
                self.refused("invalid_expected_head", old_head=head)
                self.refused("invalid_expected_head", new_head=head)

    def test_manifest_rejects_invalid_schema_head_and_json_without_echoing_content(self):
        path = self.new / MANIFEST
        for value in ({"schema_version": True, "source_head": NEW_HEAD},
                      {"schema_version": 2, "source_head": NEW_HEAD},
                      {"schema_version": 1, "source_head": 123},
                      {"schema_version": 1, "source_head": "z" * 40},
                      {"schema_version": 1, "source_head": "f" * 39},
                      {}, [], "synthetic content must not appear in diagnostics"):
            with self.subTest(value=value):
                path.write_text(json.dumps(value), encoding="utf-8")
                self.refused("invalid_manifest")
        path.write_text("{invalid synthetic JSON", encoding="utf-8")
        self.refused("invalid_manifest")

    def test_missing_manifest_has_no_alternate_filename_fallback(self):
        (self.new / MANIFEST).rename(self.new / "Contents/Resources/HIPPOCAMPUS_BUILD_MANIFEST.json")
        self.refused("missing_path")

    def test_wrong_bundle_id_on_either_side_refuses(self):
        self.edit_info(self.old, CFBundleIdentifier="ai.some-other-app")
        self.refused("invalid_bundle")
        self.edit_info(self.old, CFBundleIdentifier="ai.hippocampus")
        self.edit_info(self.new, CFBundleIdentifier="ai.some-other-app")
        self.refused("invalid_bundle")

    def test_missing_malformed_or_non_app_plist_refuses(self):
        self.edit_info(self.new, CFBundlePackageType="BNDL")
        self.refused("invalid_bundle")
        path = self.new / "Contents/Info.plist"
        path.write_bytes(b"not a plist; synthetic content")
        self.refused("invalid_bundle")
        path.unlink()
        self.refused("missing_path")

    def test_executable_name_cannot_escape_bundle_or_select_another_program(self):
        for name in ("../outside", "/bin/sh", "", "Other", "Hippocampus/child"):
            with self.subTest(name=name):
                self.edit_info(self.new, CFBundleExecutable=name)
                self.refused("invalid_bundle")

    def test_missing_non_executable_or_directory_main_refuses(self):
        main = self.new / "Contents/MacOS/Hippocampus"
        main.chmod(0o600)
        self.refused("invalid_executable")
        main.unlink()
        self.refused("missing_path")
        main.mkdir()
        self.refused("wrong_file_type")

    def test_relative_dot_traversal_trailing_slash_and_wrong_extension_refuse(self):
        for path in ("Hippocampus.app", str(self.old) + "/", str(self.root) + "/./Hippocampus.app",
                     str(self.root) + "//Hippocampus.app", str(self.root) + "/../Hippocampus.app",
                     str(self.root)):
            with self.subTest(path=path):
                self.refused("invalid_path", old=path)

    def test_missing_path_regular_file_and_same_directory_refuse(self):
        self.refused("missing_path", new=self.root / "Missing.app")
        file = self.root / "File.app"
        file.write_bytes(b"not a directory")
        self.refused("wrong_file_type", new=file)
        self.refused("overlapping_paths", new=self.old)

    def test_nested_bundles_refuse(self):
        nested = make_bundle(self.old / "Nested.app", NEW_HEAD, b"nested")
        self.refused("overlapping_paths", new=nested)
        self.refused("overlapping_paths", old=nested, new=self.old)

    def test_bundle_and_ancestor_symlinks_refuse(self):
        link = self.root / "Alias.app"
        link.symlink_to(self.new, target_is_directory=True)
        self.refused("symlink_path", new=link)
        parent_link = self.root / "linked-parent"
        parent_link.symlink_to(self.root, target_is_directory=True)
        self.refused("symlink_path", new=parent_link / self.new.name)

    def test_metadata_executable_and_contents_symlinks_refuse(self):
        for relative in (MANIFEST, "Contents/Info.plist", "Contents/MacOS/Hippocampus", "Contents"):
            with self.subTest(relative=relative):
                original = self.new / relative
                moved = self.root / "temporarily-held"
                original.rename(moved)
                original.symlink_to(moved, target_is_directory=moved.is_dir())
                try:
                    self.refused("symlink_path")
                finally:
                    original.unlink()
                    moved.rename(original)

    def test_oversized_metadata_and_fifo_refuse_without_blocking(self):
        path = self.new / MANIFEST
        path.write_bytes(b" " * (1024 * 1024 + 1))
        self.refused("metadata_too_large")
        path.unlink()
        os.mkfifo(path)
        self.refused("wrong_file_type")

    def test_unknown_duplicate_and_missing_arguments_refuse(self):
        self.refused("invalid_arguments", extra=("--launch",))
        self.refused("invalid_arguments", extra=("--old", str(self.old)))
        before = snapshot(self.root)
        result = subprocess.run([str(self.binary)], env=environment(self.build),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "bundle swap refused: invalid_arguments\n")
        self.assertEqual(snapshot(self.root), before)

    def test_kernel_denied_swap_leaves_both_bundles_untouched(self):
        self.assertNotEqual(os.geteuid(), 0, "Run synthetic swap tests without root privileges")
        self.root.chmod(0o500)
        try:
            self.refused(f"rename_failed_errno_{errno.EACCES}")
        finally:
            self.root.chmod(0o700)

    def test_different_device_refuses_without_fallback(self):
        if SECOND_DEVICE_ROOT is None:
            self.skipTest("No --second-device-root supplied; no filesystem was mounted for testing")
        second = Path(SECOND_DEVICE_ROOT).resolve(strict=True)
        self.assertNotEqual(second.stat().st_dev, self.root.stat().st_dev,
                            "The supplied scratch root must be on a different device")
        with tempfile.TemporaryDirectory(prefix="hippocampus-swap-fixture-", dir=second) as raw:
            other_root = Path(raw).resolve()
            other = make_bundle(other_root / "Staged.app", NEW_HEAD, b"other device")
            before = snapshot(other_root)
            self.refused("different_devices", new=other)
            self.assertEqual(snapshot(other_root), before)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--second-device-root")
    options, remaining = parser.parse_known_args()
    SECOND_DEVICE_ROOT = options.second_device_root
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
