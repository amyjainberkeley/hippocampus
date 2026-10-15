#!/usr/bin/env bash
set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
    printf 'FATAL: the quarantine check requires ripgrep (rg).\n' >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_SOURCES="$REPO_ROOT/apps/hippocampus/Sources"

# rg exits 0 on a match and 1 on none; anything else means the search
# itself failed, which must not read as a pass.
search_status=0
rg -n 'QuarantineUnlocker|/usr/bin/xattr|arguments = \["-dr", "com\.apple\.quarantine"' \
    "$RUNTIME_SOURCES" >/dev/null || search_status=$?
case "$search_status" in
    0)
        echo "FAIL: the app must not bypass macOS quarantine or Gatekeeper at runtime" >&2
        exit 1
        ;;
    1) ;;
    *)
        echo "FAIL: could not search $RUNTIME_SOURCES (rg exited $search_status)" >&2
        exit 1
        ;;
esac

printf 'PASS: runtime leaves quarantine and Gatekeeper enforcement to macOS\n'
