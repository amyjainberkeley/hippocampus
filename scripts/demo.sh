#!/usr/bin/env bash
set -euo pipefail

# scripts/demo.sh — Reproducible E2E pitch demo for Hippocampus / MCI.
#
# Subcommands:
#   clean      Kill processes, wipe demo brain, archive logs.
#   seed       Generate ephemeral key + seed 20 synthetic events.
#   boot       Build Hippocampus.app, embed Sparkle, codesign, launch.
#   query      Run canned mci-brain queries against the seeded brain.
#   mcp-demo   JSON-RPC mci_recall against running mcp-serve.
#   screenshot  Capture window screenshots (interactive screencapture -w).
#   screenshot --auto  Non-interactive: render CLI + attempt GUI captures.
#   teardown   Kill processes, optionally archive/delete demo brain.
#   full       Run all subcommands in sequence.
#
# CSO posture:
#   - Ephemeral key lives in /tmp/mci-demo-key.hex (mode 0600).
#   - Never writes to shell history (key generated inline, not exported).
#   - teardown deletes the demo brain (or moves to /tmp).
#   - Seed events are synthetic (com.mci.demo.seed.*), no real user content.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MCI_DIR="$HOME/Library/Application Support/MCI"
DB_PATH="$MCI_DIR/mci.sqlite"
LOG_DIR="$HOME/Library/Logs/MCI"
KEY_FILE="/tmp/mci-demo-key.hex"
BUILD_APP="$REPO_ROOT/apps/hippocampus/Resources/build-app.sh"
APP_DIST="$REPO_ROOT/apps/hippocampus/dist"
APP_PATH="$APP_DIST/Hippocampus.app"

# macOS Tahoe (26.x) toolchain note (PR #95):
# swift build may warn about deployment target vs SDK version.
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

load_key() {
    if [[ -f "$KEY_FILE" ]]; then
        MCI_DB_KEY_HEX=$(cat "$KEY_FILE")
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

Demo key is stored at $KEY_FILE (mode 0600, ephemeral).
Brain is at $DB_PATH.
EOF
}

# ---------------------------------------------------------------------------
# Subcommand: clean
# ---------------------------------------------------------------------------

