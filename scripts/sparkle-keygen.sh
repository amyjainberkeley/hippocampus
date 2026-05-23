#!/usr/bin/env bash
set -euo pipefail

# sparkle-keygen.sh — Mint a Sparkle 2.x Ed25519 (EdDSA) signing keypair for
# Hippocampus auto-update integrity.
#
# What it does:
#   1. Locates Sparkle's generate_keys binary (same lookup as sparkle-publish.sh).
#   2. Mints a fresh Ed25519 keypair via Sparkle's official tooling.
#   3. Writes the PRIVATE key to ~/.hippocampus-sparkle-private.key with mode 0600
#      and a sibling .README file containing the do-not-commit warning + storage
#      procedure (the private key file itself stays pure base64 so sign_update
#      can `cat` it directly).
#   4. Writes the PUBLIC key to stdout AND to ~/.hippocampus-sparkle-public.key.
#      Paste the public key into apps/hippocampus/Resources/Info.plist as
#      <key>SUPublicEDKey</key><string>...</string>.
#
# Usage:
#   ./scripts/sparkle-keygen.sh           # mint a fresh key (refuses if file exists)
#   ./scripts/sparkle-keygen.sh --help
#
# === SECURITY ===
#
# The private key signs every Hippocampus update that Sparkle will trust.
# Loss = no more signed updates for existing installs (users must re-download
#        manually and the new key wires through Info.plist on a fresh DMG).
# Theft = attacker can ship signed malware to every installed user.
#
# Treat this like a code-signing identity:
#   - NEVER commit to the repo (this script never writes inside the repo).
#   - NEVER paste into CI logs, chat, screenshots, or LLM transcripts.
#   - Keep ONE canonical copy on the owner's machine + ONE in 1Password / HSM.
#
# --- 1Password import flow (recommended) ---
#
#   # After this script runs:
#   op document create ~/.hippocampus-sparkle-private.key \
#       --title "Sparkle EdDSA Private Key (Hippocampus)" \
#       --vault "mci-prod-secrets" \
#       --tags "sparkle,signing,launch-blocker"
#
#   # Then verify it round-trips:
#   op document get "Sparkle EdDSA Private Key (Hippocampus)" --vault "mci-prod-secrets" \
#     | diff - ~/.hippocampus-sparkle-private.key && echo OK
#
#   # Local file stays — it's the working copy. 1Password is the backup of record.
#
# --- HSM alternative ---
#
#   Sparkle 2.x supports a custom signing binary via SPARKLE_SIGN_UPDATE. Wrap
#   your HSM's signing tool to mimic the sign_update CLI and point publish at
#   it; the on-disk private key file is never required. Out of scope for first
#   ~50 dogfood users.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KEY_FILE="${HOME}/.hippocampus-sparkle-private.key"
PUB_FILE="${HOME}/.hippocampus-sparkle-public.key"
README_FILE="${KEY_FILE}.README"

usage() {
    cat <<EOF
Usage: sparkle-keygen.sh [--help]

Mint a fresh Sparkle Ed25519 keypair for Hippocampus.

Output files:
  ${KEY_FILE}         (0600, base64-encoded Ed25519 private key)
  ${KEY_FILE}.README  (do-not-commit warning + storage procedure)
  ${PUB_FILE}         (base64-encoded Ed25519 public key — also printed to stdout)

This script REFUSES to run if ${KEY_FILE} already exists. Rotating an existing
key is a manual operation — see docs/appcast-hosting.md "Key rotation" section.

Prerequisites:
  - Sparkle 2.x release tarball or framework with bin/generate_keys, OR
  - generate_keys on PATH (e.g., installed via Sparkle's distribution).

Environment:
  SPARKLE_GENERATE_KEYS   Path to Sparkle generate_keys binary (auto-detected).

Exit codes:
  0  Key minted.
  1  Tool missing, file already exists, or other failure.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 0 ]]; then
    echo "ERROR: Unknown argument: $1"
    usage
    exit 1
fi

# --- Refuse to overwrite existing key ---

if [[ -e "$KEY_FILE" ]]; then
    cat <<EOF >&2
ERROR: Private key already exists at:
  $KEY_FILE

This script refuses to overwrite an existing Sparkle private key. Overwriting
it would silently invalidate every previously-shipped Hippocampus update.

If you intend to rotate the key, see docs/appcast-hosting.md "Key rotation"
for the staged procedure (it requires a fresh public key in Info.plist + a
manually-distributed bridge release for existing installs).

If you intend to start over from scratch on a dev machine, move the existing
file aside FIRST and back it up in 1Password:
  mv ~/.hippocampus-sparkle-private.key ~/.hippocampus-sparkle-private.key.OLD-\$(date +%Y%m%d)

Aborting.
EOF
    exit 1
fi

# --- Locate generate_keys ---

find_generate_keys() {
    if [[ -n "${SPARKLE_GENERATE_KEYS:-}" && -x "${SPARKLE_GENERATE_KEYS}" ]]; then
        echo "$SPARKLE_GENERATE_KEYS"
        return 0
    fi

    # SwiftPM build artifacts (Sparkle SPM consumer)
    local swiftpm_path="$REPO_ROOT/apps/hippocampus/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
    if [[ -x "$swiftpm_path" ]]; then
        echo "$swiftpm_path"
        return 0
    fi

    # Framework bundle (Sparkle 2.x layout — same lookup as sign_update)
    local fw_bases=(
        "$REPO_ROOT/apps/hippocampus/.build"
        "$HOME/Library/Developer/Xcode/DerivedData"
    )
    for base in "${fw_bases[@]}"; do
        if [[ -d "$base" ]]; then
            local found
            found=$(find "$base" -path "*/Sparkle.framework/Versions/B/bin/generate_keys" 2>/dev/null | head -1 || true)
            if [[ -n "$found" && -x "$found" ]]; then
                echo "$found"
                return 0
            fi
        fi
    done

    # Homebrew / PATH
    if command -v generate_keys &>/dev/null; then
        command -v generate_keys
        return 0
    fi

    return 1
}

