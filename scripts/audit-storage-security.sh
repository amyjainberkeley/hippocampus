#!/usr/bin/env bash
# audit-storage-security.sh — audit how a throwaway Hippocampus home stores
# memory: encrypted, local, owner-only, and nowhere in plain text.
#
# Run it on the home scripts/e2e-full.sh made (e2e-full.sh runs it itself):
#
#   scripts/audit-storage-security.sh --home DIR [--tmpdir DIR] [--markers FILE]
#       [--key-file FILE] [--wal-snapshots DIR] [--sampler DIR] [--outputs LIST]
#       [--keyframe-tool PATH] [--since EPOCH]
#   scripts/audit-storage-security.sh --self-test
#
# Checks, each printed as PASS or FAIL with its evidence (scripts/lib/storage_audit.py):
#   - the brain has no "SQLite format 3" header and the system sqlite3 can't open it;
#   - every screenshot blob is the codec's sealed envelope, never a JPEG or PNG,
#     opens with the key and fails with a wrong one;
#   - WAL and SHM files, live and copied during the run, hold ciphertext pages;
#   - no synthetic marker in plain text outside the encrypted stores: logs,
#     crash reports, Saved Application State, URL caches, launch agents,
#     preferences, everything else in the home and TMPDIR, and new files the
#     run's own processes opened in the per-user cache and temp folders;
#   - the database key appears nowhere but its key file;
#   - every pasteboard write (Copy for Your AI) is transient, concealed and
#     current-host-only (source);
#   - product files are 0600 and folders 0700;
#   - the production key path: Keychain, access list, no sync, and whether a
#     this-device-only class is set, cited by file:line (the real Keychain is
#     never read);
#   - no network: scripts/launch/no-egress.sh, and the runtime lsof -i samples
#     of the run's own processes taken by scripts/lib/e2e_sampler.py;
#   - MCP answers, Ask and hook packets carry no secret marker.
#
# It never prints file contents, and it reads only the throwaway home, its
# TMPDIR, files the run's own processes opened, and this repository.
# --self-test runs every detector against made-up homes, clean and dirty.
# Exit status: 0 when every check passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/lib/storage_audit.py"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
fi

if [[ "${1:-}" != "--self-test" ]]; then
    exec python3 "$AUDIT" --repo "$REPO_ROOT" "$@"
fi

# ---- Self-test: each detector against a clean and a dirty made-up home -------
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/storage-audit-selftest.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
failures=0
expect() {
    # expect LABEL STATUS CHECK LOG: the check reported STATUS in LOG.
    local label="$1" status="$2" check="$3" log="$4"
    if grep -Eq "^$status +$check " "$log"; then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s (expected %s %s)\n' "$label" "$status" "$check"
        grep -E " $check " "$log" | sed 's/^/        /' | head -n 3
        failures=$((failures + 1))
    fi
}

make_home() {
    # make_home DIR clean|dirty
    local home="$1" kind="$2" support="$1/Library/Application Support/MCI"
    mkdir -p "$support/blobs" "$home/Library/Logs/MCI" "$home/Library/LaunchAgents"
    chmod 700 "$home" "$home/Library" "$support" "$support/blobs" "$home/Library/Logs/MCI"
    ( umask 077; openssl rand -hex 32 > "$support/dev.key" )
    python3 - "$support" "$kind" <<'PY'
import os, sqlite3, sys
support, kind = sys.argv[1:]
db = os.path.join(support, "mci.sqlite")
if kind == "dirty":
    connection = sqlite3.connect(db)
    connection.execute("CREATE TABLE events (text TEXT)")
    connection.execute("INSERT INTO events VALUES ('Larkspur launch checklist')")
    connection.commit(); connection.close()
else:
    with open(db, "wb") as handle:
        handle.write(os.urandom(64 * 1024))
os.chmod(db, 0o600)
# A WAL: header, then one frame of a 4 KB page.
page = (b"Larkspur plain page " * 300)[:4096] if kind == "dirty" else os.urandom(4096)
header = bytes.fromhex("377f0682") + (3007000).to_bytes(4, "big") + (4096).to_bytes(4, "big") + bytes(20)
with open(db + "-wal", "wb") as handle:
    handle.write(header + bytes(24) + page)
os.chmod(db + "-wal", 0o600)
PY
    if [[ "$kind" == "dirty" ]]; then
        printf '\xff\xd8\xff\xe0 not sealed' > "$support/blobs/plain.bin"
        printf 'moment text: Larkspur launch checklist\n' > "$home/Library/Logs/MCI/agent.log"
        printf 'card 4242 4242 4242 4242\n' > "$home/Library/LaunchAgents/ai.hippocampus.refresh.plist"
        chmod 644 "$home/Library/Logs/MCI/agent.log"
        printf '{"key":"%s"}\n' "$(cat "$support/dev.key")" > "$home/.claude.json"
    else
        python3 - "$support/blobs" <<'PY'
import hashlib, os, sys
data = os.urandom(4096)
path = os.path.join(sys.argv[1], hashlib.sha256(data).hexdigest() + ".bin")
open(path, "wb").write(data)
os.chmod(path, 0o600)
PY
        printf '{"status":"ok"}\n' > "$home/Library/Logs/MCI/agent.log"
        chmod 600 "$home/Library/Logs/MCI/agent.log"
    fi
}

