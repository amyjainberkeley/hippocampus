#!/usr/bin/env bash
set -euo pipefail

# Truthful live gate for focused-window-only ScreenCaptureKit ingestion.
# This script never changes TCC or Gatekeeper state. It accepts either an
# explicitly ad-hoc development app or a Developer ID signed debug qualification
# app, so the live proof can bind TCC to the stable distribution identity.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION_CHECK="$SCRIPT_DIR/live-capture/check_session.py"
MEMORY_CHECK="$SCRIPT_DIR/live-capture/verify_memory.py"
SOAK_REPORTER="$SCRIPT_DIR/live-capture/summarize_soak.py"
PRODUCT_SOURCE_DIGEST_TOOL="$SCRIPT_DIR/product-source-digest.py"
BUILD_PROVENANCE_TOOL="$SCRIPT_DIR/build-provenance.py"
FOOTPRINT_TOOL="$REPO_ROOT/tools/footprint_measure.sh"
CORPUS_BUILD="$REPO_ROOT/tools/capture-overlap-corpus/build-app.sh"
CORPUS_BUNDLE_ID="ai.hippocampus.CaptureOverlapCorpus"
BACKGROUND_BUNDLE_ID="ai.hippocampus.CaptureOverlapBackground"
FOCUSED_TOKEN="FOCUSED_EVIDENCE_ZEPHYR_9241"
BACKGROUND_TOKEN="BACKGROUND_SECRET_NEBULA_7713"
FOCUS_CONTROL_TOKEN="FOCUS_REBIND_CONTROL_3087"
EXPECTED_QUALIFICATION_TEAM_ID="BV6KGKFKP4"

APP_PATH=""
CAPTURE_SECONDS=20
STARTUP_TIMEOUT=20
QUERY_TIMEOUT=20
PREFLIGHT_ONLY=0
KEEP_ARTIFACTS=0
DISCARD_FAILURE_ARTIFACTS=0
SOAK_MODE=0
SIGNED_DEBUG_QUALIFICATION=0
CORPUS_LAUNCH_ATTEMPTED=0
BACKGROUND_LAUNCH_ATTEMPTED=0

RUN_ROOT=""
CORPUS_APP=""
BACKGROUND_APP=""
EVIDENCE_CREATED=0
RUN_SUCCEEDED=0
CAPTURE_FIFO=""
FIFO_GUARD_OPEN=0
HELPER_LEASE_FIFO=""
HELPER_LEASE_GUARD_OPEN=0
CORPUS_PID=""
BACKGROUND_PID=""
HELPER_PID=""
AGENT_PID=""
QUERY_PID=""
FOOTPRINT_PID=""
HELPER=""
AGENT=""
CLEANUP_EXIT_CODE=0

