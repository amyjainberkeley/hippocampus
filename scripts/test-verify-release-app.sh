#!/usr/bin/env bash
set -euo pipefail

# test-verify-release-app.sh — verify-release-app.sh accepts an app whose
# hippocampus-mind weak-links FoundationModels, and refuses a strong link,
# no link, a missing mind, a binary that needs a newer macOS, the wrong
# version or team, the development file key, a broken seal, and an app
# syspolicy_check rejects. Builds small Mach-O fixtures against this Mac's
# SDK and signs them ad hoc; no release app is read.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-release-app.sh"
TMP_ROOT="$(mktemp -d -t hippocampus-verify-release-app)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# An ad-hoc signature has no team; codesign prints "TeamIdentifier=not set".
ADHOC_TEAM="not set"

expect_accept() {
    local message="$1"; shift
    if "$VERIFY" "$@" >"$TMP_ROOT/out.log" 2>&1; then pass "$message"; else
        cat "$TMP_ROOT/out.log" >&2
        fail "$message"
    fi
}

expect_refuse() {
    local message="$1" reason="$2"; shift 2
    if "$VERIFY" "$@" >"$TMP_ROOT/out.log" 2>&1; then
        cat "$TMP_ROOT/out.log" >&2
        fail "$message"
    elif grep -Fq -- "$reason" "$TMP_ROOT/out.log"; then
        pass "$message"
    else
        cat "$TMP_ROOT/out.log" >&2
        fail "$message (refused, but not because: $reason)"
    fi
}

printf 'int main(void) { return 0; }\n' >"$TMP_ROOT/main.c"
compile() {
    local output="$1" minimum="$2"; shift 2
    xcrun clang -mmacosx-version-min="$minimum" "$TMP_ROOT/main.c" -o "$output" "$@"
}
compile "$TMP_ROOT/mind-weak" 14.0 -Wl,-weak_framework,FoundationModels
compile "$TMP_ROOT/mind-strong" 14.0 -framework FoundationModels
compile "$TMP_ROOT/mind-none" 14.0
compile "$TMP_ROOT/host" 14.0
compile "$TMP_ROOT/host-macos15" 15.0

# The fixtures are what the cases need them to be.
otool -l "$TMP_ROOT/mind-weak" | grep -B2 'FoundationModels.framework' | grep -q LC_LOAD_WEAK_DYLIB \
    || { echo 'fixture: the weak mind has no weak FoundationModels link' >&2; exit 1; }
otool -l "$TMP_ROOT/mind-strong" | grep -B2 'FoundationModels.framework' | grep -q 'LC_LOAD_DYLIB$' \
    || { echo 'fixture: the strong mind has no strong FoundationModels link' >&2; exit 1; }

make_app() {
    local app="$1" mind="$2" host="${3:-$TMP_ROOT/host}"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Hippocampus</string>
<key>CFBundleIdentifier</key><string>test.hippocampus.verify-release-app</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>42</string>
</dict></plist>
PLIST
    cp "$host" "$app/Contents/MacOS/Hippocampus"
    if [[ -n "$mind" ]]; then cp "$mind" "$app/Contents/MacOS/hippocampus-mind"; fi
    codesign --force --sign - "$app" >/dev/null 2>&1
}

APP="$TMP_ROOT/Release.app"
ARGS=(--version 1.2.3 --team "$ADHOC_TEAM" --minimum-macos 14.0)

make_app "$APP" "$TMP_ROOT/mind-weak"
expect_accept 'an app whose mind weak-links FoundationModels is accepted' "${ARGS[@]}" "$APP"
if grep -Fq 'hippocampus-mind links FoundationModels weakly (LC_LOAD_WEAK_DYLIB)' "$TMP_ROOT/out.log"; then
    pass 'the accepted app reports the weak link it found'
else
    fail 'the accepted app reports the weak link it found'
fi

make_app "$APP" "$TMP_ROOT/mind-strong"
expect_refuse 'a strong FoundationModels link is refused (no start on macOS 14 or 15)' \
    'links FoundationModels as LC_LOAD_DYLIB, not weakly' "${ARGS[@]}" "$APP"

make_app "$APP" "$TMP_ROOT/mind-none"
expect_refuse 'a mind built without FoundationModels is refused (no Apple Intelligence)' \
    'links FoundationModels as nothing, not weakly' "${ARGS[@]}" "$APP"

make_app "$APP" ""
expect_refuse 'an app without hippocampus-mind is refused' 'hippocampus-mind is not in' "${ARGS[@]}" "$APP"

make_app "$APP" "$TMP_ROOT/mind-weak" "$TMP_ROOT/host-macos15"
expect_refuse 'a binary that needs macOS 15 is refused' 'Hippocampus needs macOS 15.0' "${ARGS[@]}" "$APP"

