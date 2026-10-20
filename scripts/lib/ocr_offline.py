#!/usr/bin/env python3
"""Run an OCR worker with no network and check that it sends nothing.

The bundled worker carries Microsoft's official ONNX Runtime build, whose
1DS telemetry client is on by default and posts usage events and a device ID
from native code (reports/e2e, finding S1). A string scan of the binaries
can't see a client under another name, so this runs the worker itself:

  - under this check's own sandbox, which denies every network operation,
    name lookups and the account's real ~/Library, so even a worker with
    telemetry on reaches nothing and writes nothing of the person's;
  - with HOME and the working folder in a throwaway directory, where ONNX
    Runtime would keep its device ID, queue and session file;
  - on a rendered screen of text, which it must still read.

Then it reads the unified log for the worker's pid, with the storage audit's
own parser (storage_audit.py): no CFNetwork task, no connection attempt and
no sandbox refusal may appear, and nothing may be left in the throwaway
directory. The worker's first upload comes about nine seconds after it
starts, so the worker is kept running for longer than that.

The environment given to the worker leaves out ORT_DISABLE_TELEMETRY on
purpose: the launcher sets it too, and this checks what the worker does by
itself.

    ocr_offline.py --worker PATH [--hold SECONDS]   # exit 0 when it sent nothing

tools/ocr/test_offline.py runs it on the source and the frozen worker, and
scripts/release-0.3.0.sh runs it on the frozen worker before it is bundled.
"""

from __future__ import annotations

import argparse
import json
import os
import pwd
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import storage_audit  # noqa: E402  (the harness's own network checks)

SANDBOX_EXEC = "/usr/bin/sandbox-exec"


def real_home() -> str:
    """The account's home from the user database, whatever HOME says."""
    return os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)


def check_profile() -> str:
    """No network of any kind, no name lookups, and none of the real ~/Library."""
    library = real_home() + "/Library"
    return ("(version 1) (allow default) "
            "(deny network-outbound) (deny network-inbound) (deny network-bind) "
            '(deny mach-lookup (global-name "com.apple.dnssd.service")) '
            f'(deny file-read* file-write* (subpath "{library}"))')


def bitmap_of_text(lines: list[str], width: int = 1200, line_height: int = 64) -> bytes:
    """A white BGRA BMP with `lines` in black, drawn with Pillow when it is
    there; the worker's own reply format is what callers compare."""
    from PIL import Image, ImageDraw, ImageFont
    image = Image.new("RGB", (width, line_height * (len(lines) + 1)), "white")
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 28)
    for index, text in enumerate(lines):
        draw.text((40, 30 + index * line_height), text, font=font, fill="black")
    data = image.convert("RGBA").tobytes("raw", "BGRA")
    w, h = image.size
    return (struct.pack("<2sIHHI", b"BM", 54 + len(data), 0, 0, 54)
            + struct.pack("<IiiHHIIiiII", 40, w, -h, 1, 32, 0, len(data), 0, 0, 0, 0) + data)


