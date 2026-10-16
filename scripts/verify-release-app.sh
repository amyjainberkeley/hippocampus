#!/usr/bin/env bash
set -euo pipefail

# verify-release-app.sh — What a Hippocampus release app must be. The release
# script and the tag workflow both check with this, so they check the same.
#
#   scripts/verify-release-app.sh --version V --team TEAM [--minimum-macos M]
#       [--gatekeeper none|notary-submission|distribution] APP
#
#   1. hippocampus-mind is in the app and links FoundationModels weakly
#      (otool -l shows LC_LOAD_WEAK_DYLIB). Weakly, it starts on macOS 14
#      and 15; linked at all, it keeps Apple Intelligence on 26 (launch
#      gate D2).
#   2. Every binary in Contents/MacOS runs on macOS M (default 14.0).
#   3. The bundle version is V, and the development file key is off.
#   4. codesign --verify --deep --strict passes, and the team is TEAM.
#   5. --gatekeeper distribution runs syspolicy_check distribution: the
#      checks macOS makes before it first opens an app, notarization,
#      Gatekeeper and XProtect included (launch gate D1).
#      --gatekeeper notary-submission runs the checks Apple's notary service
#      makes, for an app that is not notarized yet. The default is none.
#
# HIPPOCAMPUS_SYSPOLICY_CHECK replaces /usr/bin/syspolicy_check, for the
# fixture test only.

usage() {
    awk 'NR < 4 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

VERSION=""
TEAM=""
MINIMUM="14.0"
GATEKEEPER="none"
APP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; VERSION="$2"; shift 2 ;;
        --team) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; TEAM="$2"; shift 2 ;;
        --minimum-macos) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; MINIMUM="$2"; shift 2 ;;
        --gatekeeper) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; GATEKEEPER="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "verify-release-app: unknown option $1" >&2; exit 2 ;;
        *) [[ -z "$APP" ]] || { usage >&2; exit 2; }; APP="$1"; shift ;;
    esac
done
[[ -n "$VERSION" && -n "$TEAM" && -n "$APP" ]] || { usage >&2; exit 2; }
case "$GATEKEEPER" in
    none|notary-submission|distribution) ;;
    *) echo "verify-release-app: --gatekeeper must be none, notary-submission or distribution" >&2; exit 2 ;;
esac
SYSPOLICY_CHECK="${HIPPOCAMPUS_SYSPOLICY_CHECK:-/usr/bin/syspolicy_check}"

ok() { printf 'ok    %s\n' "$*"; }
refuse() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

# True when version $1 is at most $2 (each up to three numeric parts).
version_at_most() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if ((x[i] + 0) < (y[i] + 0)) exit 0
            if ((x[i] + 0) > (y[i] + 0)) exit 1
        }
        exit 0
    }'
}

macho_minos() {
    { /usr/bin/otool -l "$1" 2>/dev/null || true; } \
        | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" && !done { print $2; done = 1 }'
}

# The load command that brings in FoundationModels, if any.
foundation_models_link() {
    { /usr/bin/otool -l "$1" 2>/dev/null || true; } | awk '
        $1 == "cmd" { cmd = $2 }
        $1 == "name" && $2 ~ /\/FoundationModels\.framework\// && !done { print cmd; done = 1 }'
}

[[ -d "$APP/Contents/MacOS" ]] || refuse "not an app bundle: $APP"
NAME="$(basename "$APP")"

MIND="$APP/Contents/MacOS/hippocampus-mind"
[[ -x "$MIND" ]] || refuse "hippocampus-mind is not in $NAME; answers would need it."
LINK="$(foundation_models_link "$MIND")"
[[ "$LINK" == "LC_LOAD_WEAK_DYLIB" ]] \
    || refuse "hippocampus-mind links FoundationModels as ${LINK:-nothing}, not weakly: it would not start on macOS 14 or 15, or could not use Apple Intelligence."
ok "hippocampus-mind links FoundationModels weakly (LC_LOAD_WEAK_DYLIB)"

HIGHEST="0"
for binary in "$APP"/Contents/MacOS/*; do
    minos="$(macho_minos "$binary")"
    [[ -n "$minos" ]] || continue
    version_at_most "$minos" "$MINIMUM" || refuse "$(basename "$binary") needs macOS $minos; Hippocampus promises macOS $MINIMUM."
    version_at_most "$minos" "$HIGHEST" || HIGHEST="$minos"
done
ok "every binary in Contents/MacOS runs on macOS $MINIMUM (the highest minimum is $HIGHEST)"

INFO="$APP/Contents/Info.plist"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null || true)"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || refuse "$NAME says version ${BUNDLE_VERSION:-none}, not $VERSION."
if /usr/libexec/PlistBuddy -c 'Print :MCIDevelopmentFileKeyEnabled' "$INFO" >/dev/null 2>&1; then
    refuse "$NAME turns on the development file key. Only an ad-hoc test build may do that."
fi
ok "version $VERSION, development file key off"

if ! SIGNATURE="$(/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)"; then
    printf '%s\n' "$SIGNATURE" >&2
    refuse "codesign --verify --deep --strict failed for $NAME."
fi
SIGNED_TEAM="$(/usr/bin/codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$SIGNED_TEAM" == "$TEAM" ]] || refuse "$NAME is signed by team ${SIGNED_TEAM:-none}, not $TEAM."
ok "signature valid (deep, strict), team $TEAM"

if [[ "$GATEKEEPER" != "none" ]]; then
    if ! POLICY="$("$SYSPOLICY_CHECK" "$GATEKEEPER" "$APP" 2>&1)"; then
        printf '%s\n' "$POLICY" >&2
        refuse "syspolicy_check $GATEKEEPER rejected $NAME."
    fi
    ok "syspolicy_check $GATEKEEPER accepts $NAME"
fi
