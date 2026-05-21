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
    "$BUILD_APP" "${BUILD_ARGS[@]}"
    echo ""
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Hippocampus.app not found at $APP_PATH"
    echo "Run build-app.sh first, or use --skip-build only if the .app is already assembled."
    exit 1
fi

# --- Step 2: Prepare DMG staging directory ---

DMG_NAME="Hippocampus-${VERSION}"
DMG_STAGING=$(mktemp -d -t hippocampus-dmg)
trap 'rm -rf "$DMG_STAGING"' EXIT

echo "--- Staging DMG contents ---"

cp -R "$APP_PATH" "$DMG_STAGING/Hippocampus.app"
ln -s /Applications "$DMG_STAGING/Applications"

# Copy volume icon if available
VOLUME_ICON="$REPO_ROOT/assets/branding/AppIcon.icns"
if [[ -f "$VOLUME_ICON" ]]; then
    cp "$VOLUME_ICON" "$DMG_STAGING/.VolumeIcon.icns"
fi

# Generate background image if not already present
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

# Create .background directory (hidden in DMG)
if [[ -f "$BACKGROUND_PNG" ]]; then
    mkdir -p "$DMG_STAGING/.background"
    cp "$BACKGROUND_PNG" "$DMG_STAGING/.background/background.png"
fi

echo "  Hippocampus.app -> staging/"
echo "  Applications symlink -> staging/"

# --- Step 3: Create temporary read-write DMG ---

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

# --- Step 4: Apply window layout via AppleScript ---

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

# --- Step 5: Convert to compressed read-only DMG ---

echo ""
echo "--- Compressing final DMG ---"

hdiutil convert \
    "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$FINAL_DMG"

rm -f "$TEMP_DMG"

# --- Step 6: Write SHA-256 sidecar ---

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
echo ""
echo "NOTE: This DMG is AD-HOC signed (unsigned for distribution)."
echo "      Gatekeeper will warn on first launch. Users: right-click -> Open."
echo "      Notarization requires an Apple Developer ID (follow-on work)."
