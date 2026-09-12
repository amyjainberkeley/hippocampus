#!/usr/bin/env python3
"""Exercise the audit gate with a local scanner fixture; no network or builds."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent


class AuditGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="supply-chain-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPTS / "check.sh", self.root / "scripts/check.sh")
        auditor = SCRIPTS / "audit-supply-chain.py"
        if auditor.exists():
            shutil.copy2(auditor, self.root / "scripts" / auditor.name)
        (self.bin / "python3").symlink_to(sys.executable)
        for tool in ("bash", "dirname", "git"):
            (self.bin / tool).symlink_to(shutil.which(tool))
        self.env = {**os.environ, "PATH": str(self.bin), "PYTHONDONTWRITEBYTECODE": "1"}
        subprocess.run([shutil.which("git"), "init", "-q", str(self.root)], check=True)
        self.track("Cargo.lock")
        self.nested = "tools/fixture with spaces/Cargo.lock"
        self.track(self.nested)

    def track(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("version = 4\n", encoding="utf-8")
        subprocess.run([shutil.which("git"), "-C", str(self.root), "add", name], check=True)

    def scanner(self, mode="pass"):
        # Replace only the scanner process, which would otherwise access the network.
        path = self.bin / "cargo"
        path.write_text(
            f"#!{sys.executable}\n"
            "import json, pathlib, sys\n"
            f"mode = {mode!r}\n"
            "args = sys.argv[1:]\n"
            "if args == ['audit', '--version']:\n"
            "    print('cargo-audit 0.21.0' if mode == 'old-version' else 'cargo-audit-audit 0.22.2' if mode == 'cargo-version' else 'cargo-audit 0.22.2')\n"
            "    sys.exit(1 if mode == 'unsupported' else 0)\n"
            "assert args[0] == 'audit'\n"
            "assert args[args.index('--deny') + 1] == 'warnings'\n"
            "assert '--no-fetch' not in args and '--stale' not in args\n"
            "assert '--no-yanked' not in args\n"
            "if '--json' in args:\n"
            "    assert 'RUSTSEC-2026-0190' not in args\n"
            "lockfile = args[args.index('--file') + 1] if '--file' in args else 'Cargo.lock'\n"
            "if mode == 'malformed':\n"
            "    print('{}')\n"
            "    sys.exit(0)\n"
            "if mode == 'offline':\n"
            "    print('advisory database unavailable', file=sys.stderr)\n"
            "    sys.exit(2)\n"
            "failed = mode == 'root-fails' and lockfile == 'Cargo.lock'\n"
            "failed |= mode == 'nested-fails' and lockfile != 'Cargo.lock'\n"
            "print(json.dumps({\n"
            "    'database': {'advisory-count': 1239, 'last-commit': 'a' * 40},\n"
            "    'lockfile': {'dependency-count': 1},\n"
            "    'vulnerabilities': {'found': False, 'count': 0, 'list': []},\n"
            "    'warnings': {}\n"
            "}))\n"
            "sys.exit(1 if failed else 0)\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def invoke(self, *selectors):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/check.sh"), *selectors],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )

    def report(self, *args):
        result = subprocess.run(
            [sys.executable, str(self.root / "scripts/audit-supply-chain.py"), *args],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertTrue(result.stdout.strip(), result.stderr)
        return result, json.loads(result.stdout)

    def git(self, *args, input=None):
        return subprocess.check_output(
            [shutil.which("git"), "-C", str(self.root), *args], input=input, text=True
        ).strip()

    def release_snapshot(self, tag="v0.1.0", annotated=False):
        # Synthetic objects in the disposable fixture only; no repository commits.
        self.git("add", "scripts")
        tree = self.git("write-tree")
        identity = "Fixture <fixture@example.invalid> 1 +0000"
        commit = self.git("hash-object", "-t", "commit", "-w", "--stdin", input=(
            f"tree {tree}\nauthor {identity}\ncommitter {identity}\n\nFixture\n"
        ))
        self.git("update-ref", "HEAD", commit)
        target = commit
        if annotated:
            target = self.git("hash-object", "-t", "tag", "-w", "--stdin", input=(
                f"object {commit}\ntype commit\ntag {tag}\ntagger {identity}\n\nFixture tag\n"
            ))
        self.git("update-ref", f"refs/tags/{tag}", target)
        return commit

    def test_empty_audit_selection_cannot_pass(self):
        result = self.invoke("bash", "audit")
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_nested_lockfile_failure_reaches_local_gate(self):
        self.scanner("nested-fails")
        result = self.invoke("rust", "audit")
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_success_reports_every_tracked_lockfile(self):
        self.scanner()
        result, report = self.report()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["status"], "pass")
        self.assertEqual([scan["lockfile"] for scan in report["scans"]], ["Cargo.lock", self.nested])

    def test_scanning_continues_after_first_failure(self):
        self.scanner("root-fails")
        result, report = self.report()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([scan["status"] for scan in report["scans"]], ["fail", "pass"])

    def test_missing_scanner_is_machine_readable_unsupported(self):
        result, report = self.report()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["status"], "unsupported")
        self.assertEqual(report["scans"], [])

    def test_missing_cargo_subcommand_is_unsupported(self):
        self.scanner("unsupported")
        result, report = self.report()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["status"], "unsupported")

    def test_empty_successful_scanner_report_is_error(self):
        self.scanner("malformed")
        result, report = self.report()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["scans"][0]["status"], "error")

    def test_database_failure_is_error_with_diagnostics(self):
        self.scanner("offline")
        result, report = self.report()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["scans"][0]["status"], "error")
        self.assertIn("database unavailable", report["scans"][0]["stderr"])

    def test_deleted_tracked_lockfile_is_error(self):
        self.scanner()
        (self.root / self.nested).unlink()
        result, report = self.report()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["scans"][1]["status"], "error")

    def test_missing_root_lockfile_cannot_pass(self):
        self.scanner()
        (self.root / "Cargo.lock").unlink()
        result, report = self.report()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["scans"][0]["status"], "error")

    def test_release_audits_matching_annotated_tag_and_records_commit(self):
        self.scanner()
        commit = self.release_snapshot(annotated=True)
        result, report = self.report("--release-tag", "v0.1.0", "--require-version", "0.22.2")
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(report.get("source_commit"), commit)
        self.assertEqual(report.get("release_tag"), "v0.1.0")
        self.assertEqual(len(report["scans"]), 2)

    def test_release_rejects_unrelated_checkout_before_scanning(self):
        self.scanner()
        self.release_snapshot()
        (self.root / "Cargo.lock").write_text("version = 3\n", encoding="utf-8")
        self.git("add", "Cargo.lock")
        self.release_snapshot("v0.2.0")
        result, report = self.report("--release-tag", "v0.1.0")
        self.assertNotEqual(result.returncode, 0, report)
        self.assertEqual(report["scans"], [])

    def test_release_rejects_changed_tracked_source(self):
        self.scanner()
        self.release_snapshot()
        (self.root / self.nested).write_text("version = 3\n", encoding="utf-8")
        result, report = self.report("--release-tag", "v0.1.0")
        self.assertNotEqual(result.returncode, 0, report)
        self.assertEqual(report["scans"], [])

    def test_release_rejects_missing_tag(self):
        self.scanner()
        self.release_snapshot()
        result, report = self.report("--release-tag", "v9.9.9")
        self.assertNotEqual(result.returncode, 0, report)
        self.assertEqual(report["scans"], [])

    def test_pinned_scanner_rejects_wrong_cached_version(self):
        self.scanner("old-version")
        result, report = self.report("--require-version", "0.22.2")
        self.assertNotEqual(result.returncode, 0, report)
        self.assertEqual(report["status"], "unsupported")
        self.assertEqual(report["scans"], [])

    def test_cargo_subcommand_version_spelling_still_requires_exact_version(self):
        self.scanner("cargo-version")
        result, report = self.report("--require-version", "0.22.2")
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(report["tool_version"], "cargo-audit-audit 0.22.2")


if __name__ == "__main__":
    unittest.main()
