#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE="$REPO_ROOT/adapters/macos/MCICaptureHelper"
BINARY="$PACKAGE/.build/release/mci-capture-helper"
QUALIFICATION_FLAG="--live-overlap-qualification"
STRINGS_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/hippocampus-release-strings.XXXXXX")"
trap 'rm -f "$STRINGS_OUTPUT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

"$SCRIPT_DIR/swift-package.sh" build -c release \
    --package-path "$PACKAGE" --product mci-capture-helper >/dev/null

[[ -x "$BINARY" ]] || fail "release capture helper was not built"
strings "$BINARY" > "$STRINGS_OUTPUT"
if grep -Fq -- "$QUALIFICATION_FLAG" "$STRINGS_OUTPUT"; then
    fail "release capture helper contains the development OCR qualification capability"
fi

printf 'PASS: release capture helper compiles out the development OCR qualification capability\n'
