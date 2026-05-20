#!/usr/bin/env bash
# SPDX-License-Identifier: TBD-private
#
# step2_run.sh — interactive runbook for the Track B · Step-2 §7 corpus
# live verification on the human's Mac. Eliminates the test-execution
# timing variance that ate v3 / v4 / v5 attempts (sudo cache, missed
# helper window, ProbeHarness not focused, FairPlay not full-screen).
#
# Read-only with respect to the helper / cascade / pipeline / probe
# code. Drives `mci-capture-helper`, the user, and `wire_decode.py`
# from a single shell so paper-log timing isn't done by hand.
#
# Usage:
#   tools/step2_run.sh [--skip-sudo] [--skip-harness] [--skip-fairplay]
#                      [output-bin-path]
#
#   --skip-sudo       skip the §3 sudo trigger window (no password prompt)
#   --skip-harness    skip the §4 ProbeHarness trigger window
#   --skip-fairplay   skip the §2 FairPlay trigger window
#   output-bin-path   Optional; defaults to /tmp/mci-step2-runbook.bin .
#                     The .stderr + .footprint.csv companions live next to it.
#
# v6-run hardening (2026-05-20):
#   - Trap on EXIT/INT/TERM cleans up helper + caffeinate + harness +
#     footprint sampler. Ctrl-C in the middle of the run now still
#     produces a wire decode + summary instead of leaving a zombie helper.
#   - Caffeinate is killed explicitly (it holds the helper otherwise;
#     Ctrl-C on the script alone was leaving PID 19370 alive on v6).
#   - Skip flags for re-runs targeted at a single §-layer.
#   - Helper banner timeout extended to 20s (debug builds can be slow).
#
# What this script does NOT do:
#   - It does NOT make any privacy/cascade decision; the decoder
#     verdict is informational. Phase 1→2 gate is the human CEO's
#     call after reading the wire histogram + actuals (Amendment 1 §2).
#   - It does NOT auto-pass / auto-flip / auto-merge anything.
#     `--capture` stays default-OFF in source per Amendment 1 §4.
#   - It does NOT touch protected-set code. Pure orchestrator.
#
# Sequencing (T0 = the moment the helper's "Starting live session…"
# banner appears on stderr; we WAIT for that banner before starting
# the timer):
#
#   T+ 0– 5s : warm-up
#   T+ 5–20s : §3 trigger — sudo -v (script prompts; you type pw)
#   T+20–55s : §4 trigger — ProbeHarness focused (script launches it;
#              you click into the masked field and HOLD a key for
#              autorepeat so screen pixels keep changing → cascade
#              floor + heartbeat both produce signal)
#   T+55–115s: §2 trigger — Apple TV.app, full-screen FairPlay
#              playback (script launches; you click Play + ⌃⌘F + leave
#              mouse still; 60s window)
#   T+115s   : stop helper (script kills it cleanly via trap)
#   T+116s   : auto-decode + render verdict
#
# Caffeinate is wrapped around the helper so the Mac can't nap mid-run.
# A footprint_measure.sh sampler is launched in parallel; its CSV is
# saved next to the bin so the same run produces a soft footprint
# pre-read (NOT a G2 verdict — that's a separate real-workday run).

set -euo pipefail

# Parse flags --------------------------------------------------------

SKIP_SUDO=0
SKIP_HARNESS=0
SKIP_FAIRPLAY=0
OUT_BIN_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-sudo)     SKIP_SUDO=1; shift ;;
    --skip-harness)  SKIP_HARNESS=1; shift ;;
    --skip-fairplay) SKIP_FAIRPLAY=1; shift ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    -*)
      echo "step2_run: unknown flag $1" >&2
      exit 2
      ;;
    *)
      OUT_BIN_ARG="$1"; shift
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/adapters/macos/MCICaptureHelper/.build/debug/mci-capture-helper"
HARNESS="$REPO_ROOT/tools/probe-harness/.build/debug/ProbeHarness"
DECODER="$REPO_ROOT/tools/wire_decode.py"
FOOTPRINT="$REPO_ROOT/tools/footprint_measure.sh"

