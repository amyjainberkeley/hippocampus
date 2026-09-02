#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$REPO_ROOT/scripts/demo.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

grep -Fq 'MCI_DEMO_ROOT' "$DEMO" || fail "demo root must be configurable"
grep -Fq 'hippocampus-demo-${UID}' "$DEMO" || fail "default demo root must be disposable and per-user"
grep -Fq 'CFFIXED_USER_HOME="$DEMO_HOME"' "$DEMO" || fail "Foundation apps must resolve user-domain paths inside the disposable home"
grep -Fq 'KEY_FILE="$MCI_DIR/dev.key"' "$DEMO" || fail "seeders and packaged development app must share one fixed key path"
grep -Fq 'Contents/MacOS/recall-ui' "$DEMO" || fail "visual demo must use the bundled Recall executable"
grep -Fq 'MCI_INITIAL_TAB=now' "$DEMO" || fail "visual demo must open on the useful Now surface"
grep -Fq 'MCI_DB_KEYCHAIN_SERVICE' "$DEMO" || fail "demo commands must avoid the production Keychain reference"
grep -Fq 'ps -p "$pid" -o command=' "$DEMO" || fail "stale PID files must be identity-checked"
grep -Fq 'scripts/test-screenshot-assets.sh' "$DEMO" || fail "captured assets must pass the quality contract"
grep -Fq 'retrieval benchmark' "$DEMO" || fail "demo queries must match the current synthetic corpus"
grep -Fq 'agent context handoff' "$DEMO" || fail "MCP demo must exercise current agent context"
grep -Fq '"name":"mci_context"' "$DEMO" || fail "MCP demo must request the bounded cited handoff"
grep -Fq -- '--keyframe-digest' "$DEMO" || fail "demo seed must include authenticated visual evidence"
grep -Fq 'mci-seed-brief' "$DEMO" || fail "demo seed must include a daily brief"

if grep -Fq 'MCI_DIR="$HOME/Library/Application Support/MCI"' "$DEMO"; then
    fail "demo must never point at the real memory database"
fi
if grep -Eq 'pkill[[:space:]]+-f' "$DEMO"; then
    fail "demo must stop only processes it started"
fi
if grep -Eq 'snowflake|Cure53|zero-knowledge' "$DEMO"; then
    fail "stale queries must not make the current demo look empty"
fi

printf 'PASS: demo stays disposable, bundled, and asset-verified\n'
