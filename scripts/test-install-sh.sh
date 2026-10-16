#!/usr/bin/env bash
set -euo pipefail

# test-install-sh.sh — scripts/install.sh against a local fake release.
#
# Serves a release tree on 127.0.0.1 laid out as GitHub's is
# (releases/latest/download/Hippocampus.dmg, releases/download/<tag>/...)
# and runs the real install.sh at it, with a scratch HOME and install
# folder. The fixture app is signed ad hoc, so every run must stop at the
# developer check: what is tested is that install.sh downloads the right
# files, checks them in order, and installs nothing it should not.
#
# With INSTALL_TEST_NOTARIZED_DMG set to a notarized Hippocampus DMG, it also
# runs the whole install from the fake release into the scratch folder:
# checksum, signature, team, Gatekeeper, copy, the mci-agent link and the
# PATH line, twice. The app is copied, never opened.
#
# A stand-in `open`, `pkill` and `pgrep` come first on PATH, so nothing here
# can open an app or signal a process, whatever install.sh does.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$SCRIPT_DIR/install.sh"
TMP_ROOT="$(mktemp -d -t hippocampus-install-sh)"
SERVER_PID=""
cleanup() {
    if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    hdiutil info 2>/dev/null | awk -v root="$TMP_ROOT" 'index($0, root) && $1 ~ /^\/dev\// { print $1 }' \
        | while read -r device; do hdiutil detach "$device" -force -quiet 2>/dev/null || true; done
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# --- Stand-ins that keep the test from touching anything running ---

GUARD_BIN="$TMP_ROOT/guard-bin"
mkdir -p "$GUARD_BIN"
for tool in open pkill; do
    cat >"$GUARD_BIN/$tool" <<GUARD
#!/bin/sh
printf '%s %s\n' "$tool" "\$*" >>"$TMP_ROOT/guard.calls"
exit 1
GUARD
    chmod +x "$GUARD_BIN/$tool"
done
# pgrep finds nothing, as on a Mac where no copy is installed at the test path.
printf '#!/bin/sh\nexit 1\n' >"$GUARD_BIN/pgrep"
chmod +x "$GUARD_BIN/pgrep"

# --- A fixture app and disk images ---

VERSION="9.8.7"
make_app() {
    local app="$1"
    mkdir -p "$app/Contents/MacOS"
    cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Hippocampus</string>
<key>CFBundleIdentifier</key><string>test.hippocampus.install-sh</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
</dict></plist>
PLIST
    printf 'int main(void) { return 0; }\n' >"$TMP_ROOT/main.c"
    xcrun clang -mmacosx-version-min=14.0 "$TMP_ROOT/main.c" -o "$app/Contents/MacOS/Hippocampus"
    cp "$app/Contents/MacOS/Hippocampus" "$app/Contents/MacOS/mci-agent"
    codesign --force --sign - "$app" >/dev/null 2>&1
}

make_dmg() {
    local staging="$1" output="$2"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -srcfolder "$staging" -volname Hippocampus -fs HFS+ -format UDRW \
        -size 20m "$TMP_ROOT/rw.dmg"
    hdiutil convert -quiet "$TMP_ROOT/rw.dmg" -format ULMO -o "$output"
    rm -f "$TMP_ROOT/rw.dmg"
}

publish() {
    # publish DMG TAG: put DMG in the fake release tree as both of its names.
    local dmg="$1" tag="$2" latest tagged
    latest="$WWW/releases/latest/download"
    tagged="$WWW/releases/download/$tag"
    mkdir -p "$latest" "$tagged"
    cp "$dmg" "$latest/Hippocampus.dmg"
    cp "$dmg" "$tagged/Hippocampus-${tag#v}.dmg"
    (cd "$latest" && shasum -a 256 Hippocampus.dmg >Hippocampus.dmg.sha256)
    (cd "$tagged" && shasum -a 256 "Hippocampus-${tag#v}.dmg" >"Hippocampus-${tag#v}.dmg.sha256")
}

WWW="$TMP_ROOT/www"
mkdir -p "$TMP_ROOT/stage-signed" "$TMP_ROOT/stage-empty" "$TMP_ROOT/stage-tampered"
make_app "$TMP_ROOT/stage-signed/Hippocampus.app"
make_dmg "$TMP_ROOT/stage-signed" "$TMP_ROOT/adhoc.dmg"
make_dmg "$TMP_ROOT/stage-empty" "$TMP_ROOT/empty.dmg"
make_app "$TMP_ROOT/stage-tampered/Hippocampus.app"
printf 'changed after signing\n' >>"$TMP_ROOT/stage-tampered/Hippocampus.app/Contents/MacOS/mci-agent"
make_dmg "$TMP_ROOT/stage-tampered" "$TMP_ROOT/tampered.dmg"

mkdir -p "$WWW"
python3 -I -u -m http.server 0 --bind 127.0.0.1 --directory "$WWW" >"$TMP_ROOT/server.log" 2>&1 &
SERVER_PID=$!
PORT=""
for _ in {1..50}; do
    PORT="$(sed -n 's/^Serving HTTP on .* port \([0-9][0-9]*\).*/\1/p' "$TMP_ROOT/server.log" | head -1)"
    [[ -n "$PORT" ]] && break
    sleep 0.1
done
[[ -n "$PORT" ]] || { cat "$TMP_ROOT/server.log" >&2; echo 'FAIL: the fake release server starts' >&2; exit 1; }
RELEASES="http://127.0.0.1:$PORT/releases"

# run_install NAME [VAR=value ...]: install.sh with a scratch HOME and install
# folder, from the fake release.
run_install() {
    local name="$1"; shift
    local home="$TMP_ROOT/home-$name" appdir="$TMP_ROOT/apps-$name"
    mkdir -p "$home" "$appdir"
    env -i HOME="$home" SHELL=/bin/zsh TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 \
        PATH="$GUARD_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        HIPPOCAMPUS_RELEASES_URL="$RELEASES" HIPPOCAMPUS_APPDIR="$appdir" HIPPOCAMPUS_NO_OPEN=1 \
        "$@" sh "$INSTALL" >"$TMP_ROOT/$name.out" 2>&1
}

nothing_installed() {
    local name="$1"
    [[ ! -e "$TMP_ROOT/apps-$name/Hippocampus.app" && ! -e "$TMP_ROOT/home-$name/.hippocampus" \
        && ! -e "$TMP_ROOT/home-$name/.zprofile" ]]
}

expect_refusal() {
    local message="$1" name="$2" reason="$3"; shift 3
    if run_install "$name" "$@"; then
        cat "$TMP_ROOT/$name.out" >&2
        fail "$message (install.sh succeeded)"
    elif ! grep -Fq -- "$reason" "$TMP_ROOT/$name.out"; then
        cat "$TMP_ROOT/$name.out" >&2
        fail "$message (refused, but not because: $reason)"
    elif ! nothing_installed "$name"; then
        fail "$message (it left an app, a link or a PATH line behind)"
    else
        pass "$message"
    fi
}

served() { grep -F "\"GET $1 HTTP" "$TMP_ROOT/server.log" >/dev/null; }

# --- The latest release, by its fixed asset name ---

publish "$TMP_ROOT/adhoc.dmg" "v$VERSION"
expect_refusal 'the latest release downloads, passes its checksum, and an ad-hoc app is refused' \
    latest 'is not signed by the expected developer (BV6KGKFKP4)'
if grep -Fq 'checksum ok' "$TMP_ROOT/latest.out" && grep -Fq "Hippocampus $VERSION" "$TMP_ROOT/latest.out"; then
    pass 'the download is checked, mounted and read before the developer check'
else
    fail 'the download is checked, mounted and read before the developer check'
fi
if served /releases/latest/download/Hippocampus.dmg && served /releases/latest/download/Hippocampus.dmg.sha256; then
    pass 'latest comes from releases/latest/download/Hippocampus.dmg and its checksum'
else
    fail 'latest comes from releases/latest/download/Hippocampus.dmg and its checksum'
fi
if grep -Fq 'api.github.com' "$INSTALL"; then
    fail 'install.sh never asks the GitHub API (rate limited) for the latest tag'
else
    pass 'install.sh never asks the GitHub API (rate limited) for the latest tag'
fi

expect_refusal 'a pinned version downloads that release, and an ad-hoc app is refused' \
    pinned 'is not signed by the expected developer' HIPPOCAMPUS_VERSION="v$VERSION"
if served "/releases/download/v$VERSION/Hippocampus-$VERSION.dmg"; then
    pass 'HIPPOCAMPUS_VERSION fetches releases/download/<tag>/Hippocampus-<version>.dmg'
else
    fail 'HIPPOCAMPUS_VERSION fetches releases/download/<tag>/Hippocampus-<version>.dmg'
fi

# --- What install.sh must refuse ---

printf '%064d  Hippocampus.dmg\n' 0 >"$WWW/releases/latest/download/Hippocampus.dmg.sha256"
expect_refusal 'a DMG that does not match its checksum is refused before it is opened' \
    checksum 'checksum mismatch for Hippocampus.dmg'
if grep -Fq 'Hippocampus 9.8.7' "$TMP_ROOT/checksum.out"; then
    fail 'a DMG with the wrong checksum is never mounted'
else
    pass 'a DMG with the wrong checksum is never mounted'
fi

rm -f "$WWW/releases/latest/download/Hippocampus.dmg.sha256"
expect_refusal 'a release without a checksum file is refused' missing-sha 'could not download'

publish "$TMP_ROOT/empty.dmg" "v$VERSION"
expect_refusal 'a DMG without Hippocampus.app is refused' empty 'does not contain Hippocampus.app'

publish "$TMP_ROOT/tampered.dmg" "v$VERSION"
expect_refusal 'an app changed after signing is refused' tampered 'signature check failed'

expect_refusal 'a local DMG gets the same checks, and fetches nothing' \
    local-dmg 'is not signed by the expected developer' HIPPOCAMPUS_DMG="$TMP_ROOT/adhoc.dmg"
if grep -Fq "Installing Hippocampus from $TMP_ROOT/adhoc.dmg" "$TMP_ROOT/local-dmg.out"; then
    pass 'HIPPOCAMPUS_DMG installs from the given file'
else
    fail 'HIPPOCAMPUS_DMG installs from the given file'
fi

# --- The whole install, from a notarized DMG, when one is given ---

if [[ -n "${INSTALL_TEST_NOTARIZED_DMG:-}" ]]; then
    publish "$INSTALL_TEST_NOTARIZED_DMG" "v$VERSION"
    if run_install notarized; then
        pass 'a notarized DMG from the fake release installs'
    else
        cat "$TMP_ROOT/notarized.out" >&2
        fail 'a notarized DMG from the fake release installs'
    fi
    APP="$TMP_ROOT/apps-notarized/Hippocampus.app"
    if [[ -d "$APP" ]] && codesign --verify --deep --strict "$APP" 2>/dev/null; then
        pass 'the installed copy is the signed app'
    else
        fail 'the installed copy is the signed app'
    fi
    LINK="$TMP_ROOT/home-notarized/.hippocampus/bin/mci-agent"
    if [[ -L "$LINK" && "$(readlink "$LINK")" == "$APP/Contents/MacOS/mci-agent" ]]; then
        pass 'mci-agent is linked into ~/.hippocampus/bin'
    else
        fail 'mci-agent is linked into ~/.hippocampus/bin'
    fi
    if run_install notarized && [[ "$(grep -c 'hippocampus/bin' "$TMP_ROOT/home-notarized/.zprofile")" == 1 ]]; then
        pass 'installing again replaces the app and adds the PATH line only once'
    else
        cat "$TMP_ROOT/notarized.out" >&2
        fail 'installing again replaces the app and adds the PATH line only once'
    fi
else
    echo 'NOTE: set INSTALL_TEST_NOTARIZED_DMG to a notarized Hippocampus DMG to run the whole install too'
fi

if [[ -s "$TMP_ROOT/guard.calls" ]]; then
    cat "$TMP_ROOT/guard.calls" >&2
    fail 'install.sh opened nothing and signalled nothing'
else
    pass 'install.sh opened nothing and signalled nothing'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
