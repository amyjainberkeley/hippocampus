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
    cp "$REPO_ROOT/scripts/build-provenance.py" "$REPO_ROOT/scripts/product-source-digest.py" \
        "$REPO_ROOT/scripts/check-notary-log.py" "$fixture/scripts/"
    cp "$REPO_ROOT/assets/installer/generate-eula.py" "$REPO_ROOT/assets/installer/EULA.rtf" "$fixture/assets/installer/"
    cp "$REPO_ROOT/assets/installer/generate-background.py" "$REPO_ROOT/assets/installer/render-background.swift" \
        "$REPO_ROOT/assets/installer/read-background-text.swift" "$REPO_ROOT/assets/installer/layout.json" \
        "$fixture/assets/installer/"
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

# The installer window must show its two instructions and nothing else: no
# build number, commit or source digest. Apple's text recognition is the judge.
noted_fixture="$TEST_ROOT/noted"
make_fixture "$noted_fixture"
sed -i '' 's|^guard let image = context.makeImage(),|text("Build 4270a3264f5d / source 0123456789ab", size: 11, color: graphite, centerX: width / 2, baselineFromTop: 300)\
\
guard let image = context.makeImage(),|' "$noted_fixture/assets/installer/render-background.swift"
if "$noted_fixture/scripts/build-installer.sh" --verify-assets \
    >"$noted_fixture/stdout" 2>"$noted_fixture/stderr"; then
    fail "a background that shows a build note should be rejected"
elif grep -Fq 'shows text it should not' "$noted_fixture/stderr" \
    && grep -Fq '0123456789ab' "$noted_fixture/stderr"; then
    pass "a background that shows a build note is rejected, naming the text"
else
    fail "a background with a build note failed without the expected diagnostic"
fi

blank_fixture="$TEST_ROOT/blank"
make_fixture "$blank_fixture"
sed -i '' 's|^let dragCue = "Drag to Applications"$|let dragCue = ""|' \
    "$blank_fixture/assets/installer/render-background.swift"
if ! grep -Fxq 'let dragCue = ""' "$blank_fixture/assets/installer/render-background.swift"; then
    fail "the fixture could not remove the instruction; the renderer changed shape"
elif "$blank_fixture/scripts/build-installer.sh" --verify-assets \
    >"$blank_fixture/stdout" 2>"$blank_fixture/stderr"; then
    fail "a background missing its instruction should be rejected"
elif grep -Fq 'does not read "Drag to Applications"' "$blank_fixture/stderr"; then
    pass "a background missing its instruction is rejected"
else
    fail "a background missing its instruction failed without the expected diagnostic"
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
