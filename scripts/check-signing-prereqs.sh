#!/usr/bin/env bash
set -euo pipefail

# check-signing-prereqs.sh — Inspect the local environment for everything the
# DMG sign + notarize + staple pipeline requires. Non-destructive. Companion
# to scripts/sign-dmg-dry-run.sh — run this FIRST; if it reports blockers, no
# dry-run or real-signing pass will succeed.
#
# Usage: ./scripts/check-signing-prereqs.sh [--release] [--verbose]
# Exit codes: 0 = ready · 1 = blockers · 2 = bad arguments.

VERBOSE=0
RELEASE_MODE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) RELEASE_MODE=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        --help|-h) grep '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLOCK=0; WARN=0
ok_()    { echo "  ok    $1"; }
warn_()  { echo "  warn  $1"; WARN=$((WARN+1)); }
block_() { echo "  BLOCK $1"; BLOCK=$((BLOCK+1)); }

echo "=== Signing prereq check ==="
echo "Repo: $REPO_ROOT"
if [[ "$RELEASE_MODE" -eq 1 ]]; then
    echo "Mode: release (Developer ID + notarization required)"
else
    echo "Mode: development (ad-hoc signing allowed)"
fi
echo ""

echo "[1/7] Xcode + core tools"
for cmd in codesign spctl hdiutil security shasum; do
    if command -v "$cmd" &>/dev/null; then
        ok_ "$cmd: $(command -v "$cmd")"
    else
        block_ "$cmd not found — install Xcode CLT (xcode-select --install)"
    fi
done

DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
if [[ "$DEVELOPER_DIR" == */CommandLineTools ]]; then
    if [[ "$RELEASE_MODE" -eq 1 ]]; then
        block_ "full Xcode is not selected (active directory: $DEVELOPER_DIR)"
    else
        warn_ "full Xcode is not selected (active directory: $DEVELOPER_DIR)"
    fi
elif [[ -n "$DEVELOPER_DIR" ]] && xcodebuild -version &>/dev/null; then
    ok_ "full Xcode selected: $DEVELOPER_DIR"
else
    block_ "no usable Xcode developer directory is selected"
fi

echo ""
echo "[2/7] xcrun notarytool"
if xcrun --find notarytool &>/dev/null; then
    ok_ "notarytool present: $(xcrun --find notarytool)"
    if xcrun notarytool history --keychain-profile "notarytool-profile" &>/dev/null; then
        ok_ "keychain profile 'notarytool-profile' configured"
    elif [[ -n "${NOTARYTOOL_APPLE_ID:-}" && -n "${NOTARYTOOL_TEAM_ID:-}" && -n "${NOTARYTOOL_PASSWORD:-}" ]]; then
        ok_ "NOTARYTOOL_APPLE_ID / TEAM_ID / PASSWORD env vars set"
    else
        if [[ "$RELEASE_MODE" -eq 1 ]]; then
            block_ "no notary credentials; store Keychain profile 'notarytool-profile'"
        else
            warn_ "no notary credentials; release mode requires Keychain profile 'notarytool-profile'"
        fi
    fi
else
    block_ "xcrun notarytool missing — install Xcode CLT / Xcode.app"
fi

echo ""
echo "[3/7] xcrun stapler"
if xcrun --find stapler &>/dev/null; then
    ok_ "stapler present: $(xcrun --find stapler)"
else
    block_ "xcrun stapler missing — install Xcode.app"
fi

echo ""
echo "[4/7] Developer ID signing identities"
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || echo "")
if echo "$IDENTITIES" | grep -q "Developer ID Application"; then
    APP_CERT=$(echo "$IDENTITIES" | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    ok_ "Developer ID Application: $APP_CERT"
else
    if [[ "$RELEASE_MODE" -eq 1 ]]; then
        block_ "no valid 'Developer ID Application' identity with private key"
    else
        warn_ "no valid 'Developer ID Application' identity; ad-hoc iteration remains available"
    fi
fi
if echo "$IDENTITIES" | grep -q "Developer ID Installer"; then
    INS_CERT=$(echo "$IDENTITIES" | grep "Developer ID Installer" | head -1 | sed 's/.*"\(.*\)"/\1/')
    ok_ "Developer ID Installer: $INS_CERT"
else
    warn_ "no 'Developer ID Installer' identity (needed only for .pkg, not .dmg)"
fi
[[ "$VERBOSE" -eq 1 ]] && echo "$IDENTITIES" | sed 's/^/    /'

echo ""
echo "[5/7] In-repo signing inputs"
INFO_PLIST="$REPO_ROOT/apps/hippocampus/Resources/Info.plist"
ENTITLEMENTS="$REPO_ROOT/apps/hippocampus/Resources/Hippocampus.entitlements"
if [[ -f "$INFO_PLIST" ]]; then
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || echo "?")
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "?")
    ok_ "Info.plist: bundle=$BUNDLE_ID version=$VERSION"
else
    block_ "Info.plist missing at $INFO_PLIST"
fi
if [[ -f "$ENTITLEMENTS" ]]; then
    ok_ "entitlements file: $ENTITLEMENTS"
else
    block_ "entitlements missing at $ENTITLEMENTS"
fi

echo ""
echo "[6/7] Installer brand identity"
if "$REPO_ROOT/scripts/build-installer.sh" --verify-assets &>/dev/null; then
    ok_ "installer assets match canonical AppIcon.icns"
else
    block_ "installer brand assets fail canonical identity verification"
fi

echo ""
echo "[7/7] Candidate DMG artifacts"
DMG_HITS=""
if [[ -d "$REPO_ROOT/dist" ]]; then
    DMG_HITS=$(find "$REPO_ROOT/dist" -maxdepth 2 -name "Hippocampus-*.dmg" 2>/dev/null | head -3 || true)
fi
if [[ -n "$DMG_HITS" ]]; then
    while IFS= read -r DMG; do
        ok_ "$DMG ($(du -h "$DMG" | awk '{print $1}'))"
    done <<< "$DMG_HITS"
else
    warn_ "no DMG in dist/ yet — run scripts/build-installer.sh first"
fi

echo ""
echo "=== Summary ==="
echo "  blockers: $BLOCK"
echo "  warnings: $WARN"

if [[ "$BLOCK" -gt 0 ]]; then
    echo ""
    echo "One or more BLOCKERS present — fix before sign-dmg-dry-run.sh."
    exit 1
fi

if [[ "$WARN" -eq 0 && "$RELEASE_MODE" -eq 1 ]]; then
    echo ""
    echo "Environment is fully ready for real Developer ID signing + notarization."
elif [[ "$RELEASE_MODE" -eq 1 ]]; then
    echo ""
    echo "Release prerequisites pass with non-blocking warnings listed above."
else
    echo ""
    echo "Ad-hoc dry-run is available now:"
    echo "  ./scripts/sign-dmg-dry-run.sh dist/Hippocampus-*.dmg"
    echo ""
    echo "Real signing unlocks once the warnings above are cleared."
fi
exit 0
