#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# verify-encryption.sh — prove Hippocampus's memory is encrypted at rest.
#
# Three claims a careful reader wants shown, not asserted:
#
#   1. The brain database is SQLCipher. A raw open with no key cannot read
#      it — the system `sqlite3` CLI reports "file is not a database".
#   2. No plaintext capture text sits in the store directory — not in the
#      DB, the WAL, the SHM, or any blob.
#   3. The database key lives in the Keychain, never on disk / argv / env.
#
# How it proves them, all on a SYNTHETIC store under $TMPDIR (it NEVER
# touches ~/Library/Application Support/MCI or the real brain):
#
#   • Builds + runs core/brain/tests/at_rest_cli_proof.rs, which writes a
#     unique plaintext canary through the real SqlCipherBrainStore, then
#     asserts in-process: round-trip OK, canary absent from every byte of
#     every store file, no unencrypted SQLite header, a keyless open fails,
#     no key-shaped file beside the DB. It leaves the store for step two.
#   • Cross-checks that same file with the SYSTEM sqlite3 CLI and a byte
#     grep — an independent tool, so the proof does not rest on our code.
#   • Runs the store-layer round-trip (mci-core) and the brain store suite
#     (core/brain/tests/sqlcipher_brain_store.rs).
#   • Runs KeychainDatabaseKeyResolverTests (the key comes from the
#     Keychain via SecItemCopyMatching) and audits the no-key-on-disk
#     contract in source.
#
# Usage:  scripts/launch/verify-encryption.sh
# Note:   builds Rust + Swift tests; first run compiles, later runs are fast.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

RED=$'\033[31m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=; GRN=; DIM=; RST=; }

CARGO="${CARGO:-cargo}"
SQLITE3="${SQLITE3:-$(command -v sqlite3 || echo /usr/bin/sqlite3)}"
STORE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hippo-verify-enc.XXXXXX")"
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/hippo-verify-enc-logs.XXXXXX")"
trap 'rm -rf "$STORE_DIR" "$LOGDIR"' EXIT

fail=0
pass() { printf '  %bPASS%b %s %s%s%s\n' "$GRN" "$RST" "$1" "$DIM" "${2:-}" "$RST"; }
bad()  { printf '  %bFAIL%b %s %s\n' "$RED" "$RST" "$1" "${2:-}"; fail=1; }

echo "Hippocampus at-rest encryption proof — $(git rev-parse --short HEAD 2>/dev/null || echo '?') — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Synthetic store dir: $STORE_DIR   ${DIM}(never the real brain)${RST}"
echo

run_cargo_test() { # $1=log $2...=cargo test args ; pass if "test result: ok" and exit 0
  "$CARGO" test "${@:2}" >"$1" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]] && grep -qE 'test result: ok' "$1"; then return 0; fi
  return 1
}

# ── 1. Synthetic-store proof (in-process) + leave the file behind. ───────
echo "== 1. Synthetic SqlCipher store (brain layer) =="
if MCI_VERIFY_OUT_DIR="$STORE_DIR" run_cargo_test "$LOGDIR/atrest.log" \
      -p mci-brain --test at_rest_cli_proof -- --nocapture; then
  pass "at_rest_cli_proof: canary absent from disk, keyless open fails, no key file" \
       "$(grep -c 'test result: ok' "$LOGDIR/atrest.log" >/dev/null && echo '(1 test ok)')"
else
  bad "at_rest_cli_proof failed" "see $LOGDIR/atrest.log"; sed 's/^/    /' "$LOGDIR/atrest.log" | tail -25
fi

DB="$STORE_DIR/mci.sqlite"
CANARY=""
[[ -f "$STORE_DIR/canary.txt" ]] && CANARY="$(cat "$STORE_DIR/canary.txt")"
echo

