#!/usr/bin/env python3
"""check.sh's ocr-worker lane: skip without the worker's Python, fail without
its models, and otherwise run the worker's tests in a clean environment.

Each case copies check.sh into an empty temporary root and runs its bash test
lanes there; the other lanes fail at once because their scripts are absent.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class OCRWorkerLaneTests(unittest.TestCase):
    def run_lanes(self, root: Path) -> subprocess.CompletedProcess:
        (root / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts/check.sh", root / "scripts/check.sh")
        return subprocess.run(
            ["/bin/bash", str(root / "scripts/check.sh"), "bash", "test"],
            cwd=root, capture_output=True, text=True, timeout=60,
            env={"HOME": str(root), "PATH": "/usr/bin:/bin", "TMPDIR": str(root),
                 "CHECK_SH_QUIET": "0", "LEAK_CHECK": "must not reach the worker"},
        )

    def lane_status(self, result: subprocess.CompletedProcess) -> str:
        match = re.search(r"^\s+ocr-worker\s+(PASS|FAIL|SKIP)", result.stdout, re.MULTILINE)
        self.assertIsNotNone(match, result.stdout + result.stderr)
        return match.group(1)

    def fake_worker_python(self, root: Path) -> Path:
        python = root / "tools/ocr/.venv/bin/python"
        python.parent.mkdir(parents=True)
        python.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "record = {'args': sys.argv[1:], 'cwd': os.getcwd(), 'env': sorted(os.environ)}\n"
            "open(os.environ['HOME'] + '/worker-call.json', 'w').write(json.dumps(record))\n"
        )
        python.chmod(0o755)
        return python

    def test_skips_without_the_worker_python(self):
        with tempfile.TemporaryDirectory(prefix="check-ocr-skip-") as temporary:
            result = self.run_lanes(Path(temporary))
            self.assertEqual(self.lane_status(result), "SKIP")
            self.assertIn("tools/ocr/.venv is not set up", result.stdout)

    def test_fails_without_the_models(self):
        with tempfile.TemporaryDirectory(prefix="check-ocr-models-") as temporary:
            root = Path(temporary)
            self.fake_worker_python(root)
            result = self.run_lanes(root)
            self.assertEqual(self.lane_status(result), "FAIL")
            self.assertIn("tools/ocr/models is missing", result.stdout)
            self.assertFalse((root / "worker-call.json").exists())

    def test_runs_the_worker_tests_in_a_clean_environment(self):
        with tempfile.TemporaryDirectory(prefix="check-ocr-run-") as temporary:
            root = Path(temporary)
            self.fake_worker_python(root)
            (root / "tools/ocr/models").mkdir()
            result = self.run_lanes(root)
            self.assertEqual(self.lane_status(result), "PASS")
            call = json.loads((root / "worker-call.json").read_text())
            self.assertEqual(call["args"], ["-B", "-m", "unittest", "discover", "-s", "tools/ocr"])
            self.assertEqual(Path(call["cwd"]).resolve(), root.resolve())
            self.assertNotIn("LEAK_CHECK", call["env"])
            self.assertTrue({"HOME", "PATH", "TMPDIR"} <= set(call["env"]))


if __name__ == "__main__":
    unittest.main()