usage() {
    cat <<'EOF'
Usage:
  scripts/run-live-capture-overlap.sh --app /absolute/path/Hippocampus.app [OPTIONS]

Required:
  --app PATH              Assembled Hippocampus.app qualification artifact.

Options:
  --capture-seconds N     Keep the corpus focused for 1-30 seconds (default 20).
  --soak                  Run the release soak for exactly 30 uninterrupted
                          minutes, retain evidence, and enforce the resource SLO.
  --startup-timeout N     Bound app/helper startup in seconds (default 20).
  --query-timeout N       Bound MCP readback in seconds (default 20).
  --preflight-only        Validate the host and app; never launch capture.
  --signed-debug-qualification
                          Require a Developer ID signed debug helper carrying
                          the narrow live OCR qualification capability.
  --keep-artifacts        Retain successful evidence as well as failures.
  --discard-on-failure    Delete failed evidence instead of retaining it.
  -h, --help              Show this help.

Prerequisites:
  - The Mac is unlocked with an active display.
  - Screen Recording and Accessibility are granted to the exact assembled
    MCICaptureHelper identity. The script never grants or resets permissions.
  - Build an ad-hoc development app with the current sources using:
      scripts/swift-package.sh build --package-path apps/hippocampus
      scripts/swift-package.sh build --package-path adapters/macos/MCICaptureHelper
      scripts/swift-package.sh build --package-path apps/recall-ui
      scripts/swift-package.sh build --package-path apps/onboarding
      cargo build -p mci-agent --bins -p hippocampus-native-host
      apps/hippocampus/Resources/build-app.sh --debug \
        --development-ad-hoc --development-lite --dist /tmp/hippocampus-live-app

    To bind the proof to a stable TCC identity and the current source, run:
      apps/hippocampus/Resources/build-app.sh --debug \
        --current-source-qualification --dist /tmp/hippocampus-signed-qualification
    Then pass the resulting app with
    --signed-debug-qualification. That artifact is for qualification only and
    must never be distributed.

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

app_pid_from_launch_services() {
    local bundle_id="$1"
    local asn
    asn="$(/usr/bin/lsappinfo find bundleid="$bundle_id" 2>/dev/null || true)"
    [[ -n "$asn" ]] || return 1
    /usr/bin/lsappinfo info -only pid "$asn" 2>/dev/null \
        | sed -nE 's/^"pid"=([0-9]+)$/\1/p'
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

stop_owned_bundle_process() {
    local bundle_id="$1"
    local label="$2"
    local expected="$3"
    [[ -n "$expected" ]] || return 0

    local attempt pid
    for attempt in {1..50}; do
        pid="$(app_pid_from_launch_services "$bundle_id" || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            stop_owned_process "$pid" "$label" "$expected"
            return 0
        fi
        sleep 0.1
    done
}

cleanup() {
    CLEANUP_EXIT_CODE=$?
    set +e
    trap - EXIT INT TERM HUP

    if (( HELPER_LEASE_GUARD_OPEN == 1 )); then
        exec 8>&-
        HELPER_LEASE_GUARD_OPEN=0
    fi
    if (( FIFO_GUARD_OPEN == 1 )); then
        exec 9>&-
        FIFO_GUARD_OPEN=0
    fi
    stop_owned_process "$QUERY_PID" "MCP query" "$AGENT"
    stop_owned_process "$FOOTPRINT_PID" "footprint sampler" "$FOOTPRINT_TOOL"
    stop_owned_process "$HELPER_PID" "capture helper" "$HELPER"
    stop_owned_process "$AGENT_PID" "ingest agent" "$AGENT"
    stop_owned_process "$CORPUS_PID" "overlap corpus" "capture-overlap-corpus"
    stop_owned_process "$BACKGROUND_PID" "background corpus" "capture-overlap-background"
    if (( CORPUS_LAUNCH_ATTEMPTED == 1 )); then
        stop_owned_bundle_process "$CORPUS_BUNDLE_ID" "overlap corpus" \
            "$CORPUS_APP/Contents/MacOS/capture-overlap-corpus"
    fi
    if (( BACKGROUND_LAUNCH_ATTEMPTED == 1 )); then
        stop_owned_bundle_process "$BACKGROUND_BUNDLE_ID" "background corpus" \
            "$BACKGROUND_APP/Contents/MacOS/capture-overlap-background"
    fi
    if [[ -n "$CAPTURE_FIFO" && -p "$CAPTURE_FIFO" ]]; then
        rm -f "$CAPTURE_FIFO"
    fi
    if [[ -n "$HELPER_LEASE_FIFO" && -p "$HELPER_LEASE_FIFO" ]]; then
        rm -f "$HELPER_LEASE_FIFO"
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
        --signed-debug-qualification)
            SIGNED_DEBUG_QUALIFICATION=1
            shift
            ;;
        --keep-artifacts)
            KEEP_ARTIFACTS=1
            shift
            ;;
        --soak)
            SOAK_MODE=1
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
if (( SOAK_MODE == 1 )); then
    CAPTURE_SECONDS=1800
    KEEP_ARTIFACTS=1
    require_bounded_integer "--capture-seconds" "$CAPTURE_SECONDS" 1800
