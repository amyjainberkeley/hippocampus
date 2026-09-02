#!/usr/bin/env bash
set -euo pipefail

# Truthful live gate for focused-window-only ScreenCaptureKit ingestion.
# This script never changes TCC or Gatekeeper state. It requires an explicitly
# assembled development app so both helper and agent use the artifact under test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION_CHECK="$SCRIPT_DIR/live-capture/check_session.py"
MEMORY_CHECK="$SCRIPT_DIR/live-capture/verify_memory.py"
CORPUS_BUILD="$REPO_ROOT/tools/capture-overlap-corpus/build-app.sh"
CORPUS_BUNDLE_ID="ai.hippocampus.CaptureOverlapCorpus"
FOCUSED_TOKEN="FOCUSED_EVIDENCE_ZEPHYR_9241"
BACKGROUND_TOKEN="BACKGROUND_SECRET_NEBULA_7713"

APP_PATH=""
CAPTURE_SECONDS=20
STARTUP_TIMEOUT=20
QUERY_TIMEOUT=20
PREFLIGHT_ONLY=0
KEEP_ARTIFACTS=0
DISCARD_FAILURE_ARTIFACTS=0

RUN_ROOT=""
EVIDENCE_CREATED=0
RUN_SUCCEEDED=0
CAPTURE_FIFO=""
FIFO_GUARD_OPEN=0
CORPUS_PID=""
HELPER_PID=""
AGENT_PID=""
QUERY_PID=""
HELPER=""
AGENT=""
CLEANUP_EXIT_CODE=0

usage() {
    cat <<'EOF'
Usage:
  scripts/run-live-capture-overlap.sh --app /absolute/path/Hippocampus.app [OPTIONS]

Required:
  --app PATH              Assembled ad-hoc development Hippocampus.app.

Options:
  --capture-seconds N     Keep the corpus focused for 1-30 seconds (default 20).
  --startup-timeout N     Bound app/helper startup in seconds (default 20).
  --query-timeout N       Bound MCP readback in seconds (default 20).
  --preflight-only        Validate the host and app; never launch capture.
  --keep-artifacts        Retain successful evidence as well as failures.
  --discard-on-failure    Delete failed evidence instead of retaining it.
  -h, --help              Show this help.

Prerequisites:
  - The Mac is unlocked with an active display.
  - Screen Recording and Accessibility are granted to the exact assembled
    MCICaptureHelper identity. The script never grants or resets permissions.
  - Build the app with the current sources using:
      scripts/swift-package.sh build --package-path apps/hippocampus
      scripts/swift-package.sh build --package-path adapters/macos/MCICaptureHelper
      scripts/swift-package.sh build --package-path apps/recall-ui
      scripts/swift-package.sh build --package-path apps/onboarding
      cargo build -p mci-agent --bins -p hippocampus-native-host
      apps/hippocampus/Resources/build-app.sh --debug \
        --development-ad-hoc --development-lite --dist /tmp/hippocampus-live-app

The only success condition is exact focused-token readback with exact background-
token absence from the isolated encrypted brain. Failed evidence is mode 0700 and
retained by default; it includes the isolated mode-0600 development key.
EOF
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        fail "$option requires a value"
    fi
}

require_bounded_integer() {
    local option="$1"
    local value="$2"
    local maximum="$3"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || (( value > maximum )); then
        fail "$option must be an integer from 1 through $maximum"
    fi
}

owned_command() {
    local pid="$1"
    /bin/ps -p "$pid" -o command= 2>/dev/null || true
}

