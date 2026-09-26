#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_SOURCES="$REPO_ROOT/apps/hippocampus/Sources"

if rg -n 'QuarantineUnlocker|/usr/bin/xattr|arguments = \["-dr", "com\.apple\.quarantine"' \
    "$RUNTIME_SOURCES" >/dev/null; then
    echo "FAIL: the app must not bypass macOS quarantine or Gatekeeper at runtime" >&2
    exit 1
fi

printf 'PASS: runtime leaves quarantine and Gatekeeper enforcement to macOS\n'
