#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/release_models_manifest.py"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/release-model-manifest.XXXXXX")"
trap 'find "$TEST_ROOT" -type f -delete 2>/dev/null || true; rmdir "$TEST_ROOT" 2>/dev/null || true' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

expect_pass() {
    local message="$1"; shift
    if "$@" >"$TEST_ROOT/last.out" 2>&1; then pass "$message"; else
        cat "$TEST_ROOT/last.out" >&2
        fail "$message"
    fi
}

expect_fail() {
    local message="$1"; shift
    if "$@" >"$TEST_ROOT/last.out" 2>&1; then fail "$message"; else pass "$message"; fi
}

write_manifest() {
    local url="$1" sha="$2" version="${3:-1.2.3}"
    cat >"$TEST_ROOT/manifest.json" <<JSON
{
  "schemaVersion": 1,
  "releaseVersion": "$version",
  "archiveURL": "$url",
  "archiveSHA256": "$sha",
  "models": [
    {"id": "arctic-embed-s-int8", "bundle": "ArcticEmbedS_INT8.mlmodelc"}
  ]
}
JSON
}

SHA="$(printf 'ab%.0s' {1..32})"
URL='https://github.com/amyjainberkeley/hippocampus-models/releases/download/v1.2.3/release-models-1.2.3.tar.gz'
write_manifest "$URL" "$SHA"

expect_pass 'tag-owned model manifest is accepted' \
    "$VERIFY" --manifest "$TEST_ROOT/manifest.json" --release-version 1.2.3
expect_pass 'model manifest returns the immutable archive URL' \
    "$VERIFY" --manifest "$TEST_ROOT/manifest.json" --release-version 1.2.3 --field archive-url
expect_pass 'model manifest returns the exact archive digest' \
    "$VERIFY" --manifest "$TEST_ROOT/manifest.json" --release-version 1.2.3 --field archive-sha256

write_manifest 'https://example.com/models/latest.tar.gz' "$SHA"
expect_fail 'mutable model URL is rejected' \
    "$VERIFY" --manifest "$TEST_ROOT/manifest.json" --release-version 1.2.3

write_manifest "$URL" 'UNPROVISIONED'
expect_fail 'unprovisioned model digest is rejected' \
    "$VERIFY" --manifest "$TEST_ROOT/manifest.json" --release-version 1.2.3

write_manifest "$URL" "$SHA" 9.9.9
expect_fail 'model manifest version must match the release' \
    "$VERIFY" --manifest "$TEST_ROOT/manifest.json" --release-version 1.2.3

write_manifest "$URL" "$SHA"
python3 - "$TEST_ROOT/manifest.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)
payload["models"].append({
    "id": "qwen3-1.7b-fp16",
    "bundle": "Qwen3-1.7B-FP16.mlmodelc",
})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
expect_fail 'optional generative models cannot become silent release prerequisites' \
    "$VERIFY" --manifest "$TEST_ROOT/manifest.json" --release-version 1.2.3

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
