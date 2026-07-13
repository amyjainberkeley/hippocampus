#!/usr/bin/env bash
# scripts/eval/recall/runner.sh — recall-quality harness runner (scaffold).
#
# Reads a JSONL corpus {query, expected_top_k, context_note}, invokes
# `mci-brain search` per query, emits one JSONL result line per case:
# {query, expected_top_k, hits}. Judge computes P@k / R@k / MRR.
# Cycle 8.42 scaffold; real corpus + seed land cycle 8.44+.

set -euo pipefail

CORPUS=""; OUT=""; LIMIT=10
BRAIN_BIN="${MCI_BRAIN_BIN:-mci-brain}"

usage() {
    cat <<'EOF'
Usage: runner.sh --corpus <path.jsonl> --out <path.jsonl> [--limit N] [--brain-bin path]
  --corpus     JSONL corpus (SCHEMA.md).
  --out        JSONL result file to write.
  --limit      top-k passed to `mci-brain search` (default 10).
  --brain-bin  path to mci-brain (default: $MCI_BRAIN_BIN or PATH).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --corpus)    CORPUS="$2"; shift 2 ;;
        --out)       OUT="$2"; shift 2 ;;
        --limit)     LIMIT="$2"; shift 2 ;;
        --brain-bin) BRAIN_BIN="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "runner.sh: unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -z "$CORPUS" || -z "$OUT" ]] && { echo "runner.sh: --corpus and --out required" >&2; exit 2; }
[[ ! -f "$CORPUS" ]] && { echo "runner.sh: corpus not found: $CORPUS" >&2; exit 2; }
command -v "$BRAIN_BIN" >/dev/null 2>&1 || { echo "runner.sh: brain bin not found: $BRAIN_BIN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "runner.sh: python3 required" >&2; exit 2; }

: > "$OUT"
cases=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # `search` is the CLI-stable entry point; MCP `mci_recall` returns
    # the same output shape (future: `--mcp` mode).
    read -r query expected < <(python3 -c '
import json, sys
c = json.loads(sys.argv[1])
print(json.dumps(c["query"]), json.dumps(c["expected_top_k"]))
' "$line")
    q=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]))' "$query")
    raw=$("$BRAIN_BIN" search "$q" --limit "$LIMIT" --json 2>/dev/null || echo '{"hits":[]}')
    python3 -c '
import json, sys
q, exp, raw = json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3])
hs = raw.get("hits") or raw.get("events") or []
ids = [h.get("event_id") for h in hs if h.get("event_id") is not None]
print(json.dumps({"query": q, "expected_top_k": exp, "hits": ids}))
' "$query" "$expected" "$raw" >> "$OUT"
    cases=$((cases + 1))
done < "$CORPUS"

echo "runner.sh: wrote $cases result rows to $OUT" >&2
