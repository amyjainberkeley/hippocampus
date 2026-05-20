#!/usr/bin/env bash
# download_model.sh — fetch snowflake-arctic-embed-s + convert to a Core ML
# .mlpackage matching the schema in BUNDLING.md §2.
#
# This is a SKELETON. Phase 5 (packaging) fleshes it out + wires it into the
# signed-app build pipeline. For Phase 3 P3.3 the script's role is:
#
#   - Document the exact conversion contract the runtime depends on.
#   - Pin upstream versions so a future change in coremltools / transformers
#     / optimum surfaces as a deliberate bump, never a silent drift.
#   - Refuse to run if any required tool is missing — never silently produce
#     a half-converted model.
#
# Run manually for end-to-end dev verification:
#
#   adapters/macos/mci-embed-coreml/scripts/download_model.sh \
#       --output ~/Library/Application\ Support/MCI/arctic-embed-s.mlpackage
#
# Headless CI does NOT run this — the .mlpackage is a release-time
# artifact, not a build artifact. See BUNDLING.md §6.

set -euo pipefail

# ----------------------------------------------------------------------------
# Pinned upstream versions. Any bump is a deliberate, documented change.
# ----------------------------------------------------------------------------

# HuggingFace model revision. NEVER use a branch name here — pin to the
# commit SHA so a model swap on the upstream side cannot silently change
# what we ship.
MODEL_REPO="Snowflake/snowflake-arctic-embed-s"
MODEL_REVISION="${MODEL_REVISION:-MAIN-PIN-AT-FIRST-RUN}"  # operator must replace with commit SHA on first run

# Python toolchain pins. Tested by the operator on first run; CI never
# executes this script so these are dev-time pins only.
COREMLTOOLS_VERSION="${COREMLTOOLS_VERSION:-8.0}"
OPTIMUM_VERSION="${OPTIMUM_VERSION:-1.23.3}"
TRANSFORMERS_VERSION="${TRANSFORMERS_VERSION:-4.46.3}"
TOKENIZERS_VERSION="${TOKENIZERS_VERSION:-0.20.3}"
ONNX_VERSION="${ONNX_VERSION:-1.17.0}"

# ----------------------------------------------------------------------------
# Args
# ----------------------------------------------------------------------------

OUTPUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --revision) MODEL_REVISION="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

if [[ -z "$OUTPUT" ]]; then
    echo "error: --output PATH is required (target .mlpackage location)" >&2
    exit 64
fi
if [[ "$MODEL_REVISION" == "MAIN-PIN-AT-FIRST-RUN" ]]; then
    echo "error: MODEL_REVISION must be set to a commit SHA, not a branch name." >&2
    echo "       Visit https://huggingface.co/${MODEL_REPO}/commits/main, pick the" >&2
    echo "       latest commit you want to bundle, and re-run with:" >&2
    echo "         MODEL_REVISION=<sha> $0 --output $OUTPUT" >&2
    exit 65
fi

# ----------------------------------------------------------------------------
# Required tools
# ----------------------------------------------------------------------------

for tool in python3 git pip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' is not on PATH" >&2
        exit 69
    fi
done

# ----------------------------------------------------------------------------
# Conversion pipeline
# ----------------------------------------------------------------------------
#
# Per BUNDLING.md §3:
#   1. Pull HF weights + tokenizer at the pinned MODEL_REVISION.
#   2. Convert to ONNX via optimum-cli, preserving tokenizer as preprocessing.
#   3. ONNX → Core ML .mlpackage via coremltools.converters.mil with the
#      input/output schema from BUNDLING.md §2.
#   4. int8-quantize via coremltools.optimize.coreml.palettize_weights.
#   5. Set computeUnits = .cpuAndNeuralEngine.
#   6. Round-trip verify against the fixture text.

WORK_DIR="$(mktemp -d -t mci-arctic-embed-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat <<EOF >&2
mci-embed-coreml :: download_model.sh

  repo          : ${MODEL_REPO}
  revision      : ${MODEL_REVISION}
  coremltools   : ${COREMLTOOLS_VERSION}
  optimum       : ${OPTIMUM_VERSION}
  transformers  : ${TRANSFORMERS_VERSION}
  tokenizers    : ${TOKENIZERS_VERSION}
  onnx          : ${ONNX_VERSION}
  output        : ${OUTPUT}
  workdir       : ${WORK_DIR}

This is the P3.3 SKELETON script. The full conversion pipeline is
written in Phase 5 (signed-app packaging). Today it stops here to keep
the supply-chain surface visible (no Python deps downloaded by CI; the
Conversion happens manually by an operator who has reviewed the diff).

To extend: implement steps 1-6 from BUNDLING.md §3 below this banner.
EOF
exit 2
