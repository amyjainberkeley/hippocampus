#!/usr/bin/env python3
"""Run isolated production gate blocks, never signing, launching, or packaging."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
APP_SCRIPT = ROOT / "apps/hippocampus/Resources/build-app.sh"
INSTALLER_SCRIPT = ROOT / "scripts/build-installer.sh"


def section(path, start, end):
    source = path.read_text(encoding="utf-8")
    return source.split(start, 1)[1].split(end, 1)[0]


class VerifierTests(unittest.TestCase):
    def run_gate(self, target, *, missing=None, executable=True, model_exit=0, launch_exit=0, lite=False):
        with tempfile.TemporaryDirectory(prefix="release-verifiers-") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            app = root / "Hippocampus.app"
            (app / "Contents/Resources/Models/ArcticEmbedS_FP16.mlmodelc").mkdir(parents=True)
            log = root / "calls.jsonl"
            for name, status in (("verify-models.sh", model_exit), ("verify-app-launches.sh", launch_exit)):
                if name == missing and executable:
                    continue
                path = scripts / name
                path.write_text(
                    f"#!{sys.executable}\n"
                    "import json, os, sys\n"
                    "with open(os.environ['VERIFY_LOG'], 'a') as handle:\n"
                    f"    handle.write(json.dumps({{'name': {name!r}, 'args': sys.argv[1:], "
                    "'clean_home': os.getenv('VERIFY_CLEAN_HOME'), "
                    "'onboarding': os.getenv('VERIFY_EXPECT_ONBOARDING')}) + '\\n')\n"
                    f"sys.exit({status})\n", encoding="utf-8"
                )
                path.chmod(0o644 if name == missing else 0o755)
            if target == "app":
                body = "fatal() {" + section(APP_SCRIPT, "fatal() {", "\n}\n") + "\n}\n"
                body += section(APP_SCRIPT, "# Validate model bundling.", "# Ad-hoc development bundles")
                # The first line is the remainder of the opening comment.
                body = body.replace(" Only the explicit", "# Only the explicit", 1)
            else:
                body = section(INSTALLER_SCRIPT, "# --- Completeness gate:", "# --- Step 2:")
                body = "#" + body
            result = subprocess.run(
                ["/bin/bash", "-euc", body], cwd=root, capture_output=True, text=True,
                env={**os.environ, "REPO_ROOT": str(root), "APP": str(app), "APP_PATH": str(app),
                     "PROFILE": "debug" if lite else "release", "BUILD_PROFILE": "release",
                     "DEVELOPMENT_LITE": str(int(lite)), "SKIP_BUILD": "1", "VERIFY_LOG": str(log)},
                timeout=10,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_missing_or_nonexecutable_verifiers_are_fatal(self):
        for target in ("app", "installer"):
            for verifier in ("verify-models.sh", "verify-app-launches.sh"):
                for executable in (True, False):
                    with self.subTest(target=target, verifier=verifier, executable=executable):
                        result, calls = self.run_gate(target, missing=verifier, executable=executable)
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("FATAL", result.stdout + result.stderr)
                        self.assertIn(verifier, result.stdout + result.stderr)

    def test_model_failure_prevents_launch_verification(self):
        for target in ("app", "installer"):
            with self.subTest(target=target):
                result, calls = self.run_gate(target, model_exit=42)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual([call["name"] for call in calls], ["verify-models.sh"])

    def test_launch_failure_is_fatal(self):
        for target in ("app", "installer"):
            with self.subTest(target=target):
                result, calls = self.run_gate(target, launch_exit=42)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 2)

    def test_release_and_skip_build_run_strict_model_then_launch_gates(self):
        for target in ("app", "installer"):
            with self.subTest(target=target):
                result, calls = self.run_gate(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual([call["name"] for call in calls], ["verify-models.sh", "verify-app-launches.sh"])
                self.assertEqual(calls[0]["args"][0], "--app")
                self.assertNotIn("--allow-missing-bundled", calls[0]["args"])
                self.assertEqual((calls[1]["clean_home"], calls[1]["onboarding"]), ("1", "1"))

    def test_development_lite_retains_explicit_model_omission(self):
        result, calls = self.run_gate("app", lite=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--allow-missing-bundled", calls[0]["args"])
        self.assertEqual(len(calls), 2)


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Use the system Ruby YAML parser, with no downloaded test dependencies.
        cls.workflows = {}
        for name in ("cargo-audit", "release", "publish-release", "release-contract", "swift"):
            raw = subprocess.check_output(
                ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
                 str(ROOT / f".github/workflows/{name}.yml")], text=True
            )
            cls.workflows[name] = json.loads(raw)

    def test_recall_ci_stages_the_archive_through_the_supported_wrapper(self):
        steps = self.workflows["swift"]["jobs"]["recall-ui"]["steps"]
        runs = [step.get("run", "") for step in steps]
        self.assertIn("scripts/swift-package.sh test --package-path apps/recall-ui", runs)
        self.assertNotIn("swift test --package-path apps/recall-ui", runs)

    def test_contract_fixtures_use_the_same_swift_capable_runner_as_onboarding(self):
        contracts = self.workflows["release-contract"]["jobs"]["contracts"]
        onboarding = self.workflows["swift"]["jobs"]["onboarding"]
        self.assertEqual(contracts["runs-on"], onboarding["runs-on"])
        steps = contracts["steps"]
        runs = [step.get("run", "") for step in steps]
        environment = next((i for i, run in enumerate(runs)
                            if "swift --version" in run and "xcodebuild -version" in run), None)
        self.assertIsNotNone(environment)
        gates = [(i, step) for i, step in enumerate(steps)
                 if step.get("id") == "retention-contract"]
        self.assertEqual(len(gates), 1, "the retention contract must have one identifiable gate")
        index, gate = gates[0]
        self.assertLess(environment, index)
        command = shlex.split(gate["run"].replace("\\\n", " "))
        self.assertEqual(command[:4], ["time", "-p", "env", "-i"])
        self.assertEqual(command[-1], "scripts/test-retention-policy-contract.sh")
        self.assertNotIn("if", gate)
        self.assertFalse(gate.get("continue-on-error", False))

    def test_onboarding_diagnostic_does_not_stop_at_the_exec_event(self):
        steps = self.workflows["swift"]["jobs"]["onboarding"]["steps"]
        diagnostic = next(step for step in steps
                          if step.get("name") == "Diagnose onboarding test failure")
        command = diagnostic["run"]
        self.assertLess(command.index("settings set target.process.stop-on-exec false"),
                        command.index("-o run"))
        self.assertEqual(diagnostic["if"], "failure()")
        self.assertLessEqual(diagnostic["timeout-minutes"], 2)
        self.assertIn('xcrun --find xctest', command)
        self.assertIn('-k \'thread backtrace all\'', command)
        self.assertIn('env -i', command)
        self.assertIn('--no-lldbinit', command)

    def test_contract_runner_provisions_ripgrep_before_checks(self):
        steps = self.workflows["release-contract"]["jobs"]["contracts"]["steps"]
        first_check = next(i for i, step in enumerate(steps)
                           if step.get("run") == "scripts/test-release-contract.sh")
        installs = [(i, step) for i, step in enumerate(steps)
                    if "brew install ripgrep" in step.get("run", "")]
        self.assertEqual(len(installs), 1, "the macOS runner must provision ripgrep")
        index, install = installs[0]
        self.assertLess(index, first_check)
        self.assertNotIn("if", install)
        self.assertFalse(install.get("continue-on-error", False))
        self.assertIn("rg --version", install["run"])

    def test_contract_script_stops_before_assertions_without_ripgrep(self):
        with tempfile.TemporaryDirectory(prefix="contract-no-rg-") as temporary:
            binaries = Path(temporary)
            (binaries / "dirname").symlink_to(shutil.which("dirname"))
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "scripts/test-release-contract.sh")],
                cwd=ROOT, env={**os.environ, "PATH": str(binaries)},
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires ripgrep", result.stderr)
            self.assertNotIn("PASS:", result.stdout)
            self.assertNotIn("FAIL:", result.stderr)

    def test_safety_regressions_run_in_local_and_hosted_gates(self):
        with tempfile.TemporaryDirectory(prefix="release-safety-lane-") as temp:
            root = Path(temp)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            shutil.copyfile(ROOT / "scripts/check.sh", root / "scripts/check.sh")
            python = root / "bin/python3"
            python.write_text(
                f"#!{sys.executable}\nimport sys\n"
                "if 'scripts/test_release_safety.py' in sys.argv:\n"
                "    print('release safety failure fixture executed')\n"
                "    sys.exit(42)\n"
            )
            python.chmod(0o755)
            result = subprocess.run(
                ["bash", str(root / "scripts/check.sh"), "bash", "test"],
                cwd=root, env={**os.environ, "PATH": f"{root / 'bin'}:/usr/bin:/bin",
                               "CHECK_SH_QUIET": "0"},
                capture_output=True, text=True, timeout=10,
            )
            self.assertIn("release safety failure fixture executed", result.stdout)
            self.assertRegex(result.stdout, r"release-safety-contract\s+FAIL")
            self.assertNotEqual(result.returncode, 0)
        raw = subprocess.check_output(
            ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
             str(ROOT / ".github/workflows/release-contract.yml")], text=True
        )
        workflow = json.loads(raw)
        steps = workflow["jobs"]["contracts"]["steps"]
        gate = next((step for step in steps if step.get("run") ==
                     "python3 -B scripts/test_release_safety.py"), None)
        self.assertIsNotNone(gate, "release safety regressions must run in hosted CI")
        self.assertNotIn("if", gate)
        self.assertFalse(gate.get("continue-on-error", False))

    def test_release_audits_checked_out_tag_before_build_or_publish(self):
        cases = (("release", "build-draft", "${{ github.sha }}", "${{ github.ref_name }}", "Build all binaries"),
                 ("publish-release", "publish", "refs/tags/${{ inputs.tag }}", "${{ inputs.tag }}", "Download and re-verify draft artifacts"))
        for name, job, ref, tag, boundary in cases:
            with self.subTest(workflow=name):
                steps = self.workflows[name]["jobs"][job]["steps"]
                checkout = next(i for i, step in enumerate(steps) if step.get("uses", "").startswith("actions/checkout@"))
                audits = [(i, step) for i, step in enumerate(steps) if "scripts/audit-supply-chain.py" in step.get("run", "")]
                self.assertEqual(len(audits), 1, "release needs a blocking audit of its own checkout")
                index, audit = audits[0]
                self.assertEqual(steps[checkout]["with"].get("ref"), ref)
                self.assertGreater(index, checkout)
                self.assertLess(index, next(i for i, step in enumerate(steps) if step.get("name") == boundary))
                self.assertNotIn("if", audit)
                self.assertFalse(audit.get("continue-on-error", False))
                self.assertEqual(audit.get("env", {}).get("RELEASE_TAG"), tag)
                self.assertIn('--release-tag "$RELEASE_TAG"', audit["run"])
                self.assertIn("--require-version 0.22.2", audit["run"])
                # Execute the configured shell step with a failing scanner fixture.
                with tempfile.TemporaryDirectory(prefix="release-audit-step-") as temp:
                    scripts = Path(temp) / "scripts"
                    scripts.mkdir()
                    (scripts / "audit-supply-chain.py").write_text("raise SystemExit(42)\n")
                    result = subprocess.run(["bash", "-euc", audit["run"]], cwd=temp,
                                            env={**os.environ, "RELEASE_TAG": "v0.1.0", "RUNNER_TEMP": temp},
                                            capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_all_scanner_installs_and_caches_use_exact_version(self):
        for name in ("cargo-audit", "release", "publish-release"):
            workflow = self.workflows[name]
            with self.subTest(workflow=name):
                steps = next(iter(workflow["jobs"].values()))["steps"]
                installs = [step for step in steps if "cargo install" in step.get("run", "")]
                self.assertEqual(len(installs), 1)
                args = shlex.split(installs[0]["run"])
                self.assertIn("--locked", args)
                self.assertIn("--version", args)
                self.assertEqual(args[args.index("--version") + 1], "=0.22.2")
                cache = next(step for step in steps if step.get("id") == "cache-audit-bin")
                self.assertIn("0.22.2", cache["with"]["key"])
                self.assertIn("${{ runner.arch }}", cache["with"]["key"])
                self.assertNotIn("restore-keys", cache["with"])
                audit = next(step for step in steps if "scripts/audit-supply-chain.py" in step.get("run", ""))
                self.assertIn("--require-version 0.22.2", audit["run"])


if __name__ == "__main__":
    unittest.main()
