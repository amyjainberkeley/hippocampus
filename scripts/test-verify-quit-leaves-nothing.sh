#!/usr/bin/env bash
set -euo pipefail

# Contract test for verify-quit-leaves-nothing.sh, against a stand-in app:
# no AppKit, no permissions, no user data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-quit-leaves-nothing.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-quit-contract.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
APP="$TEST_ROOT/Fixture.app"
MACOS="$APP/Contents/MacOS"
OTHER="$TEST_ROOT/Other.app/Contents/MacOS/MCICaptureHelper"
RESULT="$TEST_ROOT/observed-home.txt"

cleanup() {
    pkill -KILL -f "^$TEST_ROOT/" 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

leftovers() {
    pgrep -f "^$TEST_ROOT/" 2>/dev/null || true
}

mkdir -p "$MACOS" "$(dirname "$OTHER")"

# A native child keeps its executable path in ps, as the real helper and
# agent do. It exits on SIGTERM unless told to ignore it.
cc -x c -o "$MACOS/MCICaptureHelper" - <<'C'
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
    if (getenv("FIXTURE_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
    for (;;) pause();
}
C
cp "$MACOS/MCICaptureHelper" "$MACOS/mci-agent"
cp "$MACOS/MCICaptureHelper" "$OTHER"

# The stand-in app: checks the launch it was given, starts a helper and a
# writer agent from inside its bundle, and stops them on SIGTERM.
cat > "$MACOS/Hippocampus" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${CFFIXED_USER_HOME:-}" && "$HOME" == "$CFFIXED_USER_HOME" ]] || exit 20
[[ -f "$HOME/Library/Application Support/MCI/.onboarding-complete" ]] || exit 21
[[ "${HIPPOCAMPUS_QUIET_LAUNCH:-}" == 1 ]] || exit 22
printf '%s\n' "$HOME" > "$VERIFY_FIXTURE_RESULT"
here="$(dirname "$0")"
if [[ "${FIXTURE_LEAVE_HELPER:-0}" == 1 ]]; then
    FIXTURE_IGNORE_TERM=1 "$here/MCICaptureHelper" --capture --parent-lease-stdin &
else
    "$here/MCICaptureHelper" --capture --parent-lease-stdin &
fi
helper=$!
"$here/mci-agent" --drain-stdin --strict &
agent=$!
other=""
if [[ -n "${FIXTURE_OTHER_BUNDLE:-}" ]]; then
    FIXTURE_IGNORE_TERM=1 "$FIXTURE_OTHER_BUNDLE" &
    other=$!
fi
stop() {
    kill -TERM "$helper" "$agent" 2>/dev/null || true
    exit 0
}
trap stop TERM
while :; do sleep 1 & wait $! || true; done
SH
chmod +x "$MACOS/Hippocampus"

if "$VERIFY" >/dev/null 2>&1; then
    fail "the verifier accepted a call without an app"
fi

# A clean quit passes, in a disposable home that is gone afterwards.
VERIFY_FIXTURE_RESULT="$RESULT" "$VERIFY" "$APP" \
    || fail "the verifier rejected a clean quit"
[[ -s "$RESULT" ]] || fail "the stand-in app did not see its launch home"
observed_home="$(cat "$RESULT")"
[[ "$observed_home" != "$HOME" ]] || fail "the verifier used the caller's real home"
[[ ! -e "$observed_home" ]] || fail "the verifier kept its disposable home"
[[ -z "$(leftovers)" ]] || fail "a clean run left processes behind"

# A helper that outlives Quit fails the check, and is cleaned up after.
if FIXTURE_LEAVE_HELPER=1 VERIFY_FIXTURE_RESULT="$RESULT" VERIFY_QUIT_SECONDS=2 \
    "$VERIFY" "$APP" >/dev/null 2>&1; then
    fail "the verifier accepted a helper that survived Quit"
fi
[[ -z "$(leftovers)" ]] || fail "the verifier left the surviving helper running"

# A process from another bundle is not this app's to answer for.
FIXTURE_OTHER_BUNDLE="$OTHER" VERIFY_FIXTURE_RESULT="$RESULT" "$VERIFY" "$APP" >/dev/null \
    || fail "the verifier blamed this app for another bundle's process"
pgrep -f "^$OTHER" >/dev/null 2>&1 || fail "the stand-in for another bundle did not run"
pkill -KILL -f "^$OTHER" 2>/dev/null || true

printf 'PASS: the quit verifier isolates HOME, launches quietly, fails on a survivor from the bundle, ignores other bundles and cleans up\n'
