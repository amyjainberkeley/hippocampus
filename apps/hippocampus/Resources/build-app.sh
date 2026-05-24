#!/usr/bin/env bash
set -euo pipefail

# build-app.sh — Assemble Hippocampus.app bundle from pre-built binaries.
#
# This script bridges `swift build` (which only builds the Hippocampus
# executable) with a working .app bundle (binaries copied in, Info.plist,
# codesigned). Auto-detects Developer ID for stable CDHash; falls back
# to ad-hoc when no Developer ID cert is present.
#
# Prerequisites:
#   1. swift build -c release   (in apps/hippocampus/)
#   2. swift build -c release   (in adapters/macos/MCICaptureHelper/)
#   3. swift build -c release   (in apps/recall-ui/)
#   4. cargo build --workspace --release
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
RECALL_UI_BIN="$REPO_ROOT/apps/recall-ui/.build/$PROFILE/recall-ui"
KNOWN_SAFE="$REPO_ROOT/adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml"
INFO_PLIST="$SCRIPT_DIR/Info.plist"

FRAMEWORKS="$CONTENTS/Frameworks"

# Locate Sparkle.framework from SwiftPM build artifacts
SPARKLE_FRAMEWORK=""
for candidate in \
    "$PKG_DIR/.build/$PROFILE/Sparkle.framework" \
    "$PKG_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.framework" \
    "$PKG_DIR/.build/artifacts/Sparkle/Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then
        SPARKLE_FRAMEWORK="$candidate"
        break
    fi
done

# --- Detect Developer ID signing identity ---

