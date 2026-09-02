#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-live-capture-overlap.sh"
SESSION_CHECK="$SCRIPT_DIR/live-capture/check_session.py"
MEMORY_CHECK="$SCRIPT_DIR/live-capture/verify_memory.py"
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

bash -n "$RUNNER"
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$SESSION_CHECK"
PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache" python3 -m py_compile "$MEMORY_CHECK"

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

if rg -n 'tccutil[[:space:]]+(reset|insert)|xattr[[:space:]].*(-d|-c)|spctl[[:space:]]+--add|pkill' \
    "$RUNNER" "$SESSION_CHECK" "$MEMORY_CHECK"; then
    fail "runner must not mutate TCC/Gatekeeper state or kill unowned processes"
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$RUNNER" "$0"
fi

if find "$SCRIPT_DIR/live-capture" -type d -name __pycache__ -print -quit \
    | grep -q .; then
    fail "focused contract test left Python bytecode in the worktree"
fi

printf 'PASS: live focused-window verifier contract is fail-closed and headless-safe\n'
