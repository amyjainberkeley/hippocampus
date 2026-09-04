#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-live-capture-overlap.sh"
SESSION_CHECK="$SCRIPT_DIR/live-capture/check_session.py"
MEMORY_CHECK="$SCRIPT_DIR/live-capture/verify_memory.py"
SOAK_REPORT="$SCRIPT_DIR/live-capture/summarize_soak.py"
STREAM_POLICY="$SCRIPT_DIR/../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/StreamConfig.swift"
CAPTURE_SESSION="$SCRIPT_DIR/../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SCStreamCaptureSession.swift"
FOCUS_TRACKER="$SCRIPT_DIR/../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Context/FocusTracker.swift"
HELPER_MAIN="$SCRIPT_DIR/../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift"
OCR_EMITTER="$SCRIPT_DIR/../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/OCRPostAllowEmitter.swift"
SUPPRESSION_CASCADE="$SCRIPT_DIR/../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Suppression/SuppressionCascade.swift"
FIXTURE_DIR="$SCRIPT_DIR/live-capture/fixtures"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-live-contract.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_literal() {
    local literal="$1"
    local message="$2"
    rg -Fq -- "$literal" "$RUNNER" || fail "$message"
}

[[ -x "$RUNNER" ]] || fail "live overlap runner is missing or not executable"
[[ -x "$SESSION_CHECK" ]] || fail "session preflight checker is missing or not executable"
[[ -x "$MEMORY_CHECK" ]] || fail "memory response checker is missing or not executable"
[[ -x "$SOAK_REPORT" ]] || fail "capture soak reporter is missing or not executable"
rg -Fq 'minimumFrameIntervalMs: 500,' "$STREAM_POLICY" \
    || fail "active capture default must honor the documented 2 fps energy ceiling"
if rg -Fq 'SCScreenshotManager.captureSampleBuffer(' "$CAPTURE_SESSION"; then
    fail "capture snapshots must not bypass stream lifecycle and ordering ownership"
fi
if rg -Fq 'updateContentFilter(' "$CAPTURE_SESSION"; then
    fail "focus changes must replace the stream so callbacks keep immutable generation provenance"
fi
rg -Fq 'requiredFocusGeneration: streamFocusGeneration(stream)' "$CAPTURE_SESSION" \
    || fail "every stream callback must carry the generation of the stream that produced it"
rg -Fq 'status == .complete || status == .started' "$CAPTURE_SESSION" \
    || fail "a new stream must admit its initial started frame for static windows"
rg -Fq 'focusTracker?.refreshBindingOnceSync()' "$CAPTURE_SESSION" \
    || fail "an OCR-eligible callback must revalidate focus before generation admission"
rg -Fq 'await focusTracker?.refreshOnce()' "$CAPTURE_SESSION" \
    || fail "startup must await an initial focus observation before choosing a capture filter"
rg -Fq 'public func refreshOnce() async' "$FOCUS_TRACKER" \
    || fail "the focus tracker must expose a deterministic one-shot startup refresh"
rg -Fq 'store.storeSync(focused)' "$FOCUS_TRACKER" \
    || fail "focus polling must publish in serial queue order without detached-task reordering"
if rg -Fq 'Task.detached(priority: .utility)' "$FOCUS_TRACKER"; then
    fail "focus polling must not publish observations through unordered detached tasks"
fi
python3 - "$CAPTURE_SESSION" <<'PY'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
gate = source.index("if focusedWindowStore != nil {")
privacy = source.index("let privacySnapshot = pipelineSnapshot.snapshotPixelPrivacy(")
baseline = source.index("self.commitPriorDHash(")
refresh = source.index("focusTracker?.refreshBindingOnceSync()")
if refresh > gate:
    raise SystemExit("focus identity must be revalidated before generation admission")
if baseline < gate:
    raise SystemExit("race-rejected frames must not mutate the accepted-frame dHash baseline")
if baseline < privacy:
    raise SystemExit("privacy-suppressed frames must not mutate the accepted-frame dHash baseline")
