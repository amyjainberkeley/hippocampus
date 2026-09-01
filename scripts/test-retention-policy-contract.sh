#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d -t hippocampus-retention-contract)"
trap 'rm -rf "$FIXTURE"' EXIT

"$REPO_ROOT/scripts/swift-package.sh" run \
    --package-path "$REPO_ROOT/apps/hippocampus" \
    RetentionPreferencesBehavior "$FIXTURE"

MCI_RETENTION_PICKER_FIXTURE_DIR="$FIXTURE" \
    cargo test -p mci-agent --test retention_preferences_contract --locked \
        picker_outputs_are_worker_compatible -- --ignored --exact

echo "PASS: Preferences retention picker output is consumed by the production worker"
