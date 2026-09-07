#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEAN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-e2e.XXXXXX")"
CLEAN_HOME="$CLEAN_ROOT/home"
INSTALL_ROOT="$CLEAN_HOME/Applications/Hippocampus Engine"
DB_PATH="$CLEAN_HOME/Library/Application Support/MCI/mci.sqlite"
RUNTIME_CONFIG="$CLEAN_HOME/.config/hippocampus/runtime.toml"
KEY_FILE="$CLEAN_HOME/Library/Application Support/MCI/dev.key"
KEEP_ARTIFACTS="${MCI_E2E_KEEP_ARTIFACTS:-0}"
HOST_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
HOST_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"

cleanup() {
    if [[ "$KEEP_ARTIFACTS" == "1" ]]; then
        printf 'E2E artifacts retained at %s\n' "$CLEAN_ROOT"
    else
        rm -rf "$CLEAN_ROOT"
    fi
}
trap cleanup EXIT

step() {
    printf '\n==> %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

export HOME="$CLEAN_HOME"
export CARGO_HOME="$HOST_CARGO_HOME"
export RUSTUP_HOME="$HOST_RUSTUP_HOME"
export CODEX_HOME="$CLEAN_HOME/.codex"
export MCI_DB_PATH="$DB_PATH"
export MCI_DEVELOPMENT_FILE_KEY=1
export MCI_EMBEDDER_DISABLED=1
export MCI_CLAUDE_BINARY=/usr/bin/true
export MCI_CODEX_BINARY=/usr/bin/true

mkdir -p "$INSTALL_ROOT" "$(dirname "$DB_PATH")" "$(dirname "$RUNTIME_CONFIG")" "$CODEX_HOME"
chmod 700 "$CLEAN_HOME" "$(dirname "$DB_PATH")" "$CODEX_HOME"
printf 'capture_enabled = false\ncrash_report_opted_in = false\n' > "$RUNTIME_CONFIG"
chmod 644 "$RUNTIME_CONFIG"
printf '{}\n' > "$CLEAN_HOME/.claude.json"
: > "$CODEX_HOME/config.toml"

step "Build the product engine and fixture tools"
cargo build --quiet --jobs 2 -p mci-agent --bins --manifest-path "$REPO_ROOT/Cargo.toml"
for binary in mci-agent mci-brain mci-seed-brain mci-seed-brief mci-e2e-fixture; do
    source_path="$REPO_ROOT/target/debug/$binary"
    [[ -x "$source_path" ]] || fail "build did not produce $binary"
    cp "$source_path" "$INSTALL_ROOT/$binary"
done

AGENT="$INSTALL_ROOT/mci-agent"
BRAIN="$INSTALL_ROOT/mci-brain"
SEED="$INSTALL_ROOT/mci-seed-brain"
SEED_BRIEF="$INSTALL_ROOT/mci-seed-brief"
FIXTURE="$INSTALL_ROOT/mci-e2e-fixture"

step "Initialize isolated development custody"
( umask 077; openssl rand -hex 32 > "$KEY_FILE" )
chmod 600 "$KEY_FILE"
export MCI_DB_KEY_HEX
MCI_DB_KEY_HEX="$(tr -d '\r\n' < "$KEY_FILE")"
[[ ${#MCI_DB_KEY_HEX} -eq 64 ]] || fail "generated key has the wrong length"
[[ "$(stat -f '%Lp' "$KEY_FILE")" == "600" ]] || fail "development key is not mode 0600"

step "Verify capture defaults off, then import synthetic history"
rg -q '^capture_enabled = false$' "$RUNTIME_CONFIG" || fail "capture did not default off"
"$SEED" --db-path "$DB_PATH"
seed_stats="$("$BRAIN" stats --json)"
python3 - "$seed_stats" <<'PY'
import json
import sys

stats = json.loads(sys.argv[1])
if stats.get("event_count") != 20:
    raise SystemExit(f"expected 20 seeded events, got {stats}")
PY

step "Enable test capture and inject one production wire frame"
printf 'capture_enabled = true\ncrash_report_opted_in = false\n' > "$RUNTIME_CONFIG"
"$FIXTURE" emit-capture | "$AGENT" --drain-stdin --strict --db-path "$DB_PATH" \
    > "$CLEAN_ROOT/drain.jsonl" 2> "$CLEAN_ROOT/drain.stderr"
rg -q '^capture_enabled = true$' "$RUNTIME_CONFIG" || fail "test capture did not enable"
if rg -qi 'brain open failed|panic|fatal' "$CLEAN_ROOT/drain.stderr"; then
    cat "$CLEAN_ROOT/drain.stderr" >&2
    fail "capture ingest emitted a fatal brain diagnostic"
fi
capture_stats="$("$BRAIN" stats --json)"
python3 - "$capture_stats" <<'PY'
import json
import sys

stats = json.loads(sys.argv[1])
if stats.get("event_count") != 21:
    raise SystemExit(f"expected 21 events after injected capture, got {stats}")
PY

step "Derive episodes and seed the brief surface"
"$AGENT" enrich --db-path "$DB_PATH" --batch-size 32 > "$CLEAN_ROOT/enrich.stdout" \
    2> "$CLEAN_ROOT/enrich.stderr"
# Capture workers own today's and yesterday's briefs; reserve a separate fixture date.
brief_fixture_date="2000-01-01"
"$SEED_BRIEF" --date "$brief_fixture_date" > "$CLEAN_ROOT/brief.stdout" 2> "$CLEAN_ROOT/brief.stderr"
if "$SEED_BRIEF" --date "$brief_fixture_date" > "$CLEAN_ROOT/brief-duplicate.stdout" \
    2> "$CLEAN_ROOT/brief-duplicate.stderr"; then
    fail "duplicate brief write unexpectedly succeeded"
fi
rg -q 'already exists' "$CLEAN_ROOT/brief-duplicate.stderr" \
    || fail "brief readback did not find the seeded row"

step "Exercise search, timeline, episodes, and cited agent context over MCP"
python3 - "$AGENT" "$DB_PATH" "$CLEAN_ROOT/mcp.stderr" <<'PY'
import json
import os
import subprocess
import sys

agent, db_path, stderr_path = sys.argv[1:]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "mci_recall", "arguments": {"query": "release sentinel", "limit": 5}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
        "name": "mci_events_since", "arguments": {"ts_us": 0, "limit": 100}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
        "name": "mci_episodes", "arguments": {"limit": 20}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {
        "name": "mci_context", "arguments": {
            "focus": "Hippocampus release sentinel", "max_tokens": 600, "max_evidence": 12}}},
]
payload = "\n".join(json.dumps(request) for request in requests) + "\n"
completed = subprocess.run(
    [agent, "--db-path", db_path, "mcp-serve"],
    input=payload,
    text=True,
    capture_output=True,
    env=os.environ,
    timeout=30,
    check=False,
)
with open(stderr_path, "w", encoding="utf-8") as handle:
    handle.write(completed.stderr)
if completed.returncode != 0:
    raise SystemExit(f"MCP server failed ({completed.returncode}): {completed.stderr}")
responses = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
by_id = {response.get("id"): response for response in responses}
if set(by_id) != {1, 2, 3, 4, 5, 6}:
    raise SystemExit(f"missing MCP responses: {sorted(by_id)}")
tools = {tool["name"] for tool in by_id[2]["result"]["tools"]}
required = {"mci_recall", "mci_events_since", "mci_episodes", "mci_context"}
if not required.issubset(tools):
    raise SystemExit(f"missing tools: {sorted(required - tools)}")
recall = json.dumps(by_id[3]["result"])
if "release sentinel" not in recall:
    raise SystemExit(f"recall missed injected capture: {recall}")
timeline = by_id[4]["result"].get("events", [])
if len(timeline) != 21:
    raise SystemExit(f"timeline expected 21 events, got {len(timeline)}")
if not any(event.get("app_bundle_id") == "ai.hippocampus.e2e.capture" for event in timeline):
    raise SystemExit("timeline missed injected capture app")
episodes = by_id[5]["result"].get("episodes", [])
if not episodes:
    raise SystemExit("episode derivation returned no sessions")
context = by_id[6]["result"]
packet = context.get("packet", {})
if packet.get("outcome") not in {"evidence_backed", "observations_only"}:
    raise SystemExit(f"unexpected context outcome: {packet}")
citations = packet.get("citations", [])
if not any(citation.get("event_id") == 21 for citation in citations):
    raise SystemExit(f"context packet has no canonical event-21 citation: {packet}")
section_items = [
    item
    for section in packet.get("sections", [])
    for item in section.get("items", [])
]
if not any(21 in item.get("citation_event_ids", []) for item in section_items):
    raise SystemExit(f"context section is not linked to event 21: {packet}")
PY
if rg -qi 'brain open failed|panic|fatal' "$CLEAN_ROOT/mcp.stderr"; then
    cat "$CLEAN_ROOT/mcp.stderr" >&2
    fail "MCP server emitted a fatal brain diagnostic"
fi

step "Register Claude and Codex without serializing custody"
"$AGENT" connect --all --db-path "$DB_PATH" > "$CLEAN_ROOT/connect.stdout" \
    2> "$CLEAN_ROOT/connect.stderr"
require_file "$CLEAN_HOME/.claude.json"
require_file "$CODEX_HOME/config.toml"
rg -q 'MCI_DB_KEYCHAIN_SERVICE' "$CLEAN_HOME/.claude.json" \
    || fail "Claude registration has no Keychain reference"
rg -q 'MCI_DB_KEYCHAIN_SERVICE' "$CODEX_HOME/config.toml" \
    || fail "Codex registration has no Keychain reference"
if rg -q 'MCI_DB_KEY_HEX|MCI_DEVELOPMENT_FILE_KEY|dev\.key' \
    "$CLEAN_HOME/.claude.json" "$CODEX_HOME/config.toml"; then
    fail "client configuration contains reusable development custody"
fi
if rg -Fq "$MCI_DB_KEY_HEX" "$CLEAN_HOME/.claude.json" "$CODEX_HOME/config.toml"; then
    fail "client configuration contains the database key"
fi

step "Delete the injected memory and verify the row is gone"
delete_result="$("$FIXTURE" delete-event 21)"
python3 - "$delete_result" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
if result != {"deleted": 1, "event_id": 21}:
    raise SystemExit(f"unexpected deletion result: {result}")
PY
if "$BRAIN" show 21 --json > "$CLEAN_ROOT/deleted.stdout" 2> "$CLEAN_ROOT/deleted.stderr"; then
    fail "deleted event 21 is still readable"
fi
final_stats="$("$BRAIN" stats --json)"
python3 - "$final_stats" <<'PY'
import json
import sys

stats = json.loads(sys.argv[1])
if stats.get("event_count") != 20:
    raise SystemExit(f"expected 20 events after deletion, got {stats}")
PY

step "Uninstall the isolated engine and verify no product state remains"
rm -rf "$INSTALL_ROOT" "$CLEAN_HOME/Library/Application Support/MCI" \
    "$CLEAN_HOME/.config/hippocampus" "$CLEAN_HOME/.claude.json" "$CODEX_HOME"
for residue in "$INSTALL_ROOT" "$DB_PATH" "$KEY_FILE" "$RUNTIME_CONFIG" \
    "$CLEAN_HOME/.claude.json" "$CODEX_HOME"; do
    [[ ! -e "$residue" ]] || fail "uninstall left residue: $residue"
done

printf '\nPASS: clean-home install, capture, memory, handoff, deletion, and uninstall\n'