printf 'moment\tLarkspur\nsecret\t4242 4242 4242 4242\n' > "$ROOT/markers.txt"
mkdir -p "$ROOT/sampler-clean" "$ROOT/sampler-dirty"
printf '{"samples": 5, "processes_watched": 2, "internet_sockets_seen": 0, "files_outside_run": 0}\n' > "$ROOT/sampler-clean/summary.json"
printf '1\t1\tmci-agent\t/x/mci-agent --drain-stdin\n' > "$ROOT/sampler-clean/processes.log"
: > "$ROOT/sampler-clean/outside-files.log"
printf '{"samples": 5, "processes_watched": 2, "internet_sockets_seen": 1, "files_outside_run": 1}\n' > "$ROOT/sampler-dirty/summary.json"
printf '1.0\tmci-agent 1 me 9u IPv4 TCP 10.0.0.2:5000->1.2.3.4:443 (ESTABLISHED)\n' > "$ROOT/sampler-dirty/net.log"
: > "$ROOT/sampler-dirty/processes.log"
printf '2\tmci-agent\t%s/Documents/private.txt\n' "$HOME" > "$ROOT/sampler-dirty/outside-files.log"
printf '{"result":"Larkspur"}\n' > "$ROOT/output-clean.jsonl"
printf '{"result":"card 4242 4242 4242 4242"}\n' > "$ROOT/output-dirty.jsonl"
echo "$ROOT/output-clean.jsonl" > "$ROOT/outputs-clean.txt"
echo "$ROOT/output-dirty.jsonl" > "$ROOT/outputs-dirty.txt"

make_home "$ROOT/clean" clean
make_home "$ROOT/dirty" dirty
# A stand-in keyframe tool: opens with the clean home's key, refuses others.
printf '#!/bin/sh\n[ "$MCI_DB_KEY_HEX" = "%s" ] || { echo '"'"'{"opened":false,"reason":"authentication_failed"}'"'"'; exit 3; }\necho '"'"'{"opened":true,"kind":"jpeg","bytes":10}'"'"'\n' \
    "$(cat "$ROOT/clean/Library/Application Support/MCI/dev.key")" > "$ROOT/keyframe-tool"
chmod +x "$ROOT/keyframe-tool"
for kind in clean dirty; do
    python3 "$AUDIT" --repo "$REPO_ROOT" --home "$ROOT/$kind" --markers "$ROOT/markers.txt" \
        --key-file "$ROOT/$kind/Library/Application Support/MCI/dev.key" --keyframe-tool "$ROOT/keyframe-tool" \
        --sampler "$ROOT/sampler-$kind" --outputs "$ROOT/outputs-$kind.txt" --real-home "$HOME" \
        --skip pasteboard --skip custody --skip egress > "$ROOT/$kind.log" 2>&1 || true
done
expect "a SQLCipher-like brain passes the header check"      PASS brain.header   "$ROOT/clean.log"
expect "a plain SQLite brain fails the header check"         FAIL brain.header   "$ROOT/dirty.log"
expect "sqlite3 refuses random bytes"                        PASS brain.sqlite3  "$ROOT/clean.log"
expect "sqlite3 reading the brain is a failure"              FAIL brain.sqlite3  "$ROOT/dirty.log"
expect "a sealed, content-addressed blob passes"             PASS blobs.sealed   "$ROOT/clean.log"
expect "a JPEG-looking blob fails"                           FAIL blobs.sealed   "$ROOT/dirty.log"
expect "a blob that opens only with its key passes"          PASS blobs.open     "$ROOT/clean.log"
expect "a ciphertext WAL page passes"                        PASS wal.encrypted  "$ROOT/clean.log"
expect "a plain WAL page fails"                              FAIL wal.encrypted  "$ROOT/dirty.log"
expect "a clean log passes"                                  PASS scan.logs      "$ROOT/clean.log"
expect "a marker in a log fails"                             FAIL scan.logs      "$ROOT/dirty.log"
expect "a marker in a launch agent fails"                    FAIL scan.launchagents "$ROOT/dirty.log"
expect "the key in a config file fails"                      FAIL scan.key       "$ROOT/dirty.log"
expect "owner-only modes pass"                               PASS modes          "$ROOT/clean.log"
expect "a 0644 log fails the modes check"                    FAIL modes          "$ROOT/dirty.log"
expect "no sockets in the samples passes"                    PASS net.runtime    "$ROOT/clean.log"
expect "an internet socket in the samples fails"             FAIL net.runtime    "$ROOT/dirty.log"
expect "a file opened in the real home fails isolation"      FAIL net.isolation  "$ROOT/dirty.log"
expect "outputs without secrets pass"                        PASS outputs        "$ROOT/clean.log"
expect "a secret in an MCP answer fails"                     FAIL outputs        "$ROOT/dirty.log"

# The source checks run against this checkout, as in a real audit.
python3 "$AUDIT" --repo "$REPO_ROOT" --home "$ROOT/clean" \
    --skip brain --skip blobs --skip wal --skip scan --skip modes --skip network --skip outputs \
    > "$ROOT/source.log" 2>&1 || true
for check in custody.keychain custody.no-sync custody.this-device custody.reference custody.dev-gate pasteboard; do
    if grep -Eq "^(PASS|FAIL) +$check " "$ROOT/source.log"; then
        printf 'ok    source check %s ran (%s)\n' "$check" "$(grep -E " $check " "$ROOT/source.log" | awk '{print $1}')"
    else
        printf 'FAIL  source check %s did not run\n' "$check"
        failures=$((failures + 1))
    fi
done

if (( failures > 0 )); then
    printf 'FAIL: %d storage-audit detector(s) did not behave\n' "$failures"
    exit 1
fi
printf 'PASS: every storage-audit detector flags its dirty fixture and passes its clean one\n'
