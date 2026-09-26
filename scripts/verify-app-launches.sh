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
#   VERIFY_WAIT_SECONDS  override the 20s default wait
#   VERIFY_CLEAN_HOME=1  launch with disposable HOME/CFFIXED_USER_HOME
#   VERIFY_EXPECT_ONBOARDING=1  require first-run onboarding to stay alive
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
ONBOARDING_BIN="$APP/Contents/MacOS/onboarding"
WAIT_SECONDS="${VERIFY_WAIT_SECONDS:-20}"
CLEAN_HOME_ENABLED="${VERIFY_CLEAN_HOME:-0}"
EXPECT_ONBOARDING="${VERIFY_EXPECT_ONBOARDING:-0}"
CLEAN_ROOT=""

if [[ ! -d "$APP" ]]; then
    echo "ERROR: not a directory: $APP"
    exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
    echo "ERROR: missing or non-executable main binary at $APP_BIN"
    exit 1
fi

if [[ "$EXPECT_ONBOARDING" == "1" && ! -x "$ONBOARDING_BIN" ]]; then
    echo "ERROR: onboarding expectation requested but binary is missing at $ONBOARDING_BIN"
    exit 1
fi

if [[ "$CLEAN_HOME_ENABLED" == "1" ]]; then
    CLEAN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-app-launch.XXXXXX")"
    export HOME="$CLEAN_ROOT/home"
    export CFFIXED_USER_HOME="$HOME"
    mkdir -p "$HOME"
fi

echo "=== Launch-verify gate ==="
echo "App:      $APP"
echo "Wait:     ${WAIT_SECONDS}s"
if [[ "$CLEAN_HOME_ENABLED" == "1" ]]; then
    echo "Home:     disposable"
fi

# Capture both stdout + stderr to a temp file so we can surface the
# fatalError message verbatim on failure.
LOG=$(mktemp -t hippocampus-verify)

# Unique per-spawn SQLite path — cycles 8.21–8.23 tripped because
# successive verify runs collided on the shared brain-store lock when an
# orphan mci-agent child from a previous invocation still held it. A
# unique path per invocation makes the lock class of race impossible.
if [[ "$CLEAN_HOME_ENABLED" == "1" ]]; then
    export MCI_DB_PATH="$HOME/Library/Application Support/MCI/mci.sqlite"
else
    export MCI_DB_PATH="/tmp/mci-verify-$$-$(date +%s).sqlite"
fi

collect_descendants() {
    local parent="$1"
    local child
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        collect_descendants "$child"
        printf '%s\n' "$child"
    done < <(pgrep -P "$parent" 2>/dev/null || true)
}

onboarding_is_child() {
    local child command
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        command="$(ps -p "$child" -o command= 2>/dev/null || true)"
        if [[ "$command" == *"$ONBOARDING_BIN"* ]]; then
            return 0
        fi
    done < <(pgrep -P "$APP_PID" 2>/dev/null || true)
    return 1
}

# Cleanup must fire on normal exit AND on ctrl-C / SIGTERM, otherwise a
# killed verify run leaks the whole child-process tree (Hippocampus.app
# forks mci-agent workers that hold the SQLite lock). Kill the entire
# process group under APP_PID via pkill -P, not just the top-level PID.
cleanup() {
    if [[ -n "${APP_PID:-}" ]]; then
        descendant_pids="$(collect_descendants "$APP_PID")"
        for child in $descendant_pids; do
            kill -TERM "$child" 2>/dev/null || true
        done
        kill -TERM "$APP_PID" 2>/dev/null || true
        sleep 1
        for child in $descendant_pids; do
            kill -KILL "$child" 2>/dev/null || true
        done
        kill -KILL "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -f "$LOG" "$MCI_DB_PATH" "$MCI_DB_PATH"-shm "$MCI_DB_PATH"-wal
    if [[ -n "$CLEAN_ROOT" ]]; then
        rm -rf "$CLEAN_ROOT"
    fi
}
# INT/TERM re-raise as an explicit exit so the EXIT handler runs cleanup
# exactly once with a stable exit code.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Run the binary in a subshell so we can capture its exit reliably.
"$APP_BIN" >"$LOG" 2>&1 &
APP_PID=$!

# Poll the PID across the wait window — fail fast if it dies before
# the deadline.
SLEEP_INTERVAL=1
ELAPSED=0
SAW_ONBOARDING=0
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
    if [[ "$EXPECT_ONBOARDING" == "1" ]] && onboarding_is_child; then
        SAW_ONBOARDING=1
    fi
done

if [[ "$EXPECT_ONBOARDING" == "1" && "$SAW_ONBOARDING" -ne 1 ]]; then
    echo ""
    echo "FAIL: first-run onboarding did not remain alive under Hippocampus.app."
    echo "--- last 30 lines of stdout/stderr ---"
    tail -30 "$LOG" || true
    echo "--------------------------------------"
    exit 1
fi

# Survived. The EXIT trap will kill the process group + wait + rm logs.
echo "ok: $(basename "$APP") survived ${WAIT_SECONDS}s without crashing"
if [[ "$EXPECT_ONBOARDING" == "1" ]]; then
    echo "ok: first-run onboarding remained attached to the app"
fi
exit 0