else
    require_bounded_integer "--capture-seconds" "$CAPTURE_SECONDS" 30
fi
require_bounded_integer "--startup-timeout" "$STARTUP_TIMEOUT" 300
require_bounded_integer "--query-timeout" "$QUERY_TIMEOUT" 300

[[ "$(uname -s)" == "Darwin" ]] || fail "live capture verification requires macOS"
[[ -d "$APP_PATH" ]] || fail "assembled app does not exist: $APP_PATH"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd -P)/$(basename "$APP_PATH")"

for command in awk codesign openssl python3 rg shasum strings; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done
for executable in /usr/bin/open /usr/bin/lsappinfo /usr/sbin/ioreg /usr/libexec/PlistBuddy; do
    [[ -x "$executable" ]] || fail "required macOS tool is missing: $executable"
done
[[ -x "$SESSION_CHECK" ]] || fail "session checker is missing: $SESSION_CHECK"
[[ -x "$MEMORY_CHECK" ]] || fail "memory checker is missing: $MEMORY_CHECK"
[[ -x "$SOAK_REPORTER" ]] || fail "soak reporter is missing: $SOAK_REPORTER"
[[ -x "$PRODUCT_SOURCE_DIGEST_TOOL" ]] \
    || fail "product source digest tool is missing: $PRODUCT_SOURCE_DIGEST_TOOL"
[[ -x "$BUILD_PROVENANCE_TOOL" ]] \
    || fail "build provenance tool is missing: $BUILD_PROVENANCE_TOOL"
[[ -x "$FOOTPRINT_TOOL" ]] || fail "footprint sampler is missing: $FOOTPRINT_TOOL"
[[ -x "$CORPUS_BUILD" ]] || fail "overlap corpus builder is missing: $CORPUS_BUILD"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
HELPER="$APP_PATH/Contents/MacOS/MCICaptureHelper"
AGENT="$APP_PATH/Contents/MacOS/mci-agent"
BUILD_PROVENANCE="$APP_PATH/Contents/Resources/build-provenance.json"
[[ -f "$INFO_PLIST" ]] || fail "assembled app has no Contents/Info.plist"
[[ -x "$HELPER" ]] || fail "assembled app has no executable MCICaptureHelper"
[[ -x "$AGENT" ]] || fail "assembled app has no executable mci-agent"
[[ -f "$BUILD_PROVENANCE" ]] \
    || fail "assembled app has no signed build-provenance.json"

repo_head="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" \
    || fail "could not resolve the qualification checkout HEAD"
source_digest="$(python3 "$PRODUCT_SOURCE_DIGEST_TOOL" --repo-root "$REPO_ROOT")" \
    || fail "could not compute the qualification checkout source digest"
PROVENANCE_VERIFY_ARGS=(
    verify
    --app "$APP_PATH"
    --expected-source-head "$repo_head"
    --expected-source-digest "$source_digest"
)
if (( SIGNED_DEBUG_QUALIFICATION == 1 )); then
    PROVENANCE_VERIFY_ARGS+=(--require-current-source)
fi
if ! python3 "$BUILD_PROVENANCE_TOOL" "${PROVENANCE_VERIFY_ARGS[@]}"; then
    fail "assembled app is not mechanically bound to the current product source"
fi

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}
app_sha256="$(sha256_file "$APP_PATH/Contents/MacOS/Hippocampus")"
helper_sha256="$(sha256_file "$HELPER")"
agent_sha256="$(sha256_file "$AGENT")"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$bundle_id" == "ai.hippocampus" ]] \
    || fail "unexpected Hippocampus bundle id: ${bundle_id:-missing}"
development_key_enabled="$(/usr/libexec/PlistBuddy \
    -c 'Print :MCIDevelopmentFileKeyEnabled' "$INFO_PLIST" 2>/dev/null || true)"
codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 \
    || fail "assembled app fails codesign verification"
