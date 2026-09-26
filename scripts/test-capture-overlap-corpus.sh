#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_ROOT="$REPO_ROOT/tools/capture-overlap-corpus"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-overlap-corpus.XXXXXX")"
APP_PATH="$TMP_ROOT/CaptureOverlapCorpus.app"
BACKGROUND_APP_PATH="$TMP_ROOT/CaptureOverlapBackground.app"
trap 'rm -rf "$TMP_ROOT"' EXIT

UNRELATED_APP="$TMP_ROOT/Unrelated.app"
mkdir -p "$UNRELATED_APP"
printf 'keep\n' > "$UNRELATED_APP/marker"
if "$FIXTURE_ROOT/build-app.sh" "$UNRELATED_APP" "$BACKGROUND_APP_PATH" \
    > /dev/null 2>&1; then
    echo "capture overlap corpus: builder overwrote an unrelated app directory" >&2
    exit 1
fi
[[ -f "$UNRELATED_APP/marker" ]] || {
    echo "capture overlap corpus: builder removed unrelated app contents" >&2
    exit 1
}

if "$FIXTURE_ROOT/build-app.sh" "$APP_PATH" "$APP_PATH" > /dev/null 2>&1; then
    echo "capture overlap corpus: builder accepted identical output paths" >&2
    exit 1
fi

"$FIXTURE_ROOT/build-app.sh" "$APP_PATH" >/dev/null

EXECUTABLE="$APP_PATH/Contents/MacOS/capture-overlap-corpus"
BACKGROUND_EXECUTABLE="$BACKGROUND_APP_PATH/Contents/MacOS/capture-overlap-background"
[[ -x "$EXECUTABLE" ]] || {
    echo "capture overlap corpus: executable is missing" >&2
    exit 1
}
[[ -x "$BACKGROUND_EXECUTABLE" ]] || {
    echo "capture overlap corpus: companion background executable is missing" >&2
    exit 1
}

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP_PATH/Contents/Info.plist")"
[[ "$bundle_id" == "ai.hippocampus.CaptureOverlapCorpus" ]] || {
    echo "capture overlap corpus: unexpected bundle id: $bundle_id" >&2
    exit 1
}
background_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$BACKGROUND_APP_PATH/Contents/Info.plist")"
[[ "$background_bundle_id" == "ai.hippocampus.CaptureOverlapBackground" ]] || {
    echo "capture overlap corpus: unexpected background bundle id: $background_bundle_id" >&2
    exit 1
}

codesign --verify --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$BACKGROUND_APP_PATH"

for token in FOCUSED_EVIDENCE_ZEPHYR_9241 BACKGROUND_SECRET_NEBULA_7713; do
    strings "$EXECUTABLE" | grep -Fq "$token" || {
        echo "capture overlap corpus: missing deterministic token $token" >&2
        exit 1
    }
done
strings "$BACKGROUND_EXECUTABLE" | grep -Fq BACKGROUND_SECRET_NEBULA_7713 || {
    echo "capture overlap corpus: background executable is missing its deterministic token" >&2
    exit 1
}

echo "PASS: focused-window overlap corpus builds as a signed deterministic app"
echo "NOTE: focused inclusion and background exclusion still require the unlocked live gate"
