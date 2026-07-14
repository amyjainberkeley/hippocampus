#!/usr/bin/env bash
set -euo pipefail

# sign-dmg-dry-run.sh — Validate the DMG sign + notarize + staple pipeline
# BEFORE the Apple Developer cert lands. Uses ad-hoc identity ("-") by default
# so pipeline bugs surface early. When the Developer ID cert clears, swap
# --identity + pass --notarize to run the real submission via the same path.
# Distinct from scripts/build-installer.sh (which BUILDS + signs + packages);
# this INSPECTS an existing DMG and reports on every notary precondition.
#
# Usage:
#   ./scripts/sign-dmg-dry-run.sh <dmg-path>
#   ./scripts/sign-dmg-dry-run.sh --identity - <dmg-path>
#   ./scripts/sign-dmg-dry-run.sh \
#       --identity "Developer ID Application: Amy Jain (XXXXXXXXXX)" \
#       --notarize dist/Hippocampus-0.1.0.dmg
# Exit: 0 all pass · 1 validation failed · 2 bad input.

IDENTITY="-"; NOTARIZE=0; VERBOSE=0; DMG_PATH=""

usage() { cat <<EOF
Usage: sign-dmg-dry-run.sh [OPTIONS] <dmg-path>
  --identity ID   "-" = ad-hoc (default), or "Developer ID Application: ..."
  --notarize      Submit to xcrun notarytool (requires Developer ID + creds)
  --verbose       Print codesign / spctl detail on failure
  --help          Show this help
Exit: 0 all pass · 1 fail · 2 bad input.
EOF
}

