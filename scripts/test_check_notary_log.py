#!/usr/bin/env python3
"""check-notary-log.py passes only a log Apple accepted with no issues.

The fixtures follow the shape of real `notarytool log` output
(logFormatVersion 1), with synthetic values.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts/check-notary-log.py"


def accepted_log(**changes):
    log = {
        "logFormatVersion": 1,
        "jobId": "00000000-0000-0000-0000-000000000000",
        "status": "Accepted",
        "statusSummary": "Ready for distribution",
        "statusCode": 0,
        "archiveFilename": "Hippocampus-1.2.3.dmg",
        "uploadDate": "2026-10-15T12:00:00.000Z",
        "sha256": "ab" * 32,
        "ticketContents": [
            {
                "path": "Hippocampus-1.2.3.dmg/Hippocampus.app/Contents/MacOS/Hippocampus",
                "digestAlgorithm": "SHA-256",
                "cdhash": "cd" * 20,
                "arch": "arm64",
            }
        ],
        "issues": None,
    }
    log.update(changes)
    return log


WARNING = {
    "severity": "warning",
    "code": None,
    "path": "Hippocampus-1.2.3.dmg/Hippocampus.app/Contents/MacOS/mci-agent",
    "message": "The binary uses an SDK older than the 10.9 SDK.",
    "docUrl": None,
    "architecture": "arm64",
}


class NotaryLogTests(unittest.TestCase):
    def run_checker(self, content, *arguments):
        with tempfile.TemporaryDirectory(prefix="notary-log-") as temporary:
            log = Path(temporary) / "notary-dmg-log.json"
            log.write_text(content if isinstance(content, str) else json.dumps(content), encoding="utf-8")
            return subprocess.run(
                [sys.executable, "-B", str(CHECKER), *arguments, str(log)],
                capture_output=True, text=True, timeout=20,
                env={"PATH": "/usr/bin:/bin", "HOME": temporary},
            )

    def test_accepted_with_no_issues_is_clean(self):
        for issues in (None, []):
            with self.subTest(issues=issues):
                result = self.run_checker(accepted_log(issues=issues), "--archive", "Hippocampus-1.2.3.dmg")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("accepted with no issues", result.stdout)

    def test_a_warning_is_not_clean_and_is_named(self):
        result = self.run_checker(accepted_log(issues=[WARNING]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("warning: Hippocampus-1.2.3.dmg/Hippocampus.app/Contents/MacOS/mci-agent", result.stderr)
        self.assertIn("older than the 10.9 SDK", result.stderr)

    def test_every_issue_is_listed(self):
        error = dict(WARNING, severity="error", message="The signature of the binary is invalid.")
        result = self.run_checker(accepted_log(issues=[WARNING, error]))
        self.assertEqual(result.returncode, 1)
        self.assertIn("warning:", result.stderr)
        self.assertIn("error:", result.stderr)

    def test_a_submission_apple_did_not_accept_fails(self):
        for status, code in (("Invalid", 4000), ("Rejected", 0), ("In Progress", None)):
            with self.subTest(status=status):
                result = self.run_checker(accepted_log(status=status, statusCode=code))
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"status is {status!r}", result.stderr)

    def test_a_nonzero_status_code_fails(self):
        result = self.run_checker(accepted_log(statusCode=1))
        self.assertEqual(result.returncode, 1)
        self.assertIn("statusCode is 1", result.stderr)

    def test_a_log_for_another_file_fails(self):
        result = self.run_checker(accepted_log(), "--archive", "Hippocampus-9.9.9.dmg")
        self.assertEqual(result.returncode, 1)
        self.assertIn("not 'Hippocampus-9.9.9.dmg'", result.stderr)

    def test_an_empty_ticket_fails(self):
        for tickets in ([], None):
            with self.subTest(tickets=tickets):
                result = self.run_checker(accepted_log(ticketContents=tickets))
                self.assertEqual(result.returncode, 1)
                self.assertIn("covers no signed code", result.stderr)

    def test_unreadable_or_malformed_logs_fail(self):
        for content in ("", "{not json", "[]", json.dumps(accepted_log(issues="none"))):
            with self.subTest(content=content[:20]):
                result = self.run_checker(content)
                self.assertEqual(result.returncode, 1, result.stdout)

    def test_a_missing_log_fails(self):
        result = subprocess.run(
            [sys.executable, "-B", str(CHECKER), "/nonexistent/notary-log.json"],
            capture_output=True, text=True, timeout=20, env={"PATH": "/usr/bin:/bin"},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read the notary log", result.stderr)


if __name__ == "__main__":
    unittest.main()
