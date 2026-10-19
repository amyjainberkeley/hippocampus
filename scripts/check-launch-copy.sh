#!/usr/bin/env bash
# check-launch-copy.sh — an outside judge for Hippocampus's launch copy.
#
# Runs over the words a stranger actually reads — the installer window, the
# menu-bar panel, the window (Overview / Ask / You), onboarding, and the
# README / website — and fails if any of them slips below a professional,
# trustworthy, Apple-quality bar. It is deliberately a plain grep gate (no
# build, no Swift) so it runs in a second, in CI or by hand, and passes or
# fails on its own, not on anyone's say-so.
#
# What it checks:
#   1. No marketing or machine-written words (seamless, supercharge, delve, …).
#   2. No exclamation marks in a UI string (status copy never shouts).
#   3. No em-dash pileups (one spaced em-dash is fine; a stack reads as machine).
#   4. No engineer jargon in display copy ("MCI", SCStream, SQLCipher, …).
#   5. No "captures"/"captured" as a user word (the product remembers moments).
#   6. No competitor echo ("your AI already knows what you're working on").
#   7. No absolute privacy/footprint claims the launch decisions ban.
#
# The in-code tests (RecallUIKit CopyStyleTests, HippocampusKit
# MenuBarCopyStyleTests, OnboardingKit OnboardingCopyTests) enforce the same
# bar string-by-string; this script is the single cross-app gate.
#
# Usage:  scripts/check-launch-copy.sh          # scan the whole repo's copy
# Exit:   0 = clean, 1 = violations found (each printed with file:line).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The user-facing copy surfaces. Each file is display copy a person reads.
COPY_FILES=(
  "apps/recall-ui/Sources/RecallUIKit/UserFacingCopy.swift"
  "apps/recall-ui/Sources/RecallUIKit/OverviewCopy.swift"
  "apps/recall-ui/Sources/RecallUIKit/YouCopy.swift"
  "apps/recall-ui/Sources/RecallUIKit/SessionCopy.swift"
  "apps/recall-ui/Sources/RecallUIKit/DesignSystem/MCIEmptyState.swift"
  "apps/recall-ui/Sources/RecallUIKit/PrivacyDashboardModel.swift"
  "apps/onboarding/Sources/OnboardingKit/OnboardingCopy.swift"
  "apps/hippocampus/Sources/HippocampusKit/MenuBarStatus.swift"
  "apps/hippocampus/Sources/HippocampusKit/StatusMenuModel.swift"
  "apps/hippocampus/Sources/HippocampusKit/CommandBar/AskPanelStatus.swift"
  "assets/installer/render-background.swift"
)

# Marketing / machine-written words (whole word, case-insensitive).
MARKETING_WORDS="seamless|seamlessly|effortless|effortlessly|unlock|supercharge|supercharged|magic|magical|delve|powerful|smart|simply|leverage|utilize|robust|elevate|empower|unleash|harness|turbocharge|frictionless|revolutionary|transformative|hiccup|oops|whoops|gotcha"
# Marketing phrases (substring, case-insensitive).
MARKETING_PHRASES="ai-powered|ai powered|game-?changer|cutting[ -]edge|state[ -]of[ -]the[ -]art|blazing fast|lightning fast|world-class|best-in-class|next-generation"
# Engineer jargon that must never reach display copy (whole word).
JARGON_WORDS="mci|scstream|sqlcipher|sentinel|errno|captures|captured"
# Absolute claims the launch decisions ban (substring).
ABSOLUTE_CLAIMS="nothing leaves your mac|never reads? passwords?|remembers everything|perfect ocr|military-grade|100% (private|secure)|bank-level"
# The competitor echo (substring). The window now leads with how your AI starts.
COMPETITOR="already knows what you"

fail=0

# Pull just the quoted string literals out of a Swift file, one per output
# line as "<lineno>:"<literal>"", so a jargon token in a code identifier
# (e.g. MCI.Color, which is not quoted) is never mistaken for display copy.
# Comment-only lines are dropped first.
quoted_literals() {
  grep -nE '"' "$1" \
    | grep -vE '^[0-9]+:[[:space:]]*(///|//|\*)' \
    | while IFS= read -r line; do
        local num="${line%%:*}" rest="${line#*:}"
        printf '%s\n' "$rest" | grep -oE '"[^"]*"' | sed "s/^/${num}:/"
      done
}

echo "== Hippocampus launch copy check =="
echo "root: $REPO_ROOT"
echo

for file in "${COPY_FILES[@]}"; do
  if [ ! -f "$file" ]; then
    printf '  WARN missing copy file: %s\n' "$file"
    continue
  fi
  lits="$(quoted_literals "$file")"
  [ -z "$lits" ] && continue

  # 1. marketing words (whole word)
  m="$(printf '%s\n' "$lits" | grep -iwE "$MARKETING_WORDS" || true)"
  if [ -n "$m" ]; then printf '%s\n' "$m" | sed "s|^|  FAIL [marketing-word] $file:|"; fail=1; fi

  # 2. marketing phrases (substring)
  p="$(printf '%s\n' "$lits" | grep -iE "$MARKETING_PHRASES" || true)"
  if [ -n "$p" ]; then printf '%s\n' "$p" | sed "s|^|  FAIL [marketing-phrase] $file:|"; fail=1; fi

  # 3. exclamation marks inside a UI string
  e="$(printf '%s\n' "$lits" | grep -E ':"[^"]*![^"]*"' || true)"
  if [ -n "$e" ]; then printf '%s\n' "$e" | sed "s|^|  FAIL [exclamation] $file:|"; fail=1; fi

  # 4. em-dash pileups (two or more in one literal)
  d="$(printf '%s\n' "$lits" | grep -E ':"[^"]*\xe2\x80\x94[^"]*\xe2\x80\x94' || true)"
  if [ -n "$d" ]; then printf '%s\n' "$d" | sed "s|^|  FAIL [em-dash-pileup] $file:|"; fail=1; fi

  # 5. engineer jargon in display copy (whole word)
  j="$(printf '%s\n' "$lits" | grep -iwE "$JARGON_WORDS" || true)"
  if [ -n "$j" ]; then printf '%s\n' "$j" | sed "s|^|  FAIL [jargon] $file:|"; fail=1; fi

  # 6. competitor echo
  c="$(printf '%s\n' "$lits" | grep -iE "$COMPETITOR" || true)"
  if [ -n "$c" ]; then printf '%s\n' "$c" | sed "s|^|  FAIL [competitor-echo] $file:|"; fail=1; fi
done

# README + website: prose surfaces. Scan whole lines (not just quotes).
PROSE_GLOBS=("README.md")
[ -d website/app ] && PROSE_GLOBS+=("website/app")
[ -d website/components ] && PROSE_GLOBS+=("website/components")

scan_prose() { # pattern label
  local pattern="$1" label="$2" hits
  hits="$(grep -rniE "$pattern" "${PROSE_GLOBS[@]}" 2>/dev/null \
          | grep -viE 'node_modules|\.test\.|__tests__' || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|  FAIL [$label] |"
    fail=1
  fi
}

echo
echo "-- README + website --"
scan_prose "$COMPETITOR" "competitor-echo"
scan_prose "$ABSOLUTE_CLAIMS" "absolute-claim"

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS — launch copy is clean."
else
  echo "FAIL — fix the lines above before launch."
fi
exit "$fail"
