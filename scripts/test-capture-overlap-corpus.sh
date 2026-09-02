#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_ROOT="$REPO_ROOT/tools/capture-overlap-corpus"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-overlap-corpus.XXXXXX")"
APP_PATH="$TMP_ROOT/CaptureOverlapCorpus.app"
trap 'rm -rf "$TMP_ROOT"' EXIT

"$FIXTURE_ROOT/build-app.sh" "$APP_PATH" >/dev/null

EXECUTABLE="$APP_PATH/Contents/MacOS/capture-overlap-corpus"
[[ -x "$EXECUTABLE" ]] || {
    echo "capture overlap corpus: executable is missing" >&2
    exit 1
}

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP_PATH/Contents/Info.plist")"
[[ "$bundle_id" == "ai.hippocampus.CaptureOverlapCorpus" ]] || {
    echo "capture overlap corpus: unexpected bundle id: $bundle_id" >&2
    exit 1
}

codesign --verify --strict --verbose=2 "$APP_PATH"

for token in FOCUSED_EVIDENCE_ZEPHYR_9241 BACKGROUND_SECRET_NEBULA_7713; do
    strings "$EXECUTABLE" | grep -Fq "$token" || {
        echo "capture overlap corpus: missing deterministic token $token" >&2
        exit 1
    }
done

echo "PASS: focused-window overlap corpus builds as a signed deterministic app"
echo "NOTE: focused inclusion and background exclusion still require the unlocked live gate"
