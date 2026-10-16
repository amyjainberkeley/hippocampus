#!/bin/sh
# Hippocampus one-line install (macOS 14+, Apple silicon).
#
#   curl -fsSL https://github.com/amyjainberkeley/hippocampus/releases/latest/download/install.sh | sh
#
# What it does, in order, and nothing else:
#   1. Downloads the notarized Hippocampus DMG from the latest GitHub release
#      (releases/latest/download/Hippocampus.dmg, so no API call and no rate
#      limit) and checks its SHA-256 against the release's checksum file.
#   2. Verifies Apple's notarization and the Developer ID signature, then
#      copies Hippocampus.app into /Applications (or ~/Applications when
#      /Applications is not writable).
#   3. Links the bundled `mci-agent` command into ~/.hippocampus/bin.
#   4. Opens Hippocampus, which walks you through permissions. Nothing is
#      recorded until you turn capture on there.
#
# It grants no permissions and imports nothing on its own.
#
# Environment overrides:
#   HIPPOCAMPUS_VERSION    release tag to install (default: latest release)
#   HIPPOCAMPUS_DMG        install from a local DMG instead of downloading
#   HIPPOCAMPUS_APPDIR     install directory (default: /Applications)
#   HIPPOCAMPUS_NO_OPEN=1  install without opening the app
#   HIPPOCAMPUS_RELEASES_URL  where releases are (default: this repository's
#                          GitHub releases); a mirror or a local test copy
#                          must serve the same files. The checks below apply
#                          whatever the source.

set -eu

REPO="amyjainberkeley/hippocampus"
RELEASES="${HIPPOCAMPUS_RELEASES_URL:-https://github.com/$REPO/releases}"
BIN_DIR="$HOME/.hippocampus/bin"
TEAM_ID="BV6KGKFKP4"

say() { printf '%s\n' "$*" >&2; }
die() { say "install: $*"; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Hippocampus runs on macOS only."
[ "$(uname -m)" = "arm64" ] || die "Hippocampus needs an Apple silicon Mac (M1 or later)."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || die "Hippocampus needs macOS 14 Sonoma or later (this Mac runs $(sw_vers -productVersion))."
for tool in curl shasum hdiutil codesign spctl ditto; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

TMP="$(mktemp -d)"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

if [ -n "${HIPPOCAMPUS_DMG:-}" ]; then
  DMG="$HIPPOCAMPUS_DMG"
  [ -f "$DMG" ] || die "no DMG at $DMG"
  say "Installing Hippocampus from $DMG"
else
  if [ -n "${HIPPOCAMPUS_VERSION:-}" ]; then
    TAG="$HIPPOCAMPUS_VERSION"
    ASSET="Hippocampus-${TAG#v}.dmg"
    BASE="$RELEASES/download/$TAG"
    say "Downloading Hippocampus ${TAG#v}"
  else
    # Every release also carries its DMG under this fixed name.
    ASSET="Hippocampus.dmg"
    BASE="$RELEASES/latest/download"
    say "Downloading the latest Hippocampus"
  fi
  DMG="$TMP/$ASSET"

  # Redirects (GitHub sends downloads to its asset host) stay on HTTPS.
  curl -fL --proto-redir '=https' --progress-bar -o "$DMG" "$BASE/$ASSET" \
    || die "could not download $BASE/$ASSET"
  curl -fsSL --proto-redir '=https' -o "$TMP/$ASSET.sha256" "$BASE/$ASSET.sha256" \
    || die "could not download $BASE/$ASSET.sha256"
  EXPECTED="$(awk '{print $1; exit}' "$TMP/$ASSET.sha256")"
  ACTUAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  [ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] \
    || die "checksum mismatch for $ASSET (expected $EXPECTED, got $ACTUAL)"
  say "  checksum ok"
fi

MOUNT="$TMP/mount"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet \
  || die "could not open the DMG"
SRC="$MOUNT/Hippocampus.app"
[ -d "$SRC" ] || die "the DMG does not contain Hippocampus.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist" 2>/dev/null || echo unknown)"
say "  Hippocampus $APP_VERSION"

# Refuse anything that is not this developer's notarized build.
codesign --verify --deep --strict "$SRC" 2>/dev/null || die "signature check failed"
codesign -dv "$SRC" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" \
  || die "Hippocampus.app is not signed by the expected developer ($TEAM_ID)"
spctl --assess --type execute "$SRC" 2>/dev/null || die "Gatekeeper rejected Hippocampus.app"
say "  signature and notarization ok"

APPDIR="${HIPPOCAMPUS_APPDIR:-/Applications}"
if [ ! -w "$APPDIR" ]; then
  APPDIR="$HOME/Applications"
  mkdir -p "$APPDIR"
fi
DEST="$APPDIR/Hippocampus.app"

# Quit the running app. Its helpers share the bundle identifier, so address
# the main process directly; SIGTERM is a graceful quit from 0.2.1 on, and
# older versions' helpers stop with it.
if pgrep -f "$DEST/Contents/MacOS/Hippocampus$" >/dev/null 2>&1; then
  say "  quitting the running copy"
  pkill -TERM -f "$DEST/Contents/MacOS/Hippocampus$" || true
  i=0
  while pgrep -f "$DEST/Contents/MacOS/(Hippocampus|MCICaptureHelper|recall-ui|onboarding)" >/dev/null 2>&1 \
      && [ "$i" -lt 40 ]; do
    sleep 0.5
    i=$((i + 1))
  done
  pgrep -f "$DEST/Contents/MacOS/(Hippocampus|MCICaptureHelper|recall-ui|onboarding)" >/dev/null 2>&1 \
    && die "Hippocampus is still running; quit it from the menu bar and run this again"
fi

# Copy beside the destination, then swap, so a failed copy never leaves a
# half-installed app. Your memory lives in ~/Library and is not touched.
STAGE="$APPDIR/.Hippocampus.app.installing"
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
say "  installed $DEST"

mkdir -p "$BIN_DIR"
ln -sf "$DEST/Contents/MacOS/mci-agent" "$BIN_DIR/mci-agent"
case ":$PATH:" in
  *":$BIN_DIR:"*) say "  mci-agent is on your PATH" ;;
  *)
    case "${SHELL:-}" in
      */zsh) PROFILE="$HOME/.zprofile" ;;
      */bash) PROFILE="$HOME/.bash_profile" ;;
      *) PROFILE="" ;;
    esac
    LINE='export PATH="$HOME/.hippocampus/bin:$PATH"'
    if [ -n "$PROFILE" ]; then
      grep -qsF "$LINE" "$PROFILE" || printf '\n# Hippocampus\n%s\n' "$LINE" >> "$PROFILE"
      say "  added ~/.hippocampus/bin to your PATH in $PROFILE (new terminals)"
    else
      say "  command line: add  $LINE  to your shell profile"
    fi
    ;;
esac

if [ "${HIPPOCAMPUS_NO_OPEN:-0}" != "1" ]; then
  open "$DEST"
  say ""
  say "Hippocampus is open. Follow the setup window to choose what it may remember."
else
  say "done. Open $DEST to finish setup."
fi
