#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd -P)
DATASET="$REPO_ROOT/eval/work-memory/synthetic-v1.json"
BASELINE="$REPO_ROOT/docs/eval/work-memory-baseline.json"
DEFAULT_MODEL="/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc"

UPDATE_BASELINE=0
OUT=""
PASS_ARGS=()

while (($# > 0)); do
    case "$1" in
        --update-baseline)
            UPDATE_BASELINE=1
            shift
            ;;
        --out)
            if (($# < 2)); then
                echo "work-memory runner: --out requires a path" >&2
                exit 2
            fi
            OUT="$2"
            shift 2
            ;;
        *)
            PASS_ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ -z "${MCI_ARCTIC_MODEL_PATH:-}" && -d "$DEFAULT_MODEL" ]]; then
    export MCI_ARCTIC_MODEL_PATH="$DEFAULT_MODEL"
fi

if [[ -z "${MCI_ARCTIC_MODEL_PATH:-}" ]]; then
    echo "work-memory runner: MCI_ARCTIC_MODEL_PATH is not set and no bundled model was found at:" >&2
    echo "  $DEFAULT_MODEL" >&2
    exit 4
fi

if [[ ! -f "$DATASET" ]]; then
    echo "work-memory runner: dataset not found at $DATASET" >&2
    exit 3
fi

if [[ $UPDATE_BASELINE -eq 1 ]]; then
    OUT="${OUT:-$BASELINE}"
    echo "work-memory runner: updating baseline at $OUT" >&2
    CMD=(
        cargo run -q -p mci-agent --bin mci-bench --
        --dataset "$DATASET" \
        --arm both \
        --out "$OUT"
    )
    if [[ ${#PASS_ARGS[@]} -gt 0 ]]; then
        CMD+=("${PASS_ARGS[@]}")
    fi
    exec "${CMD[@]}"
fi

OUT="${OUT:-$(mktemp "${TMPDIR:-/tmp}/work-memory-report.XXXXXX")}"
CMD=(
    cargo run -q -p mci-agent --bin mci-bench --
    --dataset "$DATASET"
    --arm both
    --out "$OUT"
)

if [[ -f "$BASELINE" ]]; then
    CMD+=(--baseline "$BASELINE")
fi

if [[ ${#PASS_ARGS[@]} -gt 0 ]]; then
    CMD+=("${PASS_ARGS[@]}")
fi

echo "work-memory runner: report -> $OUT" >&2
exec "${CMD[@]}"
