#!/usr/bin/env bash
# claims-check.sh — substantiate every public claim before publishing.
#
# The FTC's "substantiate before you publish" discipline, as a script that
# passes or fails. It reads the public copy a stranger sees — the repo
# README, the launch FAQ, and the marketing site — and checks three things:
#
#   1. Evidence integrity. Every claim registered in docs/launch/claims.md
#      must still point at real evidence in THIS repo: a test, an eval
#      document, a measurement, or a source file, and the cited value must
#      still be present there. Evidence that was deleted or drifted fails.
#
#   2. No unsubstantiated measurement. Every footprint/accuracy/size number
#      that appears in the public copy (percentages, MB/MiB/GB, joules,
#      CPU-seconds) must be registered in claims.md. A number with no
#      backing entry fails, so copy cannot grow a new figure without
#      recording where it came from.
#
#   3. No ruled-out claim. The absolutes and the competitor-echoing line the
#      owner ruled out (decisions, 2026-10-15) must not appear in any public
#      source. This extends scripts/test-public-tree.sh (which guards the
#      in-repo docs) to the FAQ and the external site.
#
# Usage:
#   scripts/launch/claims-check.sh [SITE_DIR]
#
# SITE_DIR is the marketing-site checkout (it holds public/*.html and
# launch/faq.md). Resolution order: $1, then $HIPPO_SITE_DIR, then a
# ../hippocampus-site sibling of this repo. When no site is found the
# README and in-repo evidence are still checked,
# and the site/FAQ scan is reported as skipped (not failed) — so this runs
# as a repo CI gate and as a full pre-publish gate with the site present.
#
# Exit status is 0 only when every check that ran passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="$REPO/docs/launch/claims.md"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
note() { printf '  %s\n' "$1"; }

# --- Resolve the site checkout (optional) ----------------------------------
# Pass "none" (or "--repo-only"), or set HIPPO_SITE_DIR=none, to gate only the
# repo's own copy (README + in-repo evidence) — what CI on the public repo
# does, since it has no site checkout beside it.
SITE_DIR=""
if [[ "${1:-}" != "none" && "${1:-}" != "--repo-only" && "${HIPPO_SITE_DIR:-}" != "none" ]]; then
    for candidate in "${1:-}" "${HIPPO_SITE_DIR:-}" "$REPO/../hippocampus-site"; do
        [[ -n "$candidate" ]] || continue
        if [[ -d "$candidate/public" ]]; then SITE_DIR="$(cd "$candidate" && pwd)"; break; fi
    done
fi

# --- The public sources this gate reads ------------------------------------
# README is always in the repo. The FAQ and site pages come from SITE_DIR.
PUBLIC_FILES=()
[[ -f "$REPO/README.md" ]] && PUBLIC_FILES+=("$REPO/README.md")
if [[ -n "$SITE_DIR" ]]; then
    [[ -f "$SITE_DIR/launch/faq.md" ]] && PUBLIC_FILES+=("$SITE_DIR/launch/faq.md")
    while IFS= read -r html; do PUBLIC_FILES+=("$html"); done \
        < <(find "$SITE_DIR/public" -maxdepth 1 -name '*.html' | sort)
fi

# --- Ruled-out claims (decisions, 2026-10-15) ------------------------------
# Absolutes that cannot be substantiated, and the headline that echoes a
# competitor's. Kept in step with scripts/test-public-tree.sh.
FORBIDDEN=(
    'nothing leaves your mac'
    'never reads passwords'
    'remembers everything'
    'perfect ocr'
    'lightweight'
    'total recall'
    'your ai already knows'
)

# --- Load the registry -----------------------------------------------------
# Rows live in the markdown table between the REGISTRY markers in claims.md.
# Columns: ID | Published value(s) | Pages | Evidence (kind:path) | Verify | Enforce
if [[ ! -f "$REGISTRY" ]]; then
    echo "FAIL: registry not found at $REGISTRY" >&2
    exit 1
fi

# Emit clean TAB-separated rows (id, values, pages, evidence, verify, enforce).
registry_rows() {
    awk '
        /<!--[ ]*REGISTRY:BEGIN[ ]*-->/ { on=1; next }
        /<!--[ ]*REGISTRY:END[ ]*-->/   { on=0 }
        on && /^[ ]*\|/ {
            line=$0
            sub(/^[ ]*\|/, "", line); sub(/\|[ ]*$/, "", line)
            n=split(line, f, /[ ]*\|[ ]*/)
            id=f[1]; gsub(/^[ ]+|[ ]+$/, "", id)
            if (id == "ID" || id ~ /^-+$/ || id == "") next
            for (i=1;i<=n;i++) gsub(/^[ ]+|[ ]+$/, "", f[i])
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", f[1], f[2], f[3], f[4], f[5], f[6]
        }
    ' "$REGISTRY"
}

ROWS="$(registry_rows)"
if [[ -z "$ROWS" ]]; then
    echo "FAIL: no claim rows parsed from $REGISTRY" >&2
    exit 1
fi

