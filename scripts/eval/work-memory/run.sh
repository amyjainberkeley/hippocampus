#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd -P)
DATASET="eval/work-memory/synthetic-v1.json"
BASELINE="docs/eval/work-memory-baseline.json"
BASELINE_NEXT="docs/eval/work-memory-baseline.next.json"
BASELINE_SHA256_FILE="docs/eval/work-memory-baseline.sha256"
BASELINE_SHA256_NEXT="docs/eval/work-memory-baseline.sha256.next"
DATASET_SHA256="f56ec3a13733343b6819edd86782d28c4ec9f6c5ee9fbb3a2d0b19c03282ae4d"
DEFAULT_MODEL="/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_FP16.mlmodelc"

UPDATE_BASELINE=0
ACCEPT_IDENTITY_CHANGE=0
OUT=""
PASS_ARGS=()

while (($# > 0)); do
    case "$1" in
        --update-baseline)
            UPDATE_BASELINE=1
            shift
            ;;
        --accept-identity-change)
            ACCEPT_IDENTITY_CHANGE=1
            shift
            ;;
        --allow-baseline-identity-migration)
            echo "work-memory runner: --allow-baseline-identity-migration is an internal flag" >&2
            exit 2
            ;;
        --no-baseline)
            echo "work-memory runner: the accepted baseline comparison is mandatory" >&2
            exit 2
            ;;
        --baseline | --baseline=*)
            echo "work-memory runner: caller-provided baselines are forbidden" >&2
            exit 2
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

if [[ $ACCEPT_IDENTITY_CHANGE -eq 1 && $UPDATE_BASELINE -ne 1 ]]; then
    echo "work-memory runner: --accept-identity-change requires --update-baseline" >&2
    exit 2
fi

cd "$REPO_ROOT"
export MCI_BENCH_REPO_ROOT="$REPO_ROOT"

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

if [[ ! -f "$BASELINE" ]]; then
    echo "work-memory runner: accepted baseline not found at $REPO_ROOT/$BASELINE" >&2
    exit 3
fi

if [[ ! -f "$BASELINE_SHA256_FILE" ]]; then
    echo "work-memory runner: accepted baseline digest not found at $REPO_ROOT/$BASELINE_SHA256_FILE" >&2
    exit 3
fi

