#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-release-identity.sh"
TMP_ROOT="$(mktemp -d -t hippocampus-release-identity)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FEED_URL='https://github.com/amyjainberkeley/hippocampus/releases/latest/download/appcast.xml'
PAGES_FEED_URL='https://amyjainberkeley.github.io/hippocampus/appcast.xml'

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

# Fails, and for the stated reason: a negative case must not pass because
# some other check happened to trip first.
expect_fail_because() {
    local message="$1" reason="$2"; shift 2
    if "$@" >"$TMP_ROOT/last.out" 2>&1; then
        cat "$TMP_ROOT/last.out" >&2
        fail "$message"
    elif grep -Fq -- "$reason" "$TMP_ROOT/last.out"; then
        pass "$message"
    else
        cat "$TMP_ROOT/last.out" >&2
        fail "$message (failed, but not because: $reason)"
    fi
}

# RFC 8032 test vector 1: a published key pair, never a release key.
SEED_HEX="9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
PUBLIC_KEY="$(printf '%s' d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a | xxd -r -p | base64 | tr -d '\n')"
OTHER_SEED_HEX="4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"

cat >"$TMP_ROOT/sign.swift" <<'SWIFT'
import CryptoKit
import Foundation

// usage: sign.swift SEED_HEX FILE -> base64 Ed25519 signature of FILE
let hex = Array(CommandLine.arguments[1].utf8)
var seed = Data()
var index = 0
while index + 1 < hex.count {
    seed.append(UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16)!)
    index += 2
}
let message = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(try key.signature(for: message).base64EncodedString())
SWIFT
xcrun swiftc -O "$TMP_ROOT/sign.swift" -o "$TMP_ROOT/sign" >/dev/null

sign_with() { "$TMP_ROOT/sign" "$1" "$2"; }

# Write OUTPUT as Sparkle's sign_update writes a signed feed: the feed's
# bytes, then a comment carrying the signature over exactly those bytes.
sign_feed() {
    local seed="$1" body="$2" output="$3" signature length
    signature="$(sign_with "$seed" "$body")"
    length="$(stat -f%z "$body")"
    cp "$body" "$output"
    printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' "$signature" "$length" >>"$output"
}

