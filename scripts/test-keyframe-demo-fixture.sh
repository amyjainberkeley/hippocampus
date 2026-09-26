#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE="$REPO_ROOT/adapters/macos/MCIKeyframeCodec"
INPUT="$REPO_ROOT/assets/screenshots/hero-recall-ui.png"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-keyframe-fixture.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

digest="$({
    MCI_DEVELOPMENT_FILE_KEY=1 \
    MCI_DB_KEY_HEX="$(printf '11%.0s' {1..32})" \
        "$SCRIPT_DIR/swift-package.sh" run \
        --package-path "$PACKAGE" KeyframeFixtureBuilder \
        --blob-root "$TEST_ROOT/blobs" "$INPUT"
} 2> "$TEST_ROOT/stderr")"

[[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || fail "fixture builder did not print one lowercase SHA-256 digest"
blob="$TEST_ROOT/blobs/$digest.bin"
[[ -f "$blob" ]] || fail "fixture builder did not write the canonical blob"

observed="$(shasum -a 256 "$blob" | awk '{print $1}')"
[[ "$observed" == "$digest" ]] \
    || fail "fixture digest does not authenticate the written blob"

printf 'PASS: demo keyframe fixture writes one authenticated encrypted blob\n'
