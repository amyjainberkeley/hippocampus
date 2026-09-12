#!/usr/bin/env python3
"""Audit tracked Cargo lockfiles locally and emit JSON, including scanner errors."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import re


ROOT = Path(__file__).resolve().parent.parent
# Existing no-patch waiver. Keep it visible in reports; see the dated audit.
IGNORED_ADVISORIES = ["RUSTSEC-2024-0436"]


def run(args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=180)


def scan(lockfile):
    result = {"lockfile": lockfile, "status": "error"}
    if not (ROOT / lockfile).is_file():
        return {**result, "error": "Tracked lockfile is missing"}
    result["sha256"] = hashlib.sha256((ROOT / lockfile).read_bytes()).hexdigest()
    command = ["cargo", "audit", "--json", "--deny", "warnings", "--file", lockfile]
    for advisory in IGNORED_ADVISORIES:
        command.extend(["--ignore", advisory])
    try:
        completed = run(command)
        result.update(exit_code=completed.returncode, stderr=completed.stderr.strip())
        report = json.loads(completed.stdout)
        # A zero exit without a complete report is not scan evidence.
        if not (
            isinstance(report, dict)
            and isinstance(report.get("database"), dict)
            and report["database"].get("last-commit")
            and isinstance(report.get("lockfile"), dict)
            and isinstance(report["lockfile"].get("dependency-count"), int)
            and isinstance(report.get("vulnerabilities"), dict)
            and isinstance(report["vulnerabilities"].get("found"), bool)
            and isinstance(report["vulnerabilities"].get("list"), list)
            and isinstance(report.get("warnings"), dict)
        ):
            raise ValueError("Incomplete cargo-audit JSON report")
        result["report"] = report
        result["status"] = "pass" if completed.returncode == 0 else "fail"
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        result["error"] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-tag", help="Require HEAD and tracked sources to match this tag")
    parser.add_argument("--require-version", help="Require this exact cargo-audit version")
    args = parser.parse_args()
    report = {
        "schema_version": 1,
        "check": "cargo-audit",
        "status": "error",
        "ignored_advisories": IGNORED_ADVISORIES,
        "scans": [],
    }
    try:
        if args.release_tag:
            if not re.fullmatch(r"v[0-9][A-Za-z0-9.+_-]*", args.release_tag):
                raise ValueError("Invalid release tag; expected a version tag beginning with v")
            head = run(["git", "rev-parse", "--verify", "HEAD^{commit}"])
            tagged = run(["git", "rev-parse", "--verify", f"refs/tags/{args.release_tag}^{{commit}}"])
            if head.returncode or tagged.returncode or head.stdout.strip() != tagged.stdout.strip():
                raise ValueError("Release tag does not identify the checked-out commit")
            if run(["git", "diff", "--quiet", "HEAD", "--"]).returncode != 0:
                raise ValueError("Release checkout has changed tracked sources")
            report.update(source_commit=head.stdout.strip(), release_tag=args.release_tag)
        try:
            capability = run(["cargo", "audit", "--version"])
        except FileNotFoundError:
            report["status"] = "unsupported"
            raise ValueError("cargo is unavailable; no dependency scan ran") from None
        if capability.returncode != 0:
            report["status"] = "unsupported"
            report["stderr"] = capability.stderr.strip()
            raise ValueError("cargo audit is unavailable; no dependency scan ran")
        report["tool_version"] = capability.stdout.strip()
        accepted_versions = {
            f"cargo-audit {args.require_version}",
            f"cargo-audit-audit {args.require_version}",
        }
        if args.require_version and report["tool_version"] not in accepted_versions:
            report["status"] = "unsupported"
            raise ValueError(f"Expected cargo-audit {args.require_version}; no dependency scan ran")
        tracked = run(["git", "ls-files", "-z", "--", "Cargo.lock", "**/Cargo.lock"])
        if tracked.returncode != 0:
            raise ValueError("Cannot enumerate tracked lockfiles: " + tracked.stderr.strip())
        lockfiles = sorted({"Cargo.lock", *filter(None, tracked.stdout.split("\0"))})
        report["scans"] = [scan(lockfile) for lockfile in lockfiles]
        report["status"] = "pass" if all(item["status"] == "pass" for item in report["scans"]) else "fail"
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        report["error"] = str(error)
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