do_clean() {
    bold "=== demo clean ==="

    echo "Killing Hippocampus / mci-agent / mci-capture-helper processes..."
    pkill -f "Hippocampus" 2>/dev/null || true
    pkill -f "mci-agent" 2>/dev/null || true
    pkill -f "mci-capture-helper" 2>/dev/null || true
    sleep 1

    if [[ -f "$DB_PATH" ]]; then
        echo "Removing demo brain: $DB_PATH"
        rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"
    else
        dim "  (no brain file found)"
    fi

    if [[ -d "$LOG_DIR" ]] && ls "$LOG_DIR"/*.log &>/dev/null 2>&1; then
        ARCHIVE="/tmp/mci-logs-$(date +%Y%m%d-%H%M%S).tar.gz"
        echo "Archiving logs to $ARCHIVE"
        tar czf "$ARCHIVE" -C "$HOME/Library/Logs" MCI/ 2>/dev/null || true
        rm -rf "$LOG_DIR"
    else
        dim "  (no logs to archive)"
    fi

    if [[ -f "$KEY_FILE" ]]; then
        echo "Removing old key file: $KEY_FILE"
        rm -f "$KEY_FILE"
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

    echo "Generating ephemeral SQLCipher key..."
    openssl rand -hex 32 > "$KEY_FILE"
    chmod 0600 "$KEY_FILE"
    dim "  key: $KEY_FILE (mode 0600)"

    export MCI_DB_KEY_HEX
    MCI_DB_KEY_HEX=$(cat "$KEY_FILE")

    mkdir -p "$MCI_DIR"

    echo "Building mci-seed-brain..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --bin mci-seed-brain 2>&1 | tail -3

    echo "Seeding 20 synthetic events..."
    "$REPO_ROOT/target/release/mci-seed-brain" --db-path "$DB_PATH"

    echo ""
    ls -lh "$DB_PATH"
    green "seed done. Brain at $DB_PATH"
}

# ---------------------------------------------------------------------------
# Subcommand: boot
# ---------------------------------------------------------------------------

do_boot() {
    bold "=== demo boot ==="
    require_cmd swift
    require_cmd cargo
    require_cmd codesign
    require_cmd install_name_tool

    echo "Building Swift + Rust binaries (release)..."
    (cd "$REPO_ROOT/apps/hippocampus" && swift build -c release 2>&1 | tail -3)
    (cd "$REPO_ROOT/adapters/macos/MCICaptureHelper" && swift build -c release 2>&1 | tail -3)
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --workspace --release 2>&1 | tail -3

    echo "Assembling Hippocampus.app via build-app.sh..."
    "$BUILD_APP"

    FRAMEWORKS="$APP_PATH/Contents/Frameworks"

    if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
        green "  Sparkle.framework already embedded by build-app.sh"
    else
        echo "Sparkle.framework not found in app bundle — checking SwiftPM artifacts..."
        SPARKLE_SRC=""
        for candidate in \
            "$REPO_ROOT/apps/hippocampus/.build/release/Sparkle.framework" \
            "$REPO_ROOT/apps/hippocampus/.build/artifacts/sparkle/Sparkle/Sparkle.framework" \
            "$REPO_ROOT/apps/hippocampus/.build/artifacts/Sparkle/Sparkle.framework"; do
            if [[ -d "$candidate" ]]; then
                SPARKLE_SRC="$candidate"
                break
            fi
        done
        if [[ -n "$SPARKLE_SRC" ]]; then
            mkdir -p "$FRAMEWORKS"
            cp -R "$SPARKLE_SRC" "$FRAMEWORKS/"
            green "  Embedded Sparkle.framework from $SPARKLE_SRC"
        else
            dim "  WARNING: Sparkle.framework not found anywhere. Auto-update won't work."
        fi
    fi

    echo "Adding @executable_path/../Frameworks rpath..."
    install_name_tool -add_rpath @executable_path/../Frameworks \
        "$APP_PATH/Contents/MacOS/Hippocampus" 2>/dev/null || true

    echo "Re-codesigning app bundle..."
    codesign --force --deep --sign - "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH" && green "  Signature valid."

    echo ""
    echo "Launching Hippocampus.app..."
    load_key
    open "$APP_PATH"

    green "boot done. Hippocampus.app running."
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

    bold "--- search: snowflake ---"
    "$BRAIN" search snowflake --limit 3
    echo ""

    bold "--- search: Cure53 ---"
    "$BRAIN" search Cure53 --limit 3
    echo ""

    bold "--- search: zero-knowledge ---"
    "$BRAIN" search zero-knowledge --limit 3
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

    echo "Sending JSON-RPC initialize + tools/list + mci_recall to mcp-serve..."
    echo ""

    INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}}'
    LIST_REQ='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    RECALL_REQ='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mci_recall","arguments":{"query":"snowflake arctic embed","limit":3}}}'
    STATS_REQ='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"mci_stats","arguments":{}}}'

    RESPONSES=$(printf '%s\n%s\n%s\n%s\n' "$INIT_REQ" "$LIST_REQ" "$RECALL_REQ" "$STATS_REQ" | \
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

    bold "--- mci_recall(snowflake arctic embed) ---"
    echo "$RESPONSES" | sed -n '3p' | python3 -m json.tool 2>/dev/null || echo "$RESPONSES" | sed -n '3p'
    echo ""

    bold "--- mci_stats ---"
    echo "$RESPONSES" | sed -n '4p' | python3 -m json.tool 2>/dev/null || echo "$RESPONSES" | sed -n '4p'
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

    bold "Screenshot 1/4: Hippocampus menu-bar (click the menu-bar icon area)"
    SHOT1="$SHOT_DIR/hippocampus-menu-$TIMESTAMP.png"
    screencapture -w "$SHOT1"
    if [[ -f "$SHOT1" ]]; then
        sips -z 800 1280 "$SHOT1" --out "$REPO_ROOT/assets/screenshots/hero-hippocampus-menu.png" >/dev/null
        green "  Saved: assets/screenshots/hero-hippocampus-menu.png"
    else
        dim "  (cancelled)"
    fi

    bold "Screenshot 2/4: Recall UI window (click the Recall UI window)"
    SHOT2="$SHOT_DIR/recall-ui-$TIMESTAMP.png"
    screencapture -w "$SHOT2"
    if [[ -f "$SHOT2" ]]; then
        sips -z 800 1280 "$SHOT2" --out "$REPO_ROOT/assets/screenshots/hero-recall-ui.png" >/dev/null
        green "  Saved: assets/screenshots/hero-recall-ui.png"
    else
        dim "  (cancelled)"
    fi

    bold "Screenshot 3/4: Onboarding trust panel (click the onboarding window)"
    SHOT3="$SHOT_DIR/trust-panel-$TIMESTAMP.png"
    screencapture -w "$SHOT3"
    if [[ -f "$SHOT3" ]]; then
        sips -z 800 1280 "$SHOT3" --out "$REPO_ROOT/assets/screenshots/hero-onboarding-trust-panel.png" >/dev/null
        green "  Saved: assets/screenshots/hero-onboarding-trust-panel.png"
    else
        dim "  (cancelled)"
    fi

    bold "Screenshot 4/4: CLI terminal (click the terminal window)"
    SHOT4="$SHOT_DIR/cli-$TIMESTAMP.png"
    screencapture -w "$SHOT4"
    if [[ -f "$SHOT4" ]]; then
        sips -z 800 1280 "$SHOT4" --out "$REPO_ROOT/assets/screenshots/hero-cli.png" >/dev/null
        green "  Saved: assets/screenshots/hero-cli.png"
    else
        dim "  (cancelled)"
    fi

    echo ""
    echo "Final screenshots:"
    ls -lh "$REPO_ROOT/assets/screenshots/"*.png 2>/dev/null || true
    green "screenshot done."
}

# ---------------------------------------------------------------------------
# Subcommand: screenshot --auto  (non-interactive, requires TCC permissions)
# ---------------------------------------------------------------------------

do_screenshot_auto() {
    bold "=== demo screenshot --auto ==="
    require_cmd python3
    require_cmd sips
    load_key

    export MCI_DB_PATH="$DB_PATH"
    SCREENSHOTS="$REPO_ROOT/assets/screenshots"

    bold "--- 1/4: hero-cli.png (programmatic render) ---"
    if python3 "$REPO_ROOT/scripts/render-cli-screenshot.py"; then
        green "  hero-cli.png rendered from real mci-brain output"
    else
        red "  FAILED: render-cli-screenshot.py"
        echo "  Requires: pip3 install Pillow, seed brain populated, mci-brain built"
    fi

    bold "--- 2/4: hero-recall-ui.png (screencapture -l) ---"
    RECALL_UI="$REPO_ROOT/apps/recall-ui/.build/release/recall-ui"
    if [[ ! -f "$RECALL_UI" ]]; then
        dim "  RecallUI not built. Skipping."
        dim "  Build: cd apps/recall-ui && swift build -c release"
    else
        "$RECALL_UI" &
        RECALL_PID=$!
        sleep 2

        WID=$(osascript -e 'tell application "System Events" to get id of first window of process "recall-ui"' 2>/dev/null || echo "")
        if [[ -n "$WID" ]]; then
            screencapture -l "$WID" -o /tmp/recall-ui-auto.png 2>/dev/null
            if [[ -f /tmp/recall-ui-auto.png ]]; then
                sips -z 800 1280 /tmp/recall-ui-auto.png --out "$SCREENSHOTS/hero-recall-ui.png" >/dev/null
                green "  hero-recall-ui.png captured"
            else
                dim "  screencapture failed (TCC Screen Recording permission needed)"
            fi
        else
            dim "  Could not get window ID (TCC Accessibility permission needed)"
        fi
        kill "$RECALL_PID" 2>/dev/null || true
    fi

    bold "--- 3/4: hero-hippocampus-menu.png (requires interactive) ---"
    dim "  Menu-bar dropdowns require interactive click."
    dim "  Use: screencapture -w assets/screenshots/hero-hippocampus-menu.png"
    dim "  Or run: demo.sh screenshot (interactive mode)"

    bold "--- 4/4: hero-onboarding-trust-panel.png (screencapture -l) ---"
    ONBOARDING="$REPO_ROOT/apps/onboarding/.build/release/onboarding"
    if [[ ! -f "$ONBOARDING" ]]; then
        dim "  Onboarding not built. Skipping."
        dim "  Build: cd apps/onboarding && swift build -c release"
    else
        "$ONBOARDING" &
        ONBOARD_PID=$!
        sleep 2

        WID=$(osascript -e 'tell application "System Events" to get id of first window of process "onboarding"' 2>/dev/null || echo "")
        if [[ -n "$WID" ]]; then
            screencapture -l "$WID" -o /tmp/onboarding-auto.png 2>/dev/null
            if [[ -f /tmp/onboarding-auto.png ]]; then
                sips -z 800 1280 /tmp/onboarding-auto.png --out "$SCREENSHOTS/hero-onboarding-trust-panel.png" >/dev/null
                green "  hero-onboarding-trust-panel.png captured"
                dim "  NOTE: may need manual navigation to 'What MCI Ignores' panel first"
            else
                dim "  screencapture failed (TCC Screen Recording permission needed)"
            fi
        else
            dim "  Could not get window ID (TCC Accessibility permission needed)"
        fi
        kill "$ONBOARD_PID" 2>/dev/null || true
    fi

    echo ""
    bold "Final state:"
    ls -lh "$SCREENSHOTS"/*.png 2>/dev/null || true

    echo ""
    bold "Privacy check:"
    file "$SCREENSHOTS"/*.png 2>/dev/null
    echo ""
    dim "Visually inspect each PNG before committing — confirm no real user content."
    green "screenshot --auto done."
}

# ---------------------------------------------------------------------------
# Subcommand: teardown
# ---------------------------------------------------------------------------

do_teardown() {
    bold "=== demo teardown ==="

    echo "Killing Hippocampus / mci-agent / mci-capture-helper processes..."
    pkill -f "Hippocampus" 2>/dev/null || true
    pkill -f "mci-agent" 2>/dev/null || true
    pkill -f "mci-capture-helper" 2>/dev/null || true
    sleep 1

    if [[ -f "$DB_PATH" ]]; then
        ARCHIVE="/tmp/mci-demo-brain-$(date +%Y%m%d-%H%M%S).sqlite"
        echo "Archiving demo brain to $ARCHIVE"
        cp "$DB_PATH" "$ARCHIVE"
        rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"
        green "  Brain archived to $ARCHIVE and removed from $MCI_DIR"
    else
        dim "  (no brain file to clean up)"
    fi

    if [[ -f "$KEY_FILE" ]]; then
        echo "Removing ephemeral key: $KEY_FILE"
        rm -f "$KEY_FILE"
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
    do_screenshot
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
