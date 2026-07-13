#!/usr/bin/env bash
# gen-changelog.sh — automated CHANGELOG.md generation from conventional-commit git log.
# Runlog architecture study §P2 pattern (cycle 8.51).
#
# Parses conventional-commit subjects on the current branch since the last
# release tag (or a --since ref) and emits categorized Markdown release notes.
# Usable both to seed CHANGELOG.md and to draft Sparkle appcast release notes
# (see scripts/publish-appcast.sh / PR #32).

set -euo pipefail

# ---- Repo root ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---- Defaults ----------------------------------------------------------------
SINCE=""              # git ref (tag or SHA). Empty -> auto: last tag, else --all.
OUTPUT=""             # file path. Empty -> stdout.
DRY_RUN=0             # 1 -> stdout only, never touch OUTPUT
VERSION=""            # optional heading label; else "Unreleased"

usage() {
    cat <<'EOF'
gen-changelog.sh — categorized CHANGELOG.md from conventional-commit git log

USAGE
    ./scripts/gen-changelog.sh [--since <ref>] [--output <file>]
                              [--version <label>] [--dry-run] [--help]

FLAGS
    --since <ref>       Start ref (tag/SHA). Default: last tag on HEAD, else
                        the entire history (--all).
    --output <file>     Write output to <file>. In prepend mode: existing
                        CHANGELOG.md content is preserved below the new entry
                        (previous file saved as CHANGELOG.md.orig on first run).
                        Default: stdout.
    --version <label>   Section heading label (e.g. "1.0.0"). Default:
                        "Unreleased".
    --dry-run           Force stdout even if --output is set. No writes.
    -h, --help          Show this help and exit.

CATEGORIES (conventional-commit type -> section)
    feat        ✨ Features
    fix         🐛 Bug fixes
    docs        📝 Docs
    perf        🚀 Performance
    deps        📦 Dependencies
    test        🧪 Tests
    refactor    ♻️ Refactor
    ci, build   🏗️ Build & CI
    security    🔒 Security   (also: fix(crypto), fix(brain-ffi))
    <other>     (skipped — chore/style/wip etc. are internal-only)

EXAMPLES
    ./scripts/gen-changelog.sh                       # stdout, auto range
    ./scripts/gen-changelog.sh --since v0.1.0        # from tag
    ./scripts/gen-changelog.sh --output CHANGELOG.md # prepend to file
    ./scripts/gen-changelog.sh --version 1.0.0 --dry-run
EOF
}

# ---- Args --------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)   SINCE="${2:-}"; shift 2 ;;
        --output)  OUTPUT="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "gen-changelog.sh: unknown flag: $1" >&2
           echo "Try: ./scripts/gen-changelog.sh --help" >&2
           exit 1 ;;
    esac
done

# ---- Resolve range -----------------------------------------------------------
if [[ -z "$SINCE" ]]; then
    if last_tag=$(git describe --tags --abbrev=0 2>/dev/null); then
        SINCE="$last_tag"
    fi
fi

if [[ -n "$SINCE" ]]; then
    if ! git rev-parse --verify --quiet "$SINCE^{commit}" >/dev/null; then
        echo "gen-changelog.sh: --since ref not found: $SINCE" >&2
        exit 1
    fi
    RANGE="${SINCE}..HEAD"
    RANGE_LABEL="$SINCE..HEAD"
else
    RANGE="--all"
    RANGE_LABEL="entire history"
fi

# ---- Section heading ---------------------------------------------------------
DATE="$(date +%Y-%m-%d)"
HEADING_LABEL="${VERSION:-Unreleased}"

# ---- Collect + categorize ----------------------------------------------------
# git log with a rare US separator between fields to avoid collisions with
# subjects that contain pipes, quotes, etc.
SEP=$'\x1f'
LOG_FMT="%H${SEP}%s"

# Buffers per category
declare -a CAT_FEAT=() CAT_FIX=() CAT_DOCS=() CAT_PERF=() CAT_DEPS=()
declare -a CAT_TEST=() CAT_REFACTOR=() CAT_CI=() CAT_SECURITY=()

commit_count=0
categorized_count=0

# Pull log. If RANGE is --all we pass it as a single arg; else a rev-range.
if [[ "$RANGE" == "--all" ]]; then
    LOG_OUT=$(git log --no-merges --pretty=format:"$LOG_FMT" --all 2>/dev/null || true)
else
    LOG_OUT=$(git log --no-merges --pretty=format:"$LOG_FMT" "$RANGE" 2>/dev/null || true)
fi

