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
printf 'weights' > "$FP16_MODEL_PATH/weight.bin"
cat > "$FP16_MODEL_PATH/model.mil" <<'MIL'
program(1.0)
{
    func main<ios17>(tensor<int32, [1, 128]> attention_mask, tensor<int32, [1, 128]> input_ids) {
        tensor<fp16, [384, 384]> encoder_weight_to_fp16 = const();
        tensor<fp16, []> finite_attention_floor = const()[val = tensor<fp16, []>(-10000.0)];
        tensor<fp32, [1, 384]> embedding = cast();
    } -> (embedding);
}
MIL

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
    echo "FAIL: verifier accepted legacy metadata for the shipping FP16 model" >&2
    exit 1
fi

if ! grep -Fq "requires app-owned compatibility metadata" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not reject the legacy metadata bypass" >&2
    exit 1
fi

echo "PASS: shipping FP16 model rejects legacy compatibility metadata"

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

if ! grep -Fq "requires app-owned compatibility metadata" "$OUTPUT"; then
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

/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$APP_PATH/Contents/Info.plist"
mkdir -p "$FP16_MODEL_PATH/weights"
printf 'weights' > "$FP16_MODEL_PATH/weights/weight.bin"
printf 'metadata' > "$FP16_MODEL_PATH/coremldata.bin"
cat > "$FP16_MODEL_PATH/hippocampus-model.json" <<'JSON'
{
  "attentionImplementation": "eager",
  "attentionMaskFloor": -10000.0,
  "embeddingDimension": 384,
  "maxSequenceLength": 128,
  "minimumSystemVersion": "14.0",
  "modelID": "arctic-embed-s-fp16",
  "precision": "float16",
  "schemaVersion": 1,
  "sourceRepo": "Snowflake/snowflake-arctic-embed-s",
  "sourceRevision": "e596f507467533e48a2e17c007f0e1dacc837b33",
  "specificationVersion": 8
}
JSON
perl -0pi -e 's/-10000\.0/-inf/' "$FP16_MODEL_PATH/model.mil"

if "$REPO_ROOT/scripts/verify-models.sh" \
    --manifest "$FP16_MANIFEST" \
    --app "$APP_PATH" >"$OUTPUT" 2>&1; then
    cat "$OUTPUT"
    echo "FAIL: verifier accepted a non-finite compiled attention graph" >&2
    exit 1
fi
if ! grep -Fq "non-finite constant" "$OUTPUT"; then
    cat "$OUTPUT"
    echo "FAIL: verifier did not explain the non-finite compiled graph" >&2
    exit 1
fi
echo "PASS: non-finite compiled attention graph is rejected"
