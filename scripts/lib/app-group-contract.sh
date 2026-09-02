#!/usr/bin/env bash

# Shared macOS App Group identity contract for app assembly and DMG re-signing.
# This file is sourced by release scripts; do not enable shell options here.

hippocampus_resolve_app_group_id() {
    local signing_mode="${1:-}"
    local signing_identity="${2:-}"
    local team_id="${APPLE_TEAM_ID:-${NOTARYTOOL_TEAM_ID:-}}"
    local identity_team_id=""

    if [[ "$signing_mode" != "developer-id" ]]; then
        printf '%s\n' 'group.ai.hippocampus'
        return 0
    fi

    if [[ "$signing_identity" =~ \(([A-Z0-9]{10})\)[[:space:]]*$ ]]; then
        identity_team_id="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$team_id" && -n "$identity_team_id" && "$team_id" != "$identity_team_id" ]]; then
        echo "FATAL: configured Apple Team ID does not match the selected signing identity." >&2
        return 1
    fi
    if [[ -z "$team_id" ]]; then
        team_id="$identity_team_id"
    fi

    if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "FATAL: Developer ID builds require a 10-character Apple Team ID." >&2
        echo "Set APPLE_TEAM_ID (or NOTARYTOOL_TEAM_ID), or use an identity whose name ends in '(TEAMID)'." >&2
        return 1
    fi

    printf '%s.ai.hippocampus\n' "$team_id"
}

hippocampus_render_app_group_entitlements() {
    local source_plist="${1:?source entitlements plist required}"
    local destination_plist="${2:?destination entitlements plist required}"
    local app_group_id="${3:?App Group identifier required}"

    python3 - "$source_plist" "$destination_plist" "$app_group_id" <<'PY'
import plistlib
import sys

source, destination, app_group_id = sys.argv[1:]
with open(source, "rb") as handle:
    payload = plistlib.load(handle)
payload["com.apple.security.application-groups"] = [app_group_id]
with open(destination, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
}

hippocampus_write_bundle_app_group_id() {
    local info_plist="${1:?bundle Info.plist required}"
    local app_group_id="${2:?App Group identifier required}"

    python3 - "$info_plist" "$app_group_id" <<'PY'
import plistlib
import sys

path, app_group_id = sys.argv[1:]
with open(path, "rb") as handle:
    payload = plistlib.load(handle)
payload["HippocampusAppGroupIdentifier"] = app_group_id
with open(path, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
}

hippocampus_verify_signed_app_group() {
    local code_path="${1:?signed code path required}"
    local expected_group="${2:?expected App Group required}"
    local expected_team_id="${3:-}"
    local actual_group actual_team_id

    actual_group=$(
        codesign -d --entitlements :- "$code_path" 2>/dev/null |
            plutil -extract 'com\.apple\.security\.application-groups'.0 raw -o - - \
                2>/dev/null
    ) || return 1
    [[ "$actual_group" == "$expected_group" ]] || return 1

    if [[ -n "$expected_team_id" ]]; then
        actual_team_id=$(
            codesign -dv --verbose=4 "$code_path" 2>&1 |
                sed -nE 's/^TeamIdentifier=(.*)$/\1/p' |
                head -1
        )
        [[ "$actual_team_id" == "$expected_team_id" ]] || return 1
    fi
}
