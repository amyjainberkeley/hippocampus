#!/usr/bin/env bash

# Shared lifecycle primitives for build-installer.sh. This file is sourced;
# callers keep their shell-option authority.

HIPP_INSTALLER_ACTIVE_PID=""
HIPP_INSTALLER_ACTIVE_PGID=""
HIPP_INSTALLER_MOUNT_ROOT=""

hippocampus_installer_mount() {
    [[ -z "${MOUNT_DIR:-}" && -z "$HIPP_INSTALLER_MOUNT_ROOT" ]] || return 1
    HIPP_INSTALLER_MOUNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocampus-installer-mount.XXXXXX")" || return 1
    MOUNT_DIR="$HIPP_INSTALLER_MOUNT_ROOT/volume"
    mkdir "$MOUNT_DIR" || return 1
    # Never discover or detach similarly named user volumes. Mark the private
    # mount before attach so even a partially failed attach has scoped cleanup.
    hdiutil attach -readwrite -noverify -noautoopen -nobrowse \
        -mountpoint "$MOUNT_DIR" "$1"
}

hippocampus_installer_unmount() {
    [[ -n "${MOUNT_DIR:-}" ]] || return 0
    if [[ -z "$HIPP_INSTALLER_MOUNT_ROOT" || "$MOUNT_DIR" != "$HIPP_INSTALLER_MOUNT_ROOT/volume" ]]; then
        echo "WARNING: Refusing to detach an unowned installer mount: $MOUNT_DIR" >&2
        return 1
    fi
    if ! hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null &&
        ! hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null; then
        echo "WARNING: Could not detach private build mount; preserving $MOUNT_DIR and ${TEMP_DMG:-its backing image}" >&2
        return 1
    fi
    rmdir "$MOUNT_DIR" 2>/dev/null || true
    rmdir "$HIPP_INSTALLER_MOUNT_ROOT" 2>/dev/null || true
    MOUNT_DIR=""
    HIPP_INSTALLER_MOUNT_ROOT=""
}

hippocampus_process_tree() {
    local parent_pid="$1"
    local child_pid

    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        hippocampus_process_tree "$child_pid"
    done < <(pgrep -P "$parent_pid" 2>/dev/null || true)
    printf '%s\n' "$parent_pid"
}

hippocampus_signal_pids() {
    local signal="$1"
    shift
    local pid

    for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "-$signal" "$pid" 2>/dev/null || true
        fi
    done
}

hippocampus_any_pid_alive() {
    local pid
    for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

hippocampus_terminate_process_tree() {
    local root_pid="$1"
    local grace_seconds="$2"
    local tree_text pid
    local -a tree_pids=()

    tree_text="$(hippocampus_process_tree "$root_pid")"
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && tree_pids+=("$pid")
    done <<<"$tree_text"

    hippocampus_signal_pids TERM "${tree_pids[@]}"
    local grace_deadline=$((SECONDS + grace_seconds))
    while hippocampus_any_pid_alive "${tree_pids[@]}" && (( SECONDS < grace_deadline )); do
        sleep 0.1
    done
    if hippocampus_any_pid_alive "${tree_pids[@]}"; then
        hippocampus_signal_pids KILL "${tree_pids[@]}"
    fi
}

hippocampus_process_group_alive() {
    local process_group_id="$1"
    kill -0 -- "-$process_group_id" 2>/dev/null
}

hippocampus_signal_process_group() {
    local signal="$1"
    local process_group_id="$2"
    kill "-$signal" -- "-$process_group_id" 2>/dev/null || true
}

hippocampus_terminate_process_group() {
    local process_group_id="$1"
    local grace_seconds="$2"

    hippocampus_signal_process_group TERM "$process_group_id"
    local grace_deadline=$((SECONDS + grace_seconds))
    while hippocampus_process_group_alive "$process_group_id" &&
        (( SECONDS < grace_deadline )); do
        sleep 0.1
    done
    if hippocampus_process_group_alive "$process_group_id"; then
        hippocampus_signal_process_group KILL "$process_group_id"
    fi
}

hippocampus_wait_for_isolated_process_group() {
    local process_id="$1"
    local process_group_id attempt

    for ((attempt = 0; attempt < 100; attempt++)); do
        if ! kill -0 "$process_id" 2>/dev/null; then
            return 1
        fi
        process_group_id="$(ps -o pgid= -p "$process_id" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$process_group_id" == "$process_id" ]]; then
            return 0
        fi
        sleep 0.01
    done
    return 2
}

