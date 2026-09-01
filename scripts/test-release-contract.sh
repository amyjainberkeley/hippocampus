#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE="$REPO_ROOT/.github/workflows/release.yml"
CARGO="$REPO_ROOT/.github/workflows/cargo.yml"

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

require_pattern() {
    local file="$1" pattern="$2" message="$3"
    if rg -q -- "$pattern" "$file"; then pass "$message"; else fail "$message"; fi
}

require_literal() {
    local file="$1" literal="$2" message="$3"
    if rg -Fq -- "$literal" "$file"; then pass "$message"; else fail "$message"; fi
}

reject_pattern() {
    local file="$1" pattern="$2" message="$3"
    if rg -q -- "$pattern" "$file"; then fail "$message"; else pass "$message"; fi
}

require_pattern "$RELEASE" 'Require release secrets' \
    'release workflow has an explicit secret gate'
for name in APPLE_CERTIFICATE_P12 APPLE_CERTIFICATE_PASSWORD NOTARYTOOL_APPLE_ID \
    NOTARYTOOL_TEAM_ID NOTARYTOOL_PASSWORD SPARKLE_PRIVATE_KEY; do
    printf -v expected 'Required release secret is missing: \\$%s' "$name"
    require_literal "$RELEASE" "$expected" \
        "release workflow requires ${name}"
done
require_pattern "$RELEASE" 'check-signing-prereqs\.sh --release' \
    'release workflow runs the fail-closed signing prerequisite gate'
require_pattern "$RELEASE" 'codesign --verify --deep --strict' \
    'release workflow always verifies the app signature'
require_pattern "$RELEASE" 'xcrun stapler validate' \
    'release workflow validates the notarization staple'
require_pattern "$RELEASE" 'scripts/publish-appcast\.sh' \
    'release workflow signs the Sparkle appcast'
reject_pattern "$RELEASE" 'DMG will be ad-hoc signed|skipping appcast publish|if: env\.APPLE_CERTIFICATE_P12|if: env\.NOTARYTOOL_APPLE_ID|if: steps\.sparkle' \
    'release workflow has no optional signing or update-signing path'
reject_pattern "$RELEASE" 'build-installer\.sh --skip-build' \
    'release workflow assembles the app before packaging the DMG'
reject_pattern "$CARGO" 'continue-on-error:[[:space:]]*true' \
    'Clippy is a blocking CI gate'

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
