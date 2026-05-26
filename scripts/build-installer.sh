#!/usr/bin/env bash
set -euo pipefail

# build-installer.sh — Produce Hippocampus-<version>.dmg from a built .app bundle.
#
# Usage:
#   ./scripts/build-installer.sh [OPTIONS]
#
# Options:
#   --skip-build    Skip calling build-app.sh (assume .app already assembled)
#   --debug         Use debug profile for build-app.sh
#   --dist DIR      Output directory (default: dist/)
#   --help          Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_APP="$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
INSTALLER_ASSETS="$REPO_ROOT/assets/installer"

SKIP_BUILD=0
BUILD_PROFILE="release"
DIST_DIR="$REPO_ROOT/dist"

usage() {
    cat <<EOF
Usage: build-installer.sh [OPTIONS]

Produce a distributable Hippocampus DMG installer.

Options:
  --skip-build    Skip build-app.sh (assume .app is already assembled)
  --debug         Pass --debug to build-app.sh
  --dist DIR      Output directory (default: dist/)
  --help          Show this help

Prerequisites:
  - macOS with hdiutil (ships with Xcode CLT)
  - Pre-built binaries (swift build + cargo build) unless --skip-build
  - codesign (Xcode CLT)

Output:
  dist/Hippocampus-<version>.dmg
  dist/Hippocampus-<version>.dmg.sha256
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --debug) BUILD_PROFILE="debug"; shift ;;
        --dist) DIST_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1"; usage; exit 1 ;;
    esac
done

# --- Pre-flight checks ---

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: Required command not found: $1"
        echo "Install Xcode Command Line Tools: xcode-select --install"
        exit 1
    fi
}

require_cmd hdiutil
require_cmd codesign

# --- Detect Developer ID signing identity ---

if [[ -z "${DEVELOPER_ID:-}" ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning | \
        grep "Developer ID Application" | \
        head -1 | \
        sed 's/.*"\(.*\)"/\1/' || true)
fi

if [[ -n "$DEVELOPER_ID" ]]; then
    echo "Developer ID: $DEVELOPER_ID"
    SIGNING_MODE="developer-id"
else
    echo "No Developer ID found — falling back to ad-hoc signing"
    SIGNING_MODE="ad-hoc"
fi

# --- Detect notarytool credentials ---

NOTARIZE=0
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    if xcrun notarytool history --keychain-profile "notarytool-profile" \
        &>/dev/null; then
        NOTARIZE=1
        echo "Notarization: enabled (keychain profile found)"
    elif [[ -n "${NOTARYTOOL_APPLE_ID:-}" && -n "${NOTARYTOOL_TEAM_ID:-}" && \
            -n "${NOTARYTOOL_PASSWORD:-}" ]]; then
        NOTARIZE=1
        echo "Notarization: enabled (env credentials)"
    else
        echo "WARNING: Notarization skipped — no keychain profile 'notarytool-profile'"
        echo "         and no NOTARYTOOL_APPLE_ID/TEAM_ID/PASSWORD env vars found."
        echo "  Setup: xcrun notarytool store-credentials notarytool-profile"
    fi
fi

# --- Extract version from Info.plist ---

INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "ERROR: Info.plist not found at $INFO_PLIST"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "")
if [[ -z "$VERSION" ]]; then
    echo "ERROR: Could not read CFBundleShortVersionString from Info.plist"
    exit 1
fi

echo "=== Hippocampus DMG Installer ==="
echo "Version:   $VERSION"
echo "Profile:   $BUILD_PROFILE"
echo "Output:    $DIST_DIR/"
echo ""

# --- Step 1: Build the .app bundle ---

APP_DIST="$REPO_ROOT/apps/hippocampus/dist"
APP_PATH="$APP_DIST/Hippocampus.app"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "--- Building Hippocampus.app ---"
    BUILD_ARGS=()
    if [[ "$BUILD_PROFILE" == "debug" ]]; then
        BUILD_ARGS+=(--debug)
    fi
    # ${VAR[@]+"${VAR[@]}"} expands safely when array is empty under `set -u`.
    "$BUILD_APP" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
    echo ""
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Hippocampus.app not found at $APP_PATH"
    echo "Run build-app.sh first, or use --skip-build only if the .app is already assembled."
    exit 1
fi

# --- Step 2: Codesign (Developer ID or ad-hoc) ---

