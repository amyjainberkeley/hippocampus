#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-app-launches.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-launch-contract.XXXXXX")"
APP="$TEST_ROOT/Fixture.app"
MACOS="$APP/Contents/MacOS"
RESULT="$TEST_ROOT/observed-home.txt"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

mkdir -p "$MACOS"

cat > "$MACOS/onboarding" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH

cat > "$MACOS/Hippocampus" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${CFFIXED_USER_HOME:-}" ]] || exit 20
[[ "$HOME" == "$CFFIXED_USER_HOME" ]] || exit 21
printf '%s\n' "$HOME" > "$VERIFY_FIXTURE_RESULT"
sleep "${VERIFY_FIXTURE_ONBOARDING_DELAY:-0}"
"$(dirname "$0")/onboarding" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM INT EXIT
while :; do sleep 1; done
SH
chmod +x "$MACOS/Hippocampus" "$MACOS/onboarding"

VERIFY_FIXTURE_RESULT="$RESULT" \
VERIFY_WAIT_SECONDS=2 \
VERIFY_CLEAN_HOME=1 \
VERIFY_EXPECT_ONBOARDING=1 \
    "$VERIFY" "$APP"

[[ -s "$RESULT" ]] || fail "fixture did not observe its launch home"
observed_home="$(cat "$RESULT")"
[[ "$observed_home" != "$HOME" ]] || fail "launch verifier reused the caller's real home"
[[ ! -e "$observed_home" ]] || fail "launch verifier retained its disposable home"
if pgrep -f "$MACOS/onboarding" >/dev/null 2>&1; then
    fail "launch verifier leaked the onboarding child"
fi

VERIFY_FIXTURE_RESULT="$RESULT" \
VERIFY_FIXTURE_ONBOARDING_DELAY=6 \
VERIFY_CLEAN_HOME=1 \
VERIFY_EXPECT_ONBOARDING=1 \
    "$VERIFY" "$APP"

if pgrep -f "$MACOS/onboarding" >/dev/null 2>&1; then
    fail "launch verifier leaked the delayed onboarding child"
fi

printf 'PASS: app launch verifier isolates HOME, proves onboarding, and cleans children\n'
