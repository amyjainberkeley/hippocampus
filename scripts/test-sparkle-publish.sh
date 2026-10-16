#!/usr/bin/env bash
set -euo pipefail

# test-sparkle-publish.sh — The appcast a release uploads is one the app's own
# Sparkle accepts.
#
# Runs the real scripts/sparkle-publish.sh, with the real sign_update, on a
# synthetic DMG and a published test key (RFC 8032), then serves the appcast
# on 127.0.0.1 and asks Sparkle itself (scripts/sparkle_feed_probe.swift,
# linked against the app's Sparkle.framework) what an installed copy would
# make of it. Nothing is downloaded, installed or launched, and no release key
# is read.
#
# Needs Sparkle's tools from the app's resolved packages
# (apps/hippocampus/.build/artifacts/sparkle). Without them it exits 42, which
# scripts/check.sh reports as SKIP; with SPARKLE_PUBLISH_TEST_REQUIRE_TOOLS=1
# (CI) that is a failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS="$REPO_ROOT/apps/hippocampus/.build/artifacts/sparkle/Sparkle"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$ARTIFACTS/bin/sign_update}"
SPARKLE_SLICE="${SPARKLE_FRAMEWORK_DIR:-$ARTIFACTS/Sparkle.xcframework/macos-arm64_x86_64}"

if [[ ! -x "$SIGN_UPDATE" || ! -d "$SPARKLE_SLICE/Sparkle.framework" ]]; then
    echo "[skip] Sparkle's sign_update and framework are not here; resolve them with:"
    echo "       scripts/swift-package.sh build --package-path apps/hippocampus"
    if [[ "${SPARKLE_PUBLISH_TEST_REQUIRE_TOOLS:-0}" == "1" ]]; then exit 1; fi
    exit 42
fi

TMP_ROOT="$(mktemp -d -t hippocampus-sparkle-publish)"
SERVER_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check() {
    local message="$1"; shift
    if "$@" >>"$TMP_ROOT/check.log" 2>&1; then pass "$message"; else fail "$message"; fi
}

# RFC 8032 test vector 1: a published key pair, never a release key.
SEED_HEX="9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
PUBLIC_KEY="$(printf '%s' d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a | xxd -r -p | base64 | tr -d '\n')"
KEY="$TMP_ROOT/test-private.key"
printf '%s' "$SEED_HEX" | xxd -r -p | base64 | tr -d '\n' >"$KEY"
chmod 600 "$KEY"

# A stand-in repository: sparkle-publish.sh reads Info.plist and CHANGELOG.md
# from the repository it sits in.
FIXTURE="$TMP_ROOT/repo"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/apps/hippocampus/Resources" "$FIXTURE/dist"
cp "$SCRIPT_DIR/sparkle-publish.sh" "$FIXTURE/scripts/"
set_release() {
    local version="$1" build="$2"
    cat >"$FIXTURE/apps/hippocampus/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
</dict></plist>
PLIST
}
cat >"$FIXTURE/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [Unreleased]

## [1.2.4] - 2026-10-20

### Ask

- Answers name the window they came from.

## [1.2.3] - 2026-10-15

### Reading

- Code keeps its indentation & chats keep their order; <tags> stay text.

## [1.2.2] - 2026-10-01

- Older notes.
CHANGELOG

DIST="$TMP_ROOT/out"
APPCAST="$DIST/appcast.xml"
DMG="$FIXTURE/dist/Hippocampus-1.2.3.dmg"
head -c 70000 /dev/urandom >"$DMG"

publish() {
    SPARKLE_SIGN_UPDATE="$SIGN_UPDATE" "$FIXTURE/scripts/sparkle-publish.sh" \
        --private-key "$KEY" --dist "$DIST" --appcast "$APPCAST" --no-confirm "$@"
}

set_release 1.2.3 42
check 'sparkle-publish writes an appcast for the DMG from its CHANGELOG section' \
    publish --dmg "$DMG" --changelog-notes

ENCLOSURE_URL="https://github.com/amyjainberkeley/hippocampus/releases/download/v1.2.3/Hippocampus-1.2.3.dmg"
check 'the appcast is well-formed XML' xmllint --noout "$APPCAST"
check 'the appcast carries a feed signature that sign_update verifies' \
    "$SIGN_UPDATE" --verify -f "$KEY" "$APPCAST"