PY

bash -n "$RUNNER"
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$SESSION_CHECK"
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$MEMORY_CHECK"
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$SOAK_REPORT"

cat > "$TMP_ROOT/health.jsonl" <<'EOF'
{"wall_ts":"2026-09-03T00:00:00Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":0,"frames_delivered":1,"frames_suppressed":0,"frames_redacted_by_failsafe":0,"cascade_forced_count":0,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0,"frames_encode_failed":0,"frames_focus_race_dropped":0,"failsafe_by_app":{},"cpu_pct_micro":10000,"rss_bytes":104857600,"tracker_alive_at_us":0}
{"wall_ts":"2026-09-03T00:30:00Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":1800000,"frames_delivered":900,"frames_suppressed":600,"frames_redacted_by_failsafe":0,"cascade_forced_count":1,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0,"frames_encode_failed":0,"frames_focus_race_dropped":1,"failsafe_by_app":{},"cpu_pct_micro":120000,"rss_bytes":314572800,"tracker_alive_at_us":0}
EOF

cat > "$TMP_ROOT/footprint.csv" <<'EOF'
ts_unix,helper_pid,rss_kb,cpu_pct
1,42,102400,1.0
2,42,204800,4.0
3,42,307200,12.0
EOF

cat > "$TMP_ROOT/memory.json" <<'EOF'
{"background_token_present":false,"corpus_event_count":600,"focused_recall_outcome":"degraded","focused_token_present":true,"timeline_event_count":600}
EOF

mkdir -p "$TMP_ROOT/brain/blobs"
truncate -s 4096 "$TMP_ROOT/brain/mci.sqlite"
truncate -s 1024 "$TMP_ROOT/brain/blobs/a.bin"

python3 "$SOAK_REPORT" \
    --health-jsonl "$TMP_ROOT/health.jsonl" \
    --footprint-csv "$TMP_ROOT/footprint.csv" \
    --memory-json "$TMP_ROOT/memory.json" \
    --brain-dir "$TMP_ROOT/brain" \
    --capture-seconds 1800 \
    --minimum-health-samples 2 \
    --minimum-footprint-samples 3 \
    --output "$TMP_ROOT/soak-report.json"

python3 - "$TMP_ROOT/soak-report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["qualified"] is True, report
assert report["capture"]["frames_delivered"] == 900, report
assert report["capture"]["ocr_events"] == 600, report
assert report["capture"]["keyframes_retained"] == 1, report
assert report["resources"]["helper_cpu_pct_p95"] == 12.0, report
assert report["resources"]["helper_rss_bytes_p95"] == 314572800, report
assert report["storage"]["total_bytes"] == 5120, report
PY

if python3 "$SOAK_REPORT" \
    --health-jsonl "$TMP_ROOT/health.jsonl" \
    --footprint-csv "$TMP_ROOT/footprint.csv" \
    --memory-json "$TMP_ROOT/memory.json" \
    --brain-dir "$TMP_ROOT/brain" \
    --capture-seconds 1799 \
    --minimum-health-samples 2 \
    --minimum-footprint-samples 3 \
    --output "$TMP_ROOT/short-report.json"; then
    fail "a sub-30-minute run must not qualify as the release soak"
fi
python3 - "$TMP_ROOT/short-report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert report["qualified"] is False, report
assert "capture_duration_below_1800_seconds" in report["failures"], report
PY

cat > "$TMP_ROOT/high-cpu.csv" <<'EOF'
ts_unix,helper_pid,rss_kb,cpu_pct
1,42,102400,1.0
2,42,204800,16.0
EOF
if python3 "$SOAK_REPORT" \
    --health-jsonl "$TMP_ROOT/health.jsonl" \
    --footprint-csv "$TMP_ROOT/high-cpu.csv" \
    --memory-json "$TMP_ROOT/memory.json" \
    --brain-dir "$TMP_ROOT/brain" \
    --capture-seconds 1800 \
    --minimum-health-samples 2 \
    --minimum-footprint-samples 2 \
    --output "$TMP_ROOT/high-cpu-report.json" > /dev/null; then
    fail "a helper over the documented CPU envelope must not qualify"
