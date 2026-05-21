#!/usr/bin/env bash
set -euo pipefail

# publish-appcast.sh — Sign a Hippocampus DMG with Sparkle EdDSA and
# generate/merge appcast.xml for auto-update distribution.
#
# Usage:
#   SPARKLE_PRIVATE_KEY=<base64-ed25519-key> ./scripts/publish-appcast.sh [OPTIONS]
#
# Options:
#   --dmg PATH        Path to DMG (default: auto-detect dist/Hippocampus-*.dmg)
#   --download-url U  Base URL for DMG downloads (default: from --hosting-mode)
#   --hosting-mode M  "ghpages" or "s3" (default: ghpages)
#   --appcast PATH    Existing appcast.xml to merge into (default: dist/appcast.xml)
#   --dist DIR        Output directory (default: dist/)
#   --help            Show this help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DMG_PATH=""
DOWNLOAD_URL=""
HOSTING_MODE="ghpages"
APPCAST_PATH=""
DIST_DIR="$REPO_ROOT/dist"

usage() {
    cat <<EOF
Usage: SPARKLE_PRIVATE_KEY=<key> publish-appcast.sh [OPTIONS]

Sign a Hippocampus DMG and generate/merge appcast.xml.

Options:
  --dmg PATH         Path to DMG (default: auto-detect dist/Hippocampus-*.dmg)
  --download-url U   Base URL for DMG downloads
  --hosting-mode M   "ghpages" or "s3" (default: ghpages)
  --appcast PATH     Existing appcast.xml to merge into (default: dist/appcast.xml)
  --dist DIR         Output directory (default: dist/)
  --help             Show this help

Environment:
  SPARKLE_PRIVATE_KEY   Base64-encoded EdDSA private key (required)
  SPARKLE_SIGN_UPDATE   Path to Sparkle sign_update binary (auto-detected)

The private key MUST NOT live in the repo. Pass via env or CI secret.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) DMG_PATH="$2"; shift 2 ;;
        --download-url) DOWNLOAD_URL="$2"; shift 2 ;;
        --hosting-mode) HOSTING_MODE="$2"; shift 2 ;;
        --appcast) APPCAST_PATH="$2"; shift 2 ;;
        --dist) DIST_DIR="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1"; usage; exit 1 ;;
    esac
done

# --- Validate private key ---

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "ERROR: SPARKLE_PRIVATE_KEY not set."
    echo "  Generate: ./Sparkle.framework/.../bin/generate_keys"
    echo "  Store as GitHub Actions secret, never in repo."
    exit 1
fi

# --- Find DMG ---

if [[ -z "$DMG_PATH" ]]; then
    DMG_PATH=$(ls "$DIST_DIR"/Hippocampus-*.dmg 2>/dev/null | sort -V | tail -1 || true)
fi

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "ERROR: No DMG found. Run build-installer.sh first or pass --dmg."
    exit 1
fi

echo "=== Sparkle Appcast Publisher ==="
echo "DMG:     $DMG_PATH"

# --- Extract version from DMG filename ---

DMG_BASENAME=$(basename "$DMG_PATH" .dmg)
VERSION="${DMG_BASENAME#Hippocampus-}"

if [[ -z "$VERSION" ]]; then
    echo "ERROR: Could not extract version from DMG filename: $DMG_BASENAME"
    exit 1
fi

echo "Version: $VERSION"

# --- Read build number from Info.plist ---

INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "1")
echo "Build:   $BUILD_NUMBER"

# --- Compute DMG size ---

DMG_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)
echo "Size:    $DMG_SIZE bytes"

# --- Find sign_update ---

find_sign_update() {
    if [[ -n "${SPARKLE_SIGN_UPDATE:-}" && -x "${SPARKLE_SIGN_UPDATE}" ]]; then
        echo "$SPARKLE_SIGN_UPDATE"
        return
    fi

    # SwiftPM build artifacts
    local swiftpm_path="$REPO_ROOT/apps/hippocampus/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    if [[ -x "$swiftpm_path" ]]; then
        echo "$swiftpm_path"
        return
    fi

    # Framework bundle (Sparkle 2.x layout)
    local fw_paths=(
        "$REPO_ROOT/apps/hippocampus/.build"
        "$HOME/Library/Developer/Xcode/DerivedData"
    )
    for base in "${fw_paths[@]}"; do
        local found
        found=$(find "$base" -path "*/Sparkle.framework/Versions/B/bin/sign_update" 2>/dev/null | head -1 || true)
        if [[ -n "$found" && -x "$found" ]]; then
            echo "$found"
            return
        fi
    done

    # Homebrew
    if command -v sign_update &>/dev/null; then
        command -v sign_update
        return
    fi

    return 1
}

