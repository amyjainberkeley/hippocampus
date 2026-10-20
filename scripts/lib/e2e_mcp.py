#!/usr/bin/env python3
"""Talk to `mci-agent mcp-serve` over stdio the way an AI tool does.

Development and test only; `scripts/e2e-full.sh` uses it.

    e2e_mcp.py --out RESPONSES.jsonl [--timeout S] -- COMMAND [ARGS...] < REQUESTS.jsonl

Sends every JSON-RPC request read from stdin, keeps the server's stdin open
until each request with an id has its response (or the timeout passes), then
closes it and waits for the server to exit. Responses are written one per
line. The environment is passed through unchanged; the caller builds it.
Exit status: 0 when every request was answered, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no server command")

    requests = [json.loads(line) for line in sys.stdin if line.strip()]
    wanted = {request["id"] for request in requests if "id" in request}
    server = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
        text=True, bufsize=1,
    )
    answered: dict[int, dict] = {}
    lines: list[str] = []
    done = threading.Event()

    def read() -> None:
        assert server.stdout is not None
        for line in server.stdout:
            if not line.strip():
                continue
            lines.append(line if line.endswith("\n") else line + "\n")
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict) and value.get("id") in wanted:
                answered[value["id"]] = value
                if wanted.issubset(answered):
                    done.set()
        done.set()

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    assert server.stdin is not None
    for request in requests:
        server.stdin.write(json.dumps(request) + "\n")
        server.stdin.flush()
    deadline = time.monotonic() + args.timeout
    while not done.is_set() and time.monotonic() < deadline:
        done.wait(0.2)
    try:
        server.stdin.close()
    except OSError:
        pass
    try:
        server.wait(timeout=30)
    except subprocess.TimeoutExpired:
        server.terminate()
        server.wait(timeout=10)
    reader.join(timeout=5)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.writelines(lines)
    missing = sorted(wanted - set(answered))
    if missing:
        print(f"e2e_mcp: no response for ids {missing}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