while IFS="$SEP" read -r sha subject; do
    [[ -z "${sha:-}" ]] && continue
    commit_count=$((commit_count + 1))

    # Extract PR number (last "#N" in subject); rest of subject is display text.
    pr=""
    pr_re='\(#([0-9]+)\)[[:space:]]*$'
    if [[ "$subject" =~ $pr_re ]]; then
        pr="${BASH_REMATCH[1]}"
    fi

    # Parse conventional-commit type + optional scope: "type(scope): rest"
    # or "type: rest". Regex must be in a variable for portable bash =~.
    cc_re='^([a-zA-Z]+)(\(([^)]+)\))?!?:[[:space:]](.*)$'
    if [[ "$subject" =~ $cc_re ]]; then
        type="${BASH_REMATCH[1],,}"
        scope="${BASH_REMATCH[3],,}"
        rest="${BASH_REMATCH[4]}"
    else
        # Non-conventional -> skip (internal noise).
        continue
    fi

    # Strip trailing " (#NN)" from display line since we render it separately.
    display="$(echo "$rest" | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//')"

    # Build bullet: "- <scope>: <display> (short-sha[, #PR])"
    short_sha="${sha:0:7}"
    prefix=""
    [[ -n "$scope" ]] && prefix="**${scope}:** "
    ref="\`${short_sha}\`"
    [[ -n "$pr" ]] && ref="${ref} · [#${pr}](../../pull/${pr})"
    bullet="- ${prefix}${display} (${ref})"

    # Route to category. Security override: fix(crypto), fix(brain-ffi),
    # and explicit security type all go to Security.
    case "$type" in
        security)
            CAT_SECURITY+=("$bullet") ;;
        fix)
            if [[ "$scope" == "crypto" || "$scope" == "brain-ffi" || "$scope" == "sync" ]]; then
                CAT_SECURITY+=("$bullet")
            else
                CAT_FIX+=("$bullet")
            fi
            ;;
        feat)     CAT_FEAT+=("$bullet") ;;
        docs)     CAT_DOCS+=("$bullet") ;;
        perf)     CAT_PERF+=("$bullet") ;;
        deps)     CAT_DEPS+=("$bullet") ;;
        test)     CAT_TEST+=("$bullet") ;;
        refactor) CAT_REFACTOR+=("$bullet") ;;
        ci|build) CAT_CI+=("$bullet") ;;
        chore|style|wip) continue ;;  # internal-only
        *) continue ;;
    esac
    categorized_count=$((categorized_count + 1))
done <<< "$LOG_OUT"

# ---- Emit --------------------------------------------------------------------
emit_section() {
    local title="$1"; shift
    local -a items=("$@")
    if [[ ${#items[@]} -gt 0 ]]; then
        printf '### %s\n\n' "$title"
        for line in "${items[@]}"; do
            printf '%s\n' "$line"
        done
        printf '\n'
    fi
}

render() {
    printf '## [%s] — %s\n\n' "$HEADING_LABEL" "$DATE"
    printf '_Range: %s · %d commit(s) categorized (%d total scanned)._\n\n' \
        "$RANGE_LABEL" "$categorized_count" "$commit_count"
    emit_section "✨ Features"          "${CAT_FEAT[@]+"${CAT_FEAT[@]}"}"
    emit_section "🐛 Bug fixes"          "${CAT_FIX[@]+"${CAT_FIX[@]}"}"
    emit_section "🔒 Security"           "${CAT_SECURITY[@]+"${CAT_SECURITY[@]}"}"
    emit_section "🚀 Performance"        "${CAT_PERF[@]+"${CAT_PERF[@]}"}"
    emit_section "📝 Docs"               "${CAT_DOCS[@]+"${CAT_DOCS[@]}"}"
    emit_section "📦 Dependencies"       "${CAT_DEPS[@]+"${CAT_DEPS[@]}"}"
    emit_section "🧪 Tests"              "${CAT_TEST[@]+"${CAT_TEST[@]}"}"
    emit_section "♻️ Refactor"           "${CAT_REFACTOR[@]+"${CAT_REFACTOR[@]}"}"
    emit_section "🏗️ Build & CI"         "${CAT_CI[@]+"${CAT_CI[@]}"}"
}

NEW_ENTRY="$(render)"

if [[ $DRY_RUN -eq 1 || -z "$OUTPUT" ]]; then
    printf '%s' "$NEW_ENTRY"
    exit 0
fi

# Prepend mode with header preservation.
HEADER=$'# Changelog\n\nAll notable changes to Hippocampus. Generated via `scripts/gen-changelog.sh` from conventional-commit history — see [CONTRIBUTING.md](CONTRIBUTING.md).\n\n'

if [[ -f "$OUTPUT" ]]; then
    # Preserve original once (idempotent).
    if [[ ! -f "${OUTPUT}.orig" ]]; then
        cp "$OUTPUT" "${OUTPUT}.orig"
    fi
    # Strip existing "# Changelog" header (first ~4 lines) if present so we
    # can prepend a fresh entry cleanly.
    existing=$(awk 'BEGIN{skip=1} /^## / {skip=0} skip==0 {print}' "$OUTPUT")
    {
        printf '%s' "$HEADER"
        printf '%s\n' "$NEW_ENTRY"
        [[ -n "$existing" ]] && printf '%s\n' "$existing"
    } > "${OUTPUT}.tmp"
    mv "${OUTPUT}.tmp" "$OUTPUT"
else
    {
        printf '%s' "$HEADER"
        printf '%s\n' "$NEW_ENTRY"
    } > "$OUTPUT"
fi

echo "wrote $OUTPUT ($categorized_count categorized / $commit_count scanned; range: $RANGE_LABEL)" >&2