app_signature="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
helper_signature="$(codesign -dv --verbose=4 "$HELPER" 2>&1)"
app_cdhash="$(printf '%s\n' "$app_signature" | sed -n 's/^CDHash=//p')"
helper_cdhash="$(printf '%s\n' "$helper_signature" | sed -n 's/^CDHash=//p')"
if (( SIGNED_DEBUG_QUALIFICATION == 1 )); then
    apple_developer_id_requirement="=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_QUALIFICATION_TEAM_ID\""
    verify_apple_developer_id_trust() {
        local executable="$1"
        local label="$2"
        codesign --verify --strict --test-requirement \
            "$apple_developer_id_requirement" "$executable" >/dev/null 2>&1 \
            || fail "$label is not signed by the Apple-anchored production Developer ID identity"
    }
    verify_apple_developer_id_trust "$APP_PATH" "qualification host app"
    verify_apple_developer_id_trust "$HELPER" "qualification capture helper"
    [[ "$development_key_enabled" != "true" ]] \
        || fail "signed debug qualification app must not expose file-key authority through its Info.plist"
    app_team_id="$(printf '%s\n' "$app_signature" | sed -n 's/^TeamIdentifier=//p')"
    helper_team_id="$(printf '%s\n' "$helper_signature" | sed -n 's/^TeamIdentifier=//p')"
    [[ -n "$app_team_id" && "$app_team_id" != "not set" ]] \
        || fail "developer-id qualification requires a stable TeamIdentifier"
    [[ "$helper_team_id" == "$app_team_id" ]] \
        || fail "qualification helper TeamIdentifier does not match its host app"
    [[ "$app_team_id" == "$EXPECTED_QUALIFICATION_TEAM_ID" ]] \
        || fail "qualification identity does not match the production TeamIdentifier $EXPECTED_QUALIFICATION_TEAM_ID"
    printf '%s\n' "$app_signature" | rg -q '^Authority=Developer ID Application:' \
        || fail "signed debug qualification requires a Developer ID Application authority"
    printf '%s\n' "$helper_signature" | rg -q '^Authority=Developer ID Application:' \
        || fail "signed debug qualification helper requires a Developer ID Application authority"
    helper_strings="$(strings -a "$HELPER")"
    [[ "$helper_strings" == *"--live-overlap-qualification"* ]] \
        || fail "signed helper does not contain the debug-only live OCR qualification capability"
    unset helper_strings
else
    [[ "$development_key_enabled" == "true" ]] \
        || fail "app is not an explicit development-file-key artifact; assemble with --debug --development-ad-hoc"
    if ! codesign -dv --verbose=2 "$APP_PATH" 2>&1 | rg -q '^Signature=adhoc$'; then
        fail "development-file-key verifier requires an ad-hoc development app"
    fi
fi

session_summary="$(/usr/sbin/ioreg -n Root -d1 -a \
    | python3 "$SESSION_CHECK" --expected-uid "$(id -u)" --expected-user "$(id -un)")" \
    || fail "no unlocked GUI session is available; see the session preflight message above"
printf 'Preflight: %s\n' "$session_summary"

existing_corpus_asn="$(/usr/bin/lsappinfo find bundleid="$CORPUS_BUNDLE_ID" 2>/dev/null || true)"
[[ -z "$existing_corpus_asn" ]] \
    || fail "the overlap corpus is already running; quit that instance so PID ownership is unambiguous"
existing_background_asn="$(/usr/bin/lsappinfo find bundleid="$BACKGROUND_BUNDLE_ID" 2>/dev/null || true)"
[[ -z "$existing_background_asn" ]] \
    || fail "the background corpus is already running; quit that instance so PID ownership is unambiguous"

if (( PREFLIGHT_ONLY == 1 )); then
    printf 'PREFLIGHT ONLY: app and unlocked-session gates passed; configured capture_seconds=%s soak=%s; live capture was not run.\n' \
        "$CAPTURE_SECONDS" "$SOAK_MODE"
    RUN_SUCCEEDED=1
    exit 0