stop_owned_process() {
    local pid="$1"
    local label="$2"
    local expected="$3"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0

    local command_line
    command_line="$(owned_command "$pid")"
    if [[ "$command_line" != *"$expected"* ]]; then
        printf 'WARNING: refusing to stop recycled/unowned %s pid %s: %s\n' \
            "$label" "$pid" "$command_line" >&2
        return 0
    fi

    kill -TERM "$pid" 2>/dev/null || true
    local attempt
    for attempt in {1..30}; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
    CLEANUP_EXIT_CODE=$?
    set +e
    trap - EXIT INT TERM HUP

    if (( FIFO_GUARD_OPEN == 1 )); then
        exec 9>&-
        FIFO_GUARD_OPEN=0
    fi
    stop_owned_process "$QUERY_PID" "MCP query" "$AGENT"
    stop_owned_process "$HELPER_PID" "capture helper" "$HELPER"
    stop_owned_process "$AGENT_PID" "ingest agent" "$AGENT"
    stop_owned_process "$CORPUS_PID" "overlap corpus" "capture-overlap-corpus"
    if [[ -n "$CAPTURE_FIFO" && -p "$CAPTURE_FIFO" ]]; then
        rm -f "$CAPTURE_FIFO"
    fi

    if (( EVIDENCE_CREATED == 1 )); then
        if (( RUN_SUCCEEDED == 1 && KEEP_ARTIFACTS == 0 )); then
            rm -rf "$RUN_ROOT"
        elif (( RUN_SUCCEEDED == 0 && DISCARD_FAILURE_ARTIFACTS == 1 )); then
            rm -rf "$RUN_ROOT"
            printf 'Failed evidence discarded by request.\n' >&2
        else
            printf 'Evidence retained at: %s\n' "$RUN_ROOT" >&2
        fi
    elif (( CLEANUP_EXIT_CODE != 0 )); then
        printf 'No evidence directory was created; preflight failed before launch.\n' >&2
    fi
    exit "$CLEANUP_EXIT_CODE"
}

on_signal() {
    printf 'Interrupted; stopping only processes launched by this verifier.\n' >&2
    exit 130
}

trap cleanup EXIT
trap on_signal INT TERM HUP

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            require_value "$1" "${2:-}"
            APP_PATH="$2"
            shift 2
            ;;
        --capture-seconds)
            require_value "$1" "${2:-}"
            CAPTURE_SECONDS="$2"
            shift 2
            ;;
        --startup-timeout)
            require_value "$1" "${2:-}"
            STARTUP_TIMEOUT="$2"
            shift 2
            ;;
        --query-timeout)
            require_value "$1" "${2:-}"
            QUERY_TIMEOUT="$2"
            shift 2
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=1
            shift
            ;;
        --keep-artifacts)
            KEEP_ARTIFACTS=1
            shift
            ;;
        --discard-on-failure)
            DISCARD_FAILURE_ARTIFACTS=1
            shift
            ;;
        -h|--help)
            usage
            RUN_SUCCEEDED=1
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[[ -n "$APP_PATH" ]] || fail "--app is required; pass an assembled Hippocampus.app"
require_bounded_integer "--capture-seconds" "$CAPTURE_SECONDS" 30
require_bounded_integer "--startup-timeout" "$STARTUP_TIMEOUT" 300
require_bounded_integer "--query-timeout" "$QUERY_TIMEOUT" 300

[[ "$(uname -s)" == "Darwin" ]] || fail "live capture verification requires macOS"
[[ -d "$APP_PATH" ]] || fail "assembled app does not exist: $APP_PATH"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd -P)/$(basename "$APP_PATH")"

for command in codesign openssl python3 rg strings; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done
for executable in /usr/bin/open /usr/bin/lsappinfo /usr/sbin/ioreg /usr/libexec/PlistBuddy; do
    [[ -x "$executable" ]] || fail "required macOS tool is missing: $executable"
done
[[ -x "$SESSION_CHECK" ]] || fail "session checker is missing: $SESSION_CHECK"
[[ -x "$MEMORY_CHECK" ]] || fail "memory checker is missing: $MEMORY_CHECK"
[[ -x "$CORPUS_BUILD" ]] || fail "overlap corpus builder is missing: $CORPUS_BUILD"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
HELPER="$APP_PATH/Contents/MacOS/MCICaptureHelper"
AGENT="$APP_PATH/Contents/MacOS/mci-agent"
[[ -f "$INFO_PLIST" ]] || fail "assembled app has no Contents/Info.plist"
[[ -x "$HELPER" ]] || fail "assembled app has no executable MCICaptureHelper"
[[ -x "$AGENT" ]] || fail "assembled app has no executable mci-agent"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$bundle_id" == "ai.hippocampus" ]] \
    || fail "unexpected Hippocampus bundle id: ${bundle_id:-missing}"
development_key_enabled="$(/usr/libexec/PlistBuddy \
    -c 'Print :MCIDevelopmentFileKeyEnabled' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$development_key_enabled" == "true" ]] \
    || fail "app is not an explicit development-file-key artifact; assemble with --debug --development-ad-hoc"

codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 \
    || fail "assembled app fails codesign verification"
