#!/usr/bin/env bash

# Shared lifecycle primitives for build-installer.sh. This file is sourced;
# callers keep their shell-option authority.

HIPP_INSTALLER_ACTIVE_PID=""
HIPP_INSTALLER_WATCHDOG_PID=""

hippocampus_run_with_deadline() {
    local timeout_seconds="$1"
    local kill_grace_seconds="$2"
    shift 2

    case "$timeout_seconds:$kill_grace_seconds" in
        *[!0-9:]*|:*|*:) return 2 ;;
    esac

    local timeout_marker
    timeout_marker="$(mktemp -t hippocampus-installer-deadline)"
    rm -f "$timeout_marker"

    "$@" &
    HIPP_INSTALLER_ACTIVE_PID=$!

    (
        sleep "$timeout_seconds"
        if kill -0 "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null; then
            : >"$timeout_marker"
            kill -TERM "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
            sleep "$kill_grace_seconds"
            if kill -0 "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null; then
                kill -KILL "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
            fi
        fi
    ) &
    HIPP_INSTALLER_WATCHDOG_PID=$!

    local child_status=0
    wait "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || child_status=$?

    if kill -0 "$HIPP_INSTALLER_WATCHDOG_PID" 2>/dev/null; then
        kill -TERM "$HIPP_INSTALLER_WATCHDOG_PID" 2>/dev/null || true
    fi
    wait "$HIPP_INSTALLER_WATCHDOG_PID" 2>/dev/null || true
    HIPP_INSTALLER_ACTIVE_PID=""
    HIPP_INSTALLER_WATCHDOG_PID=""

    if [[ -f "$timeout_marker" ]]; then
        rm -f "$timeout_marker"
        return 124
    fi
    rm -f "$timeout_marker"
    return "$child_status"
}

hippocampus_installer_cleanup() {
    local _status="${1:-0}"

    if [[ -n "${HIPP_INSTALLER_WATCHDOG_PID:-}" ]] &&
        kill -0 "$HIPP_INSTALLER_WATCHDOG_PID" 2>/dev/null; then
        kill -TERM "$HIPP_INSTALLER_WATCHDOG_PID" 2>/dev/null || true
        wait "$HIPP_INSTALLER_WATCHDOG_PID" 2>/dev/null || true
    fi
    HIPP_INSTALLER_WATCHDOG_PID=""

    if [[ -n "${HIPP_INSTALLER_ACTIVE_PID:-}" ]] &&
        kill -0 "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null; then
        kill -TERM "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
        sleep 0.2
        if kill -0 "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null; then
            kill -KILL "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
        fi
        wait "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
    fi
    HIPP_INSTALLER_ACTIVE_PID=""

    if [[ -n "${MOUNT_DIR:-}" ]] && command -v hdiutil >/dev/null 2>&1; then
        hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null ||
            hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null ||
            true
    fi
    MOUNT_DIR=""

    if [[ -n "${SIGNING_SCRATCH:-}" ]]; then
        rm -rf "$SIGNING_SCRATCH"
    fi
    SIGNING_SCRATCH=""

    if [[ -n "${DMG_STAGING:-}" ]]; then
        rm -rf "$DMG_STAGING"
    fi
    DMG_STAGING=""

    if [[ -n "${TEMP_DMG:-}" ]]; then
        rm -f "$TEMP_DMG"
    fi
    TEMP_DMG=""

    if [[ -n "${APP_ZIP:-}" ]]; then
        rm -f "$APP_ZIP"
    fi
    APP_ZIP=""

    return 0
}