# ── 2. Independent CLI cross-check with the system sqlite3. ──────────────
echo "== 2. Independent cross-check (system sqlite3 $("$SQLITE3" --version 2>/dev/null | awk '{print $1}')) =="
if [[ -s "$DB" ]]; then
  # A raw keyless open must fail to read the schema.
  cli_out="$("$SQLITE3" "$DB" 'SELECT count(*) FROM sqlite_master;' 2>&1)"; cli_rc=$?
  if [[ $cli_rc -ne 0 ]] && echo "$cli_out" | grep -qiE 'not a database|encrypted|malformed|SQLITE_NOTADB'; then
    pass "raw sqlite3 open refuses the file" "→ $(echo "$cli_out" | head -1)"
  else
    bad "raw sqlite3 open did NOT refuse the file" "rc=$cli_rc out=[$cli_out]"
  fi

  # Unencrypted SQLite files start with this magic; a SQLCipher file must not.
  hdr="$(head -c 16 "$DB" | LC_ALL=C tr -d '\0' | LC_ALL=C tr -cd 'A-Za-z0-9 .')"
  if [[ "$hdr" == "SQLite format 3" ]]; then
    bad "DB carries the unencrypted SQLite header"
  else
    pass "no unencrypted 'SQLite format 3' header on the DB"
  fi

  # The canary must not appear in ANY file in the store dir.
  if [[ -n "$CANARY" ]]; then
    hits="$(grep -rlF "$CANARY" "$STORE_DIR" 2>/dev/null | grep -v '/canary.txt$')"
    if [[ -z "$hits" ]]; then
      pass "synthetic capture text (canary) found in 0 store files" "$(ls "$STORE_DIR" | tr '\n' ' ')"
    else
      bad "plaintext canary found in store files" "$hits"
    fi
  else
    bad "no canary.txt produced — cannot run the byte grep"
  fi

  # No key-shaped file beside the DB.
  keyfiles="$(find "$STORE_DIR" -type f \( -iname '*key*' -o -iname '*.pem' -o -iname 'keyfile' \) 2>/dev/null)"
  if [[ -z "$keyfiles" ]]; then
    pass "no key-material file in the store dir (key lives in the Keychain)"
  else
    bad "key-shaped file present in store dir" "$keyfiles"
  fi
else
  bad "synthetic DB missing or empty at $DB — step 1 did not produce it"
fi
echo

# ── 3. Store-layer round-trip + brain store suite. ───────────────────────
echo "== 3. Store-layer + brain-store tests =="
if run_cargo_test "$LOGDIR/core.log" -p mci-core store::open::tests::encrypt_close_reopen_roundtrip_and_wrong_key_fails; then
  pass "mci-core: encrypt → close → reopen OK; wrong/absent key fails; no plaintext on disk"
else
  bad "mci-core store-open round-trip test failed" "see $LOGDIR/core.log"; tail -20 "$LOGDIR/core.log" | sed 's/^/    /'
fi
if run_cargo_test "$LOGDIR/brain.log" -p mci-brain --test sqlcipher_brain_store; then
  n="$(grep -oE '[0-9]+ passed' "$LOGDIR/brain.log" | head -1)"
  pass "mci-brain sqlcipher_brain_store suite" "($n)"
else
  bad "mci-brain sqlcipher_brain_store suite failed" "see $LOGDIR/brain.log"; tail -20 "$LOGDIR/brain.log" | sed 's/^/    /'
fi
echo

# ── 4. Key lives in the Keychain, not on disk. ───────────────────────────
echo "== 4. Key custody (Keychain, not disk/argv/env) =="
if bash "$REPO_ROOT/scripts/swift-package.sh" test \
      --package-path "$REPO_ROOT/adapters/macos/MCICaptureHelper" \
      --filter KeychainDatabaseKeyResolverTests >"$LOGDIR/swift.log" 2>&1; then
  pass "KeychainDatabaseKeyResolverTests (capture helper) green" "key read via SecItemCopyMatching"
else
  bad "Swift KeychainDatabaseKeyResolverTests failed" "see $LOGDIR/swift.log"; tail -20 "$LOGDIR/swift.log" | sed 's/^/    /'
fi

# Source-contract audits (file:line evidence a reviewer can open).
if grep -q 'SecItemCopyMatching' adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Security/KeychainDatabaseKeyResolver.swift; then
  pass "resolver reads the key from the Keychain (SecItemCopyMatching)" "KeychainDatabaseKeyResolver.swift"
else
  bad "could not confirm SecItemCopyMatching in the key resolver"
fi
if grep -q 'argv / env / a config file' core/src/store/open.rs; then
  pass "store-open contract: key from a DbKey only, never argv/env/config" "core/src/store/open.rs:12"
else
  bad "could not confirm the no-argv/env key contract in open.rs"
fi
if grep -q 'bundled-sqlcipher-vendored-openssl' core/Cargo.toml; then
  pass "SQLCipher is bundled with vendored OpenSSL (no plaintext fallback)" "core/Cargo.toml"
else
  bad "could not confirm bundled SQLCipher feature"
fi
echo

if [[ "$fail" -eq 0 ]]; then
  printf '%bENCRYPTION PROOF PASS%b — brain is SQLCipher at rest, no plaintext capture text on disk, key in the Keychain.\n' "$GRN" "$RST"
  exit 0
else
  printf '%bENCRYPTION PROOF FAIL%b — see FAIL rows above.\n' "$RED" "$RST"
  exit 1
fi