if ! codesign -dv --verbose=2 "$APP_PATH" 2>&1 | rg -q '^Signature=adhoc$'; then
    fail "development-file-key verifier requires an ad-hoc development app"
fi

session_summary="$(/usr/sbin/ioreg -n Root -d1 -a \
    | python3 "$SESSION_CHECK" --expected-uid "$(id -u)" --expected-user "$(id -un)")" \
    || fail "no unlocked GUI session is available; see the session preflight message above"
printf 'Preflight: %s\n' "$session_summary"

existing_corpus_asn="$(/usr/bin/lsappinfo find bundleid="$CORPUS_BUNDLE_ID" 2>/dev/null || true)"
[[ -z "$existing_corpus_asn" ]] \
    || fail "the overlap corpus is already running; quit that instance so PID ownership is unambiguous"

if (( PREFLIGHT_ONLY == 1 )); then
    printf 'PREFLIGHT ONLY: app and unlocked-session gates passed; live capture was not run.\n'
    RUN_SUCCEEDED=1
    exit 0
fi

RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-live-overlap.XXXXXX")"
chmod 700 "$RUN_ROOT"
EVIDENCE_CREATED=1
LOG_DIR="$RUN_ROOT/logs"
ISOLATED_HOME="$RUN_ROOT/home"
SUPPORT_DIR="$ISOLATED_HOME/Library/Application Support/MCI"
DB_PATH="$SUPPORT_DIR/mci.sqlite"
KEY_FILE="$SUPPORT_DIR/dev.key"
ALLOWLIST_FILE="$SUPPORT_DIR/user-allowlist.toml"
DEVICE_ID="$ISOLATED_HOME/.mci/device-id"
HEALTH_LOG="$RUN_ROOT/logs/helper-health.jsonl"
CAPTURE_FIFO="$RUN_ROOT/capture.fifo"
READINESS_FILE="$RUN_ROOT/helper-readiness.json"
CORPUS_APP="$RUN_ROOT/CaptureOverlapCorpus.app"
CORPUS_STDOUT="$LOG_DIR/corpus.stdout"
CORPUS_STDERR="$LOG_DIR/corpus.stderr"
HELPER_STDOUT="$LOG_DIR/helper.stdout"
HELPER_STDERR="$LOG_DIR/helper.stderr"
AGENT_STDOUT="$LOG_DIR/agent.stdout"
AGENT_STDERR="$LOG_DIR/agent.stderr"
MCP_REQUESTS="$LOG_DIR/mcp.requests.jsonl"
MCP_RESPONSES="$LOG_DIR/mcp.responses.jsonl"
MCP_STDERR="$LOG_DIR/mcp.stderr"
VERIFY_STDOUT="$LOG_DIR/verify.stdout"
VERIFY_STDERR="$LOG_DIR/verify.stderr"

mkdir -p "$LOG_DIR" "$SUPPORT_DIR" "$(dirname "$DEVICE_ID")"
chmod 700 "$ISOLATED_HOME" "$SUPPORT_DIR" "$(dirname "$DEVICE_ID")"

{
    printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo_head=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
    printf 'app=%s\n' "$APP_PATH"
    printf 'helper=%s\n' "$HELPER"
    printf 'agent=%s\n' "$AGENT"
    printf 'capture_seconds=%s\n' "$CAPTURE_SECONDS"
    printf 'focused_token=%s\n' "$FOCUSED_TOKEN"
    printf 'background_token=%s\n' "$BACKGROUND_TOKEN"
    printf 'session=%s\n' "$session_summary"
} > "$RUN_ROOT/metadata.txt"
chmod 600 "$RUN_ROOT/metadata.txt"

printf '\n==> Building deterministic overlap corpus\n'
if ! "$CORPUS_BUILD" "$CORPUS_APP" \
    >"$LOG_DIR/corpus-build.stdout" 2>"$LOG_DIR/corpus-build.stderr"; then
    tail -n 40 "$LOG_DIR/corpus-build.stderr" >&2 || true
    fail "overlap corpus build failed"
fi
codesign --verify --strict "$CORPUS_APP" >/dev/null 2>&1 \
    || fail "built overlap corpus fails codesign verification"
strings "$CORPUS_APP/Contents/MacOS/capture-overlap-corpus" \
    > "$LOG_DIR/corpus-executable.strings"
for token in "$FOCUSED_TOKEN" "$BACKGROUND_TOKEN"; do
    grep -Fq "$token" "$LOG_DIR/corpus-executable.strings" \
        || fail "built overlap corpus is missing deterministic token: $token"
