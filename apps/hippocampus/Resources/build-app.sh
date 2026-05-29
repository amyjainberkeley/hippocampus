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
ONBOARDING_BIN="$REPO_ROOT/apps/onboarding/.build/$PROFILE/onboarding"
NATIVE_HOST_BIN="$REPO_ROOT/target/$PROFILE/hippocampus-native-host"
KNOWN_SAFE="$REPO_ROOT/adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml"
APP_ICON="$REPO_ROOT/assets/branding/AppIcon.icns"
INFO_PLIST="$SCRIPT_DIR/Info.plist"

# SwiftPM emits {Package}_{Target}.bundle next to the executable for any
# target that declares `resources:` in Package.swift, plus an auto-
# generated `resource_bundle_accessor.swift` that exposes `Bundle.module`.
# The Swift 6.3 accessor checks exactly two paths:
#
#   1. Bundle.main.bundleURL.appendingPathComponent(<name>.bundle)
#      For an .app, Bundle.main.bundleURL IS the .app directory itself,
#      so this resolves to <.app>/Hippocampus_HippocampusKit.bundle —
#      the TOP LEVEL of the bundle, NOT Contents/Resources/. codesign
#      rejects any content (directory OR symlink) at the .app root with
#      "unsealed contents present in the bundle root", so we cannot
#      satisfy this lookup on a Developer-ID-signed build.
#   2. A compile-time absolute fallback to .build/<arch>/release/<name>.bundle
#      that exists on the build host but not on end-user machines.
#
# Cycle 8.16 (DMG 8d4dfc22…) crashed on launch on every end-user machine
# because both lookups missed. Cycle 8.15 (3fdbc52a…) and earlier appeared
# to work only because the dev-build fallback path happened to exist on
# the CEO's primary checkout (`/Users/ao/Documents/GitHub/mci/...`). The
# /tmp/dmg-reship-cycle-8.16 worktree was deleted post-build, exposing
# the latent crash.
#
# Cycle 8.17 fix has two halves:
#   (a) ModelDownloadManager + AllowlistTOMLLoader: swap resolver order
#       so Bundle.main (Contents/Resources/) is queried BEFORE Bundle.module.
#       Accessing Bundle.module triggers the SwiftPM accessor's static-let
#       init which fatalError's when both lookups miss — the prior Bundle.main
#       fallback at line 60 was dead code.
#   (b) This script copies the real `models.json` and `known-safe-apps.toml`
#       directly into Contents/Resources/ alongside the SwiftPM resource
#       bundle. Bundle.main.url(forResource:withExtension:) reads from
#       Contents/Resources/ for an .app, so the resolver-order swap above
#       finds the file via the macOS-conventional path and never touches
#       Bundle.module on a production install. The Contents/Resources/
#       `Hippocampus_HippocampusKit.bundle` directory is retained as a
#       defense-in-depth for any future Bundle.module access via the
#       SwiftPM accessor's (now non-load-bearing) fallback path.
HIPPOCAMPUS_KIT_BUNDLE="$PKG_DIR/.build/$PROFILE/Hippocampus_HippocampusKit.bundle"

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
for bin_path in "$HIPPOCAMPUS_BIN" "$HELPER_BIN" "$AGENT_BIN" "$RECALL_UI_BIN" "$ONBOARDING_BIN" "$NATIVE_HOST_BIN"; do
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
cp "$ONBOARDING_BIN" "$MACOS/onboarding"
cp "$NATIVE_HOST_BIN" "$MACOS/hippocampus-native-host"

# Copy resources
cp "$INFO_PLIST" "$CONTENTS/Info.plist"
if [[ -f "$KNOWN_SAFE" ]]; then
    cp "$KNOWN_SAFE" "$RESOURCES/known-safe-apps.toml"
fi

