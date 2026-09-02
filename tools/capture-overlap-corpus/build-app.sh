#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/CaptureOverlapCorpus.app}"
BINARY="$SCRIPT_DIR/.build/debug/capture-overlap-corpus"

"$REPO_ROOT/scripts/swift-package.sh" build \
    --package-path "$SCRIPT_DIR" \
    --product capture-overlap-corpus
mkdir -p "$OUT/Contents/MacOS"
cp "$BINARY" "$OUT/Contents/MacOS/capture-overlap-corpus"
cp "$SCRIPT_DIR/Info.plist" "$OUT/Contents/Info.plist"
codesign --force --sign - "$OUT" >/dev/null
printf '%s\n' "$OUT"