make_app "$APP" "$TMP_ROOT/mind-weak"
expect_refuse 'the wrong bundle version is refused' 'says version 1.2.3, not 9.9.9' \
    --version 9.9.9 --team "$ADHOC_TEAM" "$APP"
expect_refuse 'an app signed by another team is refused' 'not BV6KGKFKP4' \
    --version 1.2.3 --team BV6KGKFKP4 "$APP"

/usr/libexec/PlistBuddy -c 'Add :MCIDevelopmentFileKeyEnabled bool true' "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
expect_refuse 'the development file key is refused' 'development file key' "${ARGS[@]}" "$APP"

make_app "$APP" "$TMP_ROOT/mind-weak"
printf '\n' >>"$APP/Contents/Info.plist"
expect_refuse 'an app changed after signing is refused' 'codesign --verify --deep --strict failed' "${ARGS[@]}" "$APP"

# syspolicy_check: the subcommand asked for, on the app, with --json, and its
# verdict. The stand-in answers as the real one does: exit 0 and no findings,
# or exit 70 and a list with each finding's level (from SYSPOLICY_FINDINGS).
make_app "$APP" "$TMP_ROOT/mind-weak"
cat >"$TMP_ROOT/syspolicy_check" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSPOLICY_CALLS"
case "${SYSPOLICY_FINDINGS:-none}" in
    none) printf '{"output": []}\n'; exit 0 ;;
    warning) level=Warning; short="Incorrect Bundle Structure" ;;
    fatal) level=Fatal; short="Notary Ticket Missing" ;;
esac
printf '{"output": [{"SyspolicyCheckErrorLevel": "%s", "SyspolicyCheckShortError": "%s", "SyspolicyCheckErrorFile": "%s"}]}\n' \
    "$level" "$short" "$3"
exit 70
FAKE
chmod +x "$TMP_ROOT/syspolicy_check"
export HIPPOCAMPUS_SYSPOLICY_CHECK="$TMP_ROOT/syspolicy_check"
export SYSPOLICY_CALLS="$TMP_ROOT/syspolicy.calls"
: >"$SYSPOLICY_CALLS"
expect_accept 'an app syspolicy_check distribution accepts is accepted' \
    "${ARGS[@]}" --gatekeeper distribution "$APP"
if [[ "$(cat "$SYSPOLICY_CALLS")" == "distribution --json $APP" ]]; then
    pass 'syspolicy_check runs distribution on the app'
else
    fail 'syspolicy_check runs distribution on the app'
fi
: >"$SYSPOLICY_CALLS"
expect_accept 'a not-yet-notarized app is checked as a notary submission' \
    "${ARGS[@]}" --gatekeeper notary-submission "$APP"
if [[ "$(cat "$SYSPOLICY_CALLS")" == "notary-submission --json $APP" ]]; then
    pass 'syspolicy_check runs notary-submission on the app'
else
    fail 'syspolicy_check runs notary-submission on the app'
fi
: >"$SYSPOLICY_CALLS"
expect_accept 'without --gatekeeper, syspolicy_check is not run' "${ARGS[@]}" "$APP"
if [[ -s "$SYSPOLICY_CALLS" ]]; then
    fail 'without --gatekeeper, syspolicy_check is not run (it was)'
else
    pass 'without --gatekeeper, syspolicy_check stays unused'
fi
SYSPOLICY_FINDINGS=warning expect_accept 'a notary-submission warning is allowed, and shown' \
    "${ARGS[@]}" --gatekeeper notary-submission "$APP"
if grep -Fq 'warn  syspolicy_check notary-submission: Incorrect Bundle Structure' "$TMP_ROOT/out.log"; then
    pass 'the allowed warning is printed'
else
    cat "$TMP_ROOT/out.log" >&2
    fail 'the allowed warning is printed'
fi
SYSPOLICY_FINDINGS=fatal expect_refuse 'a notary-submission error is refused, with its reason' \
    'Fatal'$'\t''Notary Ticket Missing' "${ARGS[@]}" --gatekeeper notary-submission "$APP"
SYSPOLICY_FINDINGS=warning expect_refuse 'distribution must pass outright: even a warning is refused' \
    'syspolicy_check distribution rejected' "${ARGS[@]}" --gatekeeper distribution "$APP"
SYSPOLICY_FINDINGS=fatal expect_refuse 'an app syspolicy_check distribution rejects is refused, with its reason' \
    'Notary Ticket Missing' "${ARGS[@]}" --gatekeeper distribution "$APP"
if "$VERIFY" "${ARGS[@]}" --gatekeeper sometimes "$APP" >/dev/null 2>&1; then
    fail 'an unknown --gatekeeper mode is a usage error'
else
    pass 'an unknown --gatekeeper mode is a usage error'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