OUT_BIN="${OUT_BIN_ARG:-/tmp/mci-step2-runbook.bin}"
OUT_ERR="${OUT_BIN%.bin}.stderr"
OUT_CSV="${OUT_BIN%.bin}.footprint.csv"

# PID tracking — populated as we spawn things; cleanup() reads them.
CAFFEINATE_PID=""
HELPER_PID=""
REAL_HELPER_PID=""
HARNESS_PID=""
FOOTPRINT_PID=""
CLEANUP_RAN=0

# Cleanup ------------------------------------------------------------
#
# Trap-driven idempotent shutdown. Kills caffeinate (which would
# otherwise hold the helper alive after we SIGINT the helper), then
# the helper itself, then the harness + footprint sampler. Then runs
# the wire decode + summary so even a Ctrl-C mid-run produces a
# usable report.

cleanup() {
  # Guard against double-run (EXIT + INT both trigger).
  if [ "$CLEANUP_RAN" = "1" ]; then return; fi
  CLEANUP_RAN=1

  echo
  echo "==> step2_run: cleanup (stopping spawned processes)"

  # Kill the helper first. caffeinate -dis "$HELPER" makes caffeinate
  # the parent; killing only caffeinate would not signal the helper.
  # SIGINT lets the helper close its sink and flush the last frame.
  for pid in "$REAL_HELPER_PID" "$HELPER_PID"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -INT "$pid" 2>/dev/null || true
    fi
  done

  # Give helper ≤ 3s to flush + exit gracefully.
  for _ in 1 2 3 4 5 6; do
    if [ -n "$REAL_HELPER_PID" ] && kill -0 "$REAL_HELPER_PID" 2>/dev/null; then
      sleep 0.5
    else
      break
    fi
  done

  # Force-kill caffeinate (it would otherwise keep the Mac awake AND
  # hold a parent slot the shell is waiting on).
  if [ -n "$CAFFEINATE_PID" ] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
    kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    sleep 0.3
    kill -KILL "$CAFFEINATE_PID" 2>/dev/null || true
  fi

  # Last-resort helper kill if still alive (rare, but Ctrl-C right
  # after launch sometimes leaves it lingering).
  if [ -n "$REAL_HELPER_PID" ] && kill -0 "$REAL_HELPER_PID" 2>/dev/null; then
    kill -KILL "$REAL_HELPER_PID" 2>/dev/null || true
  fi

  # Belt-and-suspenders: any mci-capture-helper this script launched.
  # `--capture` is dev-only and shouldn't be running elsewhere; killing
  # by full-command match is safe here.
  pkill -INT -f "mci-capture-helper --capture --probe-debug" 2>/dev/null || true

  # Harness + footprint sampler.
  if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" 2>/dev/null; then
    kill -TERM "$HARNESS_PID" 2>/dev/null || true
  fi
  if [ -n "$FOOTPRINT_PID" ] && kill -0 "$FOOTPRINT_PID" 2>/dev/null; then
    kill -TERM "$FOOTPRINT_PID" 2>/dev/null || true
  fi

  # Decode + summary if we got any bytes on the wire. Auto-decode even
  # on interrupt — that's the v6 lesson: Ctrl-C should not lose the
  # observation report.
  if [ -s "$OUT_BIN" ]; then
    echo
    echo "================================================================"
    echo "==> step2_run: wire decode (post-cleanup)"
    echo "================================================================"
    python3 "$DECODER" "$OUT_BIN" || true

    echo
    echo "================================================================"
    echo "==> step2_run: stderr summary"
    echo "================================================================"
    echo "callback alive:               $(grep -c 'callback alive' "$OUT_ERR" 2>/dev/null || true)"
    echo "probe-debug lines:            $(grep -c 'probe(ax-subrole)' "$OUT_ERR" 2>/dev/null || true)"
    echo "mci-probe-harness focused:    $(grep -c 'mci-probe-harness' "$OUT_ERR" 2>/dev/null || true)"
    echo "TV.app focused:               $(grep -c 'title=TV' "$OUT_ERR" 2>/dev/null || true)"
    echo "positive backstop signals:    $(grep -cE 'descendant=pos|value-hidden=pos|id-regex=pos' "$OUT_ERR" 2>/dev/null || true)"

    if [ -s "$OUT_CSV" ]; then
      echo
      echo "================================================================"
      echo "==> step2_run: footprint pre-read (soft, NOT a G2 verdict)"
      echo "================================================================"
      python3 - <<PY "$OUT_CSV" || true
import csv
import statistics
import sys

path = sys.argv[1]
rss = []
cpu = []
with open(path) as f:
    r = csv.DictReader(f)
    for row in r:
        try:
            rss.append(int(row["rss_kb"]))
            cpu.append(float(row["cpu_pct"]))
        except (ValueError, KeyError):
            continue
if not rss:
    print("  no samples")
else:
    n = len(rss)
    rss_p50 = statistics.median(rss)
    rss_max = max(rss)
    cpu_p50 = statistics.median(cpu)
    cpu_max = max(cpu)
    print(f"  samples: {n}")
    print(f"  rss_kb   median={rss_p50:>8.0f}  max={rss_max:>8.0f}   (budget: <= 256000 ≡ 250 MB)")
    print(f"  cpu_pct  median={cpu_p50:>8.2f}  max={cpu_max:>8.2f}   (budget: sustained <= 2.0%)")
    print(f"  NOTE: soft pre-read. G2 = separate real-workday measurement")
    print(f"  (HUMAN-ONLY per AGENT_PROTOCOL §4 / §9).")
PY
    fi
  else
    echo "    (no wire bytes captured; nothing to decode)"
  fi

  echo
  echo "==> step2_run: outputs"
  echo "    wire bin:        $OUT_BIN"
  echo "    helper stderr:   $OUT_ERR"
  echo "    footprint csv:   $OUT_CSV"
}

