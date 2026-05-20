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
#   tools/step2_run.sh [output-bin-path]
#
#   output-bin-path  Optional; defaults to /tmp/mci-step2-runbook.bin .
#                    The .stderr companion lives next to it.
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
#   T+115s   : Ctrl-C helper (script kills it cleanly)
#   T+116s   : auto-decode + render verdict
#
# Caffeinate is wrapped around the helper so the Mac can't nap mid-run.
# A footprint_measure.sh sampler is launched in parallel; its CSV is
# saved next to the bin so the same run produces a soft footprint
# pre-read (NOT a G2 verdict — that's a separate real-workday run).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/adapters/macos/MCICaptureHelper/.build/debug/mci-capture-helper"
HARNESS="$REPO_ROOT/tools/probe-harness/.build/debug/ProbeHarness"
DECODER="$REPO_ROOT/tools/wire_decode.py"
FOOTPRINT="$REPO_ROOT/tools/footprint_measure.sh"

OUT_BIN="${1:-/tmp/mci-step2-runbook.bin}"
OUT_ERR="${OUT_BIN%.bin}.stderr"
OUT_CSV="${OUT_BIN%.bin}.footprint.csv"

# Pre-flight checks --------------------------------------------------

echo "==> step2_run: pre-flight"

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

if [ ! -x "$HARNESS" ]; then
  echo "step2_run: harness binary missing at $HARNESS" >&2
  echo "step2_run: build with:"
  echo "  cd $REPO_ROOT/tools/probe-harness && swift build"
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
sudo -k
echo "    sudo: cache flushed (next sudo -v WILL prompt for password)"

# Confirm Accessibility hint to the human. We can't directly read TCC
# from the CLI on macOS 26, so just remind.
echo "    NOTE: ensure Terminal.app has Accessibility grant"
echo "          System Settings → Privacy & Security → Accessibility"
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

# Launch the helper. caffeinate -dis keeps the Mac fully awake.
# Capture the helper PID so we can SIGINT it cleanly at the end.
caffeinate -dis "$HELPER" \
  --capture --probe-debug \
  --output "$OUT_BIN" \
  --heartbeat-seconds 5 \
  2> "$OUT_ERR" &
HELPER_PID=$!

# Wait for the "Starting live session…" banner — that's T0. Without
# this wait the operator might start the §3 step before the SCStream
# session is up.
echo "==> step2_run: waiting for helper banner (up to 10s)…"
for i in $(seq 1 50); do
  if grep -q "Starting live session" "$OUT_ERR" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if ! grep -q "Starting live session" "$OUT_ERR" 2>/dev/null; then
  echo "step2_run: helper banner not seen within 10s — aborting" >&2
  kill -INT "$HELPER_PID" 2>/dev/null || true
  wait "$HELPER_PID" 2>/dev/null || true
  exit 3
fi
echo "    helper banner observed (T0)"

# Start the footprint sampler against the (caffeinate's child = real
# helper) PID. caffeinate forks the helper so we sample the deepest
# descendant whose comm matches mci-capture-helper.
sleep 1
REAL_HELPER_PID=$(pgrep -f "mci-capture-helper --capture" | head -1)
if [ -z "$REAL_HELPER_PID" ]; then
  REAL_HELPER_PID="$HELPER_PID"
fi
echo "    helper PID: $REAL_HELPER_PID"
"$FOOTPRINT" "$REAL_HELPER_PID" 2 "$OUT_CSV" > /dev/null 2>&1 &
FOOTPRINT_PID=$!
echo "    footprint sampler PID: $FOOTPRINT_PID"
echo

# Scripted sequence --------------------------------------------------

echo "================================================================"
echo "==> T+0:  WARM-UP — do nothing for 5s"
echo "================================================================"
sleep 5

echo
echo "================================================================"
echo "==> T+5:  §3 TRIGGER — sudo prompt"
echo "    In another terminal tab, run:    sudo -v"
echo "    Type your password slowly, press Enter, wait."
echo "    >>> 15-second window starting NOW <<<"
echo "================================================================"
sleep 15

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
sleep 2

echo
echo "================================================================"
echo "==> T+55: §2 TRIGGER — full-screen FairPlay"
echo "    Opening Apple TV.app…"
echo "================================================================"
open /System/Applications/TV.app
sleep 3
echo "    >>> 60-second window starting NOW <<<"
echo "    1. Pick any movie or trailer you own / have access to"
echo "    2. Click Play"
echo "    3. Press ⌃⌘F to go full-screen"
echo "    4. DO NOT MOVE THE MOUSE — let chrome auto-hide"
echo "    5. Stay full-screen until you see the next banner here"
sleep 60

echo
echo "================================================================"
echo "==> T+115: §2 done. Press Esc + Cmd-Q TV.app if needed."
echo "================================================================"
sleep 3

# Stop helper + footprint --------------------------------------------

echo
echo "==> step2_run: stopping helper + footprint sampler"
kill -INT "$HELPER_PID" 2>/dev/null || true
wait "$HELPER_PID" 2>/dev/null || true
kill -TERM "$FOOTPRINT_PID" 2>/dev/null || true
wait "$FOOTPRINT_PID" 2>/dev/null || true

# Decode + report ----------------------------------------------------

echo
echo "================================================================"
echo "==> step2_run: wire decode"
echo "================================================================"
python3 "$DECODER" "$OUT_BIN"

echo
echo "================================================================"
echo "==> step2_run: stderr summary"
echo "================================================================"
echo "callback alive:               $(grep -c 'callback alive' "$OUT_ERR" || true)"
echo "probe-debug lines:            $(grep -c 'probe(ax-subrole)' "$OUT_ERR" || true)"
echo "mci-probe-harness focused:    $(grep -c 'mci-probe-harness' "$OUT_ERR" || true)"
echo "TV.app focused:               $(grep -c 'title=TV' "$OUT_ERR" || true)"
echo "positive backstop signals:    $(grep -cE 'descendant=pos|value-hidden=pos|id-regex=pos' "$OUT_ERR" || true)"
echo "errors / non-callback-alive:  $(grep -v -e 'callback alive' -e 'probe(ax-subrole)' "$OUT_ERR" | grep -c -v '^Starting live session' || true)"

echo
echo "================================================================"
echo "==> step2_run: footprint pre-read (soft, NOT a G2 verdict)"
echo "================================================================"
if [ -s "$OUT_CSV" ]; then
  python3 - <<PY "$OUT_CSV"
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
    print(f"  NOTE: this is a soft pre-read over ~115s. G2 = a separate")
    print(f"  real-workday measurement (HUMAN-ONLY per AGENT_PROTOCOL §4 / §9).")
PY
else
  echo "  no footprint samples written"
fi

echo
echo "==> step2_run: outputs"
echo "    wire bin:        $OUT_BIN"
echo "    helper stderr:   $OUT_ERR"
echo "    footprint csv:   $OUT_CSV"
echo
echo "==> step2_run: PASS criteria (read the histogram above)"
echo "    expect reason histogram to include AT LEAST 1 of each:"
echo "      os-blacked-region (2)   ← §2 fired on FairPlay full-screen black"
echo "      secure-event-input (3)  ← §3 fired on sudo password entry"
echo "      ax-secure-subrole (4)   ← §4 backstop fired on ProbeHarness focus"
echo "      failsafe-unknown (7)    ← §7 catchall fired in between"
echo "    AND: zero StateTransitionEvent (0x0010). seq contiguous, no gaps."
echo "    AND: one 'callback alive' line. mci-probe-harness > 0. TV.app > 0."
