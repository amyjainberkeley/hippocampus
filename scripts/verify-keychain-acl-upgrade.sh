#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: verify-keychain-acl-upgrade.sh OLD_HIPPOCAMPUS_APP NEW_HIPPOCAMPUS_APP\n' >&2
    exit 64
fi

OLD_APP="$1"
NEW_APP="$2"
EXECUTABLES=(Hippocampus MCICaptureHelper mci-agent recall-ui)

for app in "$OLD_APP" "$NEW_APP"; do
    [[ -d "$app/Contents/MacOS" ]] || {
        printf 'Missing app bundle MacOS directory: %s\n' "$app" >&2
        exit 1
    }
done

designated_requirement() {
    local executable="$1"
    local details requirement
    details="$(codesign -dv --verbose=4 "$executable" 2>&1)"
    if grep -Fq 'Signature=adhoc' <<<"$details"; then
        printf 'Ad-hoc identity is not upgrade-safe: %s\n' "$executable" >&2
        return 1
    fi
    if ! grep -Fq 'Authority=Developer ID Application' <<<"$details"; then
        printf 'Developer ID Application authority missing: %s\n' "$executable" >&2
        return 1
    fi
    requirement="$(codesign -d -r- "$executable" 2>&1 | sed -n 's/^designated => //p')"
    [[ -n "$requirement" ]] || {
        printf 'Designated requirement unavailable: %s\n' "$executable" >&2
        return 1
    }
    printf '%s' "$requirement"
}

for name in "${EXECUTABLES[@]}"; do
    old_path="$OLD_APP/Contents/MacOS/$name"
    new_path="$NEW_APP/Contents/MacOS/$name"
    [[ -f "$old_path" && -f "$new_path" ]] || {
        printf 'Missing ACL consumer %s in one app version\n' "$name" >&2
        exit 1
    }
    old_requirement="$(designated_requirement "$old_path")"
    new_requirement="$(designated_requirement "$new_path")"
    if [[ "$old_requirement" != "$new_requirement" ]]; then
        printf 'Designated requirement changed across versions: %s\n' "$name" >&2
        exit 1
    fi
    printf 'stable requirement: %s\n' "$name"
done
