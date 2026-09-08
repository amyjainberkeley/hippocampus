#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-screen-proof-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

sources=(
    "$SCRIPT_DIR/ScreenProofExposure.swift"
    "$SCRIPT_DIR/ScreenProofReceipt.swift"
    "$SCRIPT_DIR/ScreenProofWindow.swift"
)
xcrun swiftc -swift-version 6 -warnings-as-errors -typecheck "${sources[@]}"
xcrun swiftc -swift-version 6 -warnings-as-errors \
    "$SCRIPT_DIR/ScreenProofExposure.swift" "$SCRIPT_DIR/ScreenProofExposureTests.swift" \
    -o "$test_dir/exposure-tests"
"$test_dir/exposure-tests"

for suite in TextView Receipt; do
    xcrun swiftc -swift-version 6 -warnings-as-errors -D SCREEN_PROOF_TESTING \
        "${sources[@]}" "$SCRIPT_DIR/ScreenProof${suite}Tests.swift" \
        -o "$test_dir/$suite-tests"
    "$test_dir/$suite-tests"
done