done

printf '\n==> Preparing isolated encrypted brain and file-key custody\n'
( umask 077; openssl rand -hex 32 > "$KEY_FILE" )
chmod 600 "$KEY_FILE"
[[ "$(stat -f '%Lp' "$KEY_FILE")" == "600" ]] \
    || fail "isolated development key is not mode 0600"
[[ "$(tr -d '\r\n' < "$KEY_FILE" | wc -c | tr -d ' ')" == "64" ]] \
    || fail "isolated development key is not 64 ASCII hex characters"

( umask 077; cat > "$ALLOWLIST_FILE" <<EOF
[[entries]]
bundle_id = "$CORPUS_BUNDLE_ID"
capture_enabled = true
deep_hook_enabled = false
added_at = "$(date +%F)"
rationale = "Deterministic live focused-window overlap verifier"
EOF
)
chmod 600 "$ALLOWLIST_FILE"

# Foundation ignores HOME for user-domain paths unless CFFIXED_USER_HOME is
# also set. Rust uses HOME. Pinning both keeps every verifier artifact inside
# RUN_ROOT and makes the helper's expected dev.key path equal MCI_DB_KEY_FILE.
export HOME="$ISOLATED_HOME"
export CFFIXED_USER_HOME="$ISOLATED_HOME"
export MCI_DB_PATH="$DB_PATH"
export MCI_DEVELOPMENT_FILE_KEY=1
export MCI_DB_KEY_FILE="$KEY_FILE"
unset MCI_DB_KEY_HEX
unset MCI_CRASH_REPORT_URL
unset MCI_CRASH_REPORT_OPTED_IN
export MCI_CAPTURE_ENABLED=1
export MCI_EMBEDDER_DISABLED=1
export MCI_BRIEFS_DISABLED=1
export MCI_OCR_TRACE=1

if ! printf '' | "$AGENT" --device-id-path "$DEVICE_ID" \
    --log-path "$HEALTH_LOG" --db-path "$DB_PATH" --drain-stdin --strict \
    >"$LOG_DIR/key-probe.stdout" 2>"$LOG_DIR/key-probe.stderr"; then
    tail -n 50 "$LOG_DIR/key-probe.stderr" >&2 || true
    fail "assembled mci-agent rejected the explicit development key file or could not open the isolated brain"
fi
[[ -f "$DB_PATH" ]] || fail "key probe exited without creating the isolated brain"

printf '\n==> Launching corpus and proving it is frontmost\n'
/usr/bin/open -n -F -o "$CORPUS_STDOUT" --stderr "$CORPUS_STDERR" "$CORPUS_APP" \
    || fail "LaunchServices could not open the overlap corpus"

frontmost_bundle_id() {
    local asn
    asn="$(/usr/bin/lsappinfo front 2>/dev/null || true)"
    [[ -n "$asn" ]] || return 1
    /usr/bin/lsappinfo info -only bundleid "$asn" 2>/dev/null \
        | sed -nE 's/^"CFBundleIdentifier"="(.*)"$/\1/p'
}

corpus_pid_from_launch_services() {
    local asn
    asn="$(/usr/bin/lsappinfo find bundleid="$CORPUS_BUNDLE_ID" 2>/dev/null || true)"
    [[ -n "$asn" ]] || return 1
    /usr/bin/lsappinfo info -only pid "$asn" 2>/dev/null \
        | sed -nE 's/^"pid"=([0-9]+)$/\1/p'
}

deadline=$((SECONDS + STARTUP_TIMEOUT))
while (( SECONDS < deadline )); do
    if [[ -z "$CORPUS_PID" ]]; then
        CORPUS_PID="$(corpus_pid_from_launch_services || true)"
    fi
    front_bundle="$(frontmost_bundle_id || true)"
    if [[ -n "$CORPUS_PID" ]] \
        && [[ "$front_bundle" == "$CORPUS_BUNDLE_ID" ]] \
        && rg -q '^capture-overlap-corpus ready$' "$CORPUS_STDOUT" 2>/dev/null; then
        break
    fi
    sleep 0.25
done

