#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-sparkle-keypair.sh"
TMP_ROOT="$(mktemp -d -t hippocampus-sparkle-keypair)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# RFC 8032 test vector 1.
SEED_HEX="9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
PUBLIC_HEX="d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
printf '%s' "$SEED_HEX" | xxd -r -p | base64 | tr -d '\n' >"$TMP_ROOT/private.key"
chmod 600 "$TMP_ROOT/private.key"
PUBLIC_B64="$(printf '%s' "$PUBLIC_HEX" | xxd -r -p | base64 | tr -d '\n')"

make_plist() {
    local public_key="$1" output="$2"
    cat >"$output" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>SUPublicEDKey</key><string>$public_key</string></dict></plist>
PLIST
}

make_plist "$PUBLIC_B64" "$TMP_ROOT/matching.plist"
make_plist "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "$TMP_ROOT/wrong.plist"

if "$VERIFY" --private-key "$TMP_ROOT/private.key" --info-plist "$TMP_ROOT/matching.plist"; then
    echo 'PASS: matching Sparkle key pair is accepted'
else
    echo 'FAIL: matching Sparkle key pair is accepted' >&2
    exit 1
fi

if "$VERIFY" --private-key "$TMP_ROOT/private.key" --info-plist "$TMP_ROOT/wrong.plist"; then
    echo 'FAIL: mismatched Sparkle key pair is rejected' >&2
    exit 1
else
    echo 'PASS: mismatched Sparkle key pair is rejected'
fi
