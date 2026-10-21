#!/usr/bin/env python3
"""Watch one test run's own processes: network sockets and files outside it.

Development and test only. `scripts/e2e-full.sh` starts it in the background;
`scripts/audit-storage-security.sh` reads what it wrote.

Every interval it lists the processes descended from --root-pid (the test
run itself, never anything else on the Mac, and never this sampler), and asks
`lsof -i` whether any of them holds an internet socket. Every few intervals it
also lists the regular files those processes have open outside --run-root and
outside the system's own folders, so a write outside the throwaway home is
seen by path. It records process names and paths only, never file contents.

Output, in --out-dir:
  net.log            one line per internet socket seen (lsof's own fields)
  processes.log      pid, parent, program name and command line of each process
  outside-files.log  files open outside the run: pid, program, path
  ocr-sandbox.log    for each running OCR worker (hippocampus-ocr), what the
                     kernel says of it: pid, program, sandboxed, and whether
                     network-outbound and network-bind are denied (1 or 0),
                     one line per pid each time that changes
  summary.json       samples taken, processes watched, sockets seen
It stops when --stop-file disappears.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import subprocess
import time
from pathlib import Path

SYSTEM_PREFIXES = (
    "/System/", "/usr/", "/Library/", "/private/var/db/", "/dev/",
    "/Applications/Xcode.app/", "/opt/homebrew/", "/usr/local/",
    "/private/var/folders/",  # recorded separately below
)


def process_table() -> dict[int, tuple[int, str]]:
    """pid -> (parent, executable path), from ps's comm column (no arguments)."""
    output = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,comm="],
        capture_output=True, text=True, check=False,
    ).stdout
    table: dict[int, tuple[int, str]] = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        table[pid] = (ppid, parts[2] if len(parts) > 2 else "")
    return table


def command_line(pid: int) -> str:
    return subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                          capture_output=True, text=True, check=False).stdout.strip()


def descendants(table: dict[int, tuple[int, str]], root: int, exclude: int) -> list[int]:
    children: dict[int, list[int]] = {}
    for pid, (ppid, _command) in table.items():
        children.setdefault(ppid, []).append(pid)
    found: list[int] = []
    queue = [root]
    while queue:
        parent = queue.pop()
        for child in children.get(parent, []):
            if child == exclude:
                continue  # the sampler and everything it runs
            found.append(child)
            queue.append(child)
    return found


# The OCR worker runs inside a no-network sandbox (OCRWorkerSandbox). The
# kernel answers for a running process whether it is sandboxed and whether an
# operation is denied to it: sandbox_check(pid, operation, flags). The flags
# carry SANDBOX_CHECK_NO_REPORT, so asking leaves no violation report in the
# unified log, where it would read as an attempt by the worker.
OCR_WORKER_NAME = "hippocampus-ocr"


def sandbox_checker():
    try:
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        check = library.sandbox_check
        no_report = ctypes.c_int.in_dll(library, "SANDBOX_CHECK_NO_REPORT").value
    except (OSError, AttributeError, ValueError):
        return None
    check.restype = ctypes.c_int
    check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    return lambda pid, operation: check(pid, operation, no_report)


def sandbox_state(check, pid: int) -> tuple[int, int, int] | None:
    """(sandboxed, network-outbound denied, network-bind denied), each 1 or 0,
    or None when the process is gone or the kernel won't say."""
    if check is None:
        return None
    answers = (check(pid, None), check(pid, b"network-outbound"), check(pid, b"network-bind"))
    if any(answer not in (0, 1) for answer in answers):
        return None
    return answers


def lsof(arguments: list[str]) -> str:
    return subprocess.run(
        ["/usr/sbin/lsof", *arguments], capture_output=True, text=True, check=False,
    ).stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root-pid", type=int, required=True)
    parser.add_argument("--run-root", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--allow", action="append", default=[],
                        help="a folder the run is expected to read from (the checkout, the app)")
    args = parser.parse_args()

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    run_root = os.path.realpath(args.run_root) + "/"
    temp_roots = []
    for name in ("DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"):
        value = subprocess.run(["/usr/bin/getconf", name], capture_output=True, text=True).stdout.strip()
        if value:
            temp_roots.append(os.path.realpath(value) + "/")
    allowed = tuple(os.path.realpath(path) + "/" for path in args.allow)
    allowed_exact = {os.path.realpath(path) for path in args.allow}
    me = os.getpid()
    samples = 0
    sockets = 0
    watched: dict[int, str] = {}
    outside: set[str] = set()
    check = sandbox_checker()
    sandboxes: dict[int, tuple[int, int, int]] = {}
    with open(out / "net.log", "a", encoding="utf-8") as net, \
         open(out / "processes.log", "a", encoding="utf-8") as processes, \
         open(out / "ocr-sandbox.log", "a", encoding="utf-8") as ocr_sandbox:
        while os.path.exists(args.stop_file):
            table = process_table()
            pids = descendants(table, args.root_pid, me)
            samples += 1
            for pid in pids:
                # A new process, or one that exec'd into another program (a
                # wrapper that becomes the worker): one line per name.
                if watched.get(pid) != table[pid][1]:
                    watched[pid] = table[pid][1]
                    # pid, parent, program name, command line
                    processes.write(f"{pid}\t{table[pid][0]}\t{os.path.basename(table[pid][1])}\t{command_line(pid)}\n")
                    processes.flush()
                if os.path.basename(table[pid][1]) == OCR_WORKER_NAME:
                    state = sandbox_state(check, pid)
                    if state is not None and sandboxes.get(pid) != state:
                        sandboxes[pid] = state
                        ocr_sandbox.write(f"{pid}\t{OCR_WORKER_NAME}\t" + "\t".join(map(str, state)) + "\n")
                        ocr_sandbox.flush()
            if pids:
                listing = lsof(["-nP", "-a", "-i", "-p", ",".join(map(str, pids))])
                for line in listing.splitlines()[1:]:
                    sockets += 1
                    net.write(f"{time.time():.3f}\t{line}\n")
                    net.flush()
                if samples % 5 == 1:
                    files = lsof(["-nP", "-a", "-p", ",".join(map(str, pids)), "-Fpn"])
                    owner = ""
                    for line in files.splitlines():
                        if line.startswith("p"):
                            pid = int(line[1:]) if line[1:].isdigit() else 0
                            owner = f"{pid}\t{os.path.basename(table.get(pid, (0, ''))[1])}"
                            continue
                        if not line.startswith("n/"):
                            continue
                        path = os.path.realpath(line[1:])
                        if path.startswith(run_root) or path.startswith(allowed) or path in allowed_exact:
                            continue
                        if any(path.startswith(prefix) for prefix in temp_roots):
                            outside.add(f"{owner}\t{path}")
                            continue
                        if path.startswith(SYSTEM_PREFIXES):
                            continue
                        outside.add(f"{owner}\t{path}")
            time.sleep(args.interval)
    (out / "outside-files.log").write_text("".join(f"{path}\n" for path in sorted(outside)), encoding="utf-8")
    (out / "summary.json").write_text(json.dumps({
        "samples": samples,
        "processes_watched": len(watched),
        "internet_sockets_seen": sockets,
        "files_outside_run": len(outside),
    }, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