hippocampus_run_with_deadline() {
    local timeout_seconds="$1"
    local kill_grace_seconds="$2"
    shift 2

    case "$timeout_seconds:$kill_grace_seconds" in
        *[!0-9:]*|:*|*:) return 2 ;;
    esac

    local python3
    python3="$(command -v python3)" || return 125
    "$python3" -c \
        'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
        "$@" &
    HIPP_INSTALLER_ACTIVE_PID=$!

    local group_start_status=0
    hippocampus_wait_for_isolated_process_group "$HIPP_INSTALLER_ACTIVE_PID" ||
        group_start_status=$?
    if [[ "$group_start_status" -eq 1 ]]; then
        local immediate_status=0
        wait "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || immediate_status=$?
        HIPP_INSTALLER_ACTIVE_PID=""
        return "$immediate_status"
    fi
    if [[ "$group_start_status" -ne 0 ]]; then
        hippocampus_terminate_process_tree "$HIPP_INSTALLER_ACTIVE_PID" 1
        wait "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
        HIPP_INSTALLER_ACTIVE_PID=""
        return 125
    fi
    HIPP_INSTALLER_ACTIVE_PGID="$HIPP_INSTALLER_ACTIVE_PID"

    local deadline=$((SECONDS + timeout_seconds))
    while kill -0 "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null &&
        (( SECONDS < deadline )); do
        sleep 0.1
    done

    if kill -0 "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null; then
        hippocampus_terminate_process_group \
            "$HIPP_INSTALLER_ACTIVE_PGID" \
            "$kill_grace_seconds"
        wait "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
        HIPP_INSTALLER_ACTIVE_PID=""
        HIPP_INSTALLER_ACTIVE_PGID=""
        return 124
    fi

    local child_status=0
    wait "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || child_status=$?
    if hippocampus_process_group_alive "$HIPP_INSTALLER_ACTIVE_PGID"; then
        hippocampus_terminate_process_group \
            "$HIPP_INSTALLER_ACTIVE_PGID" \
            "$kill_grace_seconds"
    fi
    HIPP_INSTALLER_ACTIVE_PID=""
    HIPP_INSTALLER_ACTIVE_PGID=""
    return "$child_status"
}

hippocampus_installer_cleanup() {
    local _status="${1:-0}"

    if [[ -n "${HIPP_INSTALLER_ACTIVE_PGID:-}" ]] &&
        hippocampus_process_group_alive "$HIPP_INSTALLER_ACTIVE_PGID"; then
        hippocampus_terminate_process_group "$HIPP_INSTALLER_ACTIVE_PGID" 1
    elif [[ -n "${HIPP_INSTALLER_ACTIVE_PID:-}" ]] &&
        kill -0 "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null; then
        hippocampus_terminate_process_tree "$HIPP_INSTALLER_ACTIVE_PID" 1
    fi
    if [[ -n "${HIPP_INSTALLER_ACTIVE_PID:-}" ]]; then
        wait "$HIPP_INSTALLER_ACTIVE_PID" 2>/dev/null || true
    fi
    HIPP_INSTALLER_ACTIVE_PID=""
    HIPP_INSTALLER_ACTIVE_PGID=""

    local mount_released=1
    hippocampus_installer_unmount || mount_released=0

    if [[ -n "${SIGNING_SCRATCH:-}" ]]; then
        rm -rf "$SIGNING_SCRATCH"
    fi
    SIGNING_SCRATCH=""

    if [[ -n "${DMG_STAGING:-}" ]]; then
        rm -rf "$DMG_STAGING"
    fi
    DMG_STAGING=""

    if [[ "$mount_released" -eq 1 && -n "${TEMP_DMG:-}" ]]; then
        rm -f "$TEMP_DMG"
        TEMP_DMG=""
    fi
    if [[ "$mount_released" -eq 1 && -n "${TEMP_DMG_ROOT:-}" ]]; then
        rmdir "$TEMP_DMG_ROOT" 2>/dev/null || true
        TEMP_DMG_ROOT=""
    fi

    if [[ -n "${APP_ZIP:-}" ]]; then
        rm -f "$APP_ZIP"
    fi
    APP_ZIP=""

    if [[ "$_status" -ne 0 && -n "${FINAL_DMG_PENDING:-}" ]]; then
        rm -f "$FINAL_DMG_PENDING" "${FINAL_DMG_PENDING}.sha256"
    fi
    FINAL_DMG_PENDING=""

    return 0
}
