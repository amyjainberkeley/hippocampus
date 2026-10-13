#!/usr/bin/env bash
# test-without-foundation-models.sh — build and test hippocampus-mind as on a
# Mac without Apple's Foundation Models (macOS 14 or 15, or an SDK without the
# framework). The Apple engine is compiled out, every test must still pass
# with only the model-server engine, and the binary must not link the
# framework at all, so the run proves the Apple engine was really left out.
#
# Usage: apps/mind/scripts/test-without-foundation-models.sh [swift test arguments]
# Shares .build with a normal run, so the next normal run rebuilds.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
without=(-Xswiftc -DMIND_NO_FOUNDATION_MODELS)

swift test "${without[@]}" "$@"

binary="$(swift build "${without[@]}" --show-bin-path)/hippocampus-mind"
if [ ! -x "$binary" ]; then
    echo "FAIL: $binary was not built" >&2
    exit 1
fi
if otool -L "$binary" | grep -q FoundationModels; then
    echo "FAIL: hippocampus-mind links FoundationModels with the Apple engine compiled out" >&2
    exit 1
fi
echo "PASS: hippocampus-mind builds and its tests pass without Foundation Models"