if [[ -z "${DEVELOPER_ID:-}" ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning | \
        grep "Developer ID Application" | \
        head -1 | \
        sed 's/.*"\(.*\)"/\1/' || true)
fi

if [[ -n "$DEVELOPER_ID" ]]; then
    SIGNING_MODE="developer-id"
else
    SIGNING_MODE="ad-hoc"
fi

echo "=== Hippocampus.app assembly ==="
echo "Profile:   $PROFILE"
echo "Signing:   $SIGNING_MODE"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    echo "Identity:  $DEVELOPER_ID"
fi
echo "Output:    $APP"
echo ""

# Verify binaries exist
for bin_path in "$HIPPOCAMPUS_BIN" "$HELPER_BIN" "$AGENT_BIN" "$RECALL_UI_BIN"; do
    if [[ ! -f "$bin_path" ]]; then
        echo "ERROR: Missing binary: $bin_path"
        echo "Run the prerequisite builds first. See --help."
        exit 1
    fi
done

# Clean and create structure
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

# Copy binaries
cp "$HIPPOCAMPUS_BIN" "$MACOS/Hippocampus"
cp "$HELPER_BIN" "$MACOS/MCICaptureHelper"
cp "$AGENT_BIN" "$MACOS/mci-agent"
cp "$RECALL_UI_BIN" "$MACOS/recall-ui"

# Copy resources
cp "$INFO_PLIST" "$CONTENTS/Info.plist"
if [[ -f "$KNOWN_SAFE" ]]; then
    cp "$KNOWN_SAFE" "$RESOURCES/known-safe-apps.toml"
fi

# Embed Sparkle.framework (ships pre-signed; we re-codesign the outer app)
if [[ -n "$SPARKLE_FRAMEWORK" && -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Embedding Sparkle.framework from: $SPARKLE_FRAMEWORK"
    cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/"

    # Sparkle 2.x XPC services need to be inside the framework
    # The framework ships pre-signed — we only codesign the outer bundle.
else
    echo "WARNING: Sparkle.framework not found. Auto-update will not work."
    echo "  Build with 'swift build -c $PROFILE' first to resolve the SPM dependency."
fi

# Add @executable_path/../Frameworks to rpath so dyld finds Sparkle.framework.
# SwiftPM does not add this automatically; must be set before codesigning.
if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
    if ! otool -l "$MACOS/Hippocampus" | grep -A 2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
        echo "Adding @executable_path/../Frameworks rpath to Hippocampus binary..."
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Hippocampus"
    fi
fi

# Embed ArcticEmbedS Core ML model (per ADR-0011 + ADR-0028 §4).
# The .mlpackage is produced offline by scripts/convert_embedder.py
# and committed locally (gitignored — too big to checkin).
EMBEDDER_PACKAGE="$REPO_ROOT/models/ArcticEmbedS_INT8.mlpackage"
EMBEDDER_COMPILED="$REPO_ROOT/models/ArcticEmbedS_INT8.mlmodelc"
EMBEDDER_DEST_DIR="$RESOURCES/Models"

if [[ -d "$EMBEDDER_COMPILED" ]]; then
    echo "Bundling pre-compiled ArcticEmbedS_INT8.mlmodelc"
    mkdir -p "$EMBEDDER_DEST_DIR"
    cp -R "$EMBEDDER_COMPILED" "$EMBEDDER_DEST_DIR/"
elif [[ -d "$EMBEDDER_PACKAGE" ]]; then
    echo "Compiling ArcticEmbedS_INT8.mlpackage → .mlmodelc"
    mkdir -p "$EMBEDDER_DEST_DIR"
    xcrun coremlcompiler compile "$EMBEDDER_PACKAGE" "$EMBEDDER_DEST_DIR"
else
    echo "WARNING: ArcticEmbedS .mlpackage not found at $EMBEDDER_PACKAGE."
    echo "  Semantic search will use zero-vector stub fallback."
    echo "  To produce: pip install -r scripts/requirements-ml.txt && \\"
    echo "             python scripts/convert_embedder.py --output models/ArcticEmbedS_INT8.mlpackage"
fi

# --- Safari Web Extension .appex ---

SAFARI_EXT_DIR="$REPO_ROOT/extensions/safari"
APPEX_SRC="$SAFARI_EXT_DIR/appex"
APPEX_HANDLER="$APPEX_SRC/SafariWebExtensionHandler.swift"
APPEX_PLIST="$APPEX_SRC/Info.plist"
APPEX_ENTITLEMENTS="$APPEX_SRC/HippocampusSafariExtension.entitlements"

PLUGINS="$CONTENTS/PlugIns"
APPEX_BUNDLE="$PLUGINS/HippocampusSafariExtension.appex"
APPEX_CONTENTS="$APPEX_BUNDLE/Contents"
APPEX_MACOS="$APPEX_CONTENTS/MacOS"
APPEX_RESOURCES="$APPEX_CONTENTS/Resources"

if [[ -f "$APPEX_HANDLER" ]]; then
    echo ""
    echo "=== Safari Web Extension (.appex) ==="
    mkdir -p "$APPEX_MACOS" "$APPEX_RESOURCES"

    echo "Compiling SafariWebExtensionHandler..."
    swiftc \
        -sdk "$(xcrun --show-sdk-path)" \
        -target "$(uname -m)-apple-macos14.0" \
        -framework Foundation \
        -framework SafariServices \
        -module-name HippocampusSafariExtension \
        -emit-executable \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -o "$APPEX_MACOS/HippocampusSafariExtension" \
        "$APPEX_HANDLER"

    cp "$APPEX_PLIST" "$APPEX_CONTENTS/Info.plist"

    for f in manifest.json background.js content.js; do
        if [[ -f "$SAFARI_EXT_DIR/$f" ]]; then
            cp "$SAFARI_EXT_DIR/$f" "$APPEX_RESOURCES/$f"
        fi
    done

    # Toolbar icon set (referenced by manifest action.default_icon).
    # Regenerate with scripts/generate-extension-toolbar-icons.py.
    if [[ -d "$SAFARI_EXT_DIR/icons" ]]; then
        mkdir -p "$APPEX_RESOURCES/icons"
        cp "$SAFARI_EXT_DIR/icons"/*.png "$APPEX_RESOURCES/icons/"
    fi

    echo "  .appex assembled at $APPEX_BUNDLE"
else
    echo ""
    echo "WARNING: Safari extension handler not found at $APPEX_HANDLER"
    echo "  Skipping .appex build. Safari extension will not be available."
fi

ENTITLEMENTS="$SCRIPT_DIR/Hippocampus.entitlements"

echo ""
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    echo "Codesigning with Developer ID (hardened runtime)..."

    # Inside-out order: sign innermost first.
    if [[ -d "$APPEX_BUNDLE" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            --entitlements "$APPEX_ENTITLEMENTS" \
            "$APPEX_BUNDLE"
    fi

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$MACOS/MCICaptureHelper"

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$MACOS/mci-agent"

    if [[ -f "$MACOS/recall-ui" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            --entitlements "$ENTITLEMENTS" \
            "$MACOS/recall-ui"
    fi

    # Sign Sparkle.framework inside-out (PR #156 pattern).
    # Sparkle 2.x ships ad-hoc-signed inner binaries; codesign on the
    # outer framework does NOT re-sign these — each must be signed
    # individually for notarization.
    SPARKLE="$FRAMEWORKS/Sparkle.framework"
    if [[ -d "$SPARKLE" ]]; then
        for XPC in Downloader Installer; do
            XPC_BUNDLE="$SPARKLE/Versions/B/XPCServices/${XPC}.xpc"
            XPC_BIN="$XPC_BUNDLE/Contents/MacOS/${XPC}"
            if [[ -f "$XPC_BIN" ]]; then
                codesign --force --options=runtime --timestamp \
                    --sign "$DEVELOPER_ID" \
                    "$XPC_BIN"
            fi
            if [[ -d "$XPC_BUNDLE" ]]; then
                codesign --force --options=runtime --timestamp \
                    --sign "$DEVELOPER_ID" \
                    "$XPC_BUNDLE"
            fi
        done

        AUTOUPDATE="$SPARKLE/Versions/B/Autoupdate"
        if [[ -f "$AUTOUPDATE" ]]; then
            codesign --force --options=runtime --timestamp \
                --sign "$DEVELOPER_ID" \
                "$AUTOUPDATE"
        fi

        UPDATER_APP="$SPARKLE/Versions/B/Updater.app"
        UPDATER_BIN="$UPDATER_APP/Contents/MacOS/Updater"
        if [[ -f "$UPDATER_BIN" ]]; then
            codesign --force --options=runtime --timestamp \
                --sign "$DEVELOPER_ID" \
                "$UPDATER_BIN"
        fi
        if [[ -d "$UPDATER_APP" ]]; then
            codesign --force --options=runtime --timestamp \
                --sign "$DEVELOPER_ID" \
                "$UPDATER_APP"
        fi

        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            "$SPARKLE"
    fi

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$MACOS/Hippocampus"

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP"

    echo "Verifying signature..."
    codesign --verify --deep --strict "$APP"
    echo "  Signature valid."
else
    echo "Codesigning (ad-hoc)..."
    if [[ -d "$APPEX_BUNDLE" ]]; then
        codesign --force --sign - \
            --entitlements "$APPEX_ENTITLEMENTS" \
            "$APPEX_BUNDLE"
    fi
    codesign --force --sign - "$MACOS/MCICaptureHelper"
    codesign --force --sign - "$MACOS/mci-agent"
    [[ -f "$MACOS/recall-ui" ]] && codesign --force --sign - "$MACOS/recall-ui"
    codesign --force --sign - "$MACOS/Hippocampus"
    codesign --force --deep --sign - "$APP"
fi

# Verify rpath was added correctly
echo "Verifying rpath..."
if otool -l "$MACOS/Hippocampus" | grep -A 2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
    echo "  rpath OK: @executable_path/../Frameworks present"
else
    echo "  ERROR: rpath missing — app will fail to launch"
    exit 1
fi

# Validate model bundling (non-fatal — prints warnings only)
VERIFY_SCRIPT="$REPO_ROOT/scripts/verify-models.sh"
if [[ -x "$VERIFY_SCRIPT" ]]; then
    echo ""
    echo "=== Model validation ==="
    "$VERIFY_SCRIPT" --app "$APP" || true
fi

echo ""
echo "=== Done ==="
echo "  $APP"
echo ""
echo "To run:  open $APP"
echo "To test: $MACOS/Hippocampus"
