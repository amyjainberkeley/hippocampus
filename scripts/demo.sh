#!/usr/bin/env bash
set -euo pipefail

# scripts/demo.sh — Reproducible E2E pitch demo for Hippocampus / MCI.
#
# Subcommands:
#   clean      Stop demo processes and wipe only the disposable demo root.
#   seed       Generate ephemeral key + seed 20 synthetic events.
#   boot       Build Hippocampus.app, embed Sparkle, codesign, launch.
#   query      Run canned mci-brain queries against the seeded brain.
#   mcp-demo   JSON-RPC mci_recall against running mcp-serve.
#   screenshot  Capture window screenshots (interactive screencapture -w).
#   screenshot --auto  Non-interactive: render CLI + attempt GUI captures.
#   teardown   Stop demo processes and delete the disposable demo root.
#   full       Run all subcommands in sequence.
#
# CSO posture:
#   - Every artifact lives below MCI_DEMO_ROOT (mode 0700 directory).
#   - Never writes to shell history (key generated inline, not exported).
#   - teardown deletes the demo brain (or moves to /tmp).
#   - Seed events are synthetic (com.mci.demo.seed.*), no real user content.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEMO_ROOT="${MCI_DEMO_ROOT:-${TMPDIR:-/tmp}/hippocampus-demo-${UID}}"
DEMO_HOME="$DEMO_ROOT/home"
MCI_DIR="$DEMO_HOME/Library/Application Support/MCI"
DB_PATH="$MCI_DIR/mci.sqlite"
LOG_DIR="$DEMO_HOME/Library/Logs/MCI"
KEY_FILE="$MCI_DIR/dev.key"
PID_DIR="$DEMO_ROOT/pids"
DEMO_KEYCHAIN_SERVICE="ai.hippocampus.demo.$UID"
DEMO_KEYCHAIN_ACCOUNT="database-key"
BUILD_APP="$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
APP_DIST="$REPO_ROOT/apps/hippocampus/dist"
APP_PATH="$APP_DIST/Hippocampus.app"

# macOS Tahoe (26.x) toolchain note (PR #95):
# SwiftPM may warn about deployment target vs SDK version.
# Cosmetic only — build completes. cargo build works as-is.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        red "ERROR: required command not found: $1"
        exit 1
    fi
}

ensure_demo_dirs() {
    mkdir -p "$MCI_DIR" "$LOG_DIR" "$PID_DIR"
    chmod 0700 "$DEMO_ROOT" "$DEMO_HOME" "$MCI_DIR" "$LOG_DIR" "$PID_DIR"
}

stop_demo_processes() {
    [[ -d "$PID_DIR" ]] || return 0
    local pid_file pid command
    for pid_file in "$PID_DIR"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        pid=$(tr -dc '0-9' < "$pid_file")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            command=$(ps -p "$pid" -o command= 2>/dev/null || true)
            case "$command" in
                *"$APP_PATH/Contents/MacOS/Hippocampus"* | *"$APP_PATH/Contents/MacOS/recall-ui"*) ;;
                *)
                    dim "  Ignoring stale PID $pid; it is not a demo process."
                    rm -f "$pid_file"
                    continue
                    ;;
            esac
            kill "$pid" 2>/dev/null || true
            for _ in 1 2 3 4 5; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.2
            done
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    done
}

normalize_screenshot() {
    local input="$1" output="$2" width height scaled_width scaled_height temp
    width=$(sips -g pixelWidth "$input" | awk '/pixelWidth:/ {print $2}')
    height=$(sips -g pixelHeight "$input" | awk '/pixelHeight:/ {print $2}')
    [[ -n "$width" && -n "$height" && "$width" -gt 0 && "$height" -gt 0 ]] || return 1
    temp=$(mktemp "${TMPDIR:-/tmp}/hippocampus-shot.XXXXXX.png")
    if (( width * 10 >= height * 16 )); then
        scaled_width=1280
        scaled_height=$((1280 * height / width))
    else
        scaled_height=800
        scaled_width=$((800 * width / height))
    fi
    sips -s format png -z "$scaled_height" "$scaled_width" "$input" --out "$temp" >/dev/null
    sips -s format png -p 800 1280 --padColor F6F8FB "$temp" --out "$output" >/dev/null
    rm -f "$temp"
}

