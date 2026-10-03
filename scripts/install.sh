#!/usr/bin/env bash
# Hippocampus one-command install (macOS, Apple Silicon and Intel).
#
#   curl -fsSL https://github.com/amyjainberkeley/hippocampus/releases/latest/download/install.sh | sh
#
# What it does, in order, and nothing else:
#   1. Downloads the signed `mci-agent` binary for your CPU from the latest
#      GitHub release and checks its SHA-256 against the release's checksum file.
#   2. Puts it in ~/.hippocampus/bin and links it into /usr/local/bin if that
#      directory is writable (otherwise tells you the PATH line to add).
#   3. Runs `mci-agent init`, which creates an encrypted brain in
#      ~/Library/Application Support/MCI, imports the Claude Code and Codex
#      transcripts already on this Mac, and installs the SessionStart hooks so
#      your next Claude Code or Codex session starts with a handoff packet.
#
# It asks for no permissions. It does not start screen capture; that is the
# separate Hippocampus.app, which you can add later.
#
# Environment overrides:
#   HIPPOCAMPUS_VERSION   tag to install (default: latest release)
#   HIPPOCAMPUS_PREFIX    install dir (default: ~/.hippocampus)
#   HIPPOCAMPUS_NO_INIT=1 download only, skip `mci-agent init`

set -euo pipefail

REPO="amyjainberkeley/hippocampus"
PREFIX="${HIPPOCAMPUS_PREFIX:-$HOME/.hippocampus}"
BIN_DIR="$PREFIX/bin"

say() { printf '%s\n' "$*" >&2; }
die() { say "install: $*"; exit 1; }

case "$(uname -s)" in
  Darwin) ;;
  *) die "Hippocampus runs on macOS only (SQLCipher brain, Core ML embedder, Keychain key)." ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  TARGET="aarch64-apple-darwin" ;;
  x86_64) TARGET="x86_64-apple-darwin" ;;
  *) die "unsupported CPU: $ARCH" ;;
esac

command -v curl >/dev/null || die "curl is required"
command -v shasum >/dev/null || die "shasum is required"

if [ -n "${HIPPOCAMPUS_VERSION:-}" ]; then
  TAG="$HIPPOCAMPUS_VERSION"
else
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$TAG" ] || die "could not resolve the latest release tag; set HIPPOCAMPUS_VERSION"
fi

ASSET="mci-agent-$TAG-$TARGET.tar.gz"
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Hippocampus $TAG for $TARGET"
say "  downloading $ASSET"
curl -fsSL -o "$TMP/$ASSET" "$BASE/$ASSET"
curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"

EXPECTED="$(grep " $ASSET\$" "$TMP/SHA256SUMS" | awk '{print $1}')"
[ -n "$EXPECTED" ] || die "no checksum for $ASSET in SHA256SUMS"
ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch for $ASSET (expected $EXPECTED, got $ACTUAL)"
say "  checksum ok"

mkdir -p "$BIN_DIR"
tar -xzf "$TMP/$ASSET" -C "$TMP"
install -m 0755 "$TMP/mci-agent" "$BIN_DIR/mci-agent"
# The binary is signed with a Developer ID; a curl download carries no
# quarantine flag, so Gatekeeper does not prompt. Verify the signature anyway.
if command -v codesign >/dev/null; then
  codesign --verify --strict "$BIN_DIR/mci-agent" 2>/dev/null && say "  signature ok" || say "  warning: signature check failed; the binary may be unsigned"
fi

if [ -w /usr/local/bin ]; then
  ln -sf "$BIN_DIR/mci-agent" /usr/local/bin/mci-agent
  say "  linked /usr/local/bin/mci-agent"
else
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "  add to your shell profile:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
fi

if [ "${HIPPOCAMPUS_NO_INIT:-0}" = "1" ]; then
  say "done (init skipped). Run: $BIN_DIR/mci-agent init"
  exit 0
fi

say ""
say "Setting up your brain and connecting your agents:"
exec "$BIN_DIR/mci-agent" init
