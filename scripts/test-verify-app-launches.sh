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

# A native child preserves the executable identity exposed by ps, as the
# shipping onboarding executable does. No AppKit, permissions or user data.
cc -x c -o "$MACOS/onboarding" - <<'C'
#include <unistd.h>
int main(void) { for (;;) pause(); }
C

cat > "$MACOS/Hippocampus" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${CFFIXED_USER_HOME:-}" ]] || exit 20
[[ "$HOME" == "$CFFIXED_USER_HOME" ]] || exit 21
printf '%s\n' "$HOME" > "$VERIFY_FIXTURE_RESULT"
sleep "${VERIFY_FIXTURE_ONBOARDING_DELAY:-0}"
"${VERIFY_FIXTURE_CHILD_PATH:-$(dirname "$0")/onboarding}" &
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

ALIAS="$TEST_ROOT/App Alias.app"
ln -s "$APP" "$ALIAS"
VERIFY_FIXTURE_RESULT="$RESULT" \
VERIFY_FIXTURE_CHILD_PATH="$ALIAS/Contents/MacOS/onboarding" \
VERIFY_WAIT_SECONDS=2 \
VERIFY_CLEAN_HOME=1 \
VERIFY_EXPECT_ONBOARDING=1 \
    "$VERIFY" "$APP"

if pgrep -f "$ALIAS/Contents/MacOS/onboarding" >/dev/null 2>&1; then
    fail "launch verifier leaked the aliased onboarding child"
fi

# Identical bytes and the same filename in another bundle are not our child.
OTHER="$TEST_ROOT/Other.app/Contents/MacOS/onboarding"
mkdir -p "$(dirname "$OTHER")"
cp "$MACOS/onboarding" "$OTHER"
if VERIFY_FIXTURE_RESULT="$RESULT" \
   VERIFY_FIXTURE_CHILD_PATH="$OTHER" \
   VERIFY_WAIT_SECONDS=2 \
   VERIFY_CLEAN_HOME=1 \
   VERIFY_EXPECT_ONBOARDING=1 \
    "$VERIFY" "$APP"; then
    fail "launch verifier accepted another bundle's onboarding executable"
fi
if pgrep -f "$OTHER" >/dev/null 2>&1; then
    fail "launch verifier leaked the rejected child"
fi

printf 'PASS: app launch verifier isolates HOME, recognizes executable aliases, rejects other bundles, and cleans children\n'