if ! GENERATE_KEYS=$(find_generate_keys); then
    cat <<EOF >&2
ERROR: Sparkle generate_keys not found.

Install Sparkle tooling one of these ways:
  - Build Hippocampus once (./scripts/build-installer.sh) so SwiftPM
    resolves Sparkle into .build/artifacts/sparkle/, OR
  - brew install --cask sparkle, OR
  - Download the Sparkle 2.x release tarball from
    https://github.com/sparkle-project/Sparkle/releases and either set
    SPARKLE_GENERATE_KEYS=/path/to/bin/generate_keys or put it on PATH.
EOF
    exit 1
fi

echo "=== Sparkle EdDSA Keygen ==="
echo "Tool: $GENERATE_KEYS"
echo ""

# --- Confirm before minting ---

cat <<EOF
About to mint a new Sparkle Ed25519 keypair.

Private key → $KEY_FILE         (mode 0600)
Public key  → $PUB_FILE         (also printed to stdout)
Warning doc → $README_FILE

After this completes:
  1. Paste the public key into apps/hippocampus/Resources/Info.plist
     under <key>SUPublicEDKey</key>.
  2. Back up the private key into 1Password (see header comment for the
     'op document create' command).
  3. Ship a fresh signed DMG with the new SUPublicEDKey — existing installs
     will not auto-upgrade past this boundary (intentional, see "Key rotation"
     in docs/appcast-hosting.md).

EOF

read -r -p "Proceed? [y/N] " CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *)
        echo "Aborted."
        exit 1
        ;;
esac

# --- Mint the keypair ---
#
# Sparkle 2.x generate_keys supports:
#   -f <file>   Export the private key to <file> (and do NOT touch the Keychain).
#   -x <file>   Export the public key to <file>.
#   -p          Print the public key (Keychain mode).
#
# We use -f + -x so the key never enters the macOS Keychain (we want full
# control over backup/storage), and so the private key file is a pure base64
# string that sign_update can consume directly via `cat key | sign_update`.

TMP_DIR=$(mktemp -d -t sparkle-keygen.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_PRIV="$TMP_DIR/priv"
TMP_PUB="$TMP_DIR/pub"

if ! "$GENERATE_KEYS" -f "$TMP_PRIV" -x "$TMP_PUB"; then
    echo "ERROR: generate_keys failed. The bundled tool may predate the -f/-x" >&2
    echo "       flags (Sparkle <2.0). Upgrade Sparkle and retry." >&2
    exit 1
fi

if [[ ! -s "$TMP_PRIV" || ! -s "$TMP_PUB" ]]; then
    echo "ERROR: generate_keys produced empty key files." >&2
    exit 1
fi

# Move into place with strict permissions BEFORE any data lands at the final
# path. install(1) on macOS atomically renames + chmods.
install -m 0600 "$TMP_PRIV" "$KEY_FILE"
install -m 0644 "$TMP_PUB"  "$PUB_FILE"

# --- Write the warning README sidecar ---

cat > "$README_FILE" <<'README_EOF'
SPARKLE PRIVATE KEY — DO NOT COMMIT, DO NOT PASTE, DO NOT LOG.

This file is the working copy of the Hippocampus Ed25519 auto-update signing key.
It is referenced by scripts/sparkle-publish.sh via --private-key.

If this file is exfiltrated, an attacker can ship signed malware to every
Hippocampus user whose Info.plist contains the matching SUPublicEDKey.

Required handling:
  - File permissions: 0600 (enforced by sparkle-keygen.sh).
  - One canonical backup in 1Password / HSM (see header of sparkle-keygen.sh
    for the 'op document create' command).
  - NEVER on shared filesystems, cloud-synced folders (iCloud, Dropbox), or
    machine images / Docker layers / CI workspaces.
  - NEVER paste into Claude Code, ChatGPT, or any LLM chat. Treat this like a
    cryptographic identity, because it IS one.

If you suspect compromise: rotate per docs/appcast-hosting.md "Key rotation".
README_EOF

chmod 0644 "$README_FILE"

# --- Report ---

PUBKEY=$(cat "$PUB_FILE")

cat <<EOF

=== Done ===
Private key: $KEY_FILE   (0600)
Public key:  $PUB_FILE   (also below)
Warning:     $README_FILE

PUBLIC KEY (paste into apps/hippocampus/Resources/Info.plist):

    <key>SUPublicEDKey</key>
    <string>${PUBKEY}</string>

Next steps:
  1. Update Info.plist with the public key above.
  2. Back up the private key into 1Password — see the 'op document create'
     command in the sparkle-keygen.sh header comment.
  3. Build a fresh signed DMG, then run:
       scripts/sparkle-publish.sh \\
         --dmg dist/Hippocampus-x.y.z.dmg \\
         --private-key $KEY_FILE \\
         --release-notes RELEASE_NOTES_x.y.z.md
EOF