fi
python3 - "$TMP_ROOT/high-cpu-report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert "helper_cpu_p95_above_15_percent" in report["failures"], report
PY

cat > "$TMP_ROOT/leaked-memory.json" <<'EOF'
{"background_token_present":true,"corpus_event_count":600,"focused_recall_outcome":"degraded","focused_token_present":true,"timeline_event_count":600}
EOF
if python3 "$SOAK_REPORT" \
    --health-jsonl "$TMP_ROOT/health.jsonl" \
    --footprint-csv "$TMP_ROOT/footprint.csv" \
    --memory-json "$TMP_ROOT/leaked-memory.json" \
    --brain-dir "$TMP_ROOT/brain" \
    --capture-seconds 1800 \
    --minimum-health-samples 2 \
    --minimum-footprint-samples 3 \
    --output "$TMP_ROOT/leaked-report.json" > /dev/null; then
    fail "a background-token leak must not qualify"
fi
python3 - "$TMP_ROOT/leaked-report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert "background_token_present" in report["failures"], report
PY

if python3 "$SOAK_REPORT" \
    --health-jsonl "$TMP_ROOT/health.jsonl" \
    --footprint-csv "$TMP_ROOT/footprint.csv" \
    --memory-json "$TMP_ROOT/memory.json" \
    --brain-dir "$TMP_ROOT/brain" \
    --capture-seconds 1800 \
    --minimum-health-samples 3 \
    --minimum-footprint-samples 3 \
    --output "$TMP_ROOT/sparse-report.json" > /dev/null; then
    fail "a soak with missing health coverage must not qualify"
fi
python3 - "$TMP_ROOT/sparse-report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
assert "insufficient_health_samples" in report["failures"], report
PY

if "$RUNNER" --not-a-real-option >"$TMP_ROOT/bad-arg.out" 2>&1; then
    fail "unknown runner arguments must fail"
fi
rg -q 'unknown option' "$TMP_ROOT/bad-arg.out" \
    || fail "unknown argument failure is not actionable"

if "$RUNNER" --app >"$TMP_ROOT/missing-value.out" 2>&1; then
    fail "--app without a value must fail"
fi
rg -q -- '--app requires' "$TMP_ROOT/missing-value.out" \
    || fail "missing --app value is not actionable"

if "$RUNNER" --app "$TMP_ROOT/Missing.app" --capture-seconds 0 \
    >"$TMP_ROOT/bad-timeout.out" 2>&1; then
    fail "zero capture duration must fail"
fi
rg -q 'integer from 1 through' "$TMP_ROOT/bad-timeout.out" \
    || fail "invalid capture duration is not actionable"

if "$RUNNER" --preflight-only --app "$TMP_ROOT/Missing.app" \
    >"$TMP_ROOT/missing-app.out" 2>&1; then
    fail "preflight must reject a missing assembled app"
fi
rg -q 'assembled app does not exist' "$TMP_ROOT/missing-app.out" \
    || fail "missing-app preflight is not actionable"
if rg -q 'PASS: live' "$TMP_ROOT/missing-app.out"; then
    fail "preflight failure must never claim live capture passed"
fi

if "$RUNNER" --preflight-only --soak --capture-seconds 0 \
    --app "$TMP_ROOT/Missing.app" >"$TMP_ROOT/soak-config.out" 2>&1; then
    fail "soak preflight must still reject a missing assembled app"
fi
rg -q 'assembled app does not exist' "$TMP_ROOT/soak-config.out" \
    || fail "--soak must select its fixed duration before app preflight"
if rg -q 'unknown option\|integer from 1 through' "$TMP_ROOT/soak-config.out"; then
    fail "--soak must be recognized and override the short-run duration"
fi

cat "$FIXTURE_DIR/session-unlocked.plist" \
    | python3 "$SESSION_CHECK" --expected-uid 501 --expected-user amy \
        >"$TMP_ROOT/unlocked.out"
