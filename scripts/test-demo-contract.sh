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
grep -Fq 'open -n -g' "$DEMO" || fail "demo boot must hand the packaged app to LaunchServices"
grep -Fq 'kill -0 "$app_pid"' "$DEMO" || fail "demo boot must verify the launched app remains alive"
grep -Fq 'KEY_FILE="$MCI_DIR/dev.key"' "$DEMO" || fail "seeders and packaged development app must share one fixed key path"
grep -Fq 'Contents/MacOS/recall-ui' "$DEMO" || fail "visual demo must use the bundled Recall executable"
grep -Fq 'MCI_INITIAL_TAB=now' "$DEMO" || fail "visual demo must open on the useful Now surface"
grep -Fq 'MCI_EPHEMERAL_UI_STATE=1' "$DEMO" || fail "demo UI state must not inherit the host saved query"
grep -Fq 'if screencapture -l "$WID" -o "$RAW_RECALL_SHOT"' "$DEMO" || fail "automatic screenshots must tolerate missing Screen Recording permission"
grep -Fq 'MCI_DB_KEYCHAIN_SERVICE' "$DEMO" || fail "demo commands must avoid the production Keychain reference"
grep -Fq 'ps -p "$pid" -o command=' "$DEMO" || fail "stale PID files must be identity-checked"
grep -Fq 'scripts/test-screenshot-assets.sh' "$DEMO" || fail "captured assets must pass the quality contract"
grep -Fq 'retrieval benchmark' "$DEMO" || fail "demo queries must match the current synthetic corpus"
grep -Fq 'agent context handoff' "$DEMO" || fail "MCP demo must exercise current agent context"
grep -Fq '"name":"mci_context"' "$DEMO" || fail "MCP demo must request the bounded cited handoff"
grep -Fq -- '--keyframe-digest' "$DEMO" || fail "demo seed must include authenticated visual evidence"
grep -Fq 'mci-seed-brief' "$DEMO" || fail "demo seed must include a daily brief"
grep -Fq -- '--model-id "hippocampus-extractive"' "$DEMO" || fail "demo brief must disclose extractive provenance"
grep -Fq 'target/release/mci-agent" enrich' "$DEMO" || fail "demo seed must run the production understanding pipeline"
grep -Fq 'DEMO_ARCTIC_MODEL="$REPO_ROOT/models/ArcticEmbedS_FP16.mlmodelc"' "$DEMO" \
    || fail "demo must resolve the verified repo-local Arctic model explicitly"
grep -Fq 'export MCI_ARCTIC_MODEL_PATH="$DEMO_ARCTIC_MODEL"' "$DEMO" \
    || fail "demo enrichment must receive the resolved Arctic model path"
grep -Fq 'DEGRADED: Arctic model unavailable; demo recall will be lexical-only.' "$DEMO" \
    || fail "demo must disclose lexical-only mode when Arctic is unavailable"
grep -Fq 'if (( embedded_count != 20 ))' "$DEMO" \
    || fail "semantic demo mode must assert that all synthetic events were embedded"
grep -Fq 'Semantic enrichment verified: 20/20 events embedded.' "$DEMO" \
    || fail "demo must report its verified semantic enrichment result"
grep -Fq 'sanitize-png-metadata.py' "$DEMO" \
    || fail "demo must remove private metadata from generated product captures"
grep -Fq '"name":"mci_episodes"' "$DEMO" || fail "MCP demo must exercise derived work episodes"

if grep -Fq 'MCI_DIR="$HOME/Library/Application Support/MCI"' "$DEMO"; then
    fail "demo must never point at the real memory database"
fi
if grep -Eq 'pkill[[:space:]]+-f' "$DEMO"; then
    fail "demo must stop only processes it started"
fi
if grep -Eq 'snowflake|Cure53|zero-knowledge' "$DEMO"; then
    fail "stale queries must not make the current demo look empty"
fi
if grep -Fq 'complete local models' "$DEMO"; then
    fail "demo must not claim optional local models are a release gate"
fi

printf 'PASS: demo stays disposable, bundled, and asset-verified\n'
