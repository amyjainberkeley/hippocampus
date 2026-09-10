#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$SCRIPT_DIR/lib/installer-runtime.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-installer-runtime.XXXXXX")"
cleanup_test() {
    local pid_file pid
    for pid_file in "$TEST_ROOT"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

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

before_sleep_pids="$(pgrep -f '^sleep 17$' 2>/dev/null || true)"
hippocampus_run_with_deadline 17 1 /usr/bin/true
after_sleep_pids="$(pgrep -f '^sleep 17$' 2>/dev/null || true)"
for pid in $after_sleep_pids; do
    if ! grep -qx "$pid" <<<"$before_sleep_pids"; then
        echo "FAIL: successful deadline left watchdog sleep $pid alive" >&2
        exit 1
    fi
done
echo "PASS: successful deadline leaves no watchdog sleep"

DESCENDANT_PID_FILE="$TEST_ROOT/descendant.pid"
export DESCENDANT_PID_FILE
status=0
hippocampus_run_with_deadline 1 1 /bin/sh -c '
    trap "" TERM
    /bin/sh -c '\''trap "" TERM; while :; do sleep 0.1; done'\'' &
    printf "%s" "$!" >"$DESCENDANT_PID_FILE"
    while :; do sleep 0.1; done
' || status=$?
if [[ "$status" -ne 124 ]]; then
    echo "FAIL: descendant deadline returned $status instead of 124" >&2
    exit 1
fi
descendant_pid="$(cat "$DESCENDANT_PID_FILE")"
sleep 0.2
if kill -0 "$descendant_pid" 2>/dev/null; then
    echo "FAIL: deadline left descendant $descendant_pid alive" >&2
    exit 1
fi
echo "PASS: deadline terminates the full child process tree"

LATE_DESCENDANT_PID_FILE="$TEST_ROOT/late-descendant.pid"
export LATE_DESCENDANT_PID_FILE
status=0
hippocampus_run_with_deadline 1 1 /bin/sh -c '
    on_term() {
        trap "" TERM
        /bin/sh -c '\''trap "" TERM; while :; do sleep 0.1; done'\'' &
        printf "%s" "$!" >"$LATE_DESCENDANT_PID_FILE"
    }
    trap on_term TERM
    while :; do sleep 0.1; done
' || status=$?
if [[ "$status" -ne 124 ]]; then
    echo "FAIL: late-descendant deadline returned $status instead of 124" >&2
    exit 1
fi
if [[ ! -s "$LATE_DESCENDANT_PID_FILE" ]]; then
    echo "FAIL: TERM handler did not create the late descendant fixture" >&2
    exit 1
fi
late_descendant_pid="$(cat "$LATE_DESCENDANT_PID_FILE")"
sleep 0.2
if kill -0 "$late_descendant_pid" 2>/dev/null; then
    echo "FAIL: deadline left TERM-spawned descendant $late_descendant_pid alive" >&2
    exit 1
fi
echo "PASS: deadline terminates descendants created during shutdown"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
HDIUTIL_LOG="$TEST_ROOT/hdiutil.log"
export HDIUTIL_LOG
cat > "$FAKE_BIN/hdiutil" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HDIUTIL_LOG"
if [[ "${FAKE_DETACH_FAILURE:-}" == all && "$1" == detach ]]; then exit 1; fi
if [[ "${FAKE_DETACH_FAILURE:-}" == normal && "$1" == detach && "$*" != *-force* ]]; then exit 1; fi
SH
chmod +x "$FAKE_BIN/hdiutil"
PATH="$FAKE_BIN:$PATH"

HIPP_INSTALLER_MOUNT_ROOT="$TEST_ROOT/owned build mount"
MOUNT_DIR="$HIPP_INSTALLER_MOUNT_ROOT/volume"
EXPECTED_MOUNT_DIR="$MOUNT_DIR"
SIGNING_SCRATCH="$TEST_ROOT/signing"
DMG_STAGING="$TEST_ROOT/staging"
TEMP_DMG="$TEST_ROOT/Hippocampus-temp.dmg"
FINAL_DMG_PENDING="$TEST_ROOT/Hippocampus-0.1.0.dmg"
EXPECTED_SIGNING_SCRATCH="$SIGNING_SCRATCH"
EXPECTED_DMG_STAGING="$DMG_STAGING"
EXPECTED_TEMP_DMG="$TEMP_DMG"
EXPECTED_FINAL_DMG_PENDING="$FINAL_DMG_PENDING"
mkdir -p "$MOUNT_DIR" "$SIGNING_SCRATCH" "$DMG_STAGING"
touch "$TEMP_DMG" "$FINAL_DMG_PENDING" "${FINAL_DMG_PENDING}.sha256"

hippocampus_installer_cleanup 73

if ! grep -Fxq "detach $EXPECTED_MOUNT_DIR -quiet" "$HDIUTIL_LOG" ||
    grep -q -- '-force' "$HDIUTIL_LOG"; then
    echo "FAIL: cleanup must first detach only its own image without force" >&2
    exit 1
fi
for path in \
    "$EXPECTED_SIGNING_SCRATCH" \
    "$EXPECTED_DMG_STAGING" \
    "$EXPECTED_TEMP_DMG" \
    "$EXPECTED_FINAL_DMG_PENDING" \
    "${EXPECTED_FINAL_DMG_PENDING}.sha256"; do
    if [[ -e "$path" ]]; then
        echo "FAIL: cleanup left temporary path behind: $path" >&2
        exit 1
    fi
done
echo "PASS: failed cleanup detaches mounts and removes incomplete final artifacts"

FINAL_DMG_PENDING="$TEST_ROOT/Hippocampus-0.1.0-complete.dmg"
EXPECTED_COMPLETED_DMG="$FINAL_DMG_PENDING"
touch "$EXPECTED_COMPLETED_DMG" "${EXPECTED_COMPLETED_DMG}.sha256"
hippocampus_installer_cleanup 0
if [[ ! -f "$EXPECTED_COMPLETED_DMG" || ! -f "${EXPECTED_COMPLETED_DMG}.sha256" ]]; then
    echo "FAIL: successful cleanup removed the completed final artifact" >&2
    exit 1
fi
echo "PASS: successful cleanup preserves completed final artifacts"

USER_VOLUME="$TEST_ROOT/Volumes/Hippocampus 1"
mkdir -p "$USER_VOLUME"
touch "$USER_VOLUME/user-marker"
MOUNT_DIR="$USER_VOLUME"
HIPP_INSTALLER_MOUNT_ROOT=""
: >"$HDIUTIL_LOG"
hippocampus_installer_cleanup 1
[[ ! -s "$HDIUTIL_LOG" && -f "$USER_VOLUME/user-marker" ]] || {
    echo "FAIL: cleanup touched an unowned mounted image" >&2; exit 1;
}
MOUNT_DIR=""
echo "PASS: unowned mounted images are never detached"

TEMP_DMG="$TEST_ROOT/own image.dmg"
touch "$TEMP_DMG"
: >"$HDIUTIL_LOG"
hippocampus_installer_mount "$TEMP_DMG"
EXPECTED_MOUNT_DIR="$MOUNT_DIR"
[[ "$MOUNT_DIR" == "$HIPP_INSTALLER_MOUNT_ROOT/volume" && -d "$MOUNT_DIR" ]] || exit 1
grep -Fxq "attach -readwrite -noverify -noautoopen -nobrowse -mountpoint $MOUNT_DIR $TEMP_DMG" "$HDIUTIL_LOG" || {
    echo "FAIL: attach did not use a private headless mountpoint" >&2; exit 1;
}
FAKE_DETACH_FAILURE=normal
export FAKE_DETACH_FAILURE
hippocampus_installer_cleanup 1
grep -Fxq "detach $EXPECTED_MOUNT_DIR -force -quiet" "$HDIUTIL_LOG" || exit 1
[[ -f "$USER_VOLUME/user-marker" && ! -d "$EXPECTED_MOUNT_DIR" ]] || exit 1
echo "PASS: busy fallback is limited to the private build attachment"

TEMP_DMG="$TEST_ROOT/keep mounted image.dmg"
touch "$TEMP_DMG"
hippocampus_installer_mount "$TEMP_DMG"
EXPECTED_TEMP_DMG="$TEMP_DMG"
EXPECTED_MOUNT_DIR="$MOUNT_DIR"
FAKE_DETACH_FAILURE=all
hippocampus_installer_cleanup 1
[[ -f "$EXPECTED_TEMP_DMG" && -d "$EXPECTED_MOUNT_DIR" ]] || {
    echo "FAIL: failed detach must preserve its mounted backing image" >&2; exit 1;
}
FAKE_DETACH_FAILURE=""
hippocampus_installer_cleanup 1
[[ ! -f "$EXPECTED_TEMP_DMG" && ! -d "$EXPECTED_MOUNT_DIR" ]] || exit 1
echo "PASS: failed detach preserves the backing image for retry"