check 'the enclosure points at this version on GitHub Releases' \
    grep -Fq "url=\"$ENCLOSURE_URL\"" "$APPCAST"
check 'the enclosure length is the DMG size' \
    grep -Fq "length=\"$(stat -f%z "$DMG")\"" "$APPCAST"
check 'the notes are the CHANGELOG section, shown as Markdown' \
    grep -Fq 'Code keeps its indentation & chats keep their order; <tags> stay text.' "$APPCAST"
check 'the notes are marked as Markdown for Sparkle' \
    grep -Fq 'sparkle:format="markdown"' "$APPCAST"
if grep -Fq 'Older notes.' "$APPCAST" || grep -Fq 'Answers name the window' "$APPCAST"; then
    fail 'the notes hold only this version'
else
    pass 'the notes hold only this version'
fi
check 'the feed links to the project, not a parked domain' \
    grep -Fq '<link>https://github.com/amyjainberkeley/hippocampus</link>' "$APPCAST"
if grep -Fq 'hippocampus.ai' "$APPCAST"; then
    fail 'the feed names no hippocampus.ai address'
else
    pass 'the feed names no hippocampus.ai address'
fi
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST" | head -1)"
check 'the enclosure signature authenticates the DMG under the app public key' \
    "$SCRIPT_DIR/verify-sparkle-signature.sh" --file "$DMG" --signature "$SIGNATURE" --public-key "$PUBLIC_KEY"

# --- Sparkle as the judge ---

PROBE="$TMP_ROOT/sparkle_feed_probe"
if ! xcrun swiftc -O -F "$SPARKLE_SLICE" -framework Sparkle \
    -Xlinker -rpath -Xlinker "$SPARKLE_SLICE" \
    "$SCRIPT_DIR/sparkle_feed_probe.swift" -o "$PROBE" >"$TMP_ROOT/probe-build.log" 2>&1; then
    cat "$TMP_ROOT/probe-build.log" >&2
    fail 'the Sparkle feed probe builds against the app Sparkle.framework'
    printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
    exit 1
fi

WWW="$TMP_ROOT/www"
mkdir -p "$WWW"
SERVER_LOG="$TMP_ROOT/server.log"
python3 -I -u -m http.server 0 --bind 127.0.0.1 --directory "$WWW" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in {1..50}; do
    PORT="$(sed -n 's/^Serving HTTP on .* port \([0-9][0-9]*\).*/\1/p' "$SERVER_LOG" | head -1)"
    [[ -n "$PORT" ]] && break
    sleep 0.1
done
[[ -n "$PORT" ]] || { cat "$SERVER_LOG" >&2; echo 'FAIL: a loopback server for the feed starts' >&2; exit 1; }

# A stand-in for the installed app: an older build with the shipped updater
# settings, or (strict) one that also requires a signed feed.
make_host() {
    local name="$1" build="$2" strict="$3" plist
    plist="$TMP_ROOT/hosts/$name/Probe.app/Contents/Info.plist"
    mkdir -p "$(dirname "$plist")" "$TMP_ROOT/homes/$name"
    cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.hippocampus.sparkle-feed-probe.$name</string>
<key>CFBundleName</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.$build</string>
<key>CFBundleVersion</key><string>$build</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
PLIST
    if [[ "$strict" == "strict" ]]; then
        printf '<key>SURequireSignedFeed</key><true/>\n<key>SUVerifyUpdateBeforeExtraction</key><true/>\n' >>"$plist"
    fi
    printf '</dict></plist>\n' >>"$plist"
}

probe() {
    local host="$1" feed="$2" output="$3"
    env -i HOME="$TMP_ROOT/homes/$host" CFFIXED_USER_HOME="$TMP_ROOT/homes/$host" \
        PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" \
        "$PROBE" "$TMP_ROOT/hosts/$host/Probe.app" "http://127.0.0.1:$PORT/$feed" >"$output" 2>&1
}

