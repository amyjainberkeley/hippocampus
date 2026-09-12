#!/usr/bin/env python3
"""Source and disposable codesign checks; never build or launch the product."""

import plistlib
import shlex
import shutil
import string
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "apps/hippocampus/Resources"
ASSEMBLY = RESOURCES / "build-app.sh"
INSTALLER = ROOT / "scripts/build-installer.sh"
APPLE_EVENTS = "com.apple.security.automation.apple-events"
APP_GROUPS = "com.apple.security.application-groups"
HARDENING_EXCEPTIONS = (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.disable-executable-page-protection",
)
OTHER_EXECUTABLES = ("mci-agent", "recall-ui", "onboarding", "hippocampus-native-host")
EXECUTABLES = ("MCICaptureHelper", *OTHER_EXECUTABLES, "Hippocampus")


def signing_commands(script):
    commands = []
    for line in script.read_text().replace("\\\n", " ").splitlines():
        if "codesign --force " not in line:
            continue
        args = shlex.split(line, comments=True)
        args = args[args.index("codesign"):]
        if Path(args[-1]).name in EXECUTABLES or args[-1] in ("$APP", "$APP_PATH"):
            commands.append(args)
    return commands


def option(args, name):
    return args[args.index(name) + 1] if name in args else None


def run(*args):
    return subprocess.run(args, check=True, capture_output=True)


