#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E="$SCRIPT_DIR/e2e-clean-home.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -f "$E2E" ]] || fail "scripts/e2e-clean-home.sh is missing"
[[ -x "$E2E" ]] || fail "scripts/e2e-clean-home.sh is not executable"

require_literal() {
    local literal="$1"
    local message="$2"
    rg -Fq -- "$literal" "$E2E" || fail "$message"
}

require_pattern() {
    local pattern="$1"
    local message="$2"
    rg -q -- "$pattern" "$E2E" || fail "$message"
}

require_literal 'mktemp -d' 'E2E must allocate a throwaway home'
require_pattern 'export HOME=.*CLEAN_HOME' 'E2E must replace HOME with the throwaway home'
require_literal 'capture_enabled = false' 'E2E must begin with capture disabled'
require_literal '--drain-stdin' 'E2E must exercise the production capture ingest command'
require_literal '--strict' 'capture ingest must fail closed when the brain cannot open'
require_literal 'mci-seed-brain' 'E2E must import deterministic synthetic history'
require_literal 'mci-seed-brief' 'E2E must populate and verify the brief surface'
for tool in mci_recall mci_events_since mci_episodes mci_context; do
    require_literal "$tool" "E2E must call $tool through MCP"
done
require_literal 'delete-event' 'E2E must verify user deletion against the clean brain'
require_literal 'MCI_DB_KEY_HEX' 'E2E must scan client configs for reusable key material'
require_literal 'MCI_DEVELOPMENT_FILE_KEY' 'E2E must scan client configs for development custody'
require_literal 'trap cleanup EXIT' 'E2E must clean up even when a gate fails'

python3 -B "$SCRIPT_DIR/test_e2e_clean_home.py"

printf 'PASS: clean-home E2E contract is complete\n'