window_id_for_pid() {
    MCI_WINDOW_PID="$1" xcrun swift -e 'import CoreGraphics
import Foundation
let wanted = Int(ProcessInfo.processInfo.environment["MCI_WINDOW_PID"] ?? "") ?? -1
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == wanted {
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    if layer == 0 && number > 0 { print(number); break }
}' 2>/dev/null
}

load_key() {
    if [[ -f "$KEY_FILE" ]]; then
        export MCI_DEVELOPMENT_FILE_KEY=1
        export MCI_DB_KEYCHAIN_SERVICE="$DEMO_KEYCHAIN_SERVICE"
        export MCI_DB_KEYCHAIN_ACCOUNT="$DEMO_KEYCHAIN_ACCOUNT"
        MCI_DB_KEY_HEX=$(tr -d '\r\n' < "$KEY_FILE")
        export MCI_DB_KEY_HEX
    else
        red "ERROR: key file not found at $KEY_FILE"
        echo "  Run './scripts/demo.sh seed' first."
        exit 1
    fi
}

usage() {
    cat <<EOF
Usage: demo.sh <COMMAND>

Reproducible E2E pitch demo for Hippocampus / MCI.

Commands:
  clean        Kill processes, wipe demo brain, archive logs.
  seed         Generate ephemeral key + seed 20 synthetic events.
  boot         Build Hippocampus.app, embed Sparkle, codesign, launch.
  query        Run canned mci-brain queries against the seeded brain.
  mcp-demo     JSON-RPC mci_recall against running mcp-serve.
  screenshot          Capture window screenshots (interactive).
  screenshot --auto   Non-interactive: render CLI + attempt GUI captures.
  teardown     Kill processes, archive/delete demo brain.
  full         Run all subcommands in sequence.

Options:
  -h, --help   Show this help.

All demo state is stored below $DEMO_ROOT.
Override with MCI_DEMO_ROOT=/absolute/path when needed.
Demo key is stored at $KEY_FILE (mode 0600, ephemeral).
Brain is at $DB_PATH.
EOF
}

# ---------------------------------------------------------------------------
# Subcommand: clean
# ---------------------------------------------------------------------------

do_clean() {
    bold "=== demo clean ==="

    echo "Stopping only processes recorded below $PID_DIR..."
    stop_demo_processes
    if [[ -d "$DEMO_ROOT" ]]; then
        echo "Removing disposable demo root: $DEMO_ROOT"
        rm -rf "$DEMO_ROOT"
    else
        dim "  (no disposable demo state found)"
    fi

    green "clean done."
}

# ---------------------------------------------------------------------------
# Subcommand: seed
# ---------------------------------------------------------------------------

