#!/usr/bin/env bash
set -euo pipefail

# build-app.sh — Assemble Hippocampus.app bundle from pre-built binaries.
#
# This script bridges `swift build` (which only builds the Hippocampus
# executable) with a working .app bundle (binaries copied in, Info.plist,
# ad-hoc codesigned).
#
# Prerequisites:
#   1. swift build -c release   (in apps/hippocampus/)
#   2. swift build -c release   (in adapters/macos/MCICaptureHelper/)
#   3. cargo build --workspace --release
#
# Usage:
#   ./build-app.sh [--help] [--debug] [--dist DIR]
#
# Dev iteration loop:
#   1. Make changes to Sources/
#   2. swift build                        (debug build, fast)
#   3. ./Resources/build-app.sh --debug   (assembles from .build/debug/)
#   4. open dist/Hippocampus.app          (test from Spotlight / Finder)
#   5. To test release: swift build -c release && ./Resources/build-app.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd)"

PROFILE="release"
DIST_DIR="$PKG_DIR/dist"

usage() {
    echo "Usage: build-app.sh [OPTIONS]"
    echo ""
    echo "Assemble Hippocampus.app from pre-built binaries."
    echo ""
    echo "Options:"
    echo "  --debug     Use debug builds instead of release"
    echo "  --dist DIR  Output directory (default: apps/hippocampus/dist/)"
    echo "  --help      Show this help"
    echo ""
    echo "Prerequisites:"
    echo "  swift build -c release   (in apps/hippocampus/)"
    echo "  swift build -c release   (in adapters/macos/MCICaptureHelper/)"
    echo "  cargo build --workspace --release"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) PROFILE="debug"; shift ;;
        --dist) DIST_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

APP="$DIST_DIR/Hippocampus.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Locate binaries
HIPPOCAMPUS_BIN="$PKG_DIR/.build/$PROFILE/Hippocampus"
HELPER_BIN="$REPO_ROOT/adapters/macos/MCICaptureHelper/.build/$PROFILE/mci-capture-helper"
AGENT_BIN="$REPO_ROOT/target/$PROFILE/mci-agent"
KNOWN_SAFE="$REPO_ROOT/adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml"
INFO_PLIST="$SCRIPT_DIR/Info.plist"

echo "=== Hippocampus.app assembly ==="
echo "Profile:   $PROFILE"
echo "Output:    $APP"
echo ""

# Verify binaries exist
for bin_path in "$HIPPOCAMPUS_BIN" "$HELPER_BIN" "$AGENT_BIN"; do
    if [[ ! -f "$bin_path" ]]; then
        echo "ERROR: Missing binary: $bin_path"
        echo "Run the prerequisite builds first. See --help."
        exit 1
    fi
done

# Clean and create structure
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

# Copy binaries
cp "$HIPPOCAMPUS_BIN" "$MACOS/Hippocampus"
cp "$HELPER_BIN" "$MACOS/MCICaptureHelper"
cp "$AGENT_BIN" "$MACOS/mci-agent"

# Copy resources
cp "$INFO_PLIST" "$CONTENTS/Info.plist"
if [[ -f "$KNOWN_SAFE" ]]; then
    cp "$KNOWN_SAFE" "$RESOURCES/known-safe-apps.toml"
fi

# Placeholder icon — real icon is Wave 2.B
# (AppIcon.icns would go here)

# Ad-hoc codesign each binary + the top-level app
echo "Codesigning..."
codesign --force --sign - "$MACOS/MCICaptureHelper"
codesign --force --sign - "$MACOS/mci-agent"
codesign --force --sign - "$MACOS/Hippocampus"
codesign --force --sign - "$APP"

echo ""
echo "=== Done ==="
echo "  $APP"
echo ""
echo "To run:  open $APP"
echo "To test: $MACOS/Hippocampus"