fi

# The agent's page-content endpoint is an AF_UNIX socket below the isolated
# home. Darwin limits sockaddr_un paths to 104 bytes, while the per-user
# TMPDIR prefix alone can exceed 60. Keep this verifier root intentionally
# short so unrelated socket startup never degrades the capture proof.
RUN_ROOT="$(mktemp -d "/tmp/hippo-live.XXXXXX")"
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
HELPER_LEASE_FIFO="$RUN_ROOT/helper-lease.fifo"
READINESS_FILE="$RUN_ROOT/helper-readiness.json"
CORPUS_APP="$RUN_ROOT/CaptureOverlapCorpus.app"
BACKGROUND_APP="$RUN_ROOT/CaptureOverlapBackground.app"
CORPUS_STDOUT="$LOG_DIR/corpus.stdout"
CORPUS_STDERR="$LOG_DIR/corpus.stderr"
BACKGROUND_STDOUT="$LOG_DIR/background.stdout"
BACKGROUND_STDERR="$LOG_DIR/background.stderr"
HELPER_STDOUT="$LOG_DIR/helper.stdout"
HELPER_STDERR="$LOG_DIR/helper.stderr"
AGENT_STDOUT="$LOG_DIR/agent.stdout"
AGENT_STDERR="$LOG_DIR/agent.stderr"
MCP_REQUESTS="$LOG_DIR/mcp.requests.jsonl"
MCP_RESPONSES="$LOG_DIR/mcp.responses.jsonl"
MCP_STDERR="$LOG_DIR/mcp.stderr"
VERIFY_STDOUT="$LOG_DIR/verify.stdout"
VERIFY_STDERR="$LOG_DIR/verify.stderr"
FOOTPRINT_CSV="$LOG_DIR/helper-footprint.csv"
SOAK_REPORT="$RUN_ROOT/capture-soak-report.json"

mkdir -p "$LOG_DIR" "$SUPPORT_DIR" "$(dirname "$DEVICE_ID")"
chmod 700 "$ISOLATED_HOME" "$SUPPORT_DIR" "$(dirname "$DEVICE_ID")"

{
    printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo_head=%s\n' "$repo_head"
    printf 'source_digest=%s\n' "$source_digest"
    printf 'app_binary_sha256=%s\n' "$app_sha256"
    printf 'helper_sha256=%s\n' "$helper_sha256"
    printf 'agent_sha256=%s\n' "$agent_sha256"
    printf 'app_cdhash=%s\n' "$app_cdhash"
    printf 'helper_cdhash=%s\n' "$helper_cdhash"
    printf 'app=%s\n' "$APP_PATH"
    printf 'background_app=%s\n' "$BACKGROUND_APP"
    printf 'helper=%s\n' "$HELPER"
    printf 'agent=%s\n' "$AGENT"
    printf 'capture_seconds=%s\n' "$CAPTURE_SECONDS"
    printf 'signed_debug_qualification=%s\n' "$SIGNED_DEBUG_QUALIFICATION"
    printf 'expected_qualification_team_id=%s\n' "$EXPECTED_QUALIFICATION_TEAM_ID"
    printf 'focused_token=%s\n' "$FOCUSED_TOKEN"
    printf 'background_token=%s\n' "$BACKGROUND_TOKEN"
    printf 'focus_control_token=%s\n' "$FOCUS_CONTROL_TOKEN"
    printf 'session=%s\n' "$session_summary"
} > "$RUN_ROOT/metadata.txt"
chmod 600 "$RUN_ROOT/metadata.txt"

printf '\n==> Building deterministic overlap corpus\n'
if ! "$CORPUS_BUILD" "$CORPUS_APP" "$BACKGROUND_APP" \
    >"$LOG_DIR/corpus-build.stdout" 2>"$LOG_DIR/corpus-build.stderr"; then
    tail -n 40 "$LOG_DIR/corpus-build.stderr" >&2 || true
    fail "overlap corpus build failed"