ENTITLEMENTS="$REPO_ROOT/apps/hippocampus/Resources/Hippocampus.entitlements"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    echo "--- Codesigning with Developer ID (hardened runtime) ---"

    # Sign embedded binaries first (inside-out signing order)

    # Sign Safari extension .appex (innermost)
    APPEX_PATH="$APP_PATH/Contents/PlugIns/HippocampusSafariExtension.appex"
    APPEX_ENTITLEMENTS="$REPO_ROOT/extensions/safari/appex/HippocampusSafariExtension.entitlements"
    if [[ -d "$APPEX_PATH" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            --entitlements "$APPEX_ENTITLEMENTS" \
            "$APPEX_PATH"
    fi

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH/Contents/MacOS/MCICaptureHelper"

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH/Contents/MacOS/mci-agent"

    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH/Contents/MacOS/recall-ui"

    if [[ -f "$APP_PATH/Contents/MacOS/onboarding" ]]; then
        codesign --force --options=runtime --timestamp \
            --sign "$DEVELOPER_ID" \
            --entitlements "$ENTITLEMENTS" \
            "$APP_PATH/Contents/MacOS/onboarding"
    fi

    # Sign Sparkle.framework inside-out per the Sparkle official
    # sandboxing/code-signing doc:
    #   <https://sparkle-project.org/documentation/sandboxing/>
    #
    # Sparkle 2.x ships ad-hoc-signed; codesign on the outer framework
    # does NOT re-sign inner bundles. Each must be signed individually
    # for notarization. Order matters — XPC services first, then
    # Autoupdate, then Updater.app, then the framework itself. Without
    # this order each codesign step invalidates the parent it just
    # signed.
    #
    # `Downloader.xpc` is signed with `--preserve-metadata=entitlements`:
    # it ships with a no-network-client entitlement assertion that the
    # notary expects to find unchanged. Stripping it changes the
    # entitlement-set the notary ticket claims about that XPC service
    # and is a documented cause of Gatekeeper failing at first launch
    # even when stapler validate passes locally (Sparkle GitHub issues
    # 1550, 1641, 2069; Peter Steinberger, "Sparkle and Tears", 2025).
    SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
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

    # Sign main executable
    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH/Contents/MacOS/Hippocampus"

    # Sign top-level app bundle (covers everything)
    codesign --force --options=runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH"

    echo "Verifying signature..."
    codesign --verify --deep --strict "$APP_PATH"
    echo "  Signature valid."
else
    echo "--- Ad-hoc codesigning (dev iteration) ---"
    codesign --force --deep --sign - "$APP_PATH"
fi

# --- Step 2.5: Notarize + staple the .app ITSELF (not just the DMG) ---
#
# Critical for offline-first-launch (CEO friend, 2026-05-24):
# stapling only the outer DMG means the .app inside has no embedded
# notarization ticket. When a user without internet at first launch
# (captive portal, plane, the friend's exact case) double-clicks the
# .app, Gatekeeper has no staple to verify against and the online
# notary check fails — they see "Hippocampus cannot be opened
# because the developer cannot be verified" with no "Open Anyway"
# affordance.
#
# Fix: stamp the ticket into the .app bundle itself so Gatekeeper
# can verify entirely offline. We keep the existing DMG-level
# notarize+staple too (belt + suspenders), but this is the load-
# bearing step for the end-user-experience.

if [[ "$NOTARIZE" -eq 1 ]]; then
    echo ""
    echo "--- Notarizing + stapling Hippocampus.app (offline-first-launch fix) ---"

    APP_ZIP="$DIST_DIR/Hippocampus-${VERSION}-app.zip"
    mkdir -p "$DIST_DIR"
    rm -f "$APP_ZIP"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

    APP_NOTARY_ARGS=()
    if xcrun notarytool history --keychain-profile "notarytool-profile" \
        &>/dev/null; then
        APP_NOTARY_ARGS+=(--keychain-profile "notarytool-profile")
    else
        APP_NOTARY_ARGS+=(--apple-id "$NOTARYTOOL_APPLE_ID")
        APP_NOTARY_ARGS+=(--team-id "$NOTARYTOOL_TEAM_ID")
        APP_NOTARY_ARGS+=(--password "$NOTARYTOOL_PASSWORD")
    fi

    if xcrun notarytool submit "$APP_ZIP" "${APP_NOTARY_ARGS[@]}" --wait; then
        xcrun stapler staple "$APP_PATH"
        echo "  .app notarized + stapled (ticket embedded in bundle)"
        # Verify the staple was attached + the .app is Gatekeeper-clean.
        if ! xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
            echo "ERROR: stapler validate failed on $APP_PATH after staple"
            exit 1
        fi
        # `syspolicy_check distribution` is the closest CLI mirror of
        # what Gatekeeper actually runs at first launch. It catches
        # entitlement / signing / framework-structure issues that
        # `stapler validate` and `spctl --assess` both miss
        # (Apple devforum 773271). Skip if the tool isn't installed
        # (older macOS / Xcode CLT) — we still ship in that case but
        # log the gap loudly.
        if command -v syspolicy_check >/dev/null 2>&1; then
            if ! syspolicy_check distribution "$APP_PATH"; then
                echo "ERROR: syspolicy_check distribution failed on $APP_PATH"
                echo "  Gatekeeper WILL reject this build at first launch."
                exit 1
            fi
            echo "  syspolicy_check distribution passed"
        else
            echo "WARNING: syspolicy_check not found — Gatekeeper first-launch"
            echo "  predictor unavailable. Install Xcode 16 CLT to enable."
        fi
    else
        echo ""
        echo "ERROR: .app notarization failed. App is signed but NOT notarized."
        echo "  Check: xcrun notarytool log <submission-id> ${APP_NOTARY_ARGS[*]}"
        exit 1
    fi

    rm -f "$APP_ZIP"
fi

# --- Step 3: Prepare DMG staging directory ---

DMG_NAME="Hippocampus-${VERSION}"
DMG_STAGING=$(mktemp -d -t hippocampus-dmg)
trap 'rm -rf "$DMG_STAGING"' EXIT

echo "--- Staging DMG contents ---"

cp -R "$APP_PATH" "$DMG_STAGING/Hippocampus.app"
ln -s /Applications "$DMG_STAGING/Applications"

# Copy volume icon
VOLUME_ICON="$INSTALLER_ASSETS/volume-icon.icns"
if [[ -f "$VOLUME_ICON" ]]; then
    cp "$VOLUME_ICON" "$DMG_STAGING/.VolumeIcon.icns"
fi

# Regenerate background image if missing
BACKGROUND_PNG="$INSTALLER_ASSETS/background.png"
if [[ ! -f "$BACKGROUND_PNG" ]]; then
    echo "Generating DMG background image..."
    GENERATE_BG="$INSTALLER_ASSETS/generate-background.py"
    if [[ -f "$GENERATE_BG" ]]; then
        python3 "$GENERATE_BG" "$BACKGROUND_PNG"
    else
        echo "WARNING: No background generator found, DMG will use default Finder background"
    fi
fi

# Regenerate EULA / SLA resources if missing
EULA_RTF="$INSTALLER_ASSETS/EULA.rtf"
SLA_R="$INSTALLER_ASSETS/sla.r"
GENERATE_EULA="$INSTALLER_ASSETS/generate-eula.py"
if [[ ! -f "$EULA_RTF" || ! -f "$SLA_R" ]] && [[ -f "$GENERATE_EULA" ]]; then
    echo "Generating EULA.rtf + sla.r from terms-of-service.md..."
    python3 "$GENERATE_EULA"
fi

# Create .background directory (hidden in DMG)
if [[ -f "$BACKGROUND_PNG" ]]; then
    mkdir -p "$DMG_STAGING/.background"
    cp "$BACKGROUND_PNG" "$DMG_STAGING/.background/background.png"
fi

echo "  Hippocampus.app -> staging/"
echo "  Applications symlink -> staging/"

# --- Step 4: Create temporary read-write DMG ---

echo ""
echo "--- Creating DMG ---"

mkdir -p "$DIST_DIR"

TEMP_DMG="$DIST_DIR/${DMG_NAME}-temp.dmg"
FINAL_DMG="$DIST_DIR/${DMG_NAME}.dmg"

# Remove stale outputs
rm -f "$TEMP_DMG" "$FINAL_DMG" "${FINAL_DMG}.sha256"

# Create read-write DMG (oversized, will be compacted)
hdiutil create \
    -srcfolder "$DMG_STAGING" \
    -volname "Hippocampus" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size 200m \
    "$TEMP_DMG"

# --- Step 5: Apply window layout via AppleScript ---

APPLESCRIPT="$INSTALLER_ASSETS/dmg-layout.applescript"
if [[ -f "$APPLESCRIPT" ]] && [[ -f "$BACKGROUND_PNG" ]]; then
    echo ""
    echo "--- Applying DMG window layout ---"

    MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
    MOUNT_DIR=$(echo "$MOUNT_DIR" | xargs)

    if [[ -d "$MOUNT_DIR" ]]; then
        osascript "$APPLESCRIPT" "$MOUNT_DIR" || echo "WARNING: AppleScript layout failed (non-fatal — Finder layout is cosmetic)"

        # Set volume icon flag
        if [[ -f "$MOUNT_DIR/.VolumeIcon.icns" ]]; then
            SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
            SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
        fi

        sync
        hdiutil detach "$MOUNT_DIR" -quiet
    else
        echo "WARNING: Could not mount temp DMG for layout (non-fatal)"
    fi
else
    echo "Skipping DMG window layout (no AppleScript or background image)"
fi

# --- Step 6: Convert to compressed read-only DMG ---

echo ""
echo "--- Compressing final DMG ---"

hdiutil convert \
    "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$FINAL_DMG"

rm -f "$TEMP_DMG"

# --- Step 6.5: Attach Software License Agreement ---

SLA_R="$INSTALLER_ASSETS/sla.r"
if [[ -f "$SLA_R" ]]; then
    if command -v Rez &>/dev/null; then
        echo ""
        echo "--- Attaching Software License Agreement ---"
        if hdiutil unflatten "$FINAL_DMG" 2>/dev/null; then
            if Rez -append "$SLA_R" -o "$FINAL_DMG" 2>/dev/null; then
                hdiutil flatten "$FINAL_DMG" 2>/dev/null
                echo "  SLA attached (license shown on DMG mount)."
            else
                echo "WARNING: Rez failed — SLA not attached (non-fatal)."
                echo "         EULA available at hippocampus.ai/legal"
                hdiutil flatten "$FINAL_DMG" 2>/dev/null || true
            fi
        else
            echo "WARNING: hdiutil unflatten failed — SLA not attached (non-fatal)."
        fi
    else
        echo ""
        echo "NOTE: Rez not found — skipping SLA attachment."
        echo "      Install Xcode Command Line Tools for SLA support."
    fi
fi

# --- Step 7: Notarize + staple (Developer ID only) ---

if [[ "$NOTARIZE" -eq 1 ]]; then
    echo ""
    echo "--- Submitting DMG for notarization ---"

    NOTARY_ARGS=()
    if xcrun notarytool history --keychain-profile "notarytool-profile" \
        &>/dev/null; then
        NOTARY_ARGS+=(--keychain-profile "notarytool-profile")
    else
        NOTARY_ARGS+=(--apple-id "$NOTARYTOOL_APPLE_ID")
        NOTARY_ARGS+=(--team-id "$NOTARYTOOL_TEAM_ID")
        NOTARY_ARGS+=(--password "$NOTARYTOOL_PASSWORD")
    fi

    if xcrun notarytool submit "$FINAL_DMG" "${NOTARY_ARGS[@]}" --wait; then
        echo ""
        echo "--- Stapling notarization ticket ---"
        xcrun stapler staple "$FINAL_DMG"
        echo "  DMG notarized and stapled."
    else
        echo ""
        echo "ERROR: Notarization failed. DMG is signed but NOT notarized."
        echo "  Check: xcrun notarytool log <submission-id> ${NOTARY_ARGS[*]}"
        exit 1
    fi
fi

# --- Step 8: Write SHA-256 sidecar ---

echo ""
echo "--- Computing SHA-256 ---"

SHASUM=$(shasum -a 256 "$FINAL_DMG" | awk '{print $1}')
echo "$SHASUM  $(basename "$FINAL_DMG")" > "${FINAL_DMG}.sha256"

# --- Done ---

DMG_SIZE=$(du -h "$FINAL_DMG" | awk '{print $1}')

echo ""
echo "=== Done ==="
echo "  DMG:    $FINAL_DMG ($DMG_SIZE)"
echo "  SHA256: ${FINAL_DMG}.sha256"
echo "  Hash:   $SHASUM"
echo "  Signed: $SIGNING_MODE"
if [[ "$NOTARIZE" -eq 1 ]]; then
    echo "  Notarized: yes (stapled)"
    echo ""
    echo "Verify: spctl --assess --verbose=4 --type open --context context:primary-signature $FINAL_DMG"
elif [[ "$SIGNING_MODE" == "developer-id" ]]; then
    echo "  Notarized: no (credentials not configured)"
    echo ""
    echo "Verify app: spctl --assess --verbose $APP_PATH"
else
    echo ""
    echo "NOTE: Ad-hoc signed (not notarized). Gatekeeper will warn on first launch."
    echo "      Users: right-click -> Open."
fi

echo ""
echo "Next: run scripts/sparkle-publish.sh to publish this DMG."