trap cleanup EXIT INT TERM

# Pre-flight checks --------------------------------------------------

echo "==> step2_run: pre-flight"
[ "$SKIP_SUDO" = "1" ]     && echo "    flag: --skip-sudo  (§3 window will be skipped)"
[ "$SKIP_HARNESS" = "1" ]  && echo "    flag: --skip-harness (§4 window will be skipped)"
[ "$SKIP_FAIRPLAY" = "1" ] && echo "    flag: --skip-fairplay (§2 window will be skipped)"

if ! command -v caffeinate >/dev/null 2>&1; then
  echo "step2_run: caffeinate not available (macOS-only)" >&2
  exit 1
fi

if [ ! -x "$HELPER" ]; then
  echo "step2_run: helper binary missing at $HELPER" >&2
  echo "step2_run: build with:"
  echo "  cd $REPO_ROOT/adapters/macos/MCICaptureHelper && swift build -c debug"
  exit 1
fi

if [ "$SKIP_HARNESS" != "1" ] && [ ! -x "$HARNESS" ]; then
  echo "step2_run: harness binary missing at $HARNESS" >&2
  echo "step2_run: build with:"
  echo "  cd $REPO_ROOT/tools/probe-harness && swift build"
  echo "step2_run: (or re-run with --skip-harness if §4 isn't needed)" >&2
  exit 1
fi

if [ ! -x "$FOOTPRINT" ]; then
  echo "step2_run: footprint sampler missing at $FOOTPRINT" >&2
  exit 1
fi

if [ ! -f "$DECODER" ]; then
  echo "step2_run: decoder missing at $DECODER" >&2
  exit 1
fi

# Print HEAD so the operator can confirm the build is current.
HEAD_SHA=$(cd "$REPO_ROOT" && git log --oneline -1 || echo "<no-git>")
echo "    HEAD: $HEAD_SHA"

# TCC self-check via screencapture -x size (proxy for Screen Recording grant).
TCC_PROBE="/tmp/mci-step2-tcc.png"
screencapture -x "$TCC_PROBE" >/dev/null 2>&1 || true
if [ ! -s "$TCC_PROBE" ]; then
  echo "step2_run: screencapture -x produced empty file — Terminal lacks Screen Recording grant" >&2
  echo "step2_run: System Settings → Privacy & Security → Screen Recording → enable Terminal" >&2
  exit 2