# Copy SwiftPM-generated resource bundle for HippocampusKit into
# Contents/Resources/ (macOS-conventional location; codesign seals it as
# part of the .app's signed-resource set). Bundle.module's primary lookup
# does NOT find it there for an .app wrapper, but Bundle.main can — and
# the resolver-order swap in ModelDownloadManager + AllowlistTOMLLoader
# (cycle 8.17) routes through Bundle.main first. We additionally copy
# `models.json` directly into Contents/Resources/ so
# Bundle.main.url(forResource: "models", withExtension: "json") returns
# a valid URL via the .app's standard resource search path.
KIT_BUNDLE_NAME="$(basename "$HIPPOCAMPUS_KIT_BUNDLE")"
if [[ -d "$HIPPOCAMPUS_KIT_BUNDLE" ]]; then
    ditto "$HIPPOCAMPUS_KIT_BUNDLE" "$RESOURCES/$KIT_BUNDLE_NAME"
    # Hoist models.json to the .app's standard resource root. The Bundle.main-
    # first resolver-order swap in ModelDownloadManager.swift reads from here
    # on production installs, avoiding the SwiftPM Bundle.module accessor's
    # fatalError path entirely. Fatal because the on-launch decode chain
    # would silently fall through to an empty manifest otherwise.
    if [[ -f "$HIPPOCAMPUS_KIT_BUNDLE/models.json" ]]; then
        cp "$HIPPOCAMPUS_KIT_BUNDLE/models.json" "$RESOURCES/models.json"
    else
        echo "ERROR: models.json missing inside $HIPPOCAMPUS_KIT_BUNDLE"
        exit 1
    fi
else
    echo "ERROR: HippocampusKit resource bundle not found at $HIPPOCAMPUS_KIT_BUNDLE"
    echo "Run 'swift build -c $PROFILE' in apps/hippocampus/ first."
    exit 1
fi
# AppIcon.icns — referenced by Info.plist's CFBundleIconFile key.
# Without this copy, Finder + Dock render the generic blank app icon.
if [[ -f "$APP_ICON" ]]; then
    cp "$APP_ICON" "$RESOURCES/AppIcon.icns"
else
    echo "WARNING: AppIcon.icns missing at $APP_ICON — Finder/Dock will show the generic blank icon."
fi

# Status-bar template icons — read at runtime by MenuBarIcon via
# Image("statusbar-icon").renderingMode(.template). macOS tints the
# alpha mask for light/dark menu bars; the source PNGs are black-on-
# transparent (see AppIcon-template.svg). Without these the menu bar
# shows nothing for the running/paused states.
STATUSBAR_PNG_DIR="$REPO_ROOT/assets/branding"
for sb in statusbar-icon.png statusbar-icon@2x.png statusbar-icon@3x.png; do
    if [[ -f "$STATUSBAR_PNG_DIR/$sb" ]]; then
        cp "$STATUSBAR_PNG_DIR/$sb" "$RESOURCES/$sb"
    else
        echo "ERROR: Missing $STATUSBAR_PNG_DIR/$sb — menu-bar icon will not render."
        exit 1
    fi
done