BASELINE_SHA256=$(tr -d '[:space:]' < "$BASELINE_SHA256_FILE")
if [[ ! "$BASELINE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "work-memory runner: accepted baseline digest is malformed" >&2
    exit 3
fi

if [[ "$(shasum -a 256 "$DATASET" | awk '{print $1}')" != "$DATASET_SHA256" ]]; then
    echo "work-memory runner: canonical dataset digest does not match the accepted artifact" >&2
    exit 3
fi

if [[ "$(shasum -a 256 "$BASELINE" | awk '{print $1}')" != "$BASELINE_SHA256" ]]; then
    echo "work-memory runner: canonical baseline digest does not match the accepted artifact" >&2
    exit 3
fi

validate_canonical_report() {
    local report=$1
    local benchmark_status=$2

    [[ -s "$report" ]] || return 1
    jq -e \
        --arg dataset "$DATASET" \
        --arg dataset_sha "$DATASET_SHA256" \
        --arg baseline "$BASELINE" \
        --argjson benchmark_status "$benchmark_status" '
        def argument_values($flag):
            [.run.arguments as $arguments
             | range(0; ($arguments | length) - 1) as $index
             | select($arguments[$index] == $flag)
             | $arguments[$index + 1]];
        def canonical_scope:
            .dataset == $dataset and
            .dataset_id == "synthetic-work-memory-v1" and
            .dataset_checksum_sha256 == $dataset_sha and
            .run.limit == null and
            .run.requested_arms == ["lexical", "hybrid"] and
            .run.ks == [1, 3, 5, 10] and
            .run.original_instances == 24 and
            .run.evaluated_instances == 24;
        (.complete | type) == "boolean" and
        (.publishable | type) == "boolean" and
        (.launch_qualified | type) == "boolean" and
        (.failures | type) == "array" and
        (.regression | type) == "object" and
        (.regression.passed | type) == "boolean" and
        (.quality_gate | type) == "object" and
        (.quality_gate.passed | type) == "boolean" and
        (.run | type) == "object" and
        (.run.arguments | type) == "array" and
        all(.run.arguments[]; type == "string") and
        .dataset == $dataset and
        .dataset_id == "synthetic-work-memory-v1" and
        .dataset_checksum_sha256 == $dataset_sha and
        argument_values("--dataset") == [$dataset] and
        argument_values("--baseline") == [$baseline] and
        .complete == (((.failures | length) == 0) and
                      (.run.limit == null) and
                      .regression.passed) and
        .publishable == (.complete and canonical_scope and
                         (.run.git_dirty_at_start == false) and
                         ((.run.model_checksum_sha256 | type) == "string") and
                         ((.run.model_checksum_sha256 | length) > 0)) and
        .launch_qualified == (.publishable and .quality_gate.passed) and
        (($benchmark_status == 0 and canonical_scope and .complete and
          .quality_gate.passed) or
         ($benchmark_status == 5 and (.complete | not)) or
         ($benchmark_status == 7 and canonical_scope and .complete and
          (.quality_gate.passed | not)))
    ' "$report" >/dev/null
}

if [[ -n "${MCI_BENCH_BIN:-}" ]]; then
    BENCH_CMD=("$MCI_BENCH_BIN")
    export MCI_BENCH_COMMAND="mci-bench"
else
    BENCH_CMD=(cargo run -q -p mci-agent --bin mci-bench --)
    export MCI_BENCH_COMMAND="cargo run -q -p mci-agent --bin mci-bench --"
fi

if [[ $UPDATE_BASELINE -eq 1 ]]; then
    for ((i = 0; i < ${#PASS_ARGS[@]}; i++)); do
        case "${PASS_ARGS[$i]}" in
            --dataset | --limit | --allow-smoke | --abstention | --workdir)
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
    if [[ -e "$BASELINE_NEXT" || -e "$BASELINE_SHA256_NEXT" ]]; then
        echo "work-memory runner: refusing to overwrite stale baseline candidate artifacts" >&2
        exit 3
    fi
    cleanup_baseline_candidates() {
        rm -f "$BASELINE_NEXT" "$BASELINE_SHA256_NEXT"
    }
    trap cleanup_baseline_candidates EXIT

    OUT="${OUT:-$BASELINE}"
    echo "work-memory runner: generating publishable baseline for $OUT" >&2
    UPDATE_CMD=(
        "${BENCH_CMD[@]}"
        --dataset "$DATASET"
        --arm both
        --out "$BASELINE_NEXT"
        --baseline "$BASELINE"
    )
    if [[ $ACCEPT_IDENTITY_CHANGE -eq 1 ]]; then
        UPDATE_CMD+=(--allow-baseline-identity-migration)
    fi
    if [[ ${#PASS_ARGS[@]} -gt 0 ]]; then
        UPDATE_CMD+=("${PASS_ARGS[@]}")
    fi
    set +e
    "${UPDATE_CMD[@]}"
    BENCH_STATUS=$?
    set -e

    if ! validate_canonical_report "$BASELINE_NEXT" "$BENCH_STATUS" ||
        [[ $BENCH_STATUS -ne 0 && $BENCH_STATUS -ne 7 ]] ||
        ! jq -e --arg dataset "$DATASET" '
        .complete == true and
        .publishable == true and
        .dataset == $dataset and
        .dataset_id == "synthetic-work-memory-v1" and
        .run.git_dirty_at_start == false and
        .run.limit == null and
        .run.requested_arms == ["lexical", "hybrid"] and
        .run.ks == [1, 3, 5, 10] and
        .run.original_instances == 24 and
        .run.evaluated_instances == 24
    ' "$BASELINE_NEXT" >/dev/null; then
        echo "work-memory runner: generated report is not eligible to become a baseline" >&2
        exit 5
    fi

    if [[ "$OUT" == "$BASELINE" ]]; then
        shasum -a 256 "$BASELINE_NEXT" | awk '{print $1}' > "$BASELINE_SHA256_NEXT"
    fi
    mv "$BASELINE_NEXT" "$OUT"
    if [[ "$OUT" == "$BASELINE" ]]; then
        mv "$BASELINE_SHA256_NEXT" "$BASELINE_SHA256_FILE"
    fi
    trap - EXIT
    echo "work-memory runner: baseline written to $OUT" >&2
    exit "$BENCH_STATUS"
fi

REMOVE_DEFAULT_OUT=0
if [[ -z "$OUT" ]]; then
    OUT=$(mktemp "${TMPDIR:-/tmp}/work-memory-report.XXXXXX")
    REMOVE_DEFAULT_OUT=1
fi
OUT_DIR=$(dirname "$OUT")
if [[ ! -d "$OUT_DIR" ]]; then
    echo "work-memory runner: report directory does not exist: $OUT_DIR" >&2
    exit 3
fi
REPORT_CANDIDATE=$(mktemp "$OUT_DIR/.work-memory-report.next.XXXXXX")
cleanup_report_candidate() {
    rm -f "$REPORT_CANDIDATE"
    if [[ $REMOVE_DEFAULT_OUT -eq 1 ]]; then
        rm -f "$OUT"
    fi
}
trap cleanup_report_candidate EXIT
CMD=(
    "${BENCH_CMD[@]}"
    --dataset "$DATASET"
    --arm both
    --out "$REPORT_CANDIDATE"
)

CMD+=(--baseline "$BASELINE")

if [[ ${#PASS_ARGS[@]} -gt 0 ]]; then
    CMD+=("${PASS_ARGS[@]}")
fi

echo "work-memory runner: report -> $OUT" >&2
set +e
"${CMD[@]}"
BENCH_STATUS=$?
set -e

if ! validate_canonical_report "$REPORT_CANDIDATE" "$BENCH_STATUS"; then
    echo "work-memory runner: benchmark did not produce a valid canonical report" >&2
    exit 5
fi

mv "$REPORT_CANDIDATE" "$OUT"
REMOVE_DEFAULT_OUT=0
trap - EXIT
exit "$BENCH_STATUS"
