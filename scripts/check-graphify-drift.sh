#!/usr/bin/env bash
# Check whether graphify-out/graph.json drifts from current code (AST-level).
#
# Usage:
#   scripts/check-graphify-drift.sh           # check; exit 1 if drifted
#   scripts/check-graphify-drift.sh --fix     # check and refresh in place
#
# Strategy: compute a stable AST signature (nodes + EXTRACTED edges) of the
# committed graph.json, then run `graphify update . --force --no-cluster`
# (AST-only, no LLM) into a scratch dir, compute the same signature, and
# compare. If they differ, the graph is stale and the PR must commit a
# refreshed graph.json. INFERRED (LLM-derived) edges and community labels
# are intentionally excluded from the signature so semantic re-extraction
# isn't required on every PR.
#
# Runs locally and in CI. Honors `[skip-graphify]` in the most recent commit
# message as an escape hatch.

set -euo pipefail

GRAPH_PATH="${GRAPH_PATH:-graphify-out/graph.json}"
MODE="${1:-check}"

if [ ! -f "$GRAPH_PATH" ]; then
  echo "[graphify-drift] $GRAPH_PATH missing — committing the graph is required." >&2
  exit 1
fi

# Escape hatch: commit-message opt-out (e.g. cosmetic-only or release-only PRs).
if git log -1 --pretty=%B 2>/dev/null | grep -qi '\[skip-graphify\]'; then
  echo "[graphify-drift] [skip-graphify] in commit message — bypassing AST drift check."
  exit 0
fi

if ! command -v graphify >/dev/null 2>&1; then
  echo "[graphify-drift] graphify CLI not installed. Install: uv tool install graphifyy" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[graphify-drift] jq not installed (required for signature comparison)." >&2
  exit 1
fi

ast_signature() {
  # Stable hash of AST node identity only — `graphify update` produces a
  # deterministic node-ID set across runs (verified) but non-deterministic
  # edge sets, so we intentionally drop edges from the signature.
  #
  # Excludes: community (clustering), built_at_commit (per-run metadata),
  # source_location (line numbers shift with whitespace), all edges.
  #
  # What this catches: code added/removed/renamed that produces new or
  # missing AST symbols. What it doesn't catch: relationship changes that
  # don't add/remove symbols (e.g. refactoring a function body without
  # changing its signature). The post-commit hook covers those locally.
  jq -S '.nodes | map({id, label, source_file, file_type, norm_label}) | sort_by(.id)' "$1" \
    | shasum -a 256 | cut -d' ' -f1
}

committed_sig="$(ast_signature "$GRAPH_PATH")"

# Stage current graph aside so we can compare after running update.
stash="$(mktemp -d)/graph.json"
cp "$GRAPH_PATH" "$stash"

# Run AST-only refresh. --force allows node-count drops (refactors that delete code).
# --no-cluster skips the recommunity step (nondeterministic, not part of signature).
if ! graphify update . --force --no-cluster >/tmp/graphify-drift.log 2>&1; then
  echo "[graphify-drift] graphify update failed. Log: /tmp/graphify-drift.log" >&2
  cp "$stash" "$GRAPH_PATH"
  exit 1
fi

fresh_sig="$(ast_signature "$GRAPH_PATH")"

if [ "$committed_sig" = "$fresh_sig" ]; then
  # Restore the committed file verbatim — `graphify update` may have rewritten
  # non-signature fields (timestamps, community ids) even though the AST is identical.
  cp "$stash" "$GRAPH_PATH"
  echo "[graphify-drift] OK — AST signature matches ($committed_sig)"
  exit 0
fi

if [ "$MODE" = "--fix" ]; then
  echo "[graphify-drift] drift detected, --fix mode kept refreshed graph in place."
  echo "[graphify-drift] commit graphify-out/graph.json to clear the check."
  echo "[graphify-drift] committed sig: $committed_sig"
  echo "[graphify-drift] fresh sig:     $fresh_sig"
  exit 0
fi

# Drift detected and not in --fix mode. Restore committed file (so the working
# tree stays clean) and fail with instructions.
cp "$stash" "$GRAPH_PATH"

echo "[graphify-drift] FAIL — graphify-out/graph.json is stale vs current code." >&2
echo "" >&2
echo "  committed AST signature: $committed_sig" >&2
echo "  fresh AST signature:     $fresh_sig" >&2
echo "" >&2
echo "  To fix:" >&2
echo "    1. Run: graphify update . --force --no-cluster" >&2
echo "    2. Commit the updated graphify-out/graph.json" >&2
echo "    3. (optional) Re-cluster: graphify cluster-only ." >&2
echo "" >&2
echo "  Escape hatch (rare): add '[skip-graphify]' to the most recent commit message." >&2
exit 1