make_fixture() {
    local root="$1"
    mkdir -p "$root/apps/hippocampus/Resources" "$root/dist" "$root/docs"
    cat >"$root/apps/hippocampus/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>SUFeedURL</key><string>$FEED_URL</string>
<key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
</dict></plist>
PLIST
    cat >"$root/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [1.2.3] - 2026-09-01

### Added

- A source-backed memory release.
CHANGELOG
    cat >"$root/release-models.json" <<'MODELS'
{
  "schemaVersion": 1,
  "releaseVersion": "1.2.3",
  "archiveURL": "https://github.com/amyjainberkeley/hippocampus-models/releases/download/v1.2.3/release-models-1.2.3.tar.gz",
  "archiveSHA256": "abababababababababababababababababababababababababababababababab",
  "models": [
    {"id": "arctic-embed-s-fp16", "bundle": "ArcticEmbedS_FP16.mlmodelc"}
  ]
}
MODELS
    git -C "$root" init -q
    git -C "$root" config user.name 'Release Fixture'
    git -C "$root" config user.email 'release-fixture@example.invalid'
    git -C "$root" add apps CHANGELOG.md release-models.json
    git -C "$root" commit -qm 'fixture release inputs'
    local baseline
    baseline="$(git -C "$root" rev-parse HEAD)"
    cat >"$root/docs/STATUS.md" <<STATUS
# Hippocampus Status

Audited code baseline: \`$baseline\`
STATUS
    git -C "$root" add docs/STATUS.md
    git -C "$root" commit -qm 'fixture status audit'
}

ROOT="$TMP_ROOT/repo"
PLIST="$ROOT/apps/hippocampus/Resources/Info.plist"
make_fixture "$ROOT"

expect_fail 'prebuild rejects a tag that differs from the bundle version' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v9.9.9

expect_pass 'prebuild accepts one coherent release identity' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v1.2.3

sed -i '' "s|$FEED_URL|$PAGES_FEED_URL|" "$PLIST"
expect_fail_because 'prebuild rejects the old GitHub Pages feed, which nothing serves' \
    'SUFeedURL must match publication target' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v1.2.3
sed -i '' "s|$PAGES_FEED_URL|$FEED_URL|" "$PLIST"

sed -i '' 's|abababababababababababababababababababababababababababababababab|UNPROVISIONED|' \
    "$ROOT/release-models.json"
expect_fail 'prebuild rejects an unprovisioned tag-owned model manifest' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v1.2.3
sed -i '' 's|UNPROVISIONED|abababababababababababababababababababababababababababababababab|' \
    "$ROOT/release-models.json"

for index in 1 2 3; do
    git -C "$ROOT" commit --allow-empty -qm "stale fixture $index"
done
expect_fail 'prebuild rejects a status audit more than three commits behind' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v1.2.3
git -C "$ROOT" reset --hard -q HEAD~3

DMG="$ROOT/dist/Hippocampus-1.2.3.dmg"
APPCAST="$ROOT/dist/appcast.xml"
BODY="$TMP_ROOT/appcast-body.xml"
printf 'synthetic signed disk image' >"$DMG"
(cd "$ROOT/dist" && shasum -a 256 Hippocampus-1.2.3.dmg >Hippocampus-1.2.3.dmg.sha256)
SIGNATURE="$(sign_with "$SEED_HEX" "$DMG")"
SIZE="$(stat -f%z "$DMG")"

write_body() {
    local signature="$1" size="$2" tag="$3"
    cat >"$BODY" <<APPCAST
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>42</sparkle:version>
    <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <enclosure url="https://github.com/amyjainberkeley/hippocampus/releases/download/$tag/Hippocampus-1.2.3.dmg"
      sparkle:edSignature="$signature" length="$size" type="application/octet-stream" />
  </item></channel>
</rss>
APPCAST
}

staged() {
    "$VERIFY" --repo-root "$ROOT" --phase staged --tag v1.2.3 --dmg "$DMG" --appcast "$APPCAST"
}

write_body "$SIGNATURE" "$SIZE" v1.2.3
sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
expect_pass 'staged verification accepts matching DMG, checksum, and signed appcast' staged

ZERO_SIGNATURE="$(printf '%0128d' 0 | xxd -r -p | base64 | tr -d '\n')"
write_body "$ZERO_SIGNATURE" "$SIZE" v1.2.3
sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
expect_fail_because 'staged verification rejects a shape-valid zero signature' \
    'does not authenticate the exact DMG bytes' staged

printf 'x' >>"$DMG"
(cd "$ROOT/dist" && shasum -a 256 Hippocampus-1.2.3.dmg >Hippocampus-1.2.3.dmg.sha256)
write_body "$SIGNATURE" "$(stat -f%z "$DMG")" v1.2.3
sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
expect_fail_because 'staged verification rejects a one-byte DMG mutation with a refreshed checksum' \
    'does not authenticate the exact DMG bytes' staged
printf 'synthetic signed disk image' >"$DMG"
(cd "$ROOT/dist" && shasum -a 256 Hippocampus-1.2.3.dmg >Hippocampus-1.2.3.dmg.sha256)

write_body "$SIGNATURE" "$SIZE" v1.2.3
sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
sed -i '' "s|$PUBLIC_KEY|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=|" "$PLIST"
expect_fail_because 'staged verification rejects a mismatched public key' \
    'does not authenticate the exact DMG bytes' staged
sed -i '' "s|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=|$PUBLIC_KEY|" "$PLIST"

write_body "$SIGNATURE" "$SIZE" v9.9.9
sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
expect_fail_because 'staged verification rejects a mismatched enclosure URL' \
    'appcast enclosure URL must be' staged

# The feed itself: signed with the release key, over every byte, at the end.
write_body "$SIGNATURE" "$SIZE" v1.2.3
cp "$BODY" "$APPCAST"
expect_fail_because 'staged verification rejects an appcast with no feed signature' \
    'must end with exactly one Sparkle feed signature' staged

sign_feed "$OTHER_SEED_HEX" "$BODY" "$APPCAST"
expect_fail_because 'staged verification rejects a feed signed by another key' \
    'feed signature does not verify with SUPublicEDKey' staged

sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
sed -i '' 's|<sparkle:version>42</sparkle:version>|<sparkle:version>43</sparkle:version>|' "$APPCAST"
sed -i '' "s|<string>42</string>|<string>43</string>|" "$PLIST"
expect_fail_because 'staged verification rejects a feed changed after it was signed' \
    'feed signature does not verify with SUPublicEDKey' staged
sed -i '' "s|<string>43</string>|<string>42</string>|" "$PLIST"

sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
sed -i '' 's|^length: \([0-9]*\)$|length: 100|' "$APPCAST"
expect_fail_because 'staged verification rejects a feed signature that covers only part of the feed' \
    'does not cover every byte before it' staged

sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
printf '<!-- trailing -->\n' >>"$APPCAST"
expect_fail_because 'staged verification rejects bytes after the feed signature' \
    'not at the end of the file' staged

sign_feed "$SEED_HEX" "$BODY" "$APPCAST"
expect_pass 'staged verification accepts the re-signed feed again' staged

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