def probe(command: list[str], frames: list[bytes], *, hold_seconds: float = 15.0,
          timeout: float = 240.0) -> dict:
    """Run `command` (a worker in --serve mode) under the check's sandbox,
    send `frames`, keep it running `hold_seconds` after the last reply, end
    it by closing its input, and say what it did."""
    # The worker runs in a throwaway folder, so a relative path is resolved here.
    command = [os.path.abspath(command[0]) if os.sep in command[0] else command[0], *command[1:]]
    scratch = Path(tempfile.mkdtemp(prefix="ocr-offline."))
    try:
        home = scratch / "home"
        cwd = scratch / "cwd"
        home.mkdir()
        cwd.mkdir()
        env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(scratch) + "/",
               "PYTHONDONTWRITEBYTECODE": "1", "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "1"}
        started = time.time()
        with open(scratch / "stderr.log", "wb") as errors:
            process = subprocess.Popen([SANDBOX_EXEC, "-p", check_profile(), *command],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                                       cwd=cwd, env=env)
        replies: list[dict] = []
        ready: dict | None = None
        # A worker that hangs is killed, so the check ends either way.
        watchdog = threading.Timer(timeout, process.kill)
        watchdog.start()
        try:
            line = process.stdout.readline()
            ready = json.loads(line) if line.strip() else None
            for frame in frames if ready else []:
                process.stdin.write(frame)
                process.stdin.flush()
                answer = process.stdout.readline()
                replies.append(json.loads(answer) if answer.strip() else {})
            time.sleep(hold_seconds)
            process.stdin.close()
            process.wait(timeout=timeout)
        except Exception:
            process.kill()
            process.wait()
            raise
        finally:
            watchdog.cancel()
            process.stdout.close()
        stderr = (scratch / "stderr.log").read_bytes().decode(errors="replace")[-400:]
        pid = process.pid
        time.sleep(1)  # the log's last lines for the pid
        programs = {pid: {os.path.basename(command[0]), os.path.basename(os.path.realpath(command[0]))}}
        network = storage_audit.read_unified_log(
            f"processID == {pid} AND " + storage_audit.NETWORK_LOG_PREDICATE, started)
        refusals = storage_audit.read_unified_log(storage_audit.SANDBOX_DENIAL_PREDICATE, started)
        activity = storage_audit.network_activity(network or [], programs)
        totals = {key: sum(found[key] for found in activity.values()) for key in ("tasks", "connections", "requests")}
        left = sorted(str(path.relative_to(scratch)) for path in scratch.rglob("*")
                      if len(path.relative_to(scratch).parts) > 1
                      and path.relative_to(scratch).parts[0] in ("home", "cwd"))
        return {
            "pid": pid,
            "exit": process.returncode,
            "stderr": stderr,
            "ready": ready,
            "replies": replies,
            "log_readable": network is not None and refusals is not None,
            "network_lines": len([e for e in network or [] if e.get("processID") == pid]),
            "tasks": totals["tasks"],
            "connections": totals["connections"],
            "requests": totals["requests"],
            "refusals": [f"{operation} {target}" for _name, _pid, operation, target in
                         storage_audit.sandbox_refusals(refusals or [], [pid])],
            "left_behind": left,
        }
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def problems(result: dict, expected_lines: list[str]) -> list[str]:
    """Why `result` is not a worker that read the screen and sent nothing."""
    found = []
    if not result["log_readable"]:
        found.append("the unified log could not be read")
    if result["ready"] != {"version": 1, "ready": True}:
        found.append(f"the worker never said it was ready (stderr: {result['stderr']!r})")
    texts = [line.get("text") for reply in result["replies"] for line in reply.get("lines", [])]
    missing = [line for line in expected_lines if line not in texts]
    if missing:
        found.append(f"it did not read {missing!r} (read {texts!r})")
    if result["exit"] != 0:
        found.append(f"it exited {result['exit']}")
    if result["tasks"] or result["connections"] or result["requests"]:
        found.append(f"it reached for the network: {result['tasks']} CFNetwork task(s), "
                     f"{result['connections']} connection attempt(s), {result['requests']} request(s) "
                     f"(unified log, pid {result['pid']})")
    if result["refusals"]:
        found.append("the sandbox refused it: " + "; ".join(result["refusals"][:5]))
    if result["left_behind"]:
        found.append("it left files behind: " + ", ".join(result["left_behind"][:6]))
    return found


EXPECTED = ["Quarterly plan for the Larkspur launch", "Send the draft to Quillfeather by Thursday"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--worker", required=True, help="the worker executable (run with --serve)")
    parser.add_argument("--hold", type=float, default=15.0, help="seconds to keep it running after its reply")
    args = parser.parse_args(argv)
    result = probe([args.worker, "--serve"], [bitmap_of_text(EXPECTED)], hold_seconds=args.hold)
    found = problems(result, EXPECTED)
    if found:
        print("FAIL ocr-offline " + "; ".join(found))
        return 1
    print(f"PASS ocr-offline the worker read the screen and sent nothing: no CFNetwork task, no connection "
          f"attempt and no sandbox refusal for pid {result['pid']} in the unified log, and nothing left behind")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