fi
codesign --verify --strict "$CORPUS_APP" >/dev/null 2>&1 \
    || fail "built overlap corpus fails codesign verification"
codesign --verify --strict "$BACKGROUND_APP" >/dev/null 2>&1 \
    || fail "built background corpus fails codesign verification"
strings "$CORPUS_APP/Contents/MacOS/capture-overlap-corpus" \
    > "$LOG_DIR/corpus-executable.strings"
strings "$BACKGROUND_APP/Contents/MacOS/capture-overlap-background" \
    > "$LOG_DIR/background-executable.strings"
for token in "$FOCUSED_TOKEN" "$BACKGROUND_TOKEN" "$FOCUS_CONTROL_TOKEN"; do
    grep -Fq "$token" "$LOG_DIR/corpus-executable.strings" \
        || fail "built overlap corpus is missing deterministic token: $token"
done
grep -Fq "$BACKGROUND_TOKEN" "$LOG_DIR/background-executable.strings" \
    || fail "built background corpus is missing its deterministic token"

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

frontmost_bundle_id() {
    local asn
    asn="$(/usr/bin/lsappinfo front 2>/dev/null || true)"
    [[ -n "$asn" ]] || return 1
    /usr/bin/lsappinfo info -only bundleid "$asn" 2>/dev/null \
        | sed -nE 's/^"CFBundleIdentifier"="(.*)"$/\1/p'
}

printf '\n==> Launching separate background corpus\n'
BACKGROUND_LAUNCH_ATTEMPTED=1
/usr/bin/open -n -F -o "$BACKGROUND_STDOUT" --stderr "$BACKGROUND_STDERR" \
    "$BACKGROUND_APP" --args --background-only \
    || fail "LaunchServices could not open the background corpus"

deadline=$((SECONDS + STARTUP_TIMEOUT))
while (( SECONDS < deadline )); do
    if [[ -z "$BACKGROUND_PID" ]]; then
        BACKGROUND_PID="$(app_pid_from_launch_services "$BACKGROUND_BUNDLE_ID" || true)"
    fi
    if [[ -n "$BACKGROUND_PID" ]] \
        && rg -q '^capture-overlap-background ready$' "$BACKGROUND_STDOUT" 2>/dev/null; then
        break
    fi
    sleep 0.25
done
[[ -n "$BACKGROUND_PID" ]] \
    || fail "background corpus launched but no owned PID appeared in LaunchServices"
kill -0 "$BACKGROUND_PID" 2>/dev/null || fail "background corpus exited during startup"
rg -q '^capture-overlap-background ready$' "$BACKGROUND_STDOUT" 2>/dev/null \
    || fail "background corpus did not publish its readiness line"

printf '\n==> Launching focused corpus and proving it is frontmost\n'
CORPUS_OPEN_ARGS=(-n -F -o "$CORPUS_STDOUT" --stderr "$CORPUS_STDERR" "$CORPUS_APP")
if (( SOAK_MODE == 1 )); then
    CORPUS_OPEN_ARGS+=(--args --focus-churn)
fi
CORPUS_LAUNCH_ATTEMPTED=1
/usr/bin/open "${CORPUS_OPEN_ARGS[@]}" \
    || fail "LaunchServices could not open the overlap corpus"

deadline=$((SECONDS + STARTUP_TIMEOUT))
while (( SECONDS < deadline )); do
    if [[ -z "$CORPUS_PID" ]]; then
        CORPUS_PID="$(app_pid_from_launch_services "$CORPUS_BUNDLE_ID" || true)"
    fi
    front_bundle="$(frontmost_bundle_id || true)"
    if [[ -n "$CORPUS_PID" && "$front_bundle" != "$CORPUS_BUNDLE_ID" ]]; then
        # Reopening an already-running app asks LaunchServices to activate it
        # without adding an Automation/Accessibility permission dependency.
        /usr/bin/open "$CORPUS_APP" >/dev/null 2>&1 || true
        front_bundle="$(frontmost_bundle_id || true)"
    fi
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
    || fail "overlap corpus did not become frontmost within ${STARTUP_TIMEOUT}s; unlock the Mac and dismiss any system dialog"
