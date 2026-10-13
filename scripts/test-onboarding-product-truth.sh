#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCES="$REPO_ROOT/apps/onboarding/Sources"
COPY="$SOURCES/OnboardingKit/OnboardingCopy.swift"
PROMISE="$SOURCES/Onboarding/Slides/PromiseSlide.swift"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# Claims setup must never show, in any string it can print. A comment may
# say why a claim is left out; a string literal may not make it.
if rg -n -i \
    '"[^"]*(picture is never saved|Frames are OCR.d in memory and discarded|your data never leaves this Mac|Everything stays on this Mac.*zero network|never uploaded|password managers|only captures from apps you explicitly trust)[^"]*"' \
    "$SOURCES"; then
    fail "onboarding still makes an absolute claim the code does not keep"
fi

# Browsers are read like every other window, with no extension and no
# prompt, and a private window is skipped only when it shows it is private
# (RULINGS G8). No string may say otherwise, and the Promise says so.
if rg -n -i \
    '"[^"]*(until you add the extension|macOS will ask about|Choose Allow so Hippocampus|and private browser windows|private (browser )?windows are never)[^"]*"' \
    "$SOURCES"; then
    fail "onboarding still says a browser needs the extension or a prompt, or that private windows are never read"
fi
rg -Fq 'privateWindowsSkipped = "Private browser windows are skipped when they show they are private."' "$COPY" \
    || fail "onboarding does not say private browser windows are skipped only when they show they are private"
rg -q 'static let promiseNeverRead = .*privateWindowsSkipped' "$COPY" \
    || fail "the Promise's never-read line does not carry the private window sentence"

# Consent is the Promise screen, and its first line is what
# `promiseStays(kept:)` returns. Only that function's code counts: its
# body with comment lines dropped, so a comment that quotes a claim can
# never stand in for the claim.
STAYS="$(awk '
    /func promiseStays\(kept: String\) -> String \{/ { inside = 1; next }
    inside && /^    \}/ { exit }
    inside && !/^[[:space:]]*\/\// { print }
' "$COPY")"
[[ -n "$STAYS" ]] || fail "OnboardingCopy.promiseStays(kept:) is missing; the Promise has no first line to check"

# Each disclosure must be inside the line's string literal.
require_in_promise() {
    local phrase="$1" reason="$2"
    printf '%s\n' "$STAYS" | rg -q "\"[^\"]*${phrase}[^\"]*\"" || fail "$reason"
}

# Screenshots are kept as well as text; Hippocampus itself uploads
# nothing; sharing with an AI waits on the person connecting it; and what
# an AI reads goes to the company that runs it.
require_in_promise 'Text and screenshots, encrypted' \
    "onboarding does not disclose that text and screenshots are kept, encrypted"
require_in_promise 'Nothing is uploaded by Hippocampus\.' \
    "onboarding does not state Hippocampus's own network boundary"
require_in_promise 'only if you connect it\.' \
    "onboarding does not say that an AI gets nothing until the person connects it"
require_in_promise 'goes to the company that runs' \
    "onboarding does not disclose the AI tool provider boundary"
rg -Fq 'OnboardingCopy.promiseStays(kept:' "$PROMISE" \
    || fail "the Promise screen does not show the line that makes these disclosures"

printf 'PASS: onboarding discloses screenshots, its own network boundary, connecting, the AI tool boundary and private windows truthfully\n'
