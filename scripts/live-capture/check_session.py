#!/usr/bin/env python3
"""Fail closed unless stdin describes this user's unlocked console session."""

from __future__ import annotations

import argparse
import plistlib
import sys
from typing import Any


def fail(message: str, code: int) -> int:
    print(f"session preflight failed: {message}", file=sys.stderr)
    return code


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the IORegistry console-session plist from stdin."
    )
    parser.add_argument("--expected-uid", type=int, required=True)
    parser.add_argument("--expected-user", required=True)
    return parser.parse_args()


def plist_root(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        return value
    if isinstance(value, list) and len(value) == 1 and isinstance(value[0], dict):
        return value[0]
    return None


def main() -> int:
    args = parse_args()
    try:
        raw = plistlib.loads(sys.stdin.buffer.read())
    except Exception as error:  # plistlib reports several parse exception types.
        return fail(f"could not parse IORegistry session data: {error}", 2)

    root = plist_root(raw)
    if root is None:
        return fail("IORegistry returned an unexpected root shape", 2)

    sessions = root.get("IOConsoleUsers")
    if not isinstance(sessions, list):
        return fail("IOConsoleUsers is missing", 2)

    console_sessions = [
        session
        for session in sessions
        if isinstance(session, dict)
        and session.get("kCGSSessionOnConsoleKey") is True
    ]
    if len(console_sessions) != 1:
        return fail(
            f"expected exactly one active console session, found {len(console_sessions)}",
            3,
        )

    session = console_sessions[0]
    if root.get("IOConsoleLocked") is True or session.get(
        "CGSSessionScreenIsLocked"
    ) is True:
        return fail("the screen is locked; unlock this Mac and run again", 4)

    if session.get("kCGSessionLoginDoneKey") is not True:
        return fail("the console login has not completed", 4)

    actual_uid = session.get("kCGSSessionUserIDKey")
    actual_user = session.get("kCGSSessionUserNameKey")
    if actual_uid != args.expected_uid or actual_user != args.expected_user:
        return fail(
            "the active console session does not belong to the invoking user "
            f"(expected {args.expected_user}/{args.expected_uid}, "
            f"found {actual_user}/{actual_uid})",
            5,
        )

    print(f"unlocked console session: user={actual_user} uid={actual_uid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
