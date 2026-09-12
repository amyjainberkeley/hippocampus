#!/usr/bin/env python3
"""Exercise the actual clean-home brief gate with isolated command fixtures."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


E2E = Path(__file__).resolve().with_name("e2e-clean-home.sh")
TODAY = "2026-09-07"
WORKER_BRIEFS = {
    TODAY: {"author": "today-worker", "evidence": [21]},
    "2026-09-06": {"author": "scheduled-worker", "evidence": [1, 2]},
}


class BriefGateTests(unittest.TestCase):
    def run_gate(self, *, rows=None, enrich_exit=0, seed_exit=0,
                 duplicate_exit=15, duplicate_message="already exists"):
        source = E2E.read_text(encoding="utf-8")
        body = source.split('step "Derive episodes and seed the brief surface"', 1)[1]
        body = body.split('step "Exercise search, timeline, episodes, and cited agent context over MCP"', 1)[0]
        with tempfile.TemporaryDirectory(prefix="clean-home-brief-gate-") as temporary:
            root = Path(temporary)
            state = root / "briefs.json"
            state.write_text(json.dumps(rows or {}), encoding="utf-8")
            config = {"enrich_exit": enrich_exit, "seed_exit": seed_exit,
                      "duplicate_exit": duplicate_exit, "duplicate_message": duplicate_message}
            (root / "config.json").write_text(json.dumps(config), encoding="utf-8")
            command = f"#!{sys.executable}\n" + '''
import json
from pathlib import Path
import sys

root = Path(__file__).parent
name = Path(sys.argv[0]).name
args = sys.argv[1:]
config = json.loads((root / "config.json").read_text())
with (root / "calls.jsonl").open("a") as handle:
    handle.write(json.dumps({"name": name, "args": args}) + "\\n")
if name == "agent":
    assert args == ["enrich", "--db-path", str(root / "mci.sqlite"), "--batch-size", "32"]
    sys.exit(config["enrich_exit"])
assert len(args) == 2 and args[0] == "--date", args
if config["seed_exit"]:
    sys.exit(config["seed_exit"])
state = root / "briefs.json"
rows = json.loads(state.read_text())
date = args[1]
if date in rows:
    print(config["duplicate_message"], file=sys.stderr)
    sys.exit(config["duplicate_exit"])
rows[date] = {"author": "synthetic-fixture", "evidence": []}
state.write_text(json.dumps(rows))
'''
            for name in ("agent", "seed-brief"):
                path = root / name
                path.write_text(command, encoding="utf-8")
                path.chmod(0o755)
            # This gate only uses the shared grep-compatible `-q PATTERN FILE` form.
            (root / "rg").symlink_to(shutil.which("grep"))
            prelude = f'date() {{ printf "%s\\n" "{TODAY}"; }}\n'
            prelude += 'fail() { printf "FAIL: %s\\n" "$1" >&2; exit 1; }\n'
            result = subprocess.run(
                ["/bin/bash", "-euc", prelude + body],
                env={"HOME": str(root), "PATH": f"{root}:/usr/bin:/bin",
                     "CLEAN_ROOT": str(root), "DB_PATH": str(root / "mci.sqlite"),
                     "AGENT": str(root / "agent"), "SEED_BRIEF": str(root / "seed-brief")},
                capture_output=True, text=True, timeout=10,
            )
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            return result, calls, json.loads(state.read_text())

    def assert_seeded_once(self, calls):
        self.assertEqual([call["name"] for call in calls], ["agent", "seed-brief", "seed-brief"])
        self.assertEqual(calls[1]["args"], calls[2]["args"])
        self.assertEqual(len(calls[1]["args"]), 2)
        self.assertEqual(calls[1]["args"][0], "--date")
        return calls[1]["args"][1]

    def test_worker_briefs_do_not_collide_with_synthetic_seed(self):
        result, calls, rows = self.run_gate(rows=WORKER_BRIEFS)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fixture_date = self.assert_seeded_once(calls)
        self.assertNotIn(fixture_date, WORKER_BRIEFS)
        self.assertEqual({date: rows[date] for date in WORKER_BRIEFS}, WORKER_BRIEFS)
        self.assertEqual(set(rows), {*WORKER_BRIEFS, fixture_date})

    def test_empty_brief_store_still_seeds_and_checks_duplicate(self):
        result, calls, rows = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fixture_date = self.assert_seeded_once(calls)
        self.assertEqual(set(rows), {fixture_date})

    def test_enrich_failure_stops_before_seeding(self):
        result, calls, rows = self.run_gate(enrich_exit=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual([call["name"] for call in calls], ["agent"])
        self.assertEqual(rows, {})

    def test_custody_and_store_failures_are_not_accepted_as_duplicates(self):
        for status in (9, 10, 13):
            with self.subTest(status=status):
                result, calls, rows = self.run_gate(seed_exit=status)
                self.assertEqual(result.returncode, status)
                self.assertEqual([call["name"] for call in calls], ["agent", "seed-brief"])
                self.assertEqual(rows, {})

    def test_successful_duplicate_write_is_fatal(self):
        result, calls, _ = self.run_gate(duplicate_exit=0)
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate brief write unexpectedly succeeded", result.stderr)
        self.assert_seeded_once(calls)

    def test_unrelated_duplicate_error_is_fatal(self):
        result, calls, _ = self.run_gate(duplicate_exit=13, duplicate_message="brain open failed")
        self.assertEqual(result.returncode, 1)
        self.assertIn("brief readback did not find the seeded row", result.stderr)
        self.assert_seeded_once(calls)


if __name__ == "__main__":
    unittest.main()