[[ -n "$CORPUS_PID" ]] || fail "overlap corpus launched but no owned PID appeared in LaunchServices"
kill -0 "$CORPUS_PID" 2>/dev/null || fail "overlap corpus exited during startup"
front_bundle="$(frontmost_bundle_id || true)"
[[ "$front_bundle" == "$CORPUS_BUNDLE_ID" ]] \
    || fail "overlap corpus did not become frontmost within ${STARTUP_TIMEOUT}s (frontmost: ${front_bundle:-unknown}); unlock the Mac and dismiss any system dialog"
rg -q '^capture-overlap-corpus ready$' "$CORPUS_STDOUT" 2>/dev/null \
    || fail "overlap corpus became frontmost but did not publish its readiness line"

printf '\n==> Starting assembled helper and agent through the isolated FIFO\n'
mkfifo "$CAPTURE_FIFO"
chmod 600 "$CAPTURE_FIFO"
exec 9<> "$CAPTURE_FIFO"
FIFO_GUARD_OPEN=1

"$AGENT" --device-id-path "$DEVICE_ID" --log-path "$HEALTH_LOG" \
    --db-path "$DB_PATH" --drain-stdin --strict < "$CAPTURE_FIFO" \
    >"$AGENT_STDOUT" 2>"$AGENT_STDERR" &
AGENT_PID=$!

generation="live-overlap-$(date +%s)-$$"
"$HELPER" --capture --probe-debug --output "$CAPTURE_FIFO" \
    --heartbeat-seconds 2 --readiness-file "$READINESS_FILE" \
    --generation "$generation" >"$HELPER_STDOUT" 2>"$HELPER_STDERR" &
HELPER_PID=$!

runtime_diagnostic() {
    local helper_log="${HELPER_STDERR:-}"
    local agent_log="${AGENT_STDERR:-}"
    if [[ -f "$helper_log" ]] && rg -qi 'noDisplay|user.?declined|screen.?record|not.?authorized' "$helper_log"; then
        printf 'Action: ScreenCaptureKit could not access a display. Unlock the Mac and grant Screen Recording to the exact MCICaptureHelper in %s.\n' "$APP_PATH" >&2
    elif [[ -f "$helper_log" ]] && rg -qi 'focus=.*(nil|error)|result=nil|failsafe|no_eligible_window' "$helper_log"; then
        printf 'Action: the helper could not positively classify the focused UI. Grant Accessibility to the exact assembled helper/app, keep the corpus frontmost, and retry.\n' >&2
    elif { [[ -f "$helper_log" ]] && rg -qi 'database key unavailable|development.*key|keychain' "$helper_log"; } \
        || { [[ -f "$agent_log" ]] && rg -qi 'brain key|development.*key|keychain|MCI_DB_KEY_FILE' "$agent_log"; }; then
        printf 'Action: development key custody failed. Inspect key-probe/helper logs; the key path must be the isolated ~/Library/Application Support/MCI/dev.key and mode 0600.\n' >&2
    elif [[ -f "$agent_log" ]] && rg -qi 'BRAIN OPEN FAILED|open brain|integrity_check|writer.*lease' "$agent_log"; then
        printf 'Action: the isolated encrypted brain could not open safely. Inspect agent.stderr and confirm no prior verifier process still owns the writer lease.\n' >&2
    else
        printf 'Action: inspect helper.stderr and agent.stderr in the retained evidence directory; no live success was recorded.\n' >&2
    fi
}

runtime_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    runtime_diagnostic
    [[ ! -f "$HELPER_STDERR" ]] || tail -n 30 "$HELPER_STDERR" >&2
    [[ ! -f "$AGENT_STDERR" ]] || tail -n 30 "$AGENT_STDERR" >&2
    exit 1
}

deadline=$((SECONDS + STARTUP_TIMEOUT))
while [[ ! -f "$READINESS_FILE" ]] && (( SECONDS < deadline )); do
    kill -0 "$CORPUS_PID" 2>/dev/null || runtime_fail "overlap corpus exited before helper readiness"
    kill -0 "$HELPER_PID" 2>/dev/null || runtime_fail "capture helper exited before readiness"
    kill -0 "$AGENT_PID" 2>/dev/null || runtime_fail "ingest agent exited before helper readiness"
    front_bundle="$(frontmost_bundle_id || true)"
    [[ "$front_bundle" == "$CORPUS_BUNDLE_ID" ]] \
        || runtime_fail "overlap corpus lost frontmost status during helper startup (frontmost: ${front_bundle:-unknown})"
    sleep 0.25
