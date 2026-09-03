#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <path-to-Hippocampus.app>\n' "$0" >&2
    exit 2
fi

APP="$1"
APP_BIN="$APP/Contents/MacOS/Hippocampus"
HELPER_BIN="$APP/Contents/MacOS/MCICaptureHelper"
AGENT_BIN="$APP/Contents/MacOS/mci-agent"
ROOT="$(mktemp -d /tmp/hippocampus-parent-lifetime.XXXXXX)"
export HOME="$ROOT/home"
export CFFIXED_USER_HOME="$HOME"
SUPPORT="$HOME/Library/Application Support/MCI"
CRASH_MARKER="$HOME/Library/Application Support/Hippocampus/.running"
LOG="$ROOT/app.log"
APP_PID=""
HELPER_PID=""
AGENT_PID=""
EXIT_TIMEOUT_SECONDS=10

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [[ ! -f "$LOG" ]] || tail -n 40 "$LOG" >&2
    exit 1
}

stop_owned() {
    local pid="$1"
    local expected="$2"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    local command
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"$expected"* ]] || return 0
    kill -KILL "$pid" 2>/dev/null || true
}

process_is_running() {
    local pid="$1"
    local state
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$state" && "$state" != Z* ]]
}

cleanup() {
    stop_owned "$HELPER_PID" "$HELPER_BIN"
    stop_owned "$AGENT_PID" "$AGENT_BIN"
    stop_owned "$APP_PID" "$APP_BIN"
    [[ -z "$APP_PID" ]] || wait "$APP_PID" 2>/dev/null || true
    rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM HUP

[[ -x "$APP_BIN" ]] || fail "missing app executable: $APP_BIN"
[[ -x "$HELPER_BIN" ]] || fail "missing helper executable: $HELPER_BIN"
[[ -x "$AGENT_BIN" ]] || fail "missing agent executable: $AGENT_BIN"

mkdir -p "$SUPPORT"
chmod 700 "$HOME" "$SUPPORT"
: > "$SUPPORT/.onboarding-complete"
chmod 600 "$SUPPORT/.onboarding-complete"

"$APP_BIN" > "$LOG" 2>&1 &
APP_PID=$!

deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
    kill -0 "$APP_PID" 2>/dev/null || fail "Hippocampus exited before its supervised children started"
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        command="$(ps -p "$child" -o command= 2>/dev/null || true)"
        [[ "$command" != *"$HELPER_BIN"* ]] || HELPER_PID="$child"
        [[ "$command" != *"$AGENT_BIN"* ]] || AGENT_PID="$child"
    done < <(pgrep -P "$APP_PID" 2>/dev/null || true)
    [[ -z "$HELPER_PID" || -z "$AGENT_PID" ]] || break
    sleep 0.1
done

[[ -n "$HELPER_PID" ]] || fail "supervised capture helper did not start"
[[ -n "$AGENT_PID" ]] || fail "supervised memory agent did not start"
helper_command="$(ps -p "$HELPER_PID" -o command= 2>/dev/null || true)"
[[ "$helper_command" == *"--parent-lease-stdin"* ]] \
    || fail "capture helper was not launched with the parent-lifetime lease"

kill -KILL "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

deadline=$((SECONDS + EXIT_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
    if ! process_is_running "$HELPER_PID" && ! process_is_running "$AGENT_PID"; then
        break
    fi
    sleep 0.1
done

process_is_running "$HELPER_PID" && fail "capture helper survived owner SIGKILL"
process_is_running "$AGENT_PID" && fail "memory agent survived owner SIGKILL"
[[ ! -e "$CRASH_MARKER" ]] || fail "memory agent left an unclean-shutdown marker"

printf 'ok: owner SIGKILL closed the helper lease; helper and agent exited cleanly\n'