expect_probe() {
    local message="$1" host="$2" feed="$3" status="$4"; shift 4
    local output="$TMP_ROOT/probe-$host-$feed.out" actual=0 line
    probe "$host" "$feed" "$output" || actual=$?
    if [[ "$actual" -ne "$status" ]]; then
        cat "$output" >&2
        fail "$message (Sparkle exited $actual, expected $status)"
        return
    fi
    for line in "$@"; do
        if ! grep -Fxq -- "$line" "$output"; then
            cat "$output" >&2
            fail "$message (missing: $line)"
            return
        fi
    done
    pass "$message"
}

make_host shipped 41 shipped
make_host strict 41 strict
make_host current 42 shipped

cp "$APPCAST" "$WWW/appcast.xml"
expect_probe 'Sparkle finds 1.2.3 for an older install, with Markdown notes and the GitHub DMG' \
    shipped appcast.xml 0 \
    'found: 1.2.3 build 42' "enclosure: $ENCLOSURE_URL" \
    'description-format: markdown' 'minimum-system: 14.0'
expect_probe 'Sparkle validates the feed signature when an app requires signed feeds' \
    strict appcast.xml 0 'appcast-signing: 1' 'found: 1.2.3 build 42'
expect_probe 'Sparkle reports an install of the same build as up to date' \
    current appcast.xml 3

sed 's|<title>Hippocampus 1.2.3</title>|<title>Hippocampus 1.2.3 (changed)</title>|' "$APPCAST" >"$WWW/tampered.xml"
expect_probe 'Sparkle rejects a feed changed after signing, when it checks feeds' \
    strict tampered.xml 4

# --- A second release merges into the same signed appcast ---

check 'sparkle-publish replaces its own item when run again' \
    publish --dmg "$DMG" --changelog-notes
check 'the re-signed appcast still verifies' "$SIGN_UPDATE" --verify -f "$KEY" "$APPCAST"
if [[ "$(grep -c '<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>' "$APPCAST")" == 1 \
    && "$(grep -c '<!-- sparkle-signatures:' "$APPCAST")" == 1 ]]; then
    pass 'a re-run leaves one 1.2.3 item and one feed signature'
else
    fail 'a re-run leaves one 1.2.3 item and one feed signature'
fi

set_release 1.2.4 43
DMG_NEXT="$FIXTURE/dist/Hippocampus-1.2.4.dmg"
head -c 70000 /dev/urandom >"$DMG_NEXT"
check 'sparkle-publish adds 1.2.4 to the signed 1.2.3 appcast' \
    publish --dmg "$DMG_NEXT" --changelog-notes
check 'the merged appcast is well-formed and its signature verifies' \
    "$SIGN_UPDATE" --verify -f "$KEY" "$APPCAST"
cp "$APPCAST" "$WWW/merged.xml"
expect_probe 'Sparkle offers the newest release from the merged feed' \
    strict merged.xml 0 'appcast-items: 2' 'appcast-signing: 1' 'found: 1.2.4 build 43'

# --- Refusals ---

chmod 644 "$KEY"
if publish --dmg "$DMG_NEXT" --changelog-notes >"$TMP_ROOT/refuse.out" 2>&1; then
    fail 'a private key others can read is refused'
elif grep -Fq 'chmod 600' "$TMP_ROOT/refuse.out"; then
    pass 'a private key others can read is refused'
else
    cat "$TMP_ROOT/refuse.out" >&2
    fail 'a private key others can read is refused'
fi
chmod 600 "$KEY"
cp "$DMG" "$FIXTURE/dist/Hippocampus-9.9.9.dmg"
if publish --dmg "$FIXTURE/dist/Hippocampus-9.9.9.dmg" --changelog-notes >"$TMP_ROOT/refuse.out" 2>&1; then
    fail 'a version with no CHANGELOG notes is refused'
else
    pass 'a version with no CHANGELOG notes is refused'
fi
printf 'notes' >"$TMP_ROOT/notes.rtf"
if publish --dmg "$DMG_NEXT" --release-notes "$TMP_ROOT/notes.rtf" >"$TMP_ROOT/refuse.out" 2>&1; then
    fail 'notes in a format Sparkle cannot show are refused'
else
    pass 'notes in a format Sparkle cannot show are refused'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
    cat "$TMP_ROOT/check.log" >&2
    exit 1
fi
