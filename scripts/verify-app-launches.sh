#!/usr/bin/env bash
set -euo pipefail

# verify-app-launches.sh — Smoke test that a built Hippocampus.app starts
# without crashing in the first few seconds.
#
# Catches the class of regression that produced cycle 8.16 — a DMG that
# passed `syspolicy_check distribution`, `spctl --assess`, and stapled
# notarization but then crashed at launch because a SwiftPM-generated
# resource bundle was placed where the auto-generated accessor never
# looked. Neither Gatekeeper nor notarization probe SwiftPM internals;
# the only way to catch this is to actually run the binary.
#
# Usage:
#   verify-app-launches.sh <path-to-.app>
#
# Exit codes:
#   0 — process survived $WAIT_SECONDS without crashing
#   1 — process exited or crashed within $WAIT_SECONDS, OR missing args
#
# Environment:
#   VERIFY_WAIT_SECONDS  override the 5s default wait
#
# NOTE: This is a structural-init check, not a functional check. The app
# may still have feature-level bugs that show up later. The point is to
# trip-wire startup-fatal regressions (bundle path, missing rpath,
# missing entitlement-gated framework, etc.) before a DMG ships.

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path-to-.app>"
    exit 1
fi

APP="$1"
APP_BIN="$APP/Contents/MacOS/Hippocampus"
WAIT_SECONDS="${VERIFY_WAIT_SECONDS:-5}"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: not a directory: $APP"
    exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
    echo "ERROR: missing or non-executable main binary at $APP_BIN"
    exit 1
fi

echo "=== Launch-verify gate ==="
echo "App:      $APP"
echo "Wait:     ${WAIT_SECONDS}s"

# Capture both stdout + stderr to a temp file so we can surface the
# fatalError message verbatim on failure.
LOG=$(mktemp -t hippocampus-verify)
# shellcheck disable=SC2064
trap "rm -f '$LOG'" EXIT

# Run the binary in a subshell so we can capture its exit reliably.
"$APP_BIN" >"$LOG" 2>&1 &
APP_PID=$!

# Poll the PID across the wait window — fail fast if it dies before
# the deadline.
SLEEP_INTERVAL=1
ELAPSED=0
while (( ELAPSED < WAIT_SECONDS )); do
    sleep "$SLEEP_INTERVAL"
    ELAPSED=$(( ELAPSED + SLEEP_INTERVAL ))
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        # Process died. Reap + dump log.
        wait "$APP_PID" 2>/dev/null || true
        echo ""
        echo "FAIL: $(basename "$APP") exited within ${ELAPSED}s of launch."
        echo "--- last 30 lines of stdout/stderr ---"
        tail -30 "$LOG" || true
        echo "--------------------------------------"
        exit 1
    fi
done

# Survived. Kill cleanly and report.
kill "$APP_PID" 2>/dev/null || true
# Give it a moment to wind down so we don't leave a stray process.
sleep 1
kill -9 "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

echo "ok: $(basename "$APP") survived ${WAIT_SECONDS}s without crashing"
exit 0
