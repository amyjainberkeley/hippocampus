#!/usr/bin/env bash
# One-time setup: point this repo's git hooks at the in-repo .githooks/ directory.
# Run once per fresh clone:
#
#   ./scripts/setup-githooks.sh
#
# After that, every `git commit` in this repo runs .githooks/post-commit, which
# refreshes the graphify knowledge graph (AST-only, no LLM cost).

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/*

echo "git hooks path → .githooks/"
echo "  post-commit: graphify update . (AST-only refresh)"
echo
echo "To verify: git config core.hooksPath"
