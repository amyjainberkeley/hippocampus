#!/usr/bin/env bash
# SPDX-License-Identifier: TBD-private
#
# step1_footprint_preread.sh — SOFT footprint PRE-READ for Track B Step 1.
#
# ┌────────────────────────────────────────────────────────────────────┐
# │ THIS IS NOT THE G2 FOOTPRINT PROOF.                                 │
# │                                                                     │
# │ G2 (AGENT_PROTOCOL §4/§9: steady-state ≤ ~1–2% of one core /        │
# │ ≤ ~250 MB RAM on a REAL workday) is a separate human-in-the-loop    │
# │ gate that MUST NOT be auto-passed or fabricated. This script only   │
# │ produces a rough, indicative pre-read of the helper's CPU/RSS while │
# │ you run the Step-1 observation pass, so an obvious regression is    │
# │ visible early. A "good" pre-read does NOT satisfy G2.               │
# └────────────────────────────────────────────────────────────────────┘
#
# Read-only: samples `ps` for the helper PID. Touches no protected-set
# code. Stop with Ctrl-C; summary prints on exit.
#
# Usage:
#   tools/step1_footprint_preread.sh [pid] [interval_seconds]
# If pid is omitted it is resolved from the running mci-capture-helper.

set -u

PID="${1:-}"
INTERVAL="${2:-5}"
LOG="/tmp/mci-step1-footprint-preread.csv"

if [ -z "$PID" ]; then
  PID="$(pgrep -x mci-capture-helper | head -1 || true)"
fi
if [ -z "$PID" ] || ! ps -p "$PID" >/dev/null 2>&1; then
  echo "no running mci-capture-helper found (pass an explicit pid as arg 1)" >&2
  echo "start it first:  .build/debug/mci-capture-helper --capture --output /tmp/mci-step1.bin --heartbeat-seconds 5" >&2
  exit 1
fi

NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
echo "sampling pid=$PID every ${INTERVAL}s — Ctrl-C to stop. host cores=${NCPU}"
echo "NOTE: %cpu is share of ONE core (ps convention); compare against the"
echo "      ~1–2% one-core SLO informally only. This is a PRE-READ, not G2."
echo "ts_iso,pid,pct_cpu_one_core,rss_mb" > "$LOG"

cpu_vals=()
rss_vals=()

summary() {
  echo
  echo "--- Step-1 footprint PRE-READ summary (NOT G2) ---"
  local n=${#cpu_vals[@]}
  if [ "$n" -eq 0 ]; then echo "no samples"; exit 0; fi
  printf '%s\n' "${cpu_vals[@]}" | sort -n > /tmp/.mci_cpu_sort
  printf '%s\n' "${rss_vals[@]}" | sort -n > /tmp/.mci_rss_sort
  local cmin cmed cmax rmin rmed rmax mid
  mid=$(( n / 2 ))
  cmin=$(head -1 /tmp/.mci_cpu_sort); cmax=$(tail -1 /tmp/.mci_cpu_sort)
  cmed=$(sed -n "$((mid+1))p" /tmp/.mci_cpu_sort)
  rmin=$(head -1 /tmp/.mci_rss_sort); rmax=$(tail -1 /tmp/.mci_rss_sort)
  rmed=$(sed -n "$((mid+1))p" /tmp/.mci_rss_sort)
  echo "samples           : $n  (log: $LOG)"
  echo "%CPU (one core)   : min=$cmin  median=$cmed  max=$cmax"
  echo "RSS MB            : min=$rmin  median=$rmed  max=$rmax"
  echo "informal SLO ref  : steady-state ≤ ~1–2% one core / ≤ ~250 MB"
  echo "reminder          : indicative only — the binding G2 proof is a"
  echo "                    separate real-workday measurement, never faked."
  rm -f /tmp/.mci_cpu_sort /tmp/.mci_rss_sort
  exit 0
}
trap summary INT TERM

while ps -p "$PID" >/dev/null 2>&1; do
  line="$(ps -p "$PID" -o %cpu=,rss= 2>/dev/null | awk '{printf "%.1f,%.1f", $1, $2/1024.0}')"
  [ -z "$line" ] && break
  cpu="${line%%,*}"; rssmb="${line##*,}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "$ts,$PID,$cpu,$rssmb" >> "$LOG"
  cpu_vals+=("$cpu"); rss_vals+=("$rssmb")
  sleep "$INTERVAL"
done
summary
