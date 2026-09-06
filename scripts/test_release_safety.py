#!/usr/bin/env python3
"""Run isolated production gate blocks, never signing, launching, or packaging."""

import json
import os
from pathlib import Path
import shlex
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
                if target == "app":
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
        for name in ("cargo-audit", "release", "publish-release"):
            raw = subprocess.check_output(
                ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
                 str(ROOT / f".github/workflows/{name}.yml")], text=True
            )
            cls.workflows[name] = json.loads(raw)

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
        for name, workflow in self.workflows.items():
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
