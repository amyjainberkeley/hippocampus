#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Every Hippocampus process makes its files owner-only from its first line.

The first launch used to leave the data folder, the database and its WAL and
SHM, the logs and the settings at 0755 and 0644 (reports/e2e, finding 5; the
storage review's S13). Each product process now sets umask 077 before
anything else, so whatever code path creates a file or folder, it is 0600 or
0700, and the children it starts (the OCR worker among them) inherit the mask.

This contract reads the executables build-app.sh copies into the app bundle,
and checks that each one's entry point starts with the umask. A new
executable in the bundle fails here until its entry point is listed and does
the same. The behaviour itself is tested where it can be run: the Rust
binaries in apps/agent/tests/private_file_modes.rs, the app's launch repair in
InstallRepairTests, and every mode the end-to-end run leaves in
scripts/audit-storage-security.sh (`modes`).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD_APP = REPO / "apps/hippocampus/Resources/build-app.sh"

SWIFT_UMASK = "umask(0o077)"
RUST_UMASKS = (
    "mci_agent::private_files::restrict_new_files();",
    "let _previous = rustix::process::umask(rustix::fs::Mode::RWXG | rustix::fs::Mode::RWXO);",
)

# Each executable in Contents/MacOS: where its first line is, and what kind
# of entry point that is.
ENTRY_POINTS = {
    "Hippocampus": ("apps/hippocampus/Sources/Hippocampus/HippocampusEntryPoint.swift", "swift-main"),
    "MCICaptureHelper": ("adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift", "swift-top-level"),
    "mci-agent": ("apps/agent/src/bin/mci_agent.rs", "rust"),
    "recall-ui": ("apps/recall-ui/Sources/RecallUI/RecallEntryPoint.swift", "swift-main"),
    "onboarding": ("apps/onboarding/Sources/Onboarding/OnboardingEntryPoint.swift", "swift-main"),
    "hippocampus-native-host": ("apps/hippocampus-native-host/src/main.rs", "rust"),
    "hippocampus-mind": ("apps/mind/Sources/hippocampus-mind/main.swift", "swift-top-level"),
    "mci-seed-brain": ("apps/agent/src/bin/mci_seed_brain.rs", "rust"),
    "demo-screens": ("apps/demo-memory/Sources/demo-screens/main.swift", "swift-top-level"),
}

# Not in Contents/MacOS, but product processes all the same.
OTHER_ENTRY_POINTS = {
    # The Safari extension has no main; its handler's init runs first.
    "HippocampusSafariExtension.appex": ("extensions/safari/appex/SafariWebExtensionHandler.swift", "swift-init"),
    # The development CLI that writes decrypted exports and backups.
    "mci-brain": ("apps/agent/src/bin/mci_brain.rs", "rust"),
}


def statements(lines: list[str]) -> list[str]:
    """Code lines, without blanks, comments and attributes."""
    code = []
    for line in lines:
        text = line.strip()
        if not text or text.startswith("//") or text.startswith("@"):
            continue
        code.append(text)
    return code


def body_after(source: str, declaration: str) -> list[str]:
    start = source.index(declaration)
    return source[start + len(declaration):].splitlines()


def first_statement(path: Path, kind: str) -> str:
    source = path.read_text(encoding="utf-8")
    if kind == "rust":
        lines = body_after(source, "\nfn main() ")
        # The rest of the signature line: `-> ExitCode {` or `{`.
        return statements(lines[1:])[0]
    if kind == "swift-main":
        return statements(body_after(source, "static func main() {"))[0]
    if kind == "swift-init":
        return statements(body_after(source, "override init() {"))[0]
    if kind == "swift-top-level":
        code = [line for line in statements(source.splitlines()) if not line.startswith("import ")]
        return code[0]
    raise ValueError(kind)


def bundled_executables() -> list[str]:
    text = BUILD_APP.read_text(encoding="utf-8")
    return re.findall(r'^\s*cp "\$[A-Z_]+" "\$MACOS/([^"]+)"', text, flags=re.MULTILINE)


class OwnerOnlyProcessesTest(unittest.TestCase):
    def test_every_bundled_executable_is_listed(self) -> None:
        bundled = bundled_executables()
        self.assertGreaterEqual(len(bundled), 9, bundled)
        unknown = sorted(set(bundled) - set(ENTRY_POINTS))
        self.assertEqual(
            unknown, [],
            "a new executable in Contents/MacOS must start with umask 077: list its entry point here",
        )

    def test_each_entry_point_starts_with_the_owner_only_umask(self) -> None:
        for name, (relative, kind) in {**ENTRY_POINTS, **OTHER_ENTRY_POINTS}.items():
            with self.subTest(name):
                first = first_statement(REPO / relative, kind)
                if kind == "rust":
                    self.assertIn(first, RUST_UMASKS, f"{relative}: main starts with {first!r}")
                else:
                    self.assertEqual(first, SWIFT_UMASK, f"{relative}: the first line runs {first!r}")

    def test_the_rust_mask_takes_group_and_other_access_away(self) -> None:
        source = (REPO / "apps/agent/src/private_files.rs").read_text(encoding="utf-8")
        self.assertIn("pub const PRIVATE_UMASK: u32 = 0o077;", source)
        body = source[source.index("pub fn restrict_new_files()"):]
        body = body[:body.index("\n}\n")]
        self.assertIn("umask(Mode::RWXG | Mode::RWXO)", body)


if __name__ == "__main__":
    unittest.main()
