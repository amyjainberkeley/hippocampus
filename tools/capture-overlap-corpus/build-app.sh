#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/CaptureOverlapCorpus.app}"
BACKGROUND_OUT="${2:-$(dirname "$OUT")/CaptureOverlapBackground.app}"
BINARY="$SCRIPT_DIR/.build/debug/capture-overlap-corpus"

fail() {
    printf 'capture overlap corpus build: %s\n' "$1" >&2
    exit 1
}

canonical_output() {
    local output="$1"
    local parent
    [[ "$(basename "$output")" == *.app ]] \
        || fail "output must end in .app: $output"
    parent="$(cd "$(dirname "$output")" 2>/dev/null && pwd -P)" \
        || fail "output parent does not exist: $(dirname "$output")"
    printf '%s/%s\n' "$parent" "$(basename "$output")"
}

OUT="$(canonical_output "$OUT")"
BACKGROUND_OUT="$(canonical_output "$BACKGROUND_OUT")"
[[ "$OUT" != "$BACKGROUND_OUT" ]] \
    || fail "foreground and background outputs must be different paths"

"$REPO_ROOT/scripts/swift-package.sh" build \
    --package-path "$SCRIPT_DIR" \
    --product capture-overlap-corpus
assemble_app() {
    local output="$1"
    local plist="$2"
    local executable="$3"
    local expected_bundle_id="$4"

    if [[ -L "$output" ]]; then
        fail "refusing to replace symlink output: $output"
    fi
    if [[ -e "$output" ]]; then
        local existing_bundle_id=""
        if [[ -d "$output" && -f "$output/Contents/Info.plist" ]]; then
            existing_bundle_id="$(/usr/libexec/PlistBuddy \
                -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist" \
                2>/dev/null || true)"
        fi
        [[ "$existing_bundle_id" == "$expected_bundle_id" ]] \
            || fail "refusing to replace unrecognized output: $output"
        rm -rf -- "$output"
    fi
    mkdir -p "$output/Contents/MacOS"
    cp "$BINARY" "$output/Contents/MacOS/$executable"
    cp "$plist" "$output/Contents/Info.plist"
    codesign --force --sign - "$output" >/dev/null
}

assemble_app "$OUT" "$SCRIPT_DIR/Info.plist" "capture-overlap-corpus" \
    "ai.hippocampus.CaptureOverlapCorpus"
assemble_app "$BACKGROUND_OUT" "$SCRIPT_DIR/Background-Info.plist" \
    "capture-overlap-background" "ai.hippocampus.CaptureOverlapBackground"
printf '%s\n%s\n' "$OUT" "$BACKGROUND_OUT"
