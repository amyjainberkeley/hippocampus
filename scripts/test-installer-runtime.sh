#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$SCRIPT_DIR/lib/installer-runtime.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-installer-runtime.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

if [[ ! -f "$RUNTIME" ]]; then
    echo "FAIL: installer runtime helper is missing: $RUNTIME" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$RUNTIME"

TERM_MARKER="$TEST_ROOT/term-seen"
PID_FILE="$TEST_ROOT/hanging.pid"
export TERM_MARKER PID_FILE

SECONDS=0
status=0
hippocampus_run_with_deadline 1 1 /bin/sh -c '
    trap '\''printf term >"$TERM_MARKER"'\'' TERM
    printf "%s" "$$" >"$PID_FILE"
    while :; do sleep 0.1; done
' || status=$?
elapsed=$SECONDS

if [[ "$status" -ne 124 ]]; then
    echo "FAIL: deadline returned $status instead of 124" >&2
    exit 1
fi
if [[ "$elapsed" -gt 4 ]]; then
    echo "FAIL: deadline took ${elapsed}s" >&2
    exit 1
fi
if [[ ! -f "$TERM_MARKER" ]]; then
    echo "FAIL: deadline did not send TERM before KILL" >&2
    exit 1
fi
hanging_pid="$(cat "$PID_FILE")"
if kill -0 "$hanging_pid" 2>/dev/null; then
    echo "FAIL: deadline left child $hanging_pid alive" >&2
    exit 1
fi
echo "PASS: deadline sends TERM, escalates to KILL, and reaps the child"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
HDIUTIL_LOG="$TEST_ROOT/hdiutil.log"
export HDIUTIL_LOG
cat > "$FAKE_BIN/hdiutil" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HDIUTIL_LOG"
SH
chmod +x "$FAKE_BIN/hdiutil"
PATH="$FAKE_BIN:$PATH"

MOUNT_DIR="$TEST_ROOT/Volumes/Hippocampus"
EXPECTED_MOUNT_DIR="$MOUNT_DIR"
SIGNING_SCRATCH="$TEST_ROOT/signing"
DMG_STAGING="$TEST_ROOT/staging"
TEMP_DMG="$TEST_ROOT/Hippocampus-temp.dmg"
EXPECTED_SIGNING_SCRATCH="$SIGNING_SCRATCH"
EXPECTED_DMG_STAGING="$DMG_STAGING"
EXPECTED_TEMP_DMG="$TEMP_DMG"
mkdir -p "$MOUNT_DIR" "$SIGNING_SCRATCH" "$DMG_STAGING"
touch "$TEMP_DMG"

hippocampus_installer_cleanup 73

if ! grep -Fq "detach $EXPECTED_MOUNT_DIR -force -quiet" "$HDIUTIL_LOG"; then
    echo "FAIL: cleanup did not detach the active mounted image" >&2
    exit 1
fi
for path in "$EXPECTED_SIGNING_SCRATCH" "$EXPECTED_DMG_STAGING" "$EXPECTED_TEMP_DMG"; do
    if [[ -e "$path" ]]; then
        echo "FAIL: cleanup left temporary path behind: $path" >&2
        exit 1
    fi
done
echo "PASS: centralized cleanup detaches mounts and removes temporary artifacts"