# Embed Sparkle.framework (ships pre-signed; we re-codesign the outer app).
#
# `ditto`, NOT `cp -R` — frameworks contain symlinks
# (`Sparkle.framework/Versions/Current → B`, `Sparkle.framework/Sparkle →
# Versions/Current/Sparkle`) that the framework's code-signature seal
# depends on. `cp -R` on macOS sometimes follows symlinks and duplicates
# trees, leaving the framework structurally valid on the build host but
# broken after the DMG round-trip — Gatekeeper rejects with "developer
# cannot be verified" on the user's Mac even when notary + staple both
# pass locally. Apple explicitly recommends `ditto` for frameworks
# (Apple devforum 128166).
if [[ -n "$SPARKLE_FRAMEWORK" && -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Embedding Sparkle.framework from: $SPARKLE_FRAMEWORK"
    rm -rf "$FRAMEWORKS/Sparkle.framework"
    ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
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

# --- Bundle the Chromium extension as a load-unpacked dir ---
#
# The Chrome / Arc / Brave / Edge extension at extensions/chromium/ is
# not in the Web Store yet (DOGFOOD_V1 #16). For dogfood v1 we ship
# the unpacked dir inside the .app so onboarding's "Install" button
# can reveal it in Finder and the user can drag-drop it onto Chrome's
# chrome://extensions page. When the Web Store / .crx path lands,
# this block becomes redundant.
CHROMIUM_EXT_SRC="$REPO_ROOT/extensions/chromium"
CHROMIUM_EXT_DEST="$RESOURCES/Extensions/Chromium"
if [[ -d "$CHROMIUM_EXT_SRC" ]]; then
    echo "Bundling Chromium extension (unpacked, Load-Unpacked flow)"
    rm -rf "$CHROMIUM_EXT_DEST"
    mkdir -p "$CHROMIUM_EXT_DEST"
    # Copy only the files Chrome actually needs — skip __tests__,
    # node_modules, package.json, hidden files.
    #
    # The native-messaging host manifest JSON is NOT copied here. It is
    # NOT part of the loaded extension; Chromium reads it from a
    # per-browser NativeMessagingHosts/ directory under
    # ~/Library/Application Support/<browser>/. Hippocampus writes it
    # from `BrowserHostInstaller` at app launch with the resolved
    # binary path + deterministic extension ID.
    for entry in manifest.json background.js content.js icons; do
        src="$CHROMIUM_EXT_SRC/$entry"
        if [[ -e "$src" ]]; then
            cp -R "$src" "$CHROMIUM_EXT_DEST/"
        fi
    done
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

    if [[ -f "$MACOS/onboarding" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            --entitlements "$ENTITLEMENTS" \
            "$MACOS/onboarding"
    fi

    if [[ -f "$MACOS/hippocampus-native-host" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            --entitlements "$ENTITLEMENTS" \
            "$MACOS/hippocampus-native-host"
    fi

    # Sign Sparkle.framework inside-out per the Sparkle official
    # sandboxing/code-signing doc:
    #   <https://sparkle-project.org/documentation/sandboxing/>
    #
    # Order matters: XPC services first, then Autoupdate, then
    # Updater.app, then the framework itself. Without this order each
    # codesign step invalidates the seal of the parent it just signed.
    #
    # `Downloader.xpc` is signed with `--preserve-metadata=entitlements`:
    # it ships with a no-network-client entitlement assertion that the
    # notary expects to find unchanged. Stripping it changes the
    # entitlement-set the notary ticket claims about that XPC service
    # and is a documented cause of Gatekeeper failing at first launch
    # even when stapler validate passes locally (Sparkle GitHub issues
    # 1550, 1641, 2069; Peter Steinberger, "Sparkle and Tears", 2025).
    SPARKLE="$FRAMEWORKS/Sparkle.framework"
    if [[ -d "$SPARKLE" ]]; then
        for XPC in Installer Downloader; do
            XPC_BUNDLE="$SPARKLE/Versions/B/XPCServices/${XPC}.xpc"
            if [[ -d "$XPC_BUNDLE" ]]; then
                if [[ "$XPC" == "Downloader" ]]; then
                    codesign --force --options=runtime --timestamp \
                        --preserve-metadata=entitlements \
                        --sign "$DEVELOPER_ID" \
                        "$XPC_BUNDLE"
                else
                    codesign --force --options=runtime --timestamp \
                        --sign "$DEVELOPER_ID" \
                        "$XPC_BUNDLE"
                fi
            fi
        done

        AUTOUPDATE="$SPARKLE/Versions/B/Autoupdate"
        if [[ -f "$AUTOUPDATE" ]]; then
            codesign --force --options=runtime --timestamp \
                --sign "$DEVELOPER_ID" \
                "$AUTOUPDATE"
        fi

        UPDATER_APP="$SPARKLE/Versions/B/Updater.app"
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
    [[ -f "$MACOS/onboarding" ]] && codesign --force --sign - "$MACOS/onboarding"
    [[ -f "$MACOS/hippocampus-native-host" ]] && codesign --force --sign - "$MACOS/hippocampus-native-host"
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

# Launch-verify gate — FATAL.
# Catches the cycle 8.16 class of regression where the .app passes
# syspolicy_check + Gatekeeper + notarization but crashes on launch
# because a structural-init invariant (resource bundle path, rpath,
# missing dyld dep) is wrong. Run after all codesigning so we test the
# actual on-disk artifact that will be packaged.
LAUNCH_VERIFY="$REPO_ROOT/scripts/verify-app-launches.sh"
if [[ -x "$LAUNCH_VERIFY" ]]; then
    echo ""
    echo "=== Launch-verify gate ==="
    "$LAUNCH_VERIFY" "$APP"
else
    echo "WARNING: scripts/verify-app-launches.sh not found — skipping launch gate."
fi

echo ""
echo "=== Done ==="
echo "  $APP"
echo ""
echo "To run:  open $APP"
echo "To test: $MACOS/Hippocampus"
