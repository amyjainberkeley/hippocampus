#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-coreml-compatibility.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

APP_PATH="$TEST_ROOT/Hippocampus.app"
FP16_MODEL_PATH="$APP_PATH/Contents/Resources/Models/ArcticEmbedS_FP16.mlmodelc"
INT8_MODEL_PATH="$APP_PATH/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc"
mkdir -p "$FP16_MODEL_PATH" "$INT8_MODEL_PATH"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>ai.hippocampus.fixture</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST

cat > "$FP16_MODEL_PATH/metadata.json" <<'JSON'
[
  {
    "specificationVersion": 9,
    "storagePrecision": "Mixed (Float16, Int32)",
    "availability": {
      "macOS": "15.0"
    }
  }
]
JSON

cp "$FP16_MODEL_PATH/metadata.json" "$INT8_MODEL_PATH/metadata.json"

FP16_MANIFEST="$TEST_ROOT/models-fp16.json"
cat > "$FP16_MANIFEST" <<'JSON'
{
  "version": 1,
  "models": [
    {
      "modelID": "arctic-embed-s-fp16",
      "displayName": "Arctic Embed S (Search)",
      "bundled": true
    }
  ]
}
JSON

INT8_MANIFEST="$TEST_ROOT/models-int8.json"
cat > "$INT8_MANIFEST" <<'JSON'
{
  "version": 1,
  "models": [
    {
      "modelID": "arctic-embed-s-int8",
      "displayName": "Arctic Embed S (Search)",
      "bundled": true
    }
  ]
}
JSON

OUTPUT="$TEST_ROOT/output.txt"
if "$REPO_ROOT/scripts/verify-models.sh" \
    --manifest "$FP16_MANIFEST" \
    --app "$APP_PATH" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT"
    echo "FAIL: verifier accepted a model that requires a newer macOS than the app promises" >&2
    exit 1
fi

if ! grep -Fq "requires macOS 15.0 but the app supports macOS 14.0" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not explain the Core ML deployment mismatch" >&2
    exit 1
fi

echo "PASS: model newer than app deployment target is rejected"

rm "$FP16_MODEL_PATH/metadata.json"
cat > "$FP16_MODEL_PATH/hippocampus-model.json" <<'JSON'
{
  "schemaVersion": 1,
  "modelID": "arctic-embed-s-fp16",
  "precision": "float16",
  "minimumSystemVersion": "15.0",
  "specificationVersion": 9
}
JSON

if "$REPO_ROOT/scripts/verify-models.sh" \
    --manifest "$FP16_MANIFEST" \
    --app "$APP_PATH" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT"
    echo "FAIL: verifier ignored the app-owned Core ML compatibility manifest" >&2
    exit 1
fi

if ! grep -Fq "requires macOS 15.0 but the app supports macOS 14.0" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not enforce the app-owned Core ML compatibility manifest" >&2
    exit 1
fi

echo "PASS: app-owned model compatibility metadata is enforced"

cat > "$FP16_MODEL_PATH/hippocampus-model.json" <<'JSON'
{
  "schemaVersion": 1,
  "modelID": "arctic-embed-s-fp16",
  "precision": "int8",
  "minimumSystemVersion": "14.0",
  "specificationVersion": 8
}
JSON

if "$REPO_ROOT/scripts/verify-models.sh" \
    --manifest "$FP16_MANIFEST" \
    --app "$APP_PATH" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT"
    echo "FAIL: verifier accepted an FP16 identity backed by INT8 compatibility metadata" >&2
    exit 1
fi

if ! grep -Fq "claims FP16 but compatibility metadata says int8" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not explain the FP16 precision mismatch" >&2
    exit 1
fi

echo "PASS: false FP16 model identity is rejected"

cat > "$FP16_MODEL_PATH/hippocampus-model.json" <<'JSON'
{
  "schemaVersion": 1,
  "modelID": "different-model",
  "precision": "float16",
  "minimumSystemVersion": "14.0",
  "specificationVersion": 8
}
JSON

if "$REPO_ROOT/scripts/verify-models.sh" \
    --manifest "$FP16_MANIFEST" \
    --app "$APP_PATH" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT"
    echo "FAIL: verifier accepted compatibility metadata for a different model" >&2
    exit 1
fi

if ! grep -Fq "compatibility metadata identifies 'different-model'" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not explain the model identity mismatch" >&2
    exit 1
fi

echo "PASS: compatibility metadata for a different model is rejected"

rm "$FP16_MODEL_PATH/hippocampus-model.json"
if "$REPO_ROOT/scripts/verify-models.sh" \
    --manifest "$FP16_MANIFEST" \
    --app "$APP_PATH" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT"
    echo "FAIL: verifier accepted a model with no compatibility metadata" >&2
    exit 1
fi

if ! grep -Fq "has no compatibility metadata" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not explain the missing compatibility metadata" >&2
    exit 1
fi

echo "PASS: missing model compatibility metadata is rejected"

/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$APP_PATH/Contents/Info.plist"

if "$REPO_ROOT/scripts/verify-models.sh" \
    --manifest "$INT8_MANIFEST" \
    --app "$APP_PATH" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT"
    echo "FAIL: verifier accepted an INT8 identity for a compiled FP16 model" >&2
    exit 1
fi

if ! grep -Fq "claims INT8 but compiled storage precision is Mixed (Float16, Int32)" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not explain the model precision mismatch" >&2
    exit 1
fi

echo "PASS: false INT8 model identity is rejected"