rg -q '^unlocked console session:' "$TMP_ROOT/unlocked.out" \
    || fail "unlocked fixture was not accepted"

if cat "$FIXTURE_DIR/session-locked.plist" \
    | python3 "$SESSION_CHECK" --expected-uid 501 --expected-user amy \
        >"$TMP_ROOT/locked.out" 2>&1; then
    fail "locked fixture must fail closed"
fi
rg -q 'screen is locked' "$TMP_ROOT/locked.out" \
    || fail "locked-session failure is not actionable"

if cat "$FIXTURE_DIR/session-unlocked.plist" \
    | python3 "$SESSION_CHECK" --expected-uid 502 --expected-user other \
        >"$TMP_ROOT/wrong-user.out" 2>&1; then
    fail "foreign console session must fail closed"
fi
rg -q 'does not belong to the invoking user' "$TMP_ROOT/wrong-user.out" \
    || fail "foreign-session failure is not actionable"

python3 "$MEMORY_CHECK" emit > "$TMP_ROOT/mcp.requests.jsonl"
[[ "$(wc -l < "$TMP_ROOT/mcp.requests.jsonl" | tr -d ' ')" == "5" ]] \
    || fail "memory checker did not emit the complete deterministic MCP probe"
python3 "$MEMORY_CHECK" verify \
    --responses "$FIXTURE_DIR/mcp-focused-only.jsonl" \
    > "$TMP_ROOT/mcp-success.out"
rg -q '"focused_token_present": true' "$TMP_ROOT/mcp-success.out" \
    || fail "focused-only MCP fixture was not accepted"

if python3 "$MEMORY_CHECK" verify \
    --responses "$FIXTURE_DIR/mcp-background-leak.jsonl" \
    > "$TMP_ROOT/mcp-leak.out" 2>&1; then
    fail "memory checker must reject a background-token leak"
fi
rg -q 'background token leaked' "$TMP_ROOT/mcp-leak.out" \
    || fail "background-token leak failure is not actionable"

if python3 "$MEMORY_CHECK" verify \
    --responses "$FIXTURE_DIR/mcp-hidden-background-hit.jsonl" \
    > "$TMP_ROOT/mcp-hidden-hit.out" 2>&1; then
    fail "memory checker must reject a full-text background candidate"
fi
rg -q 'full-text background query found a candidate' "$TMP_ROOT/mcp-hidden-hit.out" \
    || fail "hidden full-text candidate failure is not actionable"

require_literal 'trap cleanup EXIT' \
    "runner must clean up on normal exit"
require_literal 'trap on_signal INT TERM HUP' \
    "runner must clean up after interruption"
require_literal 'mkfifo "$CAPTURE_FIFO"' \
    "runner must use an isolated capture FIFO"
require_literal '8>&- 9>&- < "$CAPTURE_FIFO"' \
    "ingest agent must not inherit either FIFO guard writer"
require_literal '8>&- 9>&- < "$HELPER_LEASE_FIFO"' \
    "capture helper must not inherit either FIFO guard writer"
require_literal '"$FOOTPRINT_TOOL" "$HELPER_PID" 5 "$FOOTPRINT_CSV" 8>&- 9>&-' \
    "footprint sampler must not keep either FIFO guard writer alive"
require_literal 'MCI_DEVELOPMENT_FILE_KEY=1' \
    "runner must explicitly gate development file custody"
require_literal 'MCI_DB_KEY_FILE="$KEY_FILE"' \
    "runner must pass the key by file path"
require_literal 'unset MCI_DB_KEY_HEX' \
    "runner must not fall back to a raw key environment variable"
require_literal 'CFFIXED_USER_HOME="$ISOLATED_HOME"' \
    "runner must isolate Foundation user-domain paths as well as HOME"
require_literal 'mktemp -d "/tmp/hippo-live.XXXXXX"' \
    "runner must keep isolated Unix socket paths below macOS SUN_LEN"