do_seed() {
    bold "=== demo seed ==="
    require_cmd openssl
    require_cmd cargo

    ensure_demo_dirs
    echo "Generating ephemeral SQLCipher key..."
    openssl rand -hex 32 > "$KEY_FILE"
    chmod 0600 "$KEY_FILE"
    dim "  key: $KEY_FILE (mode 0600)"

    export MCI_DB_KEY_HEX
    export MCI_DEVELOPMENT_FILE_KEY=1
    MCI_DB_KEY_HEX=$(tr -d '\r\n' < "$KEY_FILE")

    echo "Building the synthetic memory and brief seeders..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release \
        --bin mci-seed-brain --bin mci-seed-brief 2>&1 | tail -3

    echo "Sealing three fixture images with the production keyframe codec..."
    local blob_dir="$MCI_DIR/blobs"
    local digest seed_args
    local -a digests=()
    mkdir -p "$blob_dir"
    while IFS= read -r digest; do
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] && digests+=("$digest")
    done < <(
        "$REPO_ROOT/scripts/swift-package.sh" run -c release \
            --package-path "$REPO_ROOT/adapters/macos/MCIKeyframeCodec" \
            KeyframeFixtureBuilder \
            --blob-root "$blob_dir" \
            "$REPO_ROOT/assets/screenshots/hero-onboarding-welcome.png" \
            "$REPO_ROOT/assets/screenshots/hero-onboarding-trust-panel.png" \
            "$REPO_ROOT/assets/screenshots/hero-cli.png"
    )
    [[ ${#digests[@]} -eq 3 ]] || {
        red "ERROR: production keyframe fixture did not return three digests"
        return 1
    }

    echo "Seeding 20 synthetic events..."
    seed_args=(--db-path "$DB_PATH")
    for digest in "${digests[@]}"; do
        seed_args+=(--keyframe-digest "$digest")
    done
    "$REPO_ROOT/target/release/mci-seed-brain" "${seed_args[@]}"

    echo "Seeding a synthetic daily brief..."
    "$REPO_ROOT/target/release/mci-seed-brief" \
        --date "$(date +%F)" \
        --title "Today in your work" \
        --body "Hippocampus captured the launch-lifecycle fix, retrieval benchmark, agent context handoff, and local-memory architecture. The remaining release gates are a validation-qualified evidence verifier, a real capture soak, and Developer ID notarization." \
        --model-id "hippocampus-extractive" \
        --source-events 20 \
        --db-path "$DB_PATH"

    echo ""
    ls -lh "$DB_PATH"
    green "seed done. Brain at $DB_PATH"
}

# ---------------------------------------------------------------------------
# Subcommand: boot
# ---------------------------------------------------------------------------

do_boot() {
    bold "=== demo boot ==="
    ensure_demo_dirs
    echo "Assembling the development app through the canonical build graph..."
    "$BUILD_APP" --debug --development-ad-hoc --development-lite

    echo "Launching the packaged app with a disposable home..."
    HOME="$DEMO_HOME" \
        CFFIXED_USER_HOME="$DEMO_HOME" \
        "$APP_PATH/Contents/MacOS/Hippocampus" \
        >"$LOG_DIR/hippocampus.stdout.log" \
        2>"$LOG_DIR/hippocampus.stderr.log" &
    echo "$!" > "$PID_DIR/hippocampus.pid"

    green "boot done. Packaged Hippocampus.app is running against $DEMO_HOME."
}

# ---------------------------------------------------------------------------
# Subcommand: query
# ---------------------------------------------------------------------------

do_query() {
    bold "=== demo query ==="
    require_cmd cargo
    load_key

    BRAIN="$REPO_ROOT/target/release/mci-brain"
    if [[ ! -f "$BRAIN" ]]; then
        echo "Building mci-brain CLI..."
        cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --bin mci-brain 2>&1 | tail -3
    fi

    export MCI_DB_PATH="$DB_PATH"

    bold "--- stats ---"
    "$BRAIN" stats
    echo ""

    bold "--- recent (5) ---"
    "$BRAIN" recent --limit 5
    echo ""

    bold "--- search: retrieval benchmark ---"
    "$BRAIN" search "retrieval benchmark" --limit 3
    echo ""

    bold "--- search: agent context handoff ---"
    "$BRAIN" search "agent context handoff" --limit 3
    echo ""

    bold "--- search: launch lifecycle ---"
    "$BRAIN" search "launch lifecycle" --limit 3
    echo ""

    bold "--- show event 1 ---"
    "$BRAIN" show 1
    echo ""

    green "query done."
}

# ---------------------------------------------------------------------------
# Subcommand: mcp-demo
# ---------------------------------------------------------------------------

do_mcp_demo() {
    bold "=== demo mcp-demo ==="
    load_key

    AGENT="$REPO_ROOT/target/release/mci-agent"
    if [[ ! -f "$AGENT" ]]; then
        echo "Building mci-agent..."
        cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --bin mci-agent 2>&1 | tail -3
    fi

    export MCI_DB_PATH="$DB_PATH"

    echo "Sending JSON-RPC initialize + tools/list + recall + cited context to mcp-serve..."
    echo ""

    INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}}'
    LIST_REQ='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    RECALL_REQ='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mci_recall","arguments":{"query":"agent context handoff","limit":3}}}'
    CONTEXT_REQ='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"mci_context","arguments":{"focus":"agent context handoff","max_tokens":600,"max_evidence":5}}}'
    STATS_REQ='{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"mci_stats","arguments":{}}}'

    RESPONSES=$(printf '%s\n%s\n%s\n%s\n%s\n' "$INIT_REQ" "$LIST_REQ" "$RECALL_REQ" "$CONTEXT_REQ" "$STATS_REQ" | \
        "$AGENT" mcp-serve 2>/dev/null || true)

    if [[ -z "$RESPONSES" ]]; then
        red "  mcp-serve returned no output. Check MCI_DB_KEY_HEX and DB_PATH."
        return 1
    fi

    bold "--- initialize response ---"
    echo "$RESPONSES" | head -1 | python3 -m json.tool 2>/dev/null || echo "$RESPONSES" | head -1
    echo ""

    bold "--- tools/list response ---"
    echo "$RESPONSES" | sed -n '2p' | python3 -m json.tool 2>/dev/null || echo "$RESPONSES" | sed -n '2p'
    echo ""

    bold "--- mci_recall(agent context handoff) ---"
    echo "$RESPONSES" | sed -n '3p' | python3 -m json.tool 2>/dev/null || echo "$RESPONSES" | sed -n '3p'
    echo ""

    bold "--- mci_context(agent context handoff) ---"
    echo "$RESPONSES" | sed -n '4p' | python3 -m json.tool 2>/dev/null || echo "$RESPONSES" | sed -n '4p'
    echo ""

    bold "--- mci_stats ---"
    echo "$RESPONSES" | sed -n '5p' | python3 -m json.tool 2>/dev/null || echo "$RESPONSES" | sed -n '5p'
    echo ""

    green "mcp-demo done."
}

