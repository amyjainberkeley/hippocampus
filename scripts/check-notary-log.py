#!/usr/bin/env python3
"""Require a clean notarization log: Apple accepted the submission and listed
no issues at all, not even warnings (launch gate D1).

    check-notary-log.py [--archive NAME] LOG

LOG is what `xcrun notarytool log <id> LOG` saves. With --archive, the log
must also be for the file of that name. Prints one line when the log is
clean; otherwise prints every problem, each issue with its severity, path
and message, and exits 1.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def problems(log_path: Path, archive: str | None) -> list[str]:
    try:
        log = json.loads(log_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as error:
        return [f"cannot read the notary log: {error}"]
    if not isinstance(log, dict):
        return ["the notary log is not a JSON object"]

    found: list[str] = []
    if log.get("status") != "Accepted":
        found.append(f"status is {log.get('status')!r}, not 'Accepted'")
    if log.get("statusCode") != 0:
        found.append(f"statusCode is {log.get('statusCode')!r}, not 0")
    if archive is not None and log.get("archiveFilename") != archive:
        found.append(f"the log is for {log.get('archiveFilename')!r}, not {archive!r}")

    issues = log.get("issues")
    if issues is not None and not isinstance(issues, list):
        found.append(f"issues is {type(issues).__name__}, not a list")
    for issue in issues if isinstance(issues, list) else []:
        if isinstance(issue, dict):
            found.append(
                f"{issue.get('severity', 'issue')}: {issue.get('path', '?')}: "
                f"{issue.get('message', '(no message)')}"
            )
        else:
            found.append(f"issue: {issue!r}")

    tickets = log.get("ticketContents")
    if not isinstance(tickets, list) or not tickets:
        found.append("the ticket covers no signed code")
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--archive", help="the submitted file's name, which the log must name")
    parser.add_argument("log", type=Path)
    args = parser.parse_args()

    found = problems(args.log, args.archive)
    if found:
        print(f"Notary log {args.log} is not clean:", file=sys.stderr)
        for problem in found:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    log = json.loads(args.log.read_text(encoding="utf-8"))
    print(
        f"Notary log clean: {log.get('archiveFilename')} accepted with no issues, "
        f"{len(log['ticketContents'])} signed items in the ticket"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
