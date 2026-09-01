#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-release-identity.sh"
TMP_ROOT="$(mktemp -d -t hippocampus-release-identity)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

expect_pass() {
    local message="$1"; shift
    if "$@" >"$TMP_ROOT/last.out" 2>&1; then pass "$message"; else
        cat "$TMP_ROOT/last.out" >&2
        fail "$message"
    fi
}

expect_fail() {
    local message="$1"; shift
    if "$@" >"$TMP_ROOT/last.out" 2>&1; then
        cat "$TMP_ROOT/last.out" >&2
        fail "$message"
    else
        pass "$message"
    fi
}

make_fixture() {
    local root="$1"
    mkdir -p "$root/apps/hippocampus/Resources" "$root/dist"
    cat >"$root/apps/hippocampus/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>SUFeedURL</key><string>https://amyjainberkeley.github.io/hippocampus/appcast.xml</string>
<key>SUPublicEDKey</key><string>11qYAYKxCrfVS/7TyWQHOg7hcvPaRiMlrwIaaPcHURo=</string>
</dict></plist>
PLIST
    cat >"$root/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [1.2.3] - 2026-09-01

### Added

- A source-backed memory release.
CHANGELOG
}

ROOT="$TMP_ROOT/repo"
make_fixture "$ROOT"

expect_fail 'prebuild rejects a tag that differs from the bundle version' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v9.9.9

expect_pass 'prebuild accepts one coherent release identity' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v1.2.3

DMG="$ROOT/dist/Hippocampus-1.2.3.dmg"
printf 'synthetic signed disk image' >"$DMG"
(cd "$ROOT/dist" && shasum -a 256 Hippocampus-1.2.3.dmg >Hippocampus-1.2.3.dmg.sha256)
SIGNATURE="$(printf '%0128d' 0 | xxd -r -p | base64 | tr -d '\n')"
SIZE="$(stat -f%z "$DMG")"
cat >"$ROOT/dist/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>42</sparkle:version>
    <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="https://github.com/amyjainberkeley/hippocampus/releases/download/v1.2.3/Hippocampus-1.2.3.dmg"
      sparkle:edSignature="$SIGNATURE" length="$SIZE" type="application/octet-stream" />
  </item></channel>
</rss>
APPCAST

expect_pass 'staged verification accepts matching DMG, checksum, and appcast' \
    "$VERIFY" --repo-root "$ROOT" --phase staged --tag v1.2.3 \
    --dmg "$DMG" --appcast "$ROOT/dist/appcast.xml"

sed -i '' 's|releases/download/v1.2.3|releases/download/v9.9.9|' "$ROOT/dist/appcast.xml"
expect_fail 'staged verification rejects a mismatched enclosure URL' \
    "$VERIFY" --repo-root "$ROOT" --phase staged --tag v1.2.3 \
    --dmg "$DMG" --appcast "$ROOT/dist/appcast.xml"

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
