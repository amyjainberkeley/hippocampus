#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd -P)
DATASET="eval/agent-handoff/agent-handoff-v1.json"
DATASET_SHA_FILE="eval/agent-handoff/agent-handoff-v1.sha256"
RESULT="docs/eval/agent-handoff-v1-result.json"
RESULT_SHA_FILE="docs/eval/agent-handoff-v1-result.sha256"
HARNESS_MANIFEST="scripts/eval/agent-handoff/harness/Cargo.toml"
DEFAULT_MODEL="/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_FP16.mlmodelc"

ARM="both"
OUT=""
UPDATE_RESULT=0

while (($# > 0)); do
    case "$1" in
        --arm)
            [[ $# -ge 2 ]] || { echo "agent-handoff runner: --arm requires a value" >&2; exit 2; }
            ARM="$2"
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || { echo "agent-handoff runner: --out requires a path" >&2; exit 2; }
            OUT="$2"
            shift 2
            ;;
        --update-result)
            UPDATE_RESULT=1
            shift
            ;;
        *)
            echo "agent-handoff runner: unknown argument $1" >&2
            exit 2
            ;;
    esac
done

case "$ARM" in
    lexical | hybrid | both) ;;
    *) echo "agent-handoff runner: arm must be lexical, hybrid, or both" >&2; exit 2 ;;
esac

cd "$REPO_ROOT"
[[ -f "$DATASET" ]] || { echo "agent-handoff runner: missing $DATASET" >&2; exit 3; }
[[ -f "$DATASET_SHA_FILE" ]] || { echo "agent-handoff runner: missing $DATASET_SHA_FILE" >&2; exit 3; }
EXPECTED_DATASET_SHA=$(tr -d '[:space:]' < "$DATASET_SHA_FILE")
ACTUAL_DATASET_SHA=$(shasum -a 256 "$DATASET" | awk '{print $1}')
if [[ ! "$EXPECTED_DATASET_SHA" =~ ^[0-9a-f]{64}$ || "$EXPECTED_DATASET_SHA" != "$ACTUAL_DATASET_SHA" ]]; then
    echo "agent-handoff runner: corpus checksum does not match its pinned sidecar" >&2
    exit 3
fi

MODEL_PATH="${MCI_ARCTIC_MODEL_PATH:-$DEFAULT_MODEL}"
if [[ "$ARM" != "lexical" && ! -d "$MODEL_PATH" ]]; then
    echo "agent-handoff runner: hybrid arm requires the Core ML model at $MODEL_PATH" >&2
    exit 4
fi
if [[ "$ARM" != "lexical" ]]; then
    export MCI_ARCTIC_MODEL_PATH="$MODEL_PATH"
fi

if [[ $UPDATE_RESULT -eq 1 ]]; then
    [[ "$ARM" == "both" ]] || { echo "agent-handoff runner: accepted result requires both arms" >&2; exit 2; }
    [[ -z "$OUT" ]] || { echo "agent-handoff runner: --out cannot be combined with --update-result" >&2; exit 2; }
    OUT="${RESULT}.next"
    [[ ! -e "$OUT" ]] || { echo "agent-handoff runner: refusing stale $OUT" >&2; exit 3; }
fi

REMOVE_OUT=0
if [[ -z "$OUT" ]]; then
    OUT=$(mktemp "${TMPDIR:-/tmp}/agent-handoff-v1.XXXXXX.json")
    REMOVE_OUT=1
fi
OUT_DIR=$(dirname "$OUT")
[[ -d "$OUT_DIR" ]] || { echo "agent-handoff runner: output directory does not exist: $OUT_DIR" >&2; exit 3; }

RAW=$(mktemp "${TMPDIR:-/tmp}/agent-handoff-v1-raw.XXXXXX.json")
cleanup() {
    rm -f "$RAW"
    if [[ $REMOVE_OUT -eq 1 ]]; then
        rm -f "$OUT"
    fi
    if [[ $UPDATE_RESULT -eq 1 ]]; then
        rm -f "${RESULT}.next"
    fi
}
trap cleanup EXIT

echo "agent-handoff runner: evaluating 36 tasks on $ARM arm(s)" >&2
cargo run --quiet --locked --manifest-path "$HARNESS_MANIFEST" -- \
    --dataset "$DATASET" \
    --arm "$ARM" \
    --out "$RAW"

COMMAND="scripts/eval/agent-handoff/run.sh --arm $ARM"
SCORER=(
    python3 scripts/eval/agent-handoff/runner.py
    --dataset "$DATASET"
    --raw "$RAW"
    --out "$OUT"
    --command "$COMMAND"
)
if [[ "$ARM" != "lexical" ]]; then
    SCORER+=(--model-path "$MODEL_PATH")
fi
"${SCORER[@]}"

jq '{complete,publishable,trusted_answer_qualified,retrieval_and_handoff_qualified,arms:[.arms[]|{arm,metrics,quality_gate}]}' "$OUT"

if [[ $UPDATE_RESULT -eq 1 ]]; then
    if ! jq -e '
        .complete == true and
        .publishable == true and
        .trusted_answer_qualified == false and
        .dataset_id == "synthetic-agent-handoff-v1" and
        .task_count == 36 and
        ([.arms[].arm] == ["hybrid", "lexical"])
    ' "$OUT" >/dev/null; then
        echo "agent-handoff runner: generated report is not eligible to become the accepted result" >&2
        exit 5
    fi
    mv "$OUT" "$RESULT"
    shasum -a 256 "$RESULT" | awk '{print $1}' > "$RESULT_SHA_FILE"
    UPDATE_RESULT=0
    trap - EXIT
    rm -f "$RAW"
    echo "agent-handoff runner: accepted result written to $RESULT" >&2
fi
