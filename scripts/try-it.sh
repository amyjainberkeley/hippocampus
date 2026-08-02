#!/usr/bin/env bash
set -euo pipefail

# scripts/try-it.sh — see Hippocampus search work, in about a minute.
#
# Builds the two CLI binaries, makes a throwaway encrypted brain in a
# sandbox directory, fills it with 20 synthetic events, and runs a few
# searches against it so you can see what recall actually returns.
#
# Safe by construction:
#   - Everything lands in ./hippocampus-demo/ (override with DEMO_DIR).
#     Your real brain at ~/Library/Application Support/MCI is never
#     touched, read, or opened.
#   - The key is generated fresh, written mode 0600, and lives only in
#     the sandbox. Delete the directory and the data is unrecoverable,
#     which is the same crypto-shred property the real store has.
#   - The 20 events are hand-authored fixtures. No capture runs. Nothing
#     reads your screen. Nothing goes over the network.
#
# Remove it all with:  rm -rf ./hippocampus-demo

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="${DEMO_DIR:-$REPO_ROOT/hippocampus-demo}"
DB_PATH="$DEMO_DIR/demo.sqlite"
KEY_FILE="$DEMO_DIR/demo.key"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------

command -v cargo >/dev/null 2>&1 \
  || die "cargo not found. Install Rust from https://rustup.rs then re-run."

if ! command -v openssl >/dev/null 2>&1; then
  die "openssl not found. It ships with macOS; on Linux: apt install openssl"
fi

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) die "this script supports macOS and Linux. Found: $(uname -s)" ;;
esac

# --- build -----------------------------------------------------------------

bold "1/4  Building the CLI"
dim   "     First run compiles the workspace and takes a few minutes."
cargo build -q -p mci-agent --bins 2>&1 | tail -5 || die "build failed"

SEED="$REPO_ROOT/target/debug/mci-seed-brain"
BRAIN="$REPO_ROOT/target/debug/mci-brain"
[ -x "$SEED" ] && [ -x "$BRAIN" ] || die "binaries missing after build"

# --- sandbox ---------------------------------------------------------------

bold "2/4  Making a throwaway encrypted brain"
mkdir -p "$DEMO_DIR"
chmod 700 "$DEMO_DIR"
rm -f "$DB_PATH"

# Fresh key per run. Never leaves the sandbox, never enters shell history.
( umask 077 && openssl rand -hex 32 > "$KEY_FILE" )
chmod 600 "$KEY_FILE"
export MCI_DB_KEY_HEX
MCI_DB_KEY_HEX="$(cat "$KEY_FILE")"
export MCI_DB_PATH="$DB_PATH"
dim   "     $DB_PATH"
dim   "     key: $KEY_FILE (0600, this sandbox only)"

# --- seed ------------------------------------------------------------------

bold "3/4  Adding 20 synthetic events"
# Keep the output clean, but surface the seeder's own message if it fails.
seed_log="$DEMO_DIR/seed.log"
"$SEED" >"$seed_log" 2>&1 || { cat "$seed_log" >&2; die "seeding failed"; }
"$BRAIN" stats | sed 's/^/     /'

# --- search ----------------------------------------------------------------

bold "4/4  Searching it"
echo
for q in "ScreenCaptureKit" "embedding" "allowlist"; do
  printf '\033[1m  $ mci-brain search "%s"\033[0m\n' "$q"
  "$BRAIN" search "$q" --limit 2 | sed 's/^/     /' || true
  echo
done

# --- next ------------------------------------------------------------------

bold "That's recall over an encrypted store, running entirely on your machine."
cat <<EOF

Keep going. Point the CLI at the same brain:

  export MCI_DB_KEY_HEX=\$(cat "$KEY_FILE")
  export MCI_DB_PATH="$DB_PATH"

  mci-brain search "sqlite"      # find events by text
  mci-brain show 6               # one event in full
  mci-brain recent --limit 5     # newest first
  mci-brain export --format jsonl > brain.jsonl
  mci-brain stats --json

The binaries are at target/debug/. Add them to PATH with:

  export PATH="$REPO_ROOT/target/debug:\$PATH"

Done looking? This deletes the brain and its only key:

  rm -rf "$DEMO_DIR"

EOF
