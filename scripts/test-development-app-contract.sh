#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_APP="$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-app-contract.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

help_output="$($BUILD_APP --help)"
rg -q -- '--development-lite' <<< "$help_output" \
    || fail "build-app help omits --development-lite"

if "$BUILD_APP" --development-lite --dist "$TEST_ROOT/release" \
    > "$TEST_ROOT/release.stdout" 2> "$TEST_ROOT/release.stderr"; then
    fail "release-profile development-lite unexpectedly succeeded"
fi
rg -q 'development-lite.*requires --debug' "$TEST_ROOT/release.stdout" "$TEST_ROOT/release.stderr" \
    || fail "development-lite did not fail closed outside debug"

if "$BUILD_APP" --debug --development-lite --dist "$TEST_ROOT/unsigned" \
    > "$TEST_ROOT/unsigned.stdout" 2> "$TEST_ROOT/unsigned.stderr"; then
    fail "unsigned development-lite unexpectedly succeeded"
fi
rg -q 'development-lite.*requires --development-ad-hoc' \
    "$TEST_ROOT/unsigned.stdout" "$TEST_ROOT/unsigned.stderr" \
    || fail "development-lite did not require explicit ad-hoc signing"

rg -q 'if \[\[ "\$DEVELOPMENT_LITE" -eq 1 \]\]' "$BUILD_APP" \
    || fail "build-app has no explicit development-lite branch"
rg -q 'Release assembly requires a stable Developer ID Application identity' "$BUILD_APP" \
    || fail "release signing refusal was removed"

printf 'PASS: development app mode is explicit and release-fail-closed\n'