require_literal '"$HELPER" --capture' \
    "runner must exercise the explicit live helper path"
require_literal '--parent-lease-stdin' \
    "runner must stop capture through the packaged parent-lifetime lease"
require_literal 'exec 8>&-' \
    "runner must close its helper lease writer to request graceful capture drain"
require_literal '--live-overlap-qualification' \
    "runner must use the narrow pre-release OCR qualification capability"
require_literal 'MCI_OCR_TRACE=1' \
    "runner must keep diagnostic OCR tracing on during qualification"
require_literal '"$AGENT" --db-path "$DB_PATH" mcp-serve' \
    "runner must query through the assembled agent"
require_literal 'FOCUSED_EVIDENCE_ZEPHYR_9241' \
    "runner must verify the deterministic focused token"
require_literal 'BACKGROUND_SECRET_NEBULA_7713' \
    "runner must verify the deterministic background token is absent"
require_literal 'lsappinfo front' \
    "runner must prove the corpus is frontmost"
require_literal 'check_session.py' \
    "runner must fail closed when the GUI session is unavailable or locked"
require_literal 'Evidence retained at:' \
    "runner must disclose retained failure evidence"
require_literal 'integrity_check FAILED' \
    "brain diagnostics must distinguish a failed integrity check from an ok result"
if rg -Fq "'BRAIN OPEN FAILED|open brain|integrity_check|writer.*lease'" "$RUNNER"; then
    fail "brain diagnostics must not classify integrity_check ok as a database failure"
fi

if rg -n '\$HELPER.*--probe-debug' "$RUNNER"; then
    fail "live qualification must not enable AX value logging"
fi
if rg -Fq 'frontmost: ${front_bundle' "$RUNNER"; then
    fail "live qualification diagnostics must not expose the frontmost bundle identifier"
fi
if rg -Fq 'wait "$HELPER_PID" 2>/dev/null || true' "$RUNNER"; then
    fail "live qualification must not discard the capture helper exit status"
fi
require_literal 'helper_exit=$?' \
    "runner must retain the capture helper exit status"
require_literal '(( helper_exit == 0 )) || runtime_fail' \
    "runner must fail qualification when the capture helper exits nonzero"
python3 - "$RUNNER" <<'PY'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
close_lease = source.index('exec 8>&-', source.index('==> Closing capture'))
wait_helper = source.index('wait "$HELPER_PID"', close_lease)
if close_lease > wait_helper:
    raise SystemExit("helper lease must close before waiting for graceful shutdown")
PY
rg -Fq 'exit(82)' "$HELPER_MAIN" \
    || fail "capture helper must exit nonzero when shutdown cannot stop capture"
python3 - "$HELPER_MAIN" <<'PY'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
stop_call = source.index("try await captureRuntime.session.stop()")
context_stop = source.index("captureRuntime.contextProvider.stop()", stop_call)
shutdown_block = source[stop_call:context_stop]
if "captureDrainFailed = true" not in shutdown_block:
    raise SystemExit("capture shutdown failure must arm the nonzero exit path")
PY
if rg -Fq 'bundle=\(' "$OCR_EMITTER" "$SUPPRESSION_CASCADE"; then
    fail "capture diagnostics must not log application bundle identifiers"
fi

if rg -n 'tccutil[[:space:]]+(reset|insert)|xattr[[:space:]].*(-d|-c)|spctl[[:space:]]+--add|pkill' \
    "$RUNNER" "$SESSION_CHECK" "$MEMORY_CHECK"; then
    fail "runner must not mutate TCC/Gatekeeper state or kill unowned processes"
fi
if rg -Fq 'rg -Eq' "$RUNNER"; then
    fail "runner must not pass grep-style combined flags to ripgrep"
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$RUNNER" "$0"
fi

if find "$SCRIPT_DIR/live-capture" -type d -name __pycache__ -print -quit \
    | grep -q .; then
    fail "focused contract test left Python bytecode in the worktree"
fi

printf 'PASS: live focused-window verifier contract is fail-closed and headless-safe\n'