fi
TCC_SIZE=$(stat -f%z "$TCC_PROBE" 2>/dev/null || stat -c%s "$TCC_PROBE")
if [ "$TCC_SIZE" -lt 50000 ]; then
  echo "step2_run: screencapture -x produced $TCC_SIZE bytes (< 50 KB — likely permission-denied black PNG)" >&2
  echo "step2_run: Terminal lacks effective Screen Recording grant — fix in System Settings then re-run" >&2
  rm -f "$TCC_PROBE"
  exit 2
fi
rm -f "$TCC_PROBE"
echo "    TCC: Screen Recording grant verified ($TCC_SIZE bytes from screencapture -x)"

# Flush sudo cache so the §3 prompt actually fires during the helper window.
if [ "$SKIP_SUDO" != "1" ]; then
  sudo -k
  echo "    sudo: cache flushed (next sudo -v WILL prompt for password)"
fi

# Confirm Accessibility hint to the human. We can't directly read TCC
# from the CLI on macOS 26, so just remind.
if [ "$SKIP_HARNESS" != "1" ]; then
  echo "    NOTE: ensure Terminal.app has Accessibility grant"
  echo "          System Settings → Privacy & Security → Accessibility"
fi
echo

# Helper launch ------------------------------------------------------

echo "==> step2_run: launching helper (caffeinate wrapper, --capture --probe-debug)"
echo "    bin:       $OUT_BIN"
echo "    stderr:    $OUT_ERR"
echo "    footprint: $OUT_CSV"
echo

# Truncate previous run's outputs.
: > "$OUT_BIN"
: > "$OUT_ERR"
: > "$OUT_CSV"

# Launch the helper under caffeinate. caffeinate -dis keeps the Mac
# fully awake; -w would make it wait on PID but we want to control
# lifetime explicitly. Capture caffeinate's PID separately so cleanup
# can kill it after the helper exits (v6 bug: SIGINT on the script
# left caffeinate alive, which held the helper open).
caffeinate -dis "$HELPER" \
  --capture --probe-debug \
  --output "$OUT_BIN" \
  --heartbeat-seconds 5 \
  2> "$OUT_ERR" &
CAFFEINATE_PID=$!
HELPER_PID="$CAFFEINATE_PID"  # short-name until we resolve the real child below

# Wait for the "Starting live session…" banner — that's T0. Without
# this wait the operator might start the §3 step before the SCStream
# session is up. 20s timeout (debug builds can be slow on first
# launch — they JIT-warm the SCK frameworks).
echo "==> step2_run: waiting for helper banner (up to 20s)…"
for _ in $(seq 1 100); do
  if grep -q "Starting live session" "$OUT_ERR" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if ! grep -q "Starting live session" "$OUT_ERR" 2>/dev/null; then
  echo "step2_run: helper banner not seen within 20s — aborting" >&2
  exit 3
fi
echo "    helper banner observed (T0)"

# Resolve the real helper PID (the descendant of caffeinate, not
# caffeinate itself). pgrep -newest catches the most recently-started
# match — robust against multiple concurrent helpers (which there
# shouldn't be on a dev machine, but defensive).
sleep 1
REAL_HELPER_PID=$(pgrep -n -f "mci-capture-helper --capture --probe-debug" || true)
if [ -z "$REAL_HELPER_PID" ]; then
  echo "    warning: could not resolve real helper PID — footprint sampler will sample caffeinate (PID $CAFFEINATE_PID)" >&2
  REAL_HELPER_PID="$CAFFEINATE_PID"
fi
echo "    caffeinate PID: $CAFFEINATE_PID"
echo "    helper PID:     $REAL_HELPER_PID"

# Start the footprint sampler against the real helper PID.
"$FOOTPRINT" "$REAL_HELPER_PID" 2 "$OUT_CSV" > /dev/null 2>&1 &
FOOTPRINT_PID=$!
echo "    footprint sampler PID: $FOOTPRINT_PID"
echo

# Scripted sequence --------------------------------------------------

echo "================================================================"
echo "==> T+0:  WARM-UP — do nothing for 5s"
echo "================================================================"
sleep 5

