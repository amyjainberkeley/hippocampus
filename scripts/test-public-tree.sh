#!/usr/bin/env bash
# The public tree carries no private paths, no job titles from the early
# process, no enterprise or paid-tier text, no internal strategy notes, and
# no absolute privacy or quality claims in the documents people read first.
#
#   scripts/test-public-tree.sh [ROOT]
#
# ROOT defaults to this repository; a test can point it at a fixture
# repository. Each exception below is a file whose text is pinned elsewhere
# or names something outside this project, and says why.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FAILURES=0

# Run on the repository itself, first prove on a planted fixture that every
# check below can fail.
if [[ $# -eq 0 ]]; then
    FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/public-tree-fixture.XXXXXX")"
    trap 'rm -rf "$FIXTURE"' EXIT
    mkdir -p "$FIXTURE/docs/research" "$FIXTURE/src"
    printf 'Nothing leaves your Mac.\n' >"$FIXTURE/README.md"
    printf 'path = "/Users/amy/x"\n' >"$FIXTURE/src/a.toml"
    printf '// CEO ratified this\n' >"$FIXTURE/src/b.rs"
    printf 'For enterprise buyers.\n' >"$FIXTURE/src/c.md"
    printf 'struct TierGate {}\n' >"$FIXTURE/src/d.swift"
    printf 'plan\n' >"$FIXTURE/docs/research/plan.md"
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" add -A
    if planted="$("$0" "$FIXTURE" 2>&1)"; then
        echo "FAIL: the planted fixture passed:" >&2
        echo "$planted" >&2
        exit 1
    fi
    if [[ "$(grep -c '^FAIL: ' <<<"$planted")" -ne 6 ]]; then
        echo "FAIL: the planted fixture did not fail all six checks:" >&2
        echo "$planted" >&2
        exit 1
    fi
fi

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

# Tracked text files only, so build output and ignored folders never count.
# This script names what it looks for, so it is left out.
search() {
    git -C "$ROOT" grep -I -n "$@" -- . ':!scripts/test-public-tree.sh' || [[ $? -eq 1 ]]
}

matches=$(search -e '/Users/amy' -e 'Users-amy')
if [[ -n "$matches" ]]; then
    fail "a private home path is in the tree:"$'\n'"$matches"
fi

# Embedding sentences whose reference vectors are committed (two files), the
# publication "CSO Online", tokenizer vocabularies, and the seed-brain test
# that forbids an old title in the demo corpus.
matches=$(search -w -E 'CSO|CEO|COO|CTO|CPO|CMO|CRS|Director(-[A-Za-z-]+)?' \
    | grep -v -E '^adapters/macos/mci-embed-coreml/tests/fixtures/arctic_embed_sentences\.txt:' \
    | grep -v -E '^scripts/convert_embedder\.py:[0-9]+:    "(Director-Brain|CEO \+ CRS)' \
    | grep -v -F 'CSO Online' \
    | grep -v -E '/tokenizer\.json:' \
    | grep -v -E '^apps/agent/src/bin/mci_seed_brain\.rs:[0-9]+: +"Director-Recording",$' \
    || true)
if [[ -n "$matches" ]]; then
    fail "a job title from the early process is in the tree:"$'\n'"$matches"
fi

# A made-up evaluation corpus pinned by its .sha256, tokenizer vocabularies,
# and the decisions index's note on what was withdrawn.
matches=$(search -i -w 'enterprise' \
    | grep -v -E '^eval/evidence-verifier/v2-corpus\.json:' \
    | grep -v -E '/tokenizer\.json:' \
    | grep -v -E '^docs/decisions/README\.md:[0-9]+:> with three exceptions\. Team, enterprise and paid-tier sections are marked$' \
    || true)
if [[ -n "$matches" ]]; then
    fail "enterprise text is in the tree:"$'\n'"$matches"
fi

matches=$(search -i -e 'TierGate' -e 'freemium' -e 'tier-structure')
if [[ -n "$matches" ]]; then
    fail "paid-tier code or notes are in the tree:"$'\n'"$matches"
fi

if [[ -n "$(git -C "$ROOT" ls-files docs/research docs/business)" ]]; then
    fail "internal strategy notes are tracked under docs/research or docs/business"
fi

# Claims the owner ruled out (2026-10-15): absolutes, and a headline that
# repeats another product's.
for document in README.md PRIVACY.md SECURITY.md docs/STATUS.md docs/release/notes-0.3.0.md; do
    [[ -f "$ROOT/$document" ]] || continue
    for claim in 'nothing leaves your mac' 'never reads passwords' 'remembers everything' \
        'perfect ocr' 'lightweight' 'total recall' 'your ai already knows'; do
        if grep -i -n -F -- "$claim" "$ROOT/$document" >/dev/null; then
            fail "$document says \"$claim\""
        fi
    done
done

if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
fi
echo "PASS: the public tree has no private paths, old job titles, enterprise or paid-tier text, strategy notes or ruled-out claims"