rg -q '^capture-overlap-corpus ready$' "$CORPUS_STDOUT" 2>/dev/null \
    || fail "overlap corpus became frontmost but did not publish its readiness line"

printf '\n==> Starting assembled helper and agent through the isolated FIFO\n'
mkfifo "$CAPTURE_FIFO"
chmod 600 "$CAPTURE_FIFO"
exec 9<> "$CAPTURE_FIFO"
FIFO_GUARD_OPEN=1
mkfifo "$HELPER_LEASE_FIFO"
chmod 600 "$HELPER_LEASE_FIFO"
exec 8<> "$HELPER_LEASE_FIFO"
HELPER_LEASE_GUARD_OPEN=1

"$AGENT" --device-id-path "$DEVICE_ID" --log-path "$HEALTH_LOG" \
    --db-path "$DB_PATH" --drain-stdin --strict 8>&- 9>&- < "$CAPTURE_FIFO" \
    >"$AGENT_STDOUT" 2>"$AGENT_STDERR" &
AGENT_PID=$!

generation="live-overlap-$(date +%s)-$$"
"$HELPER" --capture --parent-lease-stdin --live-overlap-qualification \
    --output "$CAPTURE_FIFO" \
    --heartbeat-seconds 2 --readiness-file "$READINESS_FILE" \
    --generation "$generation" 8>&- 9>&- < "$HELPER_LEASE_FIFO" \
    >"$HELPER_STDOUT" 2>"$HELPER_STDERR" &
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
    elif [[ -f "$agent_log" ]] && rg -qi 'BRAIN OPEN FAILED|open brain|integrity_check FAILED|writer.*lease' "$agent_log"; then
        printf 'Action: the isolated encrypted brain could not open safely. Inspect agent.stderr and confirm no prior verifier process still owns the writer lease.\n' >&2
    else
        printf 'Action: inspect helper.stderr and agent.stderr in the retained evidence directory; no live success was recorded.\n' >&2
    fi
}

runtime_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    if [[ "$1" == overlap\ corpus\ lost\ frontmost* ]]; then
        printf 'Action: leave the Mac unlocked and untouched while the corpus runs; capture stopped before accepting another app as evidence.\n' >&2
    else
        runtime_diagnostic
    fi
    [[ ! -f "$HELPER_STDERR" ]] || tail -n 30 "$HELPER_STDERR" >&2
    [[ ! -f "$AGENT_STDERR" ]] || tail -n 30 "$AGENT_STDERR" >&2
    exit 1
}

frontmost_runtime_fail() {
    local phase="$1"
    if [[ -z "$front_bundle" ]]; then
        runtime_fail "frontmost query unavailable during $phase"
    fi
    runtime_fail "overlap corpus lost frontmost status during $phase"
}

ensure_corpus_frontmost() {
    local phase="$1"
    [[ "$front_bundle" == "$CORPUS_BUNDLE_ID" ]] && return 0
    frontmost_runtime_fail "$phase"
}

deadline=$((SECONDS + STARTUP_TIMEOUT))
while [[ ! -f "$READINESS_FILE" ]] && (( SECONDS < deadline )); do
    kill -0 "$BACKGROUND_PID" 2>/dev/null || runtime_fail "background corpus exited before helper readiness"
    kill -0 "$CORPUS_PID" 2>/dev/null || runtime_fail "overlap corpus exited before helper readiness"
    kill -0 "$HELPER_PID" 2>/dev/null || runtime_fail "capture helper exited before readiness"
    kill -0 "$AGENT_PID" 2>/dev/null || runtime_fail "ingest agent exited before helper readiness"
    front_bundle="$(frontmost_bundle_id || true)"
    ensure_corpus_frontmost "helper startup"
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