SIGN_UPDATE=$(find_sign_update) || {
    echo "ERROR: Sparkle sign_update not found."
    echo "  Set SPARKLE_SIGN_UPDATE=/path/to/sign_update"
    echo "  or install Sparkle tools: brew install sparkle"
    exit 1
}

echo "Signer:  $SIGN_UPDATE"

# --- Sign the DMG ---

echo ""
echo "--- Signing DMG with EdDSA ---"

SIGN_OUTPUT=$(echo "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" "$DMG_PATH" -f -)
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//' || true)

if [[ -z "$ED_SIGNATURE" ]]; then
    ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | head -1 | tr -d '[:space:]')
fi

if [[ -z "$ED_SIGNATURE" ]]; then
    echo "ERROR: sign_update produced no signature."
    echo "Output was: $SIGN_OUTPUT"
    exit 1
fi

echo "Signature: ${ED_SIGNATURE:0:20}..."

# --- Compute download URL ---

if [[ -z "$DOWNLOAD_URL" ]]; then
    case "$HOSTING_MODE" in
        ghpages)
            DOWNLOAD_URL="https://amyjainberkeley.github.io/hippocampus-appcast/$(basename "$DMG_PATH")"
            ;;
        s3)
            DOWNLOAD_URL="https://releases.hippocampus.ai/$(basename "$DMG_PATH")"
            ;;
        *)
            echo "ERROR: Unknown hosting mode: $HOSTING_MODE (use ghpages or s3)"
            exit 1
            ;;
    esac
fi

echo "URL:     $DOWNLOAD_URL"

# --- Build the new <item> XML ---

PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S %z')

NEW_ITEM=$(cat <<ITEM_EOF
        <item>
            <title>Hippocampus $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="$DOWNLOAD_URL"
                       sparkle:edSignature="$ED_SIGNATURE"
                       length="$DMG_SIZE"
                       type="application/octet-stream" />
        </item>
ITEM_EOF
)

# --- Merge into existing appcast or create new ---

echo ""
echo "--- Generating appcast.xml ---"

mkdir -p "$DIST_DIR"

if [[ -z "$APPCAST_PATH" ]]; then
    APPCAST_PATH="$DIST_DIR/appcast.xml"
fi

if [[ -f "$APPCAST_PATH" ]]; then
    echo "Merging into existing appcast: $APPCAST_PATH"

    # Check if this version already exists — replace it
    if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_PATH"; then
        echo "  Version $VERSION already in appcast — replacing."
        # Remove existing item block for this version
        TEMP_APPCAST=$(mktemp)
        awk -v ver="$VERSION" '
            /<item>/ { in_item=1; buf=$0"\n"; next }
            in_item && /<\/item>/ {
                buf=buf $0"\n"
                if (buf ~ ver) { in_item=0; buf=""; next }
                printf "%s", buf
                in_item=0; buf=""
                next
            }
            in_item { buf=buf $0"\n"; next }
            { print }
        ' "$APPCAST_PATH" > "$TEMP_APPCAST"
        APPCAST_BODY=$(cat "$TEMP_APPCAST")
        rm -f "$TEMP_APPCAST"
    else
        APPCAST_BODY=$(cat "$APPCAST_PATH")
    fi

    # Insert new item before </channel>
    echo "$APPCAST_BODY" | sed "s|</channel>|$NEW_ITEM\n    </channel>|" > "$DIST_DIR/appcast.xml"
else
    echo "Creating new appcast: $DIST_DIR/appcast.xml"
    cat > "$DIST_DIR/appcast.xml" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Hippocampus Changelog</title>
        <link>https://hippocampus.ai</link>
        <description>Hippocampus app updates</description>
        <language>en</language>
$NEW_ITEM
    </channel>
</rss>
APPCAST_EOF
fi

echo ""
echo "=== Done ==="
echo "  Appcast: $DIST_DIR/appcast.xml"
echo "  Version: $VERSION (build $BUILD_NUMBER)"
echo "  DMG URL: $DOWNLOAD_URL"