# ---------------------------------------------------------------------------
# Subcommand: screenshot
# ---------------------------------------------------------------------------

do_screenshot() {
    if [[ "${2:-}" == "--auto" ]]; then
        do_screenshot_auto
        return
    fi

    bold "=== demo screenshot (interactive) ==="

    SHOT_DIR="$REPO_ROOT/dist/demo-screenshots"
    mkdir -p "$SHOT_DIR"
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)

    echo "Click on each window when prompted by the crosshair cursor."
    echo ""

    bold "Screenshot 1/4: Onboarding welcome (click the onboarding window)"
    SHOT1="$SHOT_DIR/onboarding-welcome-$TIMESTAMP.png"
    screencapture -w "$SHOT1"
    if [[ -f "$SHOT1" ]]; then
        normalize_screenshot "$SHOT1" "$REPO_ROOT/assets/screenshots/hero-onboarding-welcome.png"
        green "  Saved: assets/screenshots/hero-onboarding-welcome.png"
    else
        dim "  (cancelled)"
    fi

    bold "Screenshot 2/4: Recall UI window (click the Recall UI window)"
    SHOT2="$SHOT_DIR/recall-ui-$TIMESTAMP.png"
    screencapture -w "$SHOT2"
    if [[ -f "$SHOT2" ]]; then
        normalize_screenshot "$SHOT2" "$REPO_ROOT/assets/screenshots/hero-recall-ui.png"
        green "  Saved: assets/screenshots/hero-recall-ui.png"
    else
        dim "  (cancelled)"
    fi

    bold "Screenshot 3/4: Onboarding trust panel (click the onboarding window)"
    SHOT3="$SHOT_DIR/trust-panel-$TIMESTAMP.png"
    screencapture -w "$SHOT3"
    if [[ -f "$SHOT3" ]]; then
        normalize_screenshot "$SHOT3" "$REPO_ROOT/assets/screenshots/hero-onboarding-trust-panel.png"
        green "  Saved: assets/screenshots/hero-onboarding-trust-panel.png"
    else
        dim "  (cancelled)"
    fi

    bold "Screenshot 4/4: CLI terminal (click the terminal window)"
    SHOT4="$SHOT_DIR/cli-$TIMESTAMP.png"
    screencapture -w "$SHOT4"
    if [[ -f "$SHOT4" ]]; then
        normalize_screenshot "$SHOT4" "$REPO_ROOT/assets/screenshots/hero-cli.png"
        green "  Saved: assets/screenshots/hero-cli.png"
    else
        dim "  (cancelled)"
    fi

    echo ""
    echo "Final screenshots:"
    ls -lh "$REPO_ROOT/assets/screenshots/"*.png 2>/dev/null || true
    "$REPO_ROOT/scripts/test-screenshot-assets.sh"
    green "screenshot done."
}

# ---------------------------------------------------------------------------
# Subcommand: screenshot --auto  (non-interactive, requires TCC permissions)
# ---------------------------------------------------------------------------