"$FOOTPRINT_TOOL" "$HELPER_PID" 5 "$FOOTPRINT_CSV" 8>&- 9>&- \
    >"$LOG_DIR/footprint.stdout" 2>"$LOG_DIR/footprint.stderr" &
FOOTPRINT_PID=$!

printf 'Capturing focused corpus for %ss...\n' "$CAPTURE_SECONDS"
deadline=$((SECONDS + CAPTURE_SECONDS))
while (( SECONDS < deadline )); do
    kill -0 "$BACKGROUND_PID" 2>/dev/null || runtime_fail "background corpus exited during capture"
    kill -0 "$CORPUS_PID" 2>/dev/null || runtime_fail "overlap corpus exited during capture"
    kill -0 "$HELPER_PID" 2>/dev/null || runtime_fail "capture helper exited during capture"
    kill -0 "$AGENT_PID" 2>/dev/null || runtime_fail "ingest agent exited during capture"
    kill -0 "$FOOTPRINT_PID" 2>/dev/null || runtime_fail "footprint sampler exited during capture"
    front_bundle="$(frontmost_bundle_id || true)"
    ensure_corpus_frontmost "capture"
    sleep 0.5
done

printf '\n==> Closing capture and waiting for the writer lease to release\n'
exec 8>&-
HELPER_LEASE_GUARD_OPEN=0
deadline=$((SECONDS + STARTUP_TIMEOUT))
while kill -0 "$HELPER_PID" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.1
done
if kill -0 "$HELPER_PID" 2>/dev/null; then
    runtime_fail "capture helper did not exit after its parent-lifetime lease closed"
fi
set +e
wait "$HELPER_PID" 2>/dev/null
helper_exit=$?
set -e
HELPER_PID=""
(( helper_exit == 0 )) || runtime_fail "capture helper exited with status $helper_exit"
rm -f "$HELPER_LEASE_FIFO"
HELPER_LEASE_FIFO=""
wait "$FOOTPRINT_PID" 2>/dev/null || true
FOOTPRINT_PID=""
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
if ! rg -q 'drained [0-9]+ frame\(s\); [0-9]+ logged, [0-9]+ non-health, [1-9][0-9]* to brain' "$AGENT_STDERR"; then
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

VERIFY_ARGS=(verify --responses "$MCP_RESPONSES")
if (( SOAK_MODE == 1 )); then
    VERIFY_ARGS+=(--require-focus-control)
fi
if ! python3 "$MEMORY_CHECK" "${VERIFY_ARGS[@]}" \
    > "$VERIFY_STDOUT" 2> "$VERIFY_STDERR"; then
    cat "$VERIFY_STDERR" >&2
    runtime_fail "focused-only memory proof failed"
fi
cat "$VERIFY_STDOUT"

printf '\n==> Summarizing content-free capture and footprint evidence\n'
set +e
python3 "$SOAK_REPORTER" \
    --health-jsonl "$HEALTH_LOG" \
    --footprint-csv "$FOOTPRINT_CSV" \
    --memory-json "$VERIFY_STDOUT" \
    --brain-dir "$SUPPORT_DIR" \
    --capture-seconds "$CAPTURE_SECONDS" \
    --output "$SOAK_REPORT"
report_exit=$?
set -e
if (( report_exit == 2 )); then
    runtime_fail "capture evidence could not be summarized"
fi
if (( SOAK_MODE == 1 && report_exit != 0 )); then
    runtime_fail "30-minute capture soak did not meet its qualification gates"
fi

RUN_SUCCEEDED=1
if (( SOAK_MODE == 1 )); then
    printf 'PASS: 30-minute capture soak qualified; evidence retained at %s.\n' "$RUN_ROOT"
else
    printf 'PASS: live focused-window overlap verified: focused token present, background token absent.\n'
fi
