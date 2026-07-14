#!/usr/bin/env bash
# scripts/perf-recall-100k.sh — thin wrapper around the recall-perf harness.
#
# Runs `core/brain/tests/recall_perf_100k.rs` (100K-event seed + 100-query
# workload, cold + steady-state) and echoes the JSON result to stdout.
# Closes CRS G-perf: makes the extended-dictation latency check a one-line
# command instead of a Cargo incantation.
#
# Usage:
#   scripts/perf-recall-100k.sh            # measure only
#   scripts/perf-recall-100k.sh --update   # also rewrite docs/eval/recall-perf-baseline.json
#
# The test is `#[ignore]` upstream so it never runs unattended in CI; this
# wrapper opts it in via `-- --ignored`.

set -euo pipefail

UPDATE=0
if [[ "${1:-}" == "--update" ]]; then
    UPDATE=1
fi

cd "$(dirname "$0")/.."

if [[ "$UPDATE" == "1" ]]; then
    echo "perf-recall-100k: baseline update mode — will rewrite docs/eval/recall-perf-baseline.json" >&2
    MCI_PERF_UPDATE_BASELINE=1 \
        cargo test --profile=perf -p mci-brain -- --ignored --nocapture recall_perf_100k::run
else
    cargo test --profile=perf -p mci-brain -- --ignored --nocapture recall_perf_100k::run
fi
