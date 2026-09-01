#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GENERATOR="$REPO_ROOT/assets/installer/generate-eula.py"
SOURCE="$REPO_ROOT/docs/legal/terms-of-service.md"
EULA="$REPO_ROOT/assets/installer/EULA.rtf"
SLA="$REPO_ROOT/assets/installer/sla.r"
INSTALLER="$REPO_ROOT/scripts/build-installer.sh"

python3 "$GENERATOR" --check

rg -Fq 'Deleted memories are removed as database rows and local storage is compacted.' \
    "$REPO_ROOT/apps/onboarding/Sources/Onboarding/Slides/RetentionSlide.swift"
rg -Fq 'python3 "$GENERATE_EULA" --check' "$INSTALLER"

for prohibited in \
    'crypto[[:space:]-]*shred' \
    'zero[[:space:]-]*knowledge' \
    'Secure[[:space:]]+Enclave' \
    'Neural[[:space:]]+Engine' \
    'sqlite[[:space:]-]*vec' \
    'no[[:space:]]+third[[:space:]]+party[[:space:]]+can[[:space:]]+decrypt'; do
    if rg -i -q -- "$prohibited" \
        "$SOURCE" "$EULA" "$SLA" \
        "$REPO_ROOT/apps/onboarding/Sources/Onboarding/Slides/RetentionSlide.swift" \
        "$REPO_ROOT/apps/agent/src/bin/mci_seed_brain.rs" \
        "$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/MciBootGuards.swift" \
        "$REPO_ROOT/docs/assets/data-flow-diagram.svg"; then
        echo "FAIL: prohibited unshipped guarantee remains: $prohibited" >&2
        exit 1
    fi
done

FIXTURE="$(mktemp -d -t hippocampus-legal-contract)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/assets/installer" "$FIXTURE/docs/legal"
cp "$GENERATOR" "$EULA" "$SLA" "$FIXTURE/assets/installer/"
cp "$SOURCE" "$FIXTURE/docs/legal/"

printf '\nDRIFT\n' >>"$FIXTURE/assets/installer/EULA.rtf"
if python3 "$FIXTURE/assets/installer/generate-eula.py" --check >/dev/null 2>&1; then
    echo "FAIL: legal artifact drift was accepted" >&2
    exit 1
fi

cp "$EULA" "$FIXTURE/assets/installer/EULA.rtf"
printf '\nThe product guarantees zero-knowledge storage.\n' >>"$FIXTURE/docs/legal/terms-of-service.md"
if python3 "$FIXTURE/assets/installer/generate-eula.py" --check >/dev/null 2>&1; then
    echo "FAIL: prohibited legal guarantee was accepted" >&2
    exit 1
fi

echo "PASS: Task 2 product truth and legal drift contract"
