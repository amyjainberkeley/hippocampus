#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SLIDES="$REPO_ROOT/apps/onboarding/Sources/Onboarding/Slides"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

if rg -n \
    'picture is never saved|Frames are OCR.d in memory and discarded|your data never leaves this Mac|Everything stays on this Mac.*zero network' \
    "$SLIDES"; then
    fail "onboarding still makes an absolute claim contradicted by encrypted keyframes or agent handoff"
fi

rg -qi 'selected encrypted (visual )?keyframes' "$SLIDES" \
    || fail "onboarding does not disclose selected encrypted keyframe retention"
rg -qi 'connected AI (tools|clients).*provider|client.*controls where.*context' "$SLIDES" \
    || fail "onboarding does not disclose the agent handoff trust boundary"
rg -qi 'does not upload captured memory|never uploads captured memory' "$SLIDES" \
    || fail "onboarding does not state Hippocampus's own network boundary"

printf 'PASS: onboarding describes keyframes, local custody, and agent handoff truthfully\n'