while [[ $# -gt 0 ]]; do case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) DMG_PATH="$1"; shift ;;
esac; done

[[ -z "$DMG_PATH" ]] && { echo "ERROR: <dmg-path> required" >&2; usage >&2; exit 2; }
[[ ! -f "$DMG_PATH" ]] && { echo "ERROR: DMG not found: $DMG_PATH" >&2; exit 2; }
if [[ "$NOTARIZE" -eq 1 && "$IDENTITY" == "-" ]]; then
    echo "ERROR: --notarize requires --identity 'Developer ID Application: ...'" >&2
    exit 2
fi
for cmd in codesign spctl hdiutil; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: missing tool: $cmd" >&2; exit 2; }
done

PASS=0; FAIL=0; WARN=0; REPORT=()
pass_() { REPORT+=("PASS  $1"); PASS=$((PASS+1)); }
fail_() { REPORT+=("FAIL  $1"); FAIL=$((FAIL+1)); }
warn_() { REPORT+=("WARN  $1"); WARN=$((WARN+1)); }

echo "=== DMG signing dry-run ==="
echo "DMG:       $DMG_PATH"
echo "Identity:  $IDENTITY"
echo "Notarize:  $([[ $NOTARIZE -eq 1 ]] && echo yes || echo 'no (dry-run)')"
echo ""

# --- Mount DMG (readonly, nobrowse) ---
MOUNT_LINE=$(hdiutil attach -readonly -nobrowse -noautoopen "$DMG_PATH" | grep "/Volumes/" | tail -1)
MOUNT_DIR=$(echo "$MOUNT_LINE" | sed 's/.*\(\/Volumes\/.*\)$/\1/' | xargs)
[[ ! -d "$MOUNT_DIR" ]] && { echo "ERROR: failed to mount $DMG_PATH" >&2; exit 1; }

APP_STAGING=""; DMG_COPY=""
cleanup() {
    [[ -n "$MOUNT_DIR" ]] && hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    [[ -n "$APP_STAGING" ]] && rm -rf "$APP_STAGING"
    [[ -n "$DMG_COPY" ]] && rm -f "$DMG_COPY"
}
trap cleanup EXIT

APP_IN_DMG=$(find "$MOUNT_DIR" -maxdepth 2 -name "*.app" -type d | head -1)
if [[ -z "$APP_IN_DMG" ]]; then
    fail_ "no .app bundle found inside DMG"; APP_PATH=""
else
    # Copy out to writable staging so we can re-sign without mutating the RO DMG.
    APP_STAGING=$(mktemp -d -t hippocampus-drysign)
    cp -R "$APP_IN_DMG" "$APP_STAGING/"
    APP_PATH="$APP_STAGING/$(basename "$APP_IN_DMG")"
    pass_ "found .app in DMG: $(basename "$APP_IN_DMG")"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/apps/hippocampus/Resources/Hippocampus.entitlements"
[[ ! -f "$ENTITLEMENTS" ]] && ENTITLEMENTS=""

if [[ -n "$APP_PATH" ]]; then
    INFO="$APP_PATH/Contents/Info.plist"
    if [[ -f "$INFO" ]]; then
        BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO" 2>/dev/null || echo "")
        VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO" 2>/dev/null || echo "")
        if [[ -n "$BID" && -n "$VER" ]]; then
            pass_ "Info.plist has bundle id ($BID) + version ($VER)"
        else
            fail_ "Info.plist missing CFBundleIdentifier or CFBundleShortVersionString"
        fi
    else
        fail_ "Info.plist missing at $INFO"
    fi

    # --- Sign the .app ---
    # Ad-hoc uses --deep; real Developer ID intentionally does NOT (inside-out
    # order matters — see build-installer.sh Sparkle block). For pipeline
    # validation, --deep is fine.
    if [[ "$IDENTITY" == "-" ]]; then
        SIGN_ARGS=(--force --deep --sign - --options=runtime)
    else
        SIGN_ARGS=(--force --timestamp --options=runtime --sign "$IDENTITY")
        [[ -n "$ENTITLEMENTS" ]] && SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    fi
    if codesign "${SIGN_ARGS[@]}" "$APP_PATH" 2>/tmp/dry-sign.log; then
        pass_ "codesign succeeded with identity: $IDENTITY"
    else
        fail_ "codesign failed — /tmp/dry-sign.log"
        [[ "$VERBOSE" -eq 1 ]] && cat /tmp/dry-sign.log
    fi

    if codesign --verify --deep --strict "$APP_PATH" 2>/tmp/dry-verify.log; then
        pass_ "codesign --verify --deep --strict passed"
    else
        fail_ "codesign --verify failed — /tmp/dry-verify.log"
        [[ "$VERBOSE" -eq 1 ]] && cat /tmp/dry-verify.log
    fi

    # --- Hardened runtime flag ---
    if codesign -d --verbose=2 "$APP_PATH" 2>&1 | grep -qE "flags=.*runtime"; then
        pass_ "hardened runtime flag is set (Apple notary requires this)"
    elif [[ "$IDENTITY" == "-" ]]; then
        warn_ "hardened runtime flag not enforced under ad-hoc (expected)"
    else
        fail_ "hardened runtime flag MISSING — notary would reject"
    fi

    # --- Secure timestamp (only under Developer ID) ---
    if [[ "$IDENTITY" != "-" ]]; then
        if codesign -d --verbose=4 "$APP_PATH" 2>&1 | grep -q "Timestamp="; then
            pass_ "secure timestamp present"
        else
            fail_ "secure timestamp MISSING — notary would reject"
        fi
    fi

    # --- TCC usage descriptions in Info.plist ---
    # Missing ones crash the app on first API touch — caught here, not by notary.
    MISSING=()
    for KEY in NSScreenCaptureUsageDescription NSAccessibilityUsageDescription NSAppleEventsUsageDescription; do
        /usr/libexec/PlistBuddy -c "Print :$KEY" "$INFO" &>/dev/null || MISSING+=("$KEY")
    done
    if [[ ${#MISSING[@]} -eq 0 ]]; then
        pass_ "Info.plist has all required TCC usage descriptions"
    else
        fail_ "Info.plist missing TCC usage descriptions: ${MISSING[*]}"
    fi

    # --- @rpath sanity: no absolute /Users/... paths inside the bundle ---
    RPATH_HITS=$(find "$APP_PATH/Contents/MacOS" -maxdepth 2 -type f -perm +111 \
        -exec otool -l {} \; 2>/dev/null | grep -E "path /Users/" | head -3 || true)
    if [[ -z "$RPATH_HITS" ]]; then
        pass_ "no @rpath references to developer home dir"
    else
        fail_ "@rpath references to /Users/... found — notary would reject"
        [[ "$VERBOSE" -eq 1 ]] && echo "$RPATH_HITS"
    fi

    # --- Every embedded Mach-O / framework signed ---
    UNSIGNED=$(find "$APP_PATH/Contents" \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.appex" \) \
        -exec sh -c 'codesign --verify "$1" 2>/dev/null || echo "$1"' _ {} \; | head -5)
    if [[ -z "$UNSIGNED" ]]; then
        pass_ "all embedded frameworks / dylibs / xpc / appex are signed"
    else
        fail_ "unsigned embedded binaries found (first 5):"
        REPORT+=("      $UNSIGNED")
    fi

    # --- Gatekeeper assessment on the .app ---
    if spctl --assess --type execute --verbose=2 "$APP_PATH" &>/tmp/dry-spctl-app.log; then
        pass_ "spctl --assess (execute) accepts the .app"
    elif [[ "$IDENTITY" == "-" ]]; then
        warn_ "spctl rejects ad-hoc signed .app (expected — needs Developer ID)"
    else
        fail_ "spctl --assess rejects the .app — /tmp/dry-spctl-app.log"
        [[ "$VERBOSE" -eq 1 ]] && cat /tmp/dry-spctl-app.log
    fi
fi

# --- Sign the DMG itself + spctl assess ---
DMG_COPY=$(mktemp -t hippocampus-dry-dmg).dmg
cp "$DMG_PATH" "$DMG_COPY"

DMG_SIGN_ARGS=(--force --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && DMG_SIGN_ARGS+=(--timestamp)
if codesign "${DMG_SIGN_ARGS[@]}" "$DMG_COPY" 2>/tmp/dry-dmg-sign.log; then
    pass_ "codesign on DMG succeeded"
else
    fail_ "codesign on DMG failed — /tmp/dry-dmg-sign.log"
fi

if spctl --assess --type open --context context:primary-signature "$DMG_COPY" &>/tmp/dry-spctl-dmg.log; then
    pass_ "spctl --assess (primary-signature) accepts the DMG"
elif [[ "$IDENTITY" == "-" ]]; then
    warn_ "spctl rejects ad-hoc signed DMG (expected — needs Developer ID)"
else
    fail_ "spctl --assess rejects the DMG — /tmp/dry-spctl-dmg.log"
fi

# --- Notarization (only if --notarize + Developer ID) ---
if [[ "$NOTARIZE" -eq 1 ]]; then
    NOTARY_ARGS=()
    if xcrun notarytool history --keychain-profile "notarytool-profile" &>/dev/null; then
        NOTARY_ARGS=(--keychain-profile "notarytool-profile")
    elif [[ -n "${NOTARYTOOL_APPLE_ID:-}" && -n "${NOTARYTOOL_TEAM_ID:-}" && -n "${NOTARYTOOL_PASSWORD:-}" ]]; then
        NOTARY_ARGS=(--apple-id "$NOTARYTOOL_APPLE_ID" --team-id "$NOTARYTOOL_TEAM_ID" --password "$NOTARYTOOL_PASSWORD")
    else
        fail_ "--notarize passed but no notarytool credentials found"
    fi
    if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
        echo ""; echo "--- Submitting to Apple notary (can take minutes) ---"
        if xcrun notarytool submit "$DMG_COPY" "${NOTARY_ARGS[@]}" --wait; then
            pass_ "Apple notary accepted the DMG"
            if xcrun stapler staple "$DMG_COPY"; then
                pass_ "stapler attached ticket to DMG"
            else
                fail_ "stapler failed to attach ticket"
            fi
        else
            fail_ "Apple notary REJECTED the DMG — xcrun notarytool log"
        fi
    fi
fi

# --- Report ---
echo ""
echo "=== Validation report ==="
for LINE in "${REPORT[@]}"; do echo "  $LINE"; done
echo ""
echo "Summary: $PASS pass, $FAIL fail, $WARN warn"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""; echo "Validation FAILED. Fix before running real signing."; exit 1
fi
if [[ "$IDENTITY" == "-" ]]; then
    echo ""
    echo "Ad-hoc dry-run PASSED. Pipeline is script-clean. When the"
    echo "Developer ID cert lands, re-run with:"
    echo "  ./scripts/sign-dmg-dry-run.sh \\"
    echo "      --identity 'Developer ID Application: Amy Jain (TEAMID)' \\"
    echo "      --notarize $DMG_PATH"
fi
exit 0
