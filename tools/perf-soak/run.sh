#!/usr/bin/env bash
# tools/perf-soak/run.sh — build + run the soak harness, pipe JSONL to
# an optional output file. Exit code mirrors the binary (0 = PASS, 1 = FAIL).
#
# Usage:
#   tools/perf-soak/run.sh [binary-args...] [--output path.jsonl]
#
# Examples:
#   tools/perf-soak/run.sh                              # 60s default, JSONL to stdout
#   tools/perf-soak/run.sh -d 120 --output soak.jsonl   # 120s, save JSONL
#   tools/perf-soak/run.sh -w 8 -r 4 -d 300             # heavy 5-min run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Separate --output from passthrough args.
BIN_ARGS=()
OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    *)        BIN_ARGS+=("$1"); shift ;;
  esac
done

echo "Building mci-perf-soak (release)..." >&2
cargo build --release -p mci-perf-soak \
  --manifest-path "$REPO_ROOT/Cargo.toml" 2>&1 | tail -1 >&2

BIN="$REPO_ROOT/target/release/mci-perf-soak"

if [ -n "$OUTPUT" ]; then
  "$BIN" "${BIN_ARGS[@]}" | tee "$OUTPUT"
else
  "$BIN" "${BIN_ARGS[@]}"
fi
