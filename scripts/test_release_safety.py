#!/usr/bin/env python3
"""Run isolated production gate blocks, never signing, launching, or packaging."""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
APP_SCRIPT = ROOT / "apps/hippocampus/Resources/build-app.sh"
INSTALLER_SCRIPT = ROOT / "scripts/build-installer.sh"
RELEASE_SCRIPT = ROOT / "scripts/release-0.3.0.sh"


def section(path, start, end):
    source = path.read_text(encoding="utf-8")
    return source.split(start, 1)[1].split(end, 1)[0]


class VerifierTests(unittest.TestCase):
    def run_gate(self, target, *, missing=None, executable=True, model_exit=0, launch_exit=0, lite=False,
                 dry_run=False):
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
            dry_run_env = {}
            if dry_run:
                dry_run_env = {"RELEASE_DRY_RUN": "1"} if target == "app" else {"DRY_RUN": "1"}
            result = subprocess.run(
                ["/bin/bash", "-euc", body], cwd=root, capture_output=True, text=True,
                env={**os.environ, "REPO_ROOT": str(root), "APP": str(app), "APP_PATH": str(app),
                     "PROFILE": "debug" if lite else "release", "BUILD_PROFILE": "release",
                     "DEVELOPMENT_LITE": str(int(lite)), "SKIP_BUILD": "1", "VERIFY_LOG": str(log),
                     **dry_run_env},
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

    def test_a_release_dry_run_checks_the_models_but_never_opens_the_app(self):
        for target in ("app", "installer"):
            with self.subTest(target=target):
                result, calls = self.run_gate(target, dry_run=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual([call["name"] for call in calls], ["verify-models.sh"])
                self.assertNotIn("--allow-missing-bundled", calls[0]["args"])
                self.assertIn("SKIPPED", result.stdout)
                self.assertIn("never opened", result.stdout)

    def test_a_release_dry_run_still_fails_on_a_model_failure(self):
        for target in ("app", "installer"):
            with self.subTest(target=target):
                result, calls = self.run_gate(target, model_exit=42, dry_run=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_development_lite_retains_explicit_model_omission(self):
        result, calls = self.run_gate("app", lite=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--allow-missing-bundled", calls[0]["args"])
        self.assertEqual(len(calls), 2)


class DryRunNotaryTests(unittest.TestCase):
    """A release dry run sends nothing to Apple's notary service; the release
    asks it for the profile and stops without one. Runs the scripts' own
    blocks with a stand-in xcrun that records every call."""

    FAKE_XCRUN = (
        "import os, sys\n"
        "with open(os.environ['XCRUN_CALLS'], 'a') as handle:\n"
        "    handle.write(' '.join(sys.argv[1:]) + '\\n')\n"
        "sys.exit(int(os.environ.get('XCRUN_EXIT', '0')))\n"
    )

    def run_block(self, body, env, xcrun_exit=0):
        with tempfile.TemporaryDirectory(prefix="dry-run-notary-") as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            xcrun = root / "bin/xcrun"
            xcrun.write_text(f"#!{sys.executable}\n" + self.FAKE_XCRUN, encoding="utf-8")
            xcrun.chmod(0o755)
            calls = root / "calls"
            calls.write_text("")
            result = subprocess.run(
                ["/bin/bash", "-euo", "pipefail", "-c", body],
                cwd=root, capture_output=True, text=True, timeout=60,
                env={"PATH": f"{root / 'bin'}:/usr/bin:/bin", "HOME": temporary,
                     "XCRUN_CALLS": str(calls), "XCRUN_EXIT": str(xcrun_exit), **env},
            )
            return result, calls.read_text().splitlines()

    def installer_block(self):
        block = section(INSTALLER_SCRIPT, "# --- Detect notarytool credentials ---", "notarize_and_record() {")
        return block + '\necho "NOTARIZE=$NOTARIZE"\n'

    def release_block(self):
        helpers = ('ok() { echo "ok $*"; }\ninfo() { echo "info $*"; }\n'
                   'fail() { echo "FAIL $*"; }\nclean_env() { "$@"; }\nNOTARY_PROFILE=notarytool-profile\n')
        body = "check_notary_profile() {" + section(RELEASE_SCRIPT, "check_notary_profile() {", "\n}\n") + "\n}\n"
        return helpers + body + "check_notary_profile\n"

    INSTALLER_ENV = {"SIGNING_MODE": "developer-id", "BUILD_PROFILE": "release"}

    def test_the_installer_dry_run_never_asks_the_notary_service(self):
        result, calls = self.run_block(self.installer_block(), {**self.INSTALLER_ENV, "DRY_RUN": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])
        self.assertIn("NOTARIZE=0", result.stdout)
        self.assertIn("skipped (dry run", result.stdout)

    def test_the_installer_release_stops_without_the_notary_profile(self):
        result, calls = self.run_block(self.installer_block(), {**self.INSTALLER_ENV, "DRY_RUN": "0"}, xcrun_exit=1)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Release installer requires notarization credentials", result.stderr)
        self.assertEqual(calls, ["notarytool history --keychain-profile notarytool-profile"])

    def test_the_installer_release_notarizes_with_the_profile(self):
        result, calls = self.run_block(self.installer_block(), {**self.INSTALLER_ENV, "DRY_RUN": "0"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NOTARIZE=1", result.stdout)
        self.assertEqual(calls, ["notarytool history --keychain-profile notarytool-profile"])

    def test_the_release_script_dry_run_never_asks_the_notary_service(self):
        result, calls = self.run_block(self.release_block(), {"DRY_RUN": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])
        self.assertIn("a dry run sends nothing to Apple's notary service", result.stdout)

    def test_the_release_script_release_checks_the_notary_profile(self):
        for xcrun_exit, verdict in ((0, "ok notary keychain profile"), (1, "FAIL notary keychain profile")):
            with self.subTest(xcrun_exit=xcrun_exit):
                result, calls = self.run_block(self.release_block(), {"DRY_RUN": "0"}, xcrun_exit=xcrun_exit)
                self.assertIn(verdict, result.stdout)
                self.assertEqual(calls, ["notarytool history --keychain-profile notarytool-profile"])


class NotarizationRecordTests(unittest.TestCase):
    """build-installer.sh's notarize_and_record, run with a stand-in
    notarytool: Apple's "Accepted" is not enough, its log must be clean."""

    FAKE_XCRUN = (
        "import json, os, sys\n"
        "args = sys.argv[1:]\n"
        "assert args[0] == 'notarytool', args\n"
        "if args[1] == 'submit':\n"
        "    print(json.dumps({'id': 'job-1', 'status': os.environ['FAKE_STATUS'], 'message': 'done'}))\n"
        "    sys.exit(0 if os.environ['FAKE_STATUS'] == 'Accepted' else 1)\n"
        "if args[1] == 'log':\n"
        "    issues = json.loads(os.environ['FAKE_ISSUES'])\n"
        "    log = {'logFormatVersion': 1, 'jobId': args[2], 'status': os.environ['FAKE_STATUS'],\n"
        "           'statusCode': 0 if os.environ['FAKE_STATUS'] == 'Accepted' else 4000,\n"
        "           'archiveFilename': os.environ['FAKE_ARCHIVE'], 'issues': issues,\n"
        "           'ticketContents': [{'path': 'Hippocampus.app/Contents/MacOS/Hippocampus',\n"
        "                               'digestAlgorithm': 'SHA-256', 'cdhash': '00', 'arch': 'arm64'}]}\n"
        "    open(args[3], 'w').write(json.dumps(log))\n"
        "    sys.exit(0)\n"
        "sys.exit(2)\n"
    )

    def run_record(self, status, issues):
        body = "notarize_and_record() {" + section(INSTALLER_SCRIPT, "notarize_and_record() {", "\n}\n") + "\n}\n"
        with tempfile.TemporaryDirectory(prefix="notarize-record-") as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            xcrun = root / "bin/xcrun"
            xcrun.write_text(f"#!{sys.executable}\n" + self.FAKE_XCRUN, encoding="utf-8")
            xcrun.chmod(0o755)
            artifact = root / "Hippocampus-1.2.3.dmg"
            artifact.write_bytes(b"synthetic disk image")
            result = subprocess.run(
                ["/bin/bash", "-euo", "pipefail", "-c", body + 'notarize_and_record "$ARTIFACT" dmg\n'],
                cwd=root, capture_output=True, text=True, timeout=60,
                env={"PATH": f"{root / 'bin'}:/usr/bin:/bin", "HOME": temporary,
                     "DIST_DIR": str(root / "dist"), "NOTARY_PROFILE": "fixture-profile",
                     "CHECK_NOTARY_LOG": str(ROOT / "scripts/check-notary-log.py"),
                     "ARTIFACT": str(artifact), "FAKE_STATUS": status,
                     "FAKE_ISSUES": json.dumps(issues), "FAKE_ARCHIVE": artifact.name},
            )
            kept = sorted(path.name for path in (root / "dist").iterdir()) if (root / "dist").exists() else []
            return result, kept

    def test_accepted_with_a_clean_log_passes_and_keeps_both_records(self):
        result, kept = self.run_record("Accepted", None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(kept, ["notary-dmg-log.json", "notary-dmg-submission.json"])

    def test_accepted_with_a_warning_in_the_log_fails(self):
        warning = {"severity": "warning", "path": "Hippocampus.app/Contents/MacOS/mci-agent",
                   "message": "The binary uses an SDK older than the 10.9 SDK."}
        result, kept = self.run_record("Accepted", [warning])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("log is not clean", result.stderr)
        self.assertIn("older than the 10.9 SDK", result.stderr)
        self.assertIn("notary-dmg-log.json", kept)

    def test_a_submission_apple_rejects_fails(self):
        result, _ = self.run_record("Invalid", [])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("was not accepted", result.stderr)


class WorkflowTests(unittest.TestCase):
    ASSEMBLY_COMMAND = (
        "apps/hippocampus/Resources/build-app.sh --debug --development-ad-hoc --development-lite"
    )
    ASSEMBLY_BUILDS = [
        ["scripts/swift-package.sh", "build", "--jobs", "2", "--configuration", "debug",
         "--package-path", package, "--product", product]
        for package, product in (
            ("apps/hippocampus", "Hippocampus"),
            ("adapters/macos/MCICaptureHelper", "mci-capture-helper"),
            ("apps/recall-ui", "recall-ui"),
            ("apps/onboarding", "onboarding"),
        )
    ] + [["cargo", "build", "--locked", "--jobs", "2", "-p", "mci-agent", "--bins",
          "-p", "hippocampus-native-host"]]

    @classmethod
    def setUpClass(cls):
        # Use the system Ruby YAML parser, with no downloaded test dependencies.
        cls.workflows = {}
        for name in ("cargo", "cargo-audit", "release", "publish-release", "release-contract", "swift"):
            raw = subprocess.check_output(
                ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
                 str(ROOT / f".github/workflows/{name}.yml")], text=True
            )
            cls.workflows[name] = json.loads(raw)

    def assembly_steps(self):
        job = self.workflows["release-contract"]["jobs"]["contracts"]
        steps = job["steps"]
        builds = [(i, step) for i, step in enumerate(steps)
                  if step.get("name") == "Build app assembly prerequisites"]
        assemblies = [(i, step) for i, step in enumerate(steps)
                      if step.get("run") == self.ASSEMBLY_COMMAND]
        self.assertEqual(len(builds), 1, "assembly requires an explicit prerequisite build step")
        self.assertEqual(len(assemblies), 1, "assembly must remain a mandatory gate")
        return job, builds[0], assemblies[0]

    def test_contract_assembly_builds_exact_products_before_packaging(self):
        job, (build_index, build), (assembly_index, assembly) = self.assembly_steps()
        self.assertEqual(build_index + 1, assembly_index)
        for gate in (job, build, assembly):
            self.assertNotIn("if", gate)
            self.assertFalse(gate.get("continue-on-error", False))
        self.assertEqual(build.get("shell"), "bash")
        self.assertEqual(build.get("env", {}).get("CARGO_BUILD_JOBS"), "2",
                         "the Recall wrapper's nested FFI build must also use two jobs")
        commands = [shlex.split(line) for line in build["run"].splitlines() if line.strip()]
        self.assertEqual(commands, self.ASSEMBLY_BUILDS)

    def test_contract_assembly_build_failures_stop_before_later_commands(self):
        _, (_, build), (_, assembly) = self.assembly_steps()
        commands = self.ASSEMBLY_BUILDS + [shlex.split(self.ASSEMBLY_COMMAND)]
        # Exercise the actual mandatory shell commands with inert executables.
        for fail_call in range(-1, len(commands)):
            with self.subTest(fail_call=fail_call), tempfile.TemporaryDirectory(
                prefix="assembly-prerequisites-"
            ) as temporary:
                root = Path(temporary)
                log = root / "calls.jsonl"
                fixture = f"#!{sys.executable}\n" + (
                    "import json, os, sys\n"
                    "from pathlib import Path\n"
                    "log = Path(os.environ['BUILD_CALLS'])\n"
                    "calls = log.read_text().splitlines() if log.exists() else []\n"
                    "with log.open('a') as handle:\n"
                    "    handle.write(json.dumps({'name': Path(sys.argv[0]).name, "
                    "'args': sys.argv[1:], 'jobs': os.getenv('CARGO_BUILD_JOBS')}) + '\\n')\n"
                    "sys.exit(42 if len(calls) == int(os.environ['FAIL_CALL']) else 0)\n"
                )
                for relative in ("scripts/swift-package.sh", "bin/cargo",
                                 "apps/hippocampus/Resources/build-app.sh"):
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(fixture, encoding="utf-8")
                    path.chmod(0o755)
                result = subprocess.run(
                    ["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c",
                     build["run"] + "\n" + assembly["run"]],
                    cwd=root, capture_output=True, text=True, timeout=10,
                    env={"HOME": temporary, "PATH": f"{root / 'bin'}:/usr/bin:/bin",
                         **build.get("env", {}), "BUILD_CALLS": str(log),
                         "FAIL_CALL": str(fail_call)},
                )
                self.assertEqual(result.returncode, 0 if fail_call == -1 else 42,
                                 result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                expected = commands if fail_call == -1 else commands[:fail_call + 1]
                self.assertEqual(calls, [
                    {"name": Path(command[0]).name, "args": command[1:], "jobs": "2"}
                    for command in expected
                ])

    def test_recall_ci_stages_the_archive_through_the_supported_wrapper(self):
        steps = self.workflows["swift"]["jobs"]["recall-ui"]["steps"]
        runs = [step.get("run", "") for step in steps]
        self.assertIn("scripts/swift-package.sh test --package-path apps/recall-ui", runs)
        self.assertNotIn("swift test --package-path apps/recall-ui", runs)

    def test_screen_proof_contract_is_complete_and_mandatory(self):
        steps = self.workflows["release-contract"]["jobs"]["contracts"]["steps"]
        gates = [step for step in steps if step.get("id") == "screen-proof-contract"]
        self.assertEqual(len(gates), 1)
        gate = gates[0]
        self.assertEqual(shlex.split(gate["run"]), ["bash", "scripts/live-capture/test-screen-proof.sh"])
        self.assertNotIn("if", gate)
        self.assertFalse(gate.get("continue-on-error", False))

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

    def test_ripgrep_checks_never_pass_without_a_search(self):
        for script, message in (("scripts/test-no-quarantine-bypass.sh", "quarantine check requires ripgrep"),
                                ("scripts/test-release-ocr-killswitch.sh", "release OCR check requires ripgrep")):
            with self.subTest(script=script), tempfile.TemporaryDirectory(prefix="contract-no-rg-") as temporary:
                binaries = Path(temporary)
                (binaries / "dirname").symlink_to(shutil.which("dirname"))
                result = subprocess.run(
                    ["/bin/bash", str(ROOT / script)],
                    cwd=ROOT, env={**os.environ, "PATH": str(binaries)},
                    capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertNotIn("PASS:", result.stdout)
        # rg exits 0 on a match and 1 on none; the quarantine check passes
        # only on 1, never when the search itself failed.
        for rg_exit, passes in ((0, False), (1, True), (2, False)):
            with self.subTest(rg_exit=rg_exit), tempfile.TemporaryDirectory(prefix="contract-fake-rg-") as temporary:
                binaries = Path(temporary)
                (binaries / "rg").write_text(f"#!/bin/sh\nexit {rg_exit}\n")
                (binaries / "rg").chmod(0o755)
                result = subprocess.run(
                    ["/bin/bash", str(ROOT / "scripts/test-no-quarantine-bypass.sh")],
                    cwd=ROOT, env={**os.environ, "PATH": f"{binaries}:/usr/bin:/bin"},
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode == 0, passes, result.stdout + result.stderr)
                self.assertEqual("PASS:" in result.stdout, passes)

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
        scanning_jobs = {"cargo-audit": "audit", "release": "build-draft", "publish-release": "publish"}
        for name, job in scanning_jobs.items():
            workflow = self.workflows[name]
            with self.subTest(workflow=name):
                steps = workflow["jobs"][job]["steps"]
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

    RELEASE_SECRETS = ("APPLE_CERTIFICATE_P12", "APPLE_CERTIFICATE_PASSWORD", "NOTARYTOOL_APPLE_ID",
                       "NOTARYTOOL_TEAM_ID", "NOTARYTOOL_PASSWORD", "SPARKLE_PRIVATE_KEY")

    def test_a_tag_without_release_secrets_builds_nothing(self):
        jobs = self.workflows["release"]["jobs"]
        check, build, draft = jobs["release-secrets"], jobs["build-draft"], jobs["create-draft"]
        # The check sees the signing environment's secrets, and gates the build.
        self.assertEqual(check["environment"]["name"], build["environment"]["name"])
        self.assertEqual(check["permissions"], {})
        self.assertEqual(build["needs"], "release-secrets")
        self.assertEqual(build["if"], "needs.release-secrets.outputs.configured == 'true'")
        self.assertEqual(draft["needs"], "build-draft")
        self.assertNotIn("if", draft)
        steps = [step for step in check["steps"] if step.get("id") == "secrets"]
        self.assertEqual(len(steps), 1)
        step = steps[0]
        self.assertEqual(check["outputs"]["configured"], "${{ steps.secrets.outputs.configured }}")
        self.assertEqual(step["env"], {name: f"${{{{ secrets.{name} }}}}" for name in self.RELEASE_SECRETS})
        # The build keeps its own gate, which requires every secret.
        gate = next(s for s in build["steps"] if s.get("name") == "Require release secrets and variables")
        self.assertEqual(sorted(gate["env"]), sorted(self.RELEASE_SECRETS))
        # Run the check's shell as the runner does: none set, one set, all set.
        for present, configured in ((set(), "false"), ({"SPARKLE_PRIVATE_KEY"}, "true"),
                                    ({"APPLE_CERTIFICATE_P12"}, "true"), (set(self.RELEASE_SECRETS), "true")):
            with self.subTest(present=sorted(present)), tempfile.TemporaryDirectory(
                prefix="release-secrets-"
            ) as temporary:
                output = Path(temporary) / "github-output"
                env = {"PATH": "/usr/bin:/bin", "GITHUB_OUTPUT": str(output)}
                env.update({name: ("value" if name in present else "") for name in self.RELEASE_SECRETS})
                result = subprocess.run(
                    ["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                    env=env, capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(output.read_text(), f"configured={configured}\n")
                if configured == "false":
                    self.assertIn("::notice", result.stdout)
                    self.assertIn("scripts/release-0.3.0.sh", result.stdout)
                else:
                    self.assertEqual(result.stdout, "")

    def test_macos_jobs_build_with_xcode_26(self):
        # Xcode 16.4 rejects the app's Swift, and the macOS 14 runners are
        # retired: every macOS job runs on macOS 26, and a job that builds
        # selects Xcode 26 before its first build step.
        build_step = re.compile(r"\b(swift|cargo|xcodebuild|xcrun)\b|scripts/|apps/mind/scripts/")
        select = 'sudo xcode-select --switch "$XCODE_APP" && xcodebuild -version'
        for name in ("cargo", "swift", "release-contract", "release", "publish-release"):
            workflow = self.workflows[name]
            for job_name, job in workflow["jobs"].items():
                if not job["runs-on"].startswith("macos"):
                    continue
                with self.subTest(workflow=name, job=job_name):
                    self.assertEqual(job["runs-on"], "macos-26")
                    runs = [step.get("run", "") for step in job["steps"]]
                    builds = [i for i, run in enumerate(runs)
                              if build_step.search(run) and run != select and run != "cargo fmt --check --all"]
                    if not builds or name == "publish-release":
                        continue
                    self.assertRegex(workflow["env"]["XCODE_APP"], r"\A/Applications/Xcode_26(\.\d+){1,2}\.app\Z")
                    self.assertIn(select, runs)
                    self.assertLess(runs.index(select), builds[0])


class OCRWorkerLayoutTests(unittest.TestCase):
    """The frozen OCR worker is a PyInstaller --onedir Mach-O tree (an executable
    next to an _internal/ of dylibs and .so modules). It must ship under
    Contents/OCR/, never under Contents/Resources/ (Apple's notary service flags
    Mach-O there as "Incorrect Bundle Structure") and never under a code location
    such as Contents/MacOS, Frameworks, PlugIns or Helpers (there codesign tries
    to seal the onedir as nested code and fails on its .dylibs/ and *.dist-info/
    folders with "bundle format unrecognized"). build-app.sh, the Swift launcher
    and the orphan sweep must agree on the location, and a post-assembly gate
    must refuse any Mach-O left under Resources/."""

    PADDLE = ROOT / "adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/PaddleOCRRunner.swift"
    SWEEP = ROOT / "apps/hippocampus/Sources/HippocampusKit/CaptureOrphanSweep.swift"
    WORKER_SUBPATH = "Contents/OCR/HippocampusOCR"

    def test_build_app_embeds_the_worker_under_contents_ocr(self):
        script = APP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('OCR_HOME="$CONTENTS/OCR"', script)
        self.assertIn('--destination "$OCR_HOME/HippocampusOCR"', script)
        # Never back under Resources/, which is what triggers the notary flag.
        self.assertNotIn("$RESOURCES/HippocampusOCR", script)

    def test_build_app_gates_mach_o_out_of_resources(self):
        script = APP_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("Mach-O binaries found under Contents/Resources/", script)
        # The gate reads each file's Mach-O magic rather than trusting names.
        for magic in ("feedfacf", "cffaedfe", "cefaedfe", "cafebabe"):
            self.assertIn(magic, script)
        # And it requires the worker where the launcher and sweep look for it.
        self.assertIn('OCR_WORKER="$OCR_HOME/HippocampusOCR/hippocampus-ocr"', script)

    def test_launcher_and_sweep_agree_with_build_app(self):
        self.assertIn(self.WORKER_SUBPATH + "/hippocampus-ocr",
                      self.PADDLE.read_text(encoding="utf-8"))
        self.assertIn("/" + self.WORKER_SUBPATH + "/",
                      self.SWEEP.read_text(encoding="utf-8"))

    def test_no_production_source_uses_a_rejected_location(self):
        # Guard against the old location (Resources) and the tempting-but-broken
        # "fix" of a code location (Helpers). Tokens are split so this assertion
        # never matches itself.
        rejected = ["Resources/" + "HippocampusOCR", "Helpers/" + "HippocampusOCR"]
        for path in (APP_SCRIPT, self.PADDLE, self.SWEEP,
                     ROOT / "NOTICE", ROOT / "ARCHITECTURE.md"):
            text = path.read_text(encoding="utf-8")
            for token in rejected:
                self.assertNotIn(token, text, f"{path.name} references {token}")

    # --- functional outside judge: the real syspolicy_check verdict ---

    def _make_signed_probe_app(self, root, worker_parent):
        import plistlib
        app = root / "Probe.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        worker_dir = app / "Contents" / worker_parent / "HippocampusOCR"
        worker_dir.mkdir(parents=True)
        # copy (not copy2): /bin/echo carries SIP file flags that cannot be
        # reproduced on the copy; we only need the Mach-O bytes and exec bit.
        shutil.copy("/bin/echo", app / "Contents/MacOS/Probe")
        shutil.copy("/bin/echo", worker_dir / "hippocampus-ocr")
        with open(app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({
                "CFBundleExecutable": "Probe",
                "CFBundleIdentifier": "com.example.probe",
                "CFBundleName": "Probe",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
            }, handle)
        # Inside-out, then the outer bundle non-deep, exactly as build-app.sh
        # seals the real app.
        for target in (worker_dir / "hippocampus-ocr", app / "Contents/MacOS/Probe", app):
            subprocess.run(["/usr/bin/codesign", "--force", "--options=runtime", "--sign", "-",
                            str(target)], check=True, capture_output=True)
        return app

    def _incorrect_bundle_structure_findings(self, app):
        proc = subprocess.run(["/usr/bin/syspolicy_check", "notary-submission", "--json", str(app)],
                              capture_output=True, text=True)
        try:
            findings = json.loads(proc.stdout or "{}").get("output") or []
        except ValueError:
            self.skipTest("syspolicy_check did not return JSON on this host")
        return [f for f in findings if f.get("SyspolicyCheckShortError") == "Incorrect Bundle Structure"]

    @unittest.skipUnless(os.path.exists("/usr/bin/syspolicy_check"),
                         "syspolicy_check (macOS 15+) is not available")
    def test_syspolicy_flags_resources_but_accepts_contents_ocr(self):
        # Negative control: a Mach-O under Resources/ must be flagged.
        with tempfile.TemporaryDirectory(prefix="ocr-layout-res-") as temporary:
            app = self._make_signed_probe_app(Path(temporary), "Resources")
            self.assertTrue(self._incorrect_bundle_structure_findings(app),
                            "syspolicy_check must flag a Mach-O under Resources/")
        # The real location: a Mach-O under Contents/OCR/ must be clean.
        with tempfile.TemporaryDirectory(prefix="ocr-layout-ocr-") as temporary:
            app = self._make_signed_probe_app(Path(temporary), "OCR")
            self.assertEqual(self._incorrect_bundle_structure_findings(app), [],
                             "syspolicy_check must accept a Mach-O under Contents/OCR/")


if __name__ == "__main__":
    unittest.main()
