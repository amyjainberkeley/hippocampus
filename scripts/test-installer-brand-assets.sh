#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-installer-brand.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

make_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/scripts/lib" "$fixture/assets/branding" "$fixture/assets/installer" "$fixture/docs/legal"
    cp "$REPO_ROOT/scripts/build-installer.sh" "$fixture/scripts/build-installer.sh"
    cp "$REPO_ROOT/scripts/lib/app-group-contract.sh" "$REPO_ROOT/scripts/lib/installer-runtime.sh" "$fixture/scripts/lib/"
    cp "$REPO_ROOT/scripts/build-provenance.py" "$REPO_ROOT/scripts/product-source-digest.py" "$fixture/scripts/"
    cp "$REPO_ROOT/assets/installer/generate-eula.py" "$REPO_ROOT/assets/installer/EULA.rtf" "$fixture/assets/installer/"
    cp "$REPO_ROOT/docs/legal/terms-of-service.md" "$fixture/docs/legal/"
    cp "$REPO_ROOT/assets/branding/AppIcon.icns" "$fixture/assets/branding/AppIcon.icns"
    cp "$REPO_ROOT/assets/installer/volume-icon.icns" "$fixture/assets/installer/volume-icon.icns"
}

matching_fixture="$TEST_ROOT/matching"
make_fixture "$matching_fixture"
if "$matching_fixture/scripts/build-installer.sh" --verify-assets \
    >"$matching_fixture/stdout" 2>"$matching_fixture/stderr"; then
    pass "matching canonical and installer icons are accepted"
else
    fail "matching canonical and installer icons should be accepted"
fi

mismatched_fixture="$TEST_ROOT/mismatched"
make_fixture "$mismatched_fixture"
printf 'brand drift' >>"$mismatched_fixture/assets/installer/volume-icon.icns"
if "$mismatched_fixture/scripts/build-installer.sh" --verify-assets \
    >"$mismatched_fixture/stdout" 2>"$mismatched_fixture/stderr"; then
    fail "mismatched installer icon should be rejected"
elif grep -Fq 'differs from canonical AppIcon.icns' "$mismatched_fixture/stderr"; then
    pass "mismatched installer icon is rejected with a repair instruction"
else
    fail "mismatched installer icon failed without the expected diagnostic"
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
