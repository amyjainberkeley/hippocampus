#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$(mktemp -d -t hippocampus-retention-contract)"
trap 'rm -rf "$FIXTURE"' EXIT

run_gate() {
    local gate="$1"
    shift
    local started="$SECONDS" status
    printf '[retention-contract] START %s\n' "$gate" >&2
    if "$@"; then
        printf '[retention-contract] PASS %s exit=0 elapsed=%ss\n' \
            "$gate" "$((SECONDS - started))" >&2
    else
        status=$?
        printf '[retention-contract] FAIL %s exit=%s elapsed=%ss\n' \
            "$gate" "$status" "$((SECONDS - started))" >&2
        return "$status"
    fi
}

run_fixture() {
    local package="$1" product="$2" output="$3" bin_path status
    local swift_package="$REPO_ROOT/scripts/swift-package.sh"

    # SwiftPM's `run` execs the fixture in its own PID. Separate the phases so
    # a killed fixture cannot be mistaken for a killed compiler in hosted logs.
    run_gate "build:$product" "$swift_package" build --jobs 2 \
        --package-path "$package" --product "$product"
    if bin_path="$(run_gate "locate:$product" "$swift_package" build --jobs 2 \
        --package-path "$package" --show-bin-path)"; then
        run_gate "run:$product" "$bin_path/$product" "$output"
    else
        status=$?
        printf '%s\n' "$bin_path" >&2
        return "$status"
    fi
}

run_fixture "$REPO_ROOT/apps/onboarding" RetentionPersistenceBehavior "$FIXTURE/onboarding"
run_fixture "$REPO_ROOT/apps/hippocampus" RetentionPreferencesBehavior "$FIXTURE"

MCI_RETENTION_PICKER_FIXTURE_DIR="$FIXTURE" \
    run_gate worker cargo test --jobs 2 -p mci-agent --test retention_preferences_contract --locked \
        picker_outputs_are_worker_compatible -- --ignored --exact

echo "PASS: onboarding and Preferences retention output is consumed by the production worker"