done
[[ -f "$READINESS_FILE" ]] \
    || runtime_fail "capture helper did not publish readiness within ${STARTUP_TIMEOUT}s"

if ! python3 - "$READINESS_FILE" "$generation" <<'PY'
import json
import sys

path, expected_generation = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    receipt = json.load(handle)
if receipt.get("generation") != expected_generation:
    raise SystemExit(
        f"readiness generation mismatch: expected {expected_generation}, got {receipt}"
    )
if receipt.get("capture_enabled") is not True:
    raise SystemExit(f"readiness did not attest capture_enabled=true: {receipt}")
PY
then
    runtime_fail "capture helper published an invalid readiness receipt"
fi
[[ "$(stat -f '%Lp' "$READINESS_FILE")" == "600" ]] \
    || runtime_fail "capture helper readiness receipt is not mode 0600"

printf 'Capturing focused corpus for %ss...\n' "$CAPTURE_SECONDS"
deadline=$((SECONDS + CAPTURE_SECONDS))
while (( SECONDS < deadline )); do
    kill -0 "$CORPUS_PID" 2>/dev/null || runtime_fail "overlap corpus exited during capture"
    kill -0 "$HELPER_PID" 2>/dev/null || runtime_fail "capture helper exited during capture"
    kill -0 "$AGENT_PID" 2>/dev/null || runtime_fail "ingest agent exited during capture"
    front_bundle="$(frontmost_bundle_id || true)"
    [[ "$front_bundle" == "$CORPUS_BUNDLE_ID" ]] \
        || runtime_fail "overlap corpus lost frontmost status during capture (frontmost: ${front_bundle:-unknown})"
    sleep 0.5
done

printf '\n==> Closing capture and waiting for the writer lease to release\n'
stop_owned_process "$HELPER_PID" "capture helper" "$HELPER"
wait "$HELPER_PID" 2>/dev/null || true
HELPER_PID=""
exec 9>&-
FIFO_GUARD_OPEN=0

deadline=$((SECONDS + STARTUP_TIMEOUT))
while kill -0 "$AGENT_PID" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.25
done
if kill -0 "$AGENT_PID" 2>/dev/null; then
    runtime_fail "ingest agent did not exit after the helper closed its FIFO"
fi
set +e
wait "$AGENT_PID"
agent_exit=$?
set -e
AGENT_PID=""
(( agent_exit == 0 )) || runtime_fail "ingest agent exited with status $agent_exit"
rm -f "$CAPTURE_FIFO"
CAPTURE_FIFO=""

if rg -qi 'BRAIN OPEN FAILED|CAPTURE IS NOT BEING SAVED|integrity_check FAILED|another writer owns' "$AGENT_STDERR"; then
    runtime_fail "agent diagnostics show that capture was not safely committed"
fi
if ! rg -Eq 'drained [0-9]+ frame\(s\); [0-9]+ logged, [0-9]+ non-health, [1-9][0-9]* to brain' "$AGENT_STDERR"; then
    runtime_fail "agent completed without proving that at least one content frame reached the brain"
fi

printf '\n==> Querying the encrypted brain through assembled mci-agent MCP\n'
python3 "$MEMORY_CHECK" emit > "$MCP_REQUESTS"
"$AGENT" --db-path "$DB_PATH" mcp-serve < "$MCP_REQUESTS" \
    > "$MCP_RESPONSES" 2> "$MCP_STDERR" &
QUERY_PID=$!

deadline=$((SECONDS + QUERY_TIMEOUT))
while kill -0 "$QUERY_PID" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.25
done
if kill -0 "$QUERY_PID" 2>/dev/null; then
    runtime_fail "MCP readback did not finish within ${QUERY_TIMEOUT}s"
fi
set +e
wait "$QUERY_PID"
query_exit=$?
set -e
QUERY_PID=""
if (( query_exit != 0 )); then
    tail -n 40 "$MCP_STDERR" >&2 || true
    runtime_fail "assembled mci-agent MCP readback exited with status $query_exit"
fi

if ! python3 "$MEMORY_CHECK" verify --responses "$MCP_RESPONSES" \
    > "$VERIFY_STDOUT" 2> "$VERIFY_STDERR"; then
    cat "$VERIFY_STDERR" >&2
    runtime_fail "focused-only memory proof failed"
fi
cat "$VERIFY_STDOUT"

RUN_SUCCEEDED=1
printf 'PASS: live focused-window overlap verified: focused token present, background token absent.\n'
