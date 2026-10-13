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

# Consent is the Promise screen. It says that screenshots are kept as well
# as text, that Hippocampus itself uploads nothing, and that what an AI
# tool reads goes to the company that runs it.
rg -Fq 'Text and screenshots, encrypted' "$COPY" \
    || fail "onboarding does not disclose that text and screenshots are kept, encrypted"
rg -Fq 'Nothing is uploaded by Hippocampus.' "$COPY" \
    || fail "onboarding does not state Hippocampus's own network boundary"
rg -Fq 'goes to the company that runs' "$COPY" \
    || fail "onboarding does not disclose the AI tool provider boundary"
rg -Fq 'OnboardingCopy.promiseStays(kept:' "$PROMISE" \
    || fail "the Promise screen does not show the line that makes these disclosures"

printf 'PASS: onboarding discloses screenshots, its own network boundary and the AI tool boundary truthfully\n'
