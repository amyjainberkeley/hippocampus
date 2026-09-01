#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd -P)
DATASET="eval/work-memory/synthetic-v1.json"
BASELINE="docs/eval/work-memory-baseline.json"
BASELINE_NEXT="docs/eval/work-memory-baseline.next.json"
DEFAULT_MODEL="/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc"

UPDATE_BASELINE=0
USE_BASELINE=1
OUT=""
PASS_ARGS=()

while (($# > 0)); do
    case "$1" in
        --update-baseline)
            UPDATE_BASELINE=1
            shift
            ;;
        --no-baseline)
            USE_BASELINE=0
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

cd "$REPO_ROOT"

REQUESTED_ARM="both"
for ((i = 0; i < ${#PASS_ARGS[@]}; i++)); do
    if [[ "${PASS_ARGS[$i]}" == "--arm" && $((i + 1)) -lt ${#PASS_ARGS[@]} ]]; then
        REQUESTED_ARM="${PASS_ARGS[$((i + 1))]}"
    fi
done

if [[ "$REQUESTED_ARM" != "lexical" ]]; then
    if [[ -z "${MCI_ARCTIC_MODEL_PATH:-}" && -d "$DEFAULT_MODEL" ]]; then
        export MCI_ARCTIC_MODEL_PATH="$DEFAULT_MODEL"
    fi
    if [[ -z "${MCI_ARCTIC_MODEL_PATH:-}" ]]; then
        echo "work-memory runner: MCI_ARCTIC_MODEL_PATH is not set and no bundled model was found at:" >&2
        echo "  $DEFAULT_MODEL" >&2
        exit 4
    fi
fi

if [[ ! -f "$DATASET" ]]; then
    echo "work-memory runner: dataset not found at $REPO_ROOT/$DATASET" >&2
    exit 3
fi

if [[ -n "${MCI_BENCH_BIN:-}" ]]; then
    BENCH_CMD=("$MCI_BENCH_BIN")
    export MCI_BENCH_COMMAND="mci-bench"
else
    BENCH_CMD=(cargo run -q -p mci-agent --bin mci-bench --)
    export MCI_BENCH_COMMAND="cargo run -q -p mci-agent --bin mci-bench --"
fi

if [[ $UPDATE_BASELINE -eq 1 ]]; then
    if [[ $USE_BASELINE -eq 0 ]]; then
        echo "work-memory runner: --no-baseline is not meaningful with --update-baseline" >&2
        exit 2
    fi
    for ((i = 0; i < ${#PASS_ARGS[@]}; i++)); do
        case "${PASS_ARGS[$i]}" in
            --limit | --allow-smoke | --abstention | --workdir)
                echo "work-memory runner: ${PASS_ARGS[$i]} cannot produce a publishable baseline" >&2
                exit 2
                ;;
            --arm)
                if [[ $((i + 1)) -ge ${#PASS_ARGS[@]} || "${PASS_ARGS[$((i + 1))]}" != "both" ]]; then
                    echo "work-memory runner: baseline generation requires --arm both" >&2
                    exit 2
                fi
                ;;
            --k)
                if [[ $((i + 1)) -ge ${#PASS_ARGS[@]} || "${PASS_ARGS[$((i + 1))]}" != "1,3,5,10" ]]; then
                    echo "work-memory runner: baseline generation requires --k 1,3,5,10" >&2
                    exit 2
                fi
                ;;
        esac
    done
    if [[ -e "$BASELINE_NEXT" ]]; then
        echo "work-memory runner: refusing to overwrite stale $REPO_ROOT/$BASELINE_NEXT" >&2
        exit 3
    fi

    OUT="${OUT:-$BASELINE}"
    echo "work-memory runner: generating publishable baseline for $OUT" >&2
    UPDATE_CMD=(
        "${BENCH_CMD[@]}"
        --dataset "$DATASET"
        --arm both
        --out "$BASELINE_NEXT"
    )
    if [[ ${#PASS_ARGS[@]} -gt 0 ]]; then
        UPDATE_CMD+=("${PASS_ARGS[@]}")
    fi
    set +e
    "${UPDATE_CMD[@]}"
    BENCH_STATUS=$?
    set -e

    if ! jq -e '
        .complete == true and
        .publishable == true and
        .run.git_dirty_at_start == false and
        .run.limit == null and
        .run.requested_arms == ["lexical", "hybrid"] and
        .run.ks == [1, 3, 5, 10]
    ' "$BASELINE_NEXT" >/dev/null; then
        echo "work-memory runner: generated report is not eligible to become a baseline" >&2
        mv "$BASELINE_NEXT" "${OUT}.rejected"
        exit 5
    fi

    mv "$BASELINE_NEXT" "$OUT"
    echo "work-memory runner: baseline written to $OUT" >&2
    exit "$BENCH_STATUS"
fi

OUT="${OUT:-$(mktemp "${TMPDIR:-/tmp}/work-memory-report.XXXXXX")}"
CMD=(
    "${BENCH_CMD[@]}"
    --dataset "$DATASET"
    --arm both
    --out "$OUT"
)

if [[ $USE_BASELINE -eq 1 && -f "$BASELINE" ]]; then
    CMD+=(--baseline "$BASELINE")
fi

if [[ ${#PASS_ARGS[@]} -gt 0 ]]; then
    CMD+=("${PASS_ARGS[@]}")
fi

echo "work-memory runner: report -> $OUT" >&2
exec "${CMD[@]}"
