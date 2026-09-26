#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="$SCRIPT_DIR/prepare-release-models.sh"
TMP_ROOT="$(mktemp -d -t hippocampus-release-models)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

expect_pass() {
    local message="$1"; shift
    if "$@" >"$TMP_ROOT/last.out" 2>&1; then pass "$message"; else
        cat "$TMP_ROOT/last.out" >&2
        fail "$message"
    fi
}

expect_fail() {
    local message="$1"; shift
    if "$@" >"$TMP_ROOT/last.out" 2>&1; then
        cat "$TMP_ROOT/last.out" >&2
        fail "$message"
    else
        pass "$message"
    fi
}

SOURCE="$TMP_ROOT/source/models"
for model in ArcticEmbedS_FP16.mlmodelc; do
    mkdir -p "$SOURCE/$model/weights"
    cat >"$SOURCE/$model/model.mil" <<'MIL'
program(1.0)
{
    func main<ios17>(tensor<int32, [1, 128]> attention_mask, tensor<int32, [1, 128]> input_ids) {
        tensor<fp16, [384, 384]> encoder_weight_to_fp16 = const();
        tensor<fp16, [1, 1, 1, 128]> mask_cast_fp16 = cast(x = attention_mask);
        tensor<fp16, [1, 1, 1, 128]> inverted_mask = sub(x = one, y = mask_cast_fp16);
        tensor<fp16, []> finite_attention_floor = const()[val = tensor<fp16, []>(-0x1.388p+13)];
        tensor<fp16, [1, 1, 1, 128]> attention_mask_cast_fp16 = mul(x = inverted_mask, y = finite_attention_floor);
        tensor<fp16, [1, 12, 128, 128]> masked_scores = add(x = attention_scores, y = attention_mask_cast_fp16);
        tensor<fp16, [1, 12, 128, 128]> probabilities = softmax(x = masked_scores);
        tensor<fp32, [1, 384]> embedding = cast();
    } -> (embedding);
}
MIL
    printf 'metadata' >"$SOURCE/$model/coremldata.bin"
    printf 'weights' >"$SOURCE/$model/weights/weight.bin"
done

ARCHIVE="$TMP_ROOT/release-models.tar.gz"
tar -C "$TMP_ROOT/source" -czf "$ARCHIVE" models
SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"

expect_fail 'model preparation rejects missing compatibility metadata' \
    "$PREPARE" --archive "$ARCHIVE" --sha256 "$SHA" \
    --output "$TMP_ROOT/missing-contract"

cat > "$SOURCE/ArcticEmbedS_FP16.mlmodelc/hippocampus-model.json" <<'JSON'
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
tar -C "$TMP_ROOT/source" -czf "$ARCHIVE" models
SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"

expect_fail 'model preparation rejects the wrong archive hash' \
    "$PREPARE" --archive "$ARCHIVE" --sha256 "$(printf '%064d' 0)" \
    --output "$TMP_ROOT/wrong-hash"

expect_pass 'model preparation validates and atomically installs required models' \
    "$PREPARE" --archive "$ARCHIVE" --sha256 "$SHA" \
    --output "$TMP_ROOT/output"

perl -0pi -e 's/-0x1\.388p\+13/-inf/' "$SOURCE/ArcticEmbedS_FP16.mlmodelc/model.mil"
tar -C "$TMP_ROOT/source" -czf "$ARCHIVE" models
SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
expect_fail 'model preparation rejects a non-finite compiled attention graph' \
    "$PREPARE" --archive "$ARCHIVE" --sha256 "$SHA" \
    --output "$TMP_ROOT/non-finite-graph"

for model in ArcticEmbedS_FP16.mlmodelc; do
    if [[ -f "$TMP_ROOT/output/$model/model.mil" && \
          -f "$TMP_ROOT/output/$model/coremldata.bin" && \
          -f "$TMP_ROOT/output/$model/weights/weight.bin" ]]; then
        pass "$model is complete"
    else
        fail "$model is complete"
    fi
done

expect_fail 'model preparation refuses to overwrite an existing model directory' \
    "$PREPARE" --archive "$ARCHIVE" --sha256 "$SHA" \
    --output "$TMP_ROOT/output"

TRAVERSAL="$TMP_ROOT/traversal.tar"
python3 - "$TRAVERSAL" <<'PY'
import io
import tarfile
import sys

with tarfile.open(sys.argv[1], "w") as archive:
    member = tarfile.TarInfo("models/../../escaped")
    member.size = 4
    archive.addfile(member, io.BytesIO(b"nope"))
PY
TRAVERSAL_SHA="$(shasum -a 256 "$TRAVERSAL" | awk '{print $1}')"
expect_fail 'model preparation rejects archive path traversal' \
    "$PREPARE" --archive "$TRAVERSAL" --sha256 "$TRAVERSAL_SHA" \
    --output "$TMP_ROOT/traversal-output"
if [[ -e "$TMP_ROOT/escaped" ]]; then
    fail 'path traversal writes nothing outside the destination'
else
    pass 'path traversal writes nothing outside the destination'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