class AppleEventsSigningContract(unittest.TestCase):
    def assert_hardened_entitlements(self, payload):
        for key in HARDENING_EXCEPTIONS:
            self.assertIs(payload.get(key, False), False, key)

    def helper_entitlements(self, script):
        prefix = "CAPTURE_HELPER_ENTITLEMENTS="
        assignments = [line for line in script.read_text().splitlines() if line.startswith(prefix)]
        self.assertEqual(len(assignments), 1, f"{script.name}: helper needs its own entitlement source")
        value = shlex.split(assignments[0])[0][len(prefix):]
        resolved = string.Template(value).substitute(SCRIPT_DIR=str(script.parent), REPO_ROOT=str(ROOT))
        self.assertEqual(Path(resolved), RESOURCES / "MCICaptureHelper.entitlements")
        return resolved

    def test_only_parent_and_helper_receive_apple_events(self):
        for name in ("Hippocampus", "MCICaptureHelper"):
            with self.subTest(binary=name):
                path = RESOURCES / f"{name}.entitlements"
                self.assertTrue(path.is_file(), f"missing narrowly scoped {path.name}")
                payload = plistlib.loads(path.read_bytes())
                self.assertIs(payload.get(APPLE_EVENTS), True, f"{name} must be allowed to request Automation")
                self.assert_hardened_entitlements(payload)
                if name == "MCICaptureHelper":
                    self.assertEqual({key for key, value in payload.items() if value}, {APPLE_EVENTS})
                    self.assertNotIn(APP_GROUPS, payload)
                else:
                    self.assertEqual(payload[APP_GROUPS], ["group.ai.hippocampus"])
        safari = ROOT / "extensions/safari/appex/HippocampusSafariExtension.entitlements"
        self.assertNotIn(APPLE_EVENTS, plistlib.loads(safari.read_bytes()))

    def test_purpose_explains_classification_local_memory_and_opt_in_sharing(self):
        purpose = plistlib.loads((RESOURCES / "Info.plist").read_bytes())["NSAppleEventsUsageDescription"]
        self.assertIsInstance(purpose, str)
        text = purpose.lower()
        for concept in ("url", "normal", "private", "local", "memory", "share"):
            self.assertIn(concept, text)
        self.assertRegex(text, r"opt.in|choose to share|only.*enable.*shar")
        self.assertRegex(text, r"exclude.*private|private.*exclud")
        self.assertNotIn("no page content is sent anywhere", text)

    def test_both_signing_paths_bind_entitlements_to_the_right_executables(self):
        for script, identities in ((ASSEMBLY, ("$DEVELOPER_ID", "-")), (INSTALLER, ("$DEVELOPER_ID",))):
            with self.subTest(script=script.name, contract="helper source"):
                self.helper_entitlements(script)
            for identity in identities:
                commands = [args for args in signing_commands(script) if option(args, "--sign") == identity]
                with self.subTest(script=script.name, identity=identity):
                    self.assertEqual(len(commands), len(EXECUTABLES) + 1)
                for args in commands:
                    target = args[-1]
                    with self.subTest(script=script.name, identity=identity, target=target):
                        self.assertNotIn("--deep", args)
                        self.assertFalse(any(arg.startswith("--preserve-metadata") for arg in args))
                        if identity == "$DEVELOPER_ID":
                            self.assertIn("--options=runtime", args)
                            self.assertIn("--timestamp", args)
                        if target.endswith("/MCICaptureHelper"):
                            self.assertEqual(option(args, "--entitlements"), "$CAPTURE_HELPER_ENTITLEMENTS")
                        elif target.endswith("/Hippocampus") or target in ("$APP", "$APP_PATH"):
                            self.assertEqual(option(args, "--entitlements"), "$ENTITLEMENTS")
                        else:
                            self.assertIsNone(option(args, "--entitlements"))

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign")
    def test_assembly_and_installer_signatures_preserve_the_contract(self):
        for identity in ("$DEVELOPER_ID", "-"):
            with self.subTest(identity=identity), tempfile.TemporaryDirectory(prefix="hippocampus-apple-events.") as temp:
                scratch = Path(temp)
                app = scratch / "Hippocampus.app"
                macos = app / "Contents/MacOS"
                macos.mkdir(parents=True)
                shutil.copyfile(RESOURCES / "Info.plist", app / "Contents/Info.plist")
                for executable in EXECUTABLES:
                    shutil.copy("/usr/bin/true", macos / executable)
                entitlements = scratch / "Hippocampus.entitlements"
                group = "A1B2C3D4E5.ai.hippocampus" if identity == "$DEVELOPER_ID" else "group.ai.hippocampus"
                run("bash", "-c", 'source "$1"; hippocampus_render_app_group_entitlements "$2" "$3" "$4"',
                    "contract-test", str(ROOT / "scripts/lib/app-group-contract.sh"),
                    str(RESOURCES / "Hippocampus.entitlements"), str(entitlements), group)
                for script in (ASSEMBLY, INSTALLER):
                    with self.subTest(stage=script.name):
                        # Use the real signing argv with a disposable identity and no timestamp service.
                        variables = dict(APP=str(app), APP_PATH=str(app), MACOS=str(macos), DEVELOPER_ID="-",
                                         ENTITLEMENTS=str(entitlements))
                        commands = [args for args in signing_commands(script) if option(args, "--sign") == identity]
                        if any("$CAPTURE_HELPER_ENTITLEMENTS" in args for args in commands):
                            variables["CAPTURE_HELPER_ENTITLEMENTS"] = self.helper_entitlements(script)
                        for args in commands:
                            expanded = [string.Template(arg).substitute(variables) for arg in args]
                            expanded = ["--timestamp=none" if arg == "--timestamp" else arg for arg in expanded]
                            run(*expanded)
                        run("codesign", "--verify", "--deep", "--strict", str(app))
                        for name in (*EXECUTABLES, "Hippocampus.app"):
                            code = app if name == "Hippocampus.app" else macos / name
                            # Match the existing App Group check's macOS 14-compatible XML output.
                            signed = run("codesign", "-d", "--entitlements", ":-", str(code)).stdout
                            with self.subTest(signed=name):
                                payload = plistlib.loads(signed) if signed.strip() else {}
                                self.assert_hardened_entitlements(payload)
                                if name in ("Hippocampus", "Hippocampus.app", "MCICaptureHelper"):
                                    self.assertIs(payload.get(APPLE_EVENTS), True, f"{name}: signed Automation entitlement missing")
                                else:
                                    self.assertNotIn(APPLE_EVENTS, payload)
                                if name in ("Hippocampus", "Hippocampus.app"):
                                    self.assertEqual(payload.get(APP_GROUPS), [group])
                                else:
                                    self.assertNotIn(APP_GROUPS, payload)
                                if identity == "$DEVELOPER_ID":
                                    details = run("codesign", "-d", "--verbose=4", str(code)).stderr
                                    self.assertRegex(details, rb"flags=.*\bruntime\b")


if __name__ == "__main__":
    unittest.main(verbosity=2)
