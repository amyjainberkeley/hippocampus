#!/usr/bin/env python3
"""Exercise the retention runner with disposable compiler and worker processes."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent
WORKFLOW = SCRIPTS.parent / ".github/workflows/release-contract.yml"
ONBOARDING = "RetentionPersistenceBehavior"
PREFERENCES = "RetentionPreferencesBehavior"

# Compilation is replaced at the toolchain boundary; the real shell runner and
# Swift compatibility wrapper still select commands, handle failures and clean up.
TOOL = r'''
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
scenario = json.loads((root / "scenario.json").read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]

def event(gate):
    with (root / "trace.jsonl").open("a") as trace:
        trace.write(json.dumps({"gate": gate, "args": args}) + "\n")
    if scenario.get("fail") == gate:
        print("injected stdout", flush=True)
        print("injected stderr", file=sys.stderr, flush=True)
        if scenario["status"] == 137:
            os.kill(os.getpid(), signal.SIGKILL)
        sys.exit(scenario["status"])

if name == "xcrun":
    assert args[0] == "--find" and args[1] in ("swift", "swiftc")
    print(root / "bin" / args[1])
elif name == "swift":
    package = Path(args[args.index("--package-path") + 1]).name
    product = "RetentionPersistenceBehavior" if package == "onboarding" else "RetentionPreferencesBehavior"
    if "--show-bin-path" in args:
        event("locate:" + product)
        print(root / "products")
    elif args[0] == "build":
        assert args[args.index("--product") + 1] == product
        event("build:" + product)
    elif args[0] == "run":
        event("swift-run:" + product)
        result = subprocess.run([str(root / "products" / product), args[-1]])
        sys.exit(128 - result.returncode if result.returncode < 0 else result.returncode)
    else:
        raise AssertionError(args)
elif name == "cargo":
    event("worker")
    fixture = Path(os.environ["MCI_RETENTION_PICKER_FIXTURE_DIR"])
    assert (fixture / "onboarding" / "RetentionPersistenceBehavior.receipt").is_file()
    assert (fixture / "RetentionPreferencesBehavior.receipt").is_file()
elif name in ("RetentionPersistenceBehavior", "RetentionPreferencesBehavior"):
    event("run:" + name)
    output = Path(args[0])
    output.mkdir(parents=True, exist_ok=True)
    (output / (name + ".receipt")).write_text("fixture executed\n")
else:
    raise AssertionError(name)
'''


class RetentionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="retention-runner-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout with spaces"
        for directory in ("scripts", "bin", "products", "home", "tmp", "apps/onboarding", "apps/hippocampus"):
            (self.root / directory).mkdir(parents=True)
        for script in ("test-retention-policy-contract.sh", "swift-package.sh"):
            shutil.copy2(SCRIPTS / script, self.root / "scripts" / script)
        for directory, names in (("bin", ("xcrun", "swift", "swiftc", "cargo")),
                                 ("products", (ONBOARDING, PREFERENCES))):
            for name in names:
                tool = self.root / directory / name
                tool.write_text("#!" + sys.executable + "\n" + TOOL)
                tool.chmod(0o700)

    def run_contract(self, fail=None, status=47):
        (self.root / "scenario.json").write_text(json.dumps({"fail": fail, "status": status}))
        result = subprocess.run(
            ["bash", str(self.root / "scripts/test-retention-policy-contract.sh")],
            cwd=self.root,
            env={"HOME": str(self.root / "home"),
                 "PATH": str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
                 "TMPDIR": str(self.root / "tmp")},
            capture_output=True, text=True, timeout=20,
        )
        events = [json.loads(line) for line in (self.root / "trace.jsonl").read_text().splitlines()]
        self.assertEqual(list((self.root / "tmp").iterdir()), [], "temporary fixtures must be removed")
        for event in events:
            if event["gate"].startswith("run:"):
                self.assertFalse(Path(event["args"][0]).exists(), "retention output must be removed")
        return result, events

    def test_build_run_and_worker_are_distinct_observable_gates(self):
        result, events = self.run_contract()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = [f"{phase}:{product}" for product in (ONBOARDING, PREFERENCES)
                    for phase in ("build", "locate", "run")] + ["worker"]
        self.assertEqual([event["gate"] for event in events], expected)
        for gate in expected:
            self.assertIn("START " + gate, result.stderr)
            self.assertIn("PASS " + gate + " exit=0", result.stderr)
        for event in events:
            if not event["gate"].startswith("run:"):
                args = event["args"]
                self.assertIn("--jobs", args)
                self.assertEqual(args[args.index("--jobs") + 1], "2")
        self.assertEqual(events[-1]["args"], [
            "test", "--jobs", "2", "-p", "mci-agent", "--test", "retention_preferences_contract",
            "--locked", "picker_outputs_are_worker_compatible", "--", "--ignored", "--exact",
        ])
        self.assertIn("PASS: onboarding and Preferences retention output", result.stdout)

    def assert_failure_stops_contract(self, gate, status):
        result, events = self.run_contract(gate, status)
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertEqual(events[-1]["gate"], gate, "later gates must not run after a failure")
        self.assertIn(f"FAIL {gate} exit={status}", result.stderr)
        self.assertNotIn(f"PASS {gate}", result.stderr)
        self.assertIn("injected stderr", result.stderr)
        self.assertNotIn("PASS: onboarding and Preferences", result.stdout)

    def test_build_failure_preserves_status_and_stops_execution(self):
        self.assert_failure_stops_contract("build:" + PREFERENCES, 47)

    def test_bin_path_failure_cannot_launch_a_stale_fixture(self):
        self.assert_failure_stops_contract("locate:" + PREFERENCES, 48)

    def test_onboarding_failure_stops_parent_and_worker(self):
        self.assert_failure_stops_contract("run:" + ONBOARDING, 49)

    def test_parent_assertion_failure_stops_worker(self):
        self.assert_failure_stops_contract("run:" + PREFERENCES, 50)

    def test_sigkill_is_not_retried_or_reported_as_success(self):
        self.assert_failure_stops_contract("run:" + PREFERENCES, 137)

    def test_worker_failure_preserves_status(self):
        self.assert_failure_stops_contract("worker", 51)


class RetentionDiagnosticsTests(unittest.TestCase):
    def workflow_step(self, name):
        parsed = subprocess.run([
            "ruby", "-r", "yaml", "-r", "json", "-e",
            'puts JSON.generate(YAML.load_file(ARGV[0]))', str(WORKFLOW),
        ], check=True, capture_output=True, text=True, timeout=10)
        steps = json.loads(parsed.stdout)["jobs"]["contracts"]["steps"]
        step = next((step for step in steps if step.get("name") == name), None)
        self.assertIsNotNone(step, "missing retention workflow step: " + name)
        return step

    def test_hosted_launcher_preserves_sigkill(self):
        step = self.workflow_step("Retention policy contract")
        with tempfile.TemporaryDirectory(prefix="retention-launcher-") as root:
            script = Path(root) / "scripts/test-retention-policy-contract.sh"
            script.parent.mkdir()
            script.write_text("#!/bin/bash\nkill -KILL $$\n")
            script.chmod(0o700)
            result = subprocess.run([
                "bash", "-e", "-o", "pipefail", "-c", step["run"],
            ], cwd=root, env={"HOME": root, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 137, result.stderr)

    def run_diagnostics(self, reports):
        diagnostic = self.workflow_step("Diagnose retention failure")
        with tempfile.TemporaryDirectory(prefix="retention-diagnostics-") as root:
            home = Path(root) / "home"
            directory = home / "Library/Logs/DiagnosticReports"
            directory.mkdir(parents=True)
            for name, content in reports.items():
                (directory / name).write_text(content)
            return subprocess.run([
                "bash", "-e", "-o", "pipefail", "-c", diagnostic["run"],
            ], cwd=root, env={"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                capture_output=True, text=True, timeout=10)

    def test_crash_summary_handles_ips_header_and_does_not_dump_private_fields(self):
        report = json.dumps({"app_name": PREFERENCES}) + "\n" + json.dumps({
            "procName": PREFERENCES, "pid": 123,
            "exception": {"type": "EXC_CRASH", "signal": "SIGKILL"},
            "termination": {"namespace": "CODESIGNING", "code": 2, "indicator": "Invalid Page"},
            "environment": {"SECRET": "must-not-appear"},
            "threads": [{"private": "must-not-appear"}],
        })
        result = self.run_diagnostics({
            PREFERENCES + "-fixture.ips": report,
            "UnrelatedApplication.ips": "must-not-appear",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(next(line for line in result.stdout.splitlines() if line.startswith("{")))
        self.assertEqual(summary["termination"], {
            "namespace": "CODESIGNING", "code": 2, "indicator": "Invalid Page",
        })
        self.assertEqual(summary["exception"]["signal"], "SIGKILL")
        self.assertNotIn("must-not-appear", result.stdout + result.stderr)

    def test_missing_report_leaves_termination_reason_unknown(self):
        result = self.run_diagnostics({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("termination reason remains unknown", result.stdout)

    def test_malformed_report_is_reported_without_dumping_contents(self):
        result = self.run_diagnostics({PREFERENCES + "-fixture.ips": "private malformed data"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unable to parse", result.stdout)
        self.assertNotIn("private malformed data", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
