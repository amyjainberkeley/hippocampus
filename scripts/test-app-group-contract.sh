#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT="$SCRIPT_DIR/lib/app-group-contract.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[[ -f "$CONTRACT" ]] || fail "missing App Group contract helper"
# shellcheck source=/dev/null
source "$CONTRACT"

[[ "$(hippocampus_resolve_app_group_id ad-hoc "")" == "group.ai.hippocampus" ]] ||
    fail "ad-hoc builds must use the disposable development group"

APPLE_TEAM_ID=8L2K4M6N8P
export APPLE_TEAM_ID
[[ "$(hippocampus_resolve_app_group_id developer-id "Developer ID Application: Amy (8L2K4M6N8P)")" == "8L2K4M6N8P.ai.hippocampus" ]] ||
    fail "matching explicit and certificate Team IDs must resolve"
if hippocampus_resolve_app_group_id developer-id \
    "Developer ID Application: Amy (A1B2C3D4E5)" >/dev/null 2>&1; then
    fail "an environment Team ID that disagrees with the certificate must be rejected"
fi
unset APPLE_TEAM_ID

[[ "$(hippocampus_resolve_app_group_id developer-id "Developer ID Application: Amy (A1B2C3D4E5)")" == "A1B2C3D4E5.ai.hippocampus" ]] ||
    fail "Developer ID identity must supply the Team ID when the environment does not"

if hippocampus_resolve_app_group_id developer-id "Developer ID Application: Amy" >/dev/null 2>&1; then
    fail "Developer ID builds must reject an unknown Team ID"
fi

if APPLE_TEAM_ID=not-a-team-id hippocampus_resolve_app_group_id developer-id "" >/dev/null 2>&1; then
    fail "Developer ID builds must reject malformed Team IDs"
fi

scratch="$(mktemp -d -t hippocampus-app-group-test)"
trap 'rm -rf "$scratch"' EXIT

cat >"$scratch/source.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.ai.hippocampus</string>
    </array>
</dict>
</plist>
PLIST

hippocampus_render_app_group_entitlements \
    "$scratch/source.plist" \
    "$scratch/rendered.plist" \
    "A1B2C3D4E5.ai.hippocampus"

rendered_group=$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:0' \
    "$scratch/rendered.plist")
[[ "$rendered_group" == "A1B2C3D4E5.ai.hippocampus" ]] ||
    fail "rendered entitlements must contain the resolved group"
plutil -lint "$scratch/rendered.plist" >/dev/null ||
    fail "rendered entitlements must remain a valid plist"

cp "$scratch/source.plist" "$scratch/bundle-info.plist"
hippocampus_write_bundle_app_group_id \
    "$scratch/bundle-info.plist" \
    "A1B2C3D4E5.ai.hippocampus"
bundle_group=$(/usr/libexec/PlistBuddy -c \
    'Print :HippocampusAppGroupIdentifier' \
    "$scratch/bundle-info.plist")
[[ "$bundle_group" == "A1B2C3D4E5.ai.hippocampus" ]] ||
    fail "bundle metadata must expose the same resolved group to runtime"

cp /usr/bin/true "$scratch/signed-fixture"
codesign --force --sign - \
    --entitlements "$scratch/rendered.plist" \
    "$scratch/signed-fixture" >/dev/null 2>&1
hippocampus_verify_signed_app_group \
    "$scratch/signed-fixture" \
    "A1B2C3D4E5.ai.hippocampus" ||
    fail "post-sign verification must read the entitlement from signed code"
if hippocampus_verify_signed_app_group \
    "$scratch/signed-fixture" \
    "Z9Y8X7W6V5.ai.hippocampus"; then
    fail "post-sign verification must reject the wrong App Group"
fi

echo "PASS: App Group identity and entitlement rendering are fail-closed"

python3 -B "$SCRIPT_DIR/test_apple_events_signing_contract.py"