echo "== claims-check =="
echo "repo:  $REPO"
echo "site:  ${SITE_DIR:-<none found — README + in-repo evidence only>}"
echo "rows:  $(printf '%s\n' "$ROWS" | grep -c .)"
echo

# --- Check 1: evidence integrity -------------------------------------------
echo "-- evidence integrity --"
while IFS=$'\t' read -r id _ _ evidence verify _; do
    [[ -n "$id" ]] || continue
    path="${evidence#*:}"
    abspath="$REPO/$path"
    if [[ ! -e "$abspath" ]]; then
        fail "[$id] evidence missing: $evidence"
        continue
    fi
    if [[ "$verify" != "-" && -n "$verify" ]]; then
        if [[ -d "$abspath" ]]; then
            if ! grep -R -F -q -- "$verify" "$abspath" 2>/dev/null; then
                fail "[$id] value \"$verify\" not found under $path/"
            fi
        elif ! grep -F -q -- "$verify" "$abspath" 2>/dev/null; then
            fail "[$id] value \"$verify\" not found in $path (evidence drifted)"
        fi
    fi
done <<< "$ROWS"
[[ "$FAILURES" -eq 0 ]] && note "every registered claim resolves to present evidence"
echo

# --- Build the set of registered (enforced) measurement tokens -------------
ENFORCED_FILE="$(mktemp "${TMPDIR:-/tmp}/claims-enforced.XXXXXX")"
trap 'rm -f "$ENFORCED_FILE"' EXIT
while IFS=$'\t' read -r _ values _ _ _ enforce; do
    [[ "$enforce" == "Y" ]] || continue
    # values may hold several tokens separated by ", "
    printf '%s\n' "$values" | sed 's/, */\n/g' | sed 's/^ *//; s/ *$//' >> "$ENFORCED_FILE"
done <<< "$ROWS"
# Normalise: collapse internal whitespace to single spaces.
normalise() { tr -s ' \t' '  ' | sed 's/^ *//; s/ *$//' | tr -s ' ' ' '; }
sort -u "$ENFORCED_FILE" -o "$ENFORCED_FILE"

is_registered() {
    local token; token="$(printf '%s' "$1" | normalise)"
    grep -F -x -q -- "$token" "$ENFORCED_FILE"
}

# Pull number+unit measurement tokens out of a stream of visible text.
# Matches an optional "N to N" range, optional space, then a unit. POSIX ERE
# is leftmost-longest, so MiB wins over MB and the whole range is captured.
# Units are the ones real footprint/accuracy claims use: %, MB/MiB/GB/GiB, J,
# CPU-seconds. KB-scale numbers on the page are sample attachment sizes in the
# reading demo, not product claims, so KB is deliberately out of scope.
extract_measurements() {
    grep -oE '[0-9][0-9.,]*( to [0-9][0-9.,]*)?[ ]?(CPU-seconds|CPU-s|MiB|MB|GiB|GB|J|%)' \
        || true
}

# --- Check 2: no unsubstantiated measurement -------------------------------
echo "-- no unsubstantiated measurement --"
if [[ "${#PUBLIC_FILES[@]}" -eq 0 ]]; then
    note "no public sources found to scan"
else
    for src in "${PUBLIC_FILES[@]}"; do
        # Strip HTML tags so attribute data (SVG paths, pixel sizes) is ignored.
        text="$(sed -e 's/<[^>]*>/ /g' "$src")"
        while IFS= read -r tok; do
            [[ -n "$tok" ]] || continue
            if ! is_registered "$tok"; then
                fail "unregistered measurement \"$tok\" in ${src#"$REPO"/} — add it to docs/launch/claims.md with its source"
            fi
        done < <(printf '%s\n' "$text" | extract_measurements | normalise | sort -u)
    done
    [[ "$FAILURES" -eq 0 ]] && note "every public measurement is registered with a source"
fi
echo

# --- Check 3: no ruled-out claim -------------------------------------------
echo "-- no ruled-out claim --"
if [[ "${#PUBLIC_FILES[@]}" -eq 0 ]]; then
    note "no public sources found to scan"
else
    for src in "${PUBLIC_FILES[@]}"; do
        for phrase in "${FORBIDDEN[@]}"; do
            # Raw file (not tag-stripped) so meta/og descriptions are covered.
            if grep -i -n -F -- "$phrase" "$src" >/dev/null 2>&1; then
                hits="$(grep -i -c -F -- "$phrase" "$src")"
                fail "ruled-out claim \"$phrase\" appears ${hits}x in ${src#"$REPO"/}"
            fi
        done
    done
    [[ "$FAILURES" -eq 0 ]] && note "no ruled-out absolute or competitor-echo phrase in public copy"
fi
echo

# --- Verdict ---------------------------------------------------------------
if [[ "$FAILURES" -gt 0 ]]; then
    echo "claims-check: $FAILURES problem(s). Public copy is NOT ready to publish." >&2
    exit 1
fi
echo "PASS: every public claim is substantiated, every measurement is sourced, and no ruled-out claim appears."
