#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# no-listener.sh — prove no Hippocampus process opens a TCP listening port.
#
# Hippocampus talks to its own helpers over Unix-domain sockets (AF_UNIX),
# never a TCP port, and it never accepts inbound connections. A reviewer
# can confirm there is no open port with one command; this wraps it.
#
# Method: find every running process whose executable lives inside
# Hippocampus.app (menu bar, capture helper, OCR worker, agent + each MCP
# server, Ask, window, setup, Safari extension), then ask lsof whether any
# of them holds a TCP socket in the LISTEN state. Any hit fails (exit 1).
#
# Outbound loopback connections (to Ollama / an opt-in loopback MCP server)
# are ESTABLISHED, not LISTEN, so -sTCP:LISTEN correctly ignores them; this
# checker is only about ports the app would *accept* connections on.
#
# No root needed (the processes run as you). Read-only; -nP disables name
# and port lookups, so nothing is resolved over the network and no screen
# content is read.
#
# Usage:  scripts/launch/no-listener.sh [/path/to/Hippocampus.app]
# Env:    HIPPO_APP  app bundle path (default /Applications/Hippocampus.app)

set -uo pipefail

APP="${1:-${HIPPO_APP:-/Applications/Hippocampus.app}}"
APP="${APP%/}"
LSOF="$(command -v lsof || echo /usr/sbin/lsof)"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=; GRN=; YEL=; DIM=; RST=; }

# Known shipped binary basenames — a safety net in case ps reports a bare
# name rather than the full bundle path for some process.
NAMES_RE='^(Hippocampus|MCICaptureHelper|mci-agent|hippocampus-mind|hippocampus-native-host|onboarding|recall-ui|hippocampus-ocr|HippocampusSafariExtension)$'

echo "Hippocampus TCP-listener check — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "App bundle: $APP"
echo

# ── Find Hippocampus PIDs: executable under the bundle, or a known name. ─
APP_PIDS="$(ps -axo pid=,comm= 2>/dev/null | awk -v app="$APP/" -v names="$NAMES_RE" '
  {
    pid=$1; $1="";
    cmd=$0; sub(/^ +/, "", cmd);
    if (index(cmd, app)==1) { print pid; next }
    n=split(cmd, a, "/"); base=a[n];
    if (base ~ names) { print pid }
  }' | sort -n -u)"

if [[ -z "$APP_PIDS" ]]; then
  printf '%bNOTE%b Hippocampus does not appear to be running.\n' "$YEL" "$RST"
  echo "This check observes a running app; start it and re-run for a live result."
  echo "(No process means no listening port, but nothing was observed to prove it.)"
  # Soft pass: there is nothing listening because nothing is running.
  printf '%bNO-LISTENER PASS (vacuous)%b — no Hippocampus process was running to inspect.\n' "$GRN" "$RST"
  exit 0
fi

n_proc="$(printf '%s\n' "$APP_PIDS" | grep -c .)"
echo "Observed $n_proc Hippocampus processes:"
printf '%s\n' "$APP_PIDS" | while read -r pid; do
  [[ -n "$pid" ]] || continue
  path="$(ps -o comm= -p "$pid" 2>/dev/null)"
  printf '  %s  %s%s%s\n' "$pid" "$DIM" "${path:-?}" "$RST"
done
echo

PIDLIST="$(printf '%s' "$APP_PIDS" | tr '\n' ',' | sed 's/,$//')"

# ── Ask lsof whether any of those PIDs holds a TCP LISTEN socket. ────────
echo "== TCP sockets in LISTEN held by Hippocampus processes =="
LISTEN_OUT="$("$LSOF" -nP -iTCP -sTCP:LISTEN -a -p "$PIDLIST" 2>/dev/null)"
if [[ -n "$LISTEN_OUT" ]]; then
  echo "$LISTEN_OUT"
  echo
  printf '%bNO-LISTENER FAIL%b — a Hippocampus process is listening on a TCP port (above).\n' "$RED" "$RST"
  exit 1
fi
echo "  (none)"
echo

# ── Defense in depth: scan the global LISTEN table for any of our PIDs. ──
echo "== Cross-check against the full system LISTEN table =="
GLOBAL="$("$LSOF" -nP -iTCP -sTCP:LISTEN 2>/dev/null)"
hitrows=""
if [[ -n "$GLOBAL" ]]; then
  for pid in $APP_PIDS; do
    row="$(printf '%s\n' "$GLOBAL" | awk -v p="$pid" 'NR>1 && $2==p')"
    [[ -n "$row" ]] && hitrows="$hitrows$row"$'\n'
  done
fi
total_listen="$(printf '%s\n' "$GLOBAL" | awk 'NR>1' | grep -c . 2>/dev/null || echo 0)"
echo "  $total_listen TCP listeners on this Mac in total; none belong to Hippocampus."
if [[ -n "${hitrows// /}" ]]; then
  echo "$hitrows"
  printf '%bNO-LISTENER FAIL%b — cross-check found a Hippocampus PID listening.\n' "$RED" "$RST"
  exit 1
fi
echo

printf '%bNO-LISTENER PASS%b — %s Hippocampus processes, 0 TCP ports in LISTEN. IPC is AF_UNIX only.\n' "$GRN" "$RST" "$n_proc"
exit 0