do_screenshot_auto() {
    bold "=== demo screenshot --auto ==="
    require_cmd python3
    require_cmd sips
    require_cmd xcrun
    load_key
    ensure_demo_dirs

    export MCI_DB_PATH="$DB_PATH"
    export MCI_DB_KEY_FILE="$KEY_FILE"
    export MCI_BRAIN_BIN="$REPO_ROOT/target/release/mci-brain"
    SCREENSHOTS="$REPO_ROOT/assets/screenshots"

    bold "--- 1/4: hero-cli.png (programmatic render) ---"
    if python3 "$REPO_ROOT/scripts/render-cli-screenshot.py"; then
        green "  hero-cli.png rendered from real mci-brain output"
    else
        red "  FAILED: render-cli-screenshot.py"
        echo "  Requires: pip3 install Pillow, seed brain populated, mci-brain built"
    fi

    bold "--- 2/4: hero-recall-ui.png (screencapture -l) ---"
    RECALL_UI="$APP_PATH/Contents/MacOS/recall-ui"
    if [[ ! -f "$RECALL_UI" ]]; then
        dim "  Packaged Recall UI not built. Run: ./scripts/demo.sh boot"
    else
        HOME="$DEMO_HOME" \
            CFFIXED_USER_HOME="$DEMO_HOME" \
            MCI_DEVELOPMENT_FILE_KEY=1 \
            MCI_DB_KEY_HEX="$MCI_DB_KEY_HEX" \
            MCI_DB_PATH="$DB_PATH" \
            MCI_INITIAL_TAB=now \
            "$RECALL_UI" \
            >"$LOG_DIR/recall.stdout.log" \
            2>"$LOG_DIR/recall.stderr.log" &
        RECALL_PID=$!
        echo "$RECALL_PID" > "$PID_DIR/recall.pid"

        WID=""
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            WID=$(window_id_for_pid "$RECALL_PID")
            [[ -n "$WID" ]] && break
            sleep 0.5
        done
        if [[ -n "$WID" ]]; then
            screencapture -l "$WID" -o /tmp/recall-ui-auto.png 2>/dev/null
            if [[ -f /tmp/recall-ui-auto.png ]]; then
                normalize_screenshot /tmp/recall-ui-auto.png "$SCREENSHOTS/hero-recall-ui.png"
                green "  hero-recall-ui.png captured"
            else
                dim "  screencapture failed (TCC Screen Recording permission needed)"
            fi
        else
            dim "  Could not find the Recall window for process $RECALL_PID"
        fi
        kill "$RECALL_PID" 2>/dev/null || true
        rm -f "$PID_DIR/recall.pid"
    fi

    bold "--- 3/4: hero-onboarding-welcome.png ---"
    dim "  Preserving the reviewed Welcome capture. Navigation is intentionally interactive."

    bold "--- 4/4: hero-onboarding-trust-panel.png ---"
    dim "  Preserving the reviewed Trust-panel capture. Navigation is intentionally interactive."

    echo ""
    bold "Final state:"
    ls -lh "$SCREENSHOTS"/*.png 2>/dev/null || true

    echo ""
    bold "Privacy check:"
    file "$SCREENSHOTS"/*.png 2>/dev/null
    "$REPO_ROOT/scripts/test-screenshot-assets.sh"
    echo ""
    dim "Visually inspect each PNG before committing — confirm no real user content."
    green "screenshot --auto done."
}

# ---------------------------------------------------------------------------
# Subcommand: teardown
# ---------------------------------------------------------------------------

do_teardown() {
    bold "=== demo teardown ==="

    echo "Stopping only processes recorded below $PID_DIR..."
    stop_demo_processes
    if [[ -d "$DEMO_ROOT" ]]; then
        echo "Deleting disposable demo state: $DEMO_ROOT"
        rm -rf "$DEMO_ROOT"
    fi

    green "teardown done."
}

# ---------------------------------------------------------------------------
# Subcommand: full
# ---------------------------------------------------------------------------

do_full() {
    bold "========================================"
    bold "  MCI / Hippocampus — Full E2E Demo"
    bold "========================================"
    echo ""

    do_clean
    echo ""
    do_seed
    echo ""
    do_boot
    echo ""
    echo "Waiting 3s for Hippocampus.app to settle..."
    sleep 3
    echo ""
    do_query
    echo ""
    do_mcp_demo
    echo ""
    do_screenshot_auto
    echo ""
    do_teardown

    echo ""
    green "========================================"
    green "  Full demo complete."
    green "========================================"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

case "$1" in
    clean)      do_clean ;;
    seed)       do_seed ;;
    boot)       do_boot ;;
    query)      do_query ;;
    mcp-demo)   do_mcp_demo ;;
    screenshot) do_screenshot "$@" ;;
    teardown)   do_teardown ;;
    full)       do_full ;;
    -h|--help)  usage ;;
    *)
        red "Unknown command: $1"
        usage
        exit 1
        ;;
esac
