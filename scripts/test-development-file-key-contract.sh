#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_APP="$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
SOURCE_INFO="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

if /usr/libexec/PlistBuddy -c 'Print :MCIDevelopmentFileKeyEnabled' "$SOURCE_INFO" \
    >/dev/null 2>&1; then
    fail "source Info.plist must never grant development file-key authority"
fi

rg -q 'if \[\[ "\$SIGNING_MODE" == "ad-hoc" \]\]' "$BUILD_APP" \
    || fail "development key capability is not limited to ad-hoc signing"
rg -q 'MCIDevelopmentFileKeyEnabled' "$BUILD_APP" \
    || fail "build script does not inject the development key capability"
rg -q 'PlistBuddy.*MCIDevelopmentFileKeyEnabled.*true' "$BUILD_APP" \
    || fail "ad-hoc assembly does not add the signed development key capability"
rg -q 'MCI_DEVELOPMENT_FILE_KEY' \
    "$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift" \
    || fail "supervisor does not pass an explicit development marker to children"
rg -q 'MCI_DB_KEY_FILE' \
    "$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift" \
    || fail "supervisor does not pass a development key path reference to children"
if rg -q 'MCI_DB_KEY_HEX.*=' \
    "$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift"; then
    fail "supervisor must never pass raw database key material to children"
fi

printf 'PASS: development file-key capability is artifact-scoped and raw-key-free\n'