if [ "$SKIP_SUDO" != "1" ]; then
  echo
  echo "================================================================"
  echo "==> T+5:  §3 TRIGGER — sudo prompt"
  echo "    In another terminal tab, run:    sudo -v"
  echo "    Type your password slowly, press Enter, wait."
  echo "    >>> 15-second window starting NOW <<<"
  echo "================================================================"
  sleep 15
else
  echo
  echo "==> T+5: §3 SKIPPED (--skip-sudo)"
fi

if [ "$SKIP_HARNESS" != "1" ]; then
  echo
  echo "================================================================"
  echo "==> T+20: §4 TRIGGER — ProbeHarness focused"
  echo "    Launching ProbeHarness in background…"
  echo "================================================================"
  "$HARNESS" >/dev/null 2>&1 &
  HARNESS_PID=$!
  sleep 2
  echo "    >>> 33-second window starting NOW <<<"
  echo "    1. Click the WINDOW (not Terminal) to bring it forward"
  echo "    2. Click into the MASKED (secure) field"
  echo "    3. HOLD any letter key — autorepeat fills the field with dots"
  echo "       (autorepeat = screen pixels keep changing = cascade floor + heartbeat both produce signal)"
  echo "    4. Keep holding until you see the next banner here"
  sleep 33

  echo
  echo "================================================================"
  echo "==> T+53: §4 done. Closing ProbeHarness…"
  echo "================================================================"
  kill -TERM "$HARNESS_PID" 2>/dev/null || true
  wait "$HARNESS_PID" 2>/dev/null || true
  HARNESS_PID=""
  sleep 2
else
  echo
  echo "==> T+20: §4 SKIPPED (--skip-harness)"
fi

if [ "$SKIP_FAIRPLAY" != "1" ]; then
  echo
  echo "================================================================"
  echo "==> T+55: §2 TRIGGER — full-screen FairPlay"
  echo "    Opening Apple TV.app…"
  echo "================================================================"
  open /System/Applications/TV.app
  sleep 3
  echo "    >>> 60-second window starting NOW <<<"
  echo "    1. Pick any movie or trailer you own / have access to"
  echo "    2. CLICK PLAY — opening TV.app alone is not enough!"
  echo "    3. Press ⌃⌘F to go full-screen"
  echo "    4. Scrub to a DARK SCENE (night, opening credits, end credits)"
  echo "       — bright scenes won't trigger §2 (≥85% pixels black needed)"
  echo "    5. DO NOT MOVE THE MOUSE — let chrome auto-hide"
  echo "    6. Stay full-screen until you see the next banner here"
  sleep 60

  echo
  echo "================================================================"
  echo "==> T+115: §2 done. Press Esc + Cmd-Q TV.app if needed."
  echo "================================================================"
  sleep 3
else
  echo
  echo "==> T+55: §2 SKIPPED (--skip-fairplay)"
fi

# Stop helper + footprint --------------------------------------------
#
# The trap will run cleanup() on EXIT — that's where the helper +
# caffeinate + harness + footprint sampler are killed and the wire
# decode runs. We just need to fall off the bottom of the script.

echo
echo "==> step2_run: scripted sequence complete; running cleanup + decode"

# PASS criteria — print BEFORE cleanup so operators see them above
# the decode output.

echo
echo "==> step2_run: PASS criteria (read the histogram in the cleanup output below)"
echo "    expect reason histogram to include AT LEAST 1 of each:"
[ "$SKIP_FAIRPLAY" != "1" ] && echo "      os-blacked-region (2)   ← §2 fired on FairPlay full-screen black"
[ "$SKIP_SUDO" != "1" ]     && echo "      secure-event-input (3)  ← §3 fired on sudo password entry"
[ "$SKIP_HARNESS" != "1" ]  && echo "      ax-secure-subrole (4)   ← §4 backstop fired on ProbeHarness focus"
echo "      failsafe-unknown (7)    ← §7 catchall fired in between"
echo "    AND: zero StateTransitionEvent (0x0010). seq contiguous, no gaps."
echo "    AND: one 'callback alive' line."
[ "$SKIP_HARNESS" != "1" ] && echo "    AND: mci-probe-harness > 0 (harness focused during cascade frames)."
[ "$SKIP_FAIRPLAY" != "1" ] && echo "    AND: TV.app focused > 0."
