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
    mkdir -p "$root/apps/hippocampus/Resources" "$root/dist" "$root/docs"
    cat >"$root/apps/hippocampus/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>SUFeedURL</key><string>https://amyjainberkeley.github.io/hippocampus/appcast.xml</string>
<key>SUPublicEDKey</key><string>11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=</string>
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
    {"id": "arctic-embed-s-int8", "bundle": "ArcticEmbedS_INT8.mlmodelc"},
    {"id": "bert-base-ner-int8", "bundle": "bert_base_NER_INT8.mlmodelc"},
    {"id": "qwen3-1.7b-fp16", "bundle": "Qwen3-1.7B-FP16.mlmodelc"}
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
make_fixture "$ROOT"

expect_fail 'prebuild rejects a tag that differs from the bundle version' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v9.9.9

expect_pass 'prebuild accepts one coherent release identity' \
    "$VERIFY" --repo-root "$ROOT" --phase prebuild --tag v1.2.3

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
printf 'synthetic signed disk image' >"$DMG"
(cd "$ROOT/dist" && shasum -a 256 Hippocampus-1.2.3.dmg >Hippocampus-1.2.3.dmg.sha256)
SIGNATURE='IHZFOR4ggvM83HDgB8gsxbyIZZb/RCpIsRXmgC3xZ7TNPegZdJk0ZUk/ntDpkBYh9SPExcTf1IJOZe96gNc5Ag=='
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

ZERO_SIGNATURE="$(printf '%0128d' 0 | xxd -r -p | base64 | tr -d '\n')"
sed -i '' "s|$SIGNATURE|$ZERO_SIGNATURE|" "$ROOT/dist/appcast.xml"
expect_fail 'staged verification rejects a shape-valid zero signature' \
    "$VERIFY" --repo-root "$ROOT" --phase staged --tag v1.2.3 \
    --dmg "$DMG" --appcast "$ROOT/dist/appcast.xml"
sed -i '' "s|$ZERO_SIGNATURE|$SIGNATURE|" "$ROOT/dist/appcast.xml"

printf 'x' >>"$DMG"
(cd "$ROOT/dist" && shasum -a 256 Hippocampus-1.2.3.dmg >Hippocampus-1.2.3.dmg.sha256)
MUTATED_SIZE="$(stat -f%z "$DMG")"
sed -i '' "s|length=\"$SIZE\"|length=\"$MUTATED_SIZE\"|" "$ROOT/dist/appcast.xml"
expect_fail 'staged verification rejects a one-byte DMG mutation with a refreshed checksum' \
    "$VERIFY" --repo-root "$ROOT" --phase staged --tag v1.2.3 \
    --dmg "$DMG" --appcast "$ROOT/dist/appcast.xml"
printf 'synthetic signed disk image' >"$DMG"
(cd "$ROOT/dist" && shasum -a 256 Hippocampus-1.2.3.dmg >Hippocampus-1.2.3.dmg.sha256)
sed -i '' "s|length=\"$MUTATED_SIZE\"|length=\"$SIZE\"|" "$ROOT/dist/appcast.xml"

sed -i '' 's|11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=|' \
    "$ROOT/apps/hippocampus/Resources/Info.plist"
expect_fail 'staged verification rejects a mismatched public key' \
    "$VERIFY" --repo-root "$ROOT" --phase staged --tag v1.2.3 \
    --dmg "$DMG" --appcast "$ROOT/dist/appcast.xml"
sed -i '' 's|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=|11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=|' \
    "$ROOT/apps/hippocampus/Resources/Info.plist"

sed -i '' 's|releases/download/v1.2.3|releases/download/v9.9.9|' "$ROOT/dist/appcast.xml"
expect_fail 'staged verification rejects a mismatched enclosure URL' \
    "$VERIFY" --repo-root "$ROOT" --phase staged --tag v1.2.3 \
    --dmg "$DMG" --appcast "$ROOT/dist/appcast.xml"

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
