#!/usr/bin/env bash
set -euo pipefail

# verify-quit-leaves-nothing.sh — Quit leaves nothing running (spec-shell S6).
#
# Starts a built Hippocampus.app with a disposable HOME and setup already
# finished, waits for its capture helper and memory agent, then sends the
# app SIGTERM: the same deliberate quit as the menu, the installer and
# `brew uninstall`. Fails if the app, or any process it started from inside
# the bundle, is still alive 5 seconds later.
#
# What it covers: the app, the capture helper and the memory agent. With a
# disposable HOME remembering is off and no permission is asked, so the OCR
# worker, Ask's sessions, the window and setup never start. The launch is
# quiet (HIPPOCAMPUS_QUIET_LAUNCH=1), so no window opens; the menu-bar icon
# shows for a few seconds. The rest is the hands-on proof in spec-shell S6.
#
# Usage:
#   verify-quit-leaves-nothing.sh <path-to-Hippocampus.app>
#
# Environment:
#   VERIFY_START_SECONDS  how long the helper and agent may take to start (20)
#   VERIFY_QUIT_SECONDS   how long Quit may take (5)

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <path-to-Hippocampus.app>\n' "$0" >&2
    exit 2
fi
[[ -d "$1" ]] || { printf 'FAIL: not a folder: %s\n' "$1" >&2; exit 1; }

APP="$(cd "$1" && pwd -P)"
APP_BIN="$APP/Contents/MacOS/Hippocampus"
HELPER_BIN="$APP/Contents/MacOS/MCICaptureHelper"
AGENT_BIN="$APP/Contents/MacOS/mci-agent"
START_SECONDS="${VERIFY_START_SECONDS:-20}"
QUIT_SECONDS="${VERIFY_QUIT_SECONDS:-5}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-quit.XXXXXX")"
export HOME="$ROOT/home"
export CFFIXED_USER_HOME="$HOME"
export HIPPOCAMPUS_QUIET_LAUNCH=1
SUPPORT="$HOME/Library/Application Support/MCI"
LOG="$ROOT/app.log"
APP_PID=""
# Every process the app started from inside the bundle, by pid. They are
# found while the app runs; once it exits, survivors belong to launchd.
STARTED=()

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [[ ! -f "$LOG" ]] || tail -n 40 "$LOG" >&2
    exit 1
}

is_running() {
    local pid="$1"
    local state
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$state" && "$state" != Z* ]]
}

command_of() {
    ps -p "$1" -o command= 2>/dev/null || true
}

# The pid is still a process from inside this bundle, not a reused pid.
in_bundle() {
    [[ "$(command_of "$1")" == "$APP/"* ]]
}

remember() {
    local pid
    for pid in ${STARTED[@]+"${STARTED[@]}"}; do
        [[ "$pid" != "$1" ]] || return 0
    done
    STARTED+=("$1")
}

# Walk the app's children, their children and so on.
collect() {
    local queue=("$APP_PID")
    local pid child
    while ((${#queue[@]} > 0)); do
        pid="${queue[0]}"
        queue=(${queue[@]+"${queue[@]:1}"})
        while IFS= read -r child; do
            [[ -n "$child" ]] || continue
            queue+=("$child")
            if in_bundle "$child"; then
                remember "$child"
            fi
        done < <(pgrep -P "$pid" 2>/dev/null || true)
    done
}

cleanup() {
    local pid
    for pid in ${STARTED[@]+"${STARTED[@]}"}; do
        if is_running "$pid" && in_bundle "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    if [[ -n "$APP_PID" ]] && is_running "$APP_PID"; then
        kill -KILL "$APP_PID" 2>/dev/null || true
    fi
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

helper_seen=0
agent_seen=0
deadline=$((SECONDS + START_SECONDS))
while (( SECONDS < deadline )); do
    is_running "$APP_PID" || fail "Hippocampus exited before it started its helper and agent"
    collect
    for pid in ${STARTED[@]+"${STARTED[@]}"}; do
        case "$(command_of "$pid")" in
            "$HELPER_BIN "*|"$HELPER_BIN") helper_seen=1 ;;
            "$AGENT_BIN --drain-stdin"*) agent_seen=1 ;;
        esac
    done
    (( helper_seen && agent_seen )) && break
    sleep 0.1
done
(( helper_seen )) || fail "the capture helper did not start"
(( agent_seen )) || fail "the memory agent did not start"

# Quit on a whole second, so the 5 seconds are 5 seconds.
tick=$SECONDS
while (( SECONDS == tick )); do sleep 0.02; done
kill -TERM "$APP_PID" 2>/dev/null || fail "Hippocampus exited before it was asked to quit"
deadline=$((SECONDS + QUIT_SECONDS))
while (( SECONDS < deadline )); do
    if is_running "$APP_PID"; then
        collect
        sleep 0.1
        continue
    fi
    alive=0
    for pid in ${STARTED[@]+"${STARTED[@]}"}; do
        if is_running "$pid" && in_bundle "$pid"; then
            alive=1
            break
        fi
    done
    (( alive )) || break
    sleep 0.1
done

survivors=()
is_running "$APP_PID" && survivors+=("$APP_PID $APP_BIN")
for pid in ${STARTED[@]+"${STARTED[@]}"}; do
    if is_running "$pid" && in_bundle "$pid"; then
        survivors+=("$pid $(command_of "$pid")")
    fi
done
if (( ${#survivors[@]} > 0 )); then
    printf 'still running %ss after Quit:\n' "$QUIT_SECONDS" >&2
    printf '  %s\n' "${survivors[@]}" >&2
    fail "Quit left processes running"
fi

printf 'ok: Quit stopped Hippocampus and the %d processes it started within %ss\n' "${#STARTED[@]}" "$QUIT_SECONDS"
