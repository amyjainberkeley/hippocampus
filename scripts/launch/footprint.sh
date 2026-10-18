#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# footprint.sh — measure what Hippocampus costs this Mac, right now.
#
# Samples CPU (as % of one core and % of the whole machine, mean + p95),
# total resident memory, and the memory store's disk growth, across EVERY
# process whose executable lives in Hippocampus.app, then compares them to
# the budgets in reports/launch-design/budgets.md and prints a table.
#
# It is content-free: the sampler (hippo_footprint.c) reads the kernel's
# per-process counters (CPU time, energy, memory footprint, wakeups, disk
# bytes) via proc_pid_rusage. It never reads window contents, files, the
# brain, or the screen. Disk growth is the store directory's byte SIZE at
# the start and end of the window (du), never its contents.
#
# A ~60 s sample against the already-running app is the default. It is a
# snapshot, not the scripted "normal hour" of budgets.md §5.1 — it tells
# you where the app sits this minute, honestly, with its source shown.
#
# Exit status: 0 if every measured number is within its CEILING (the line
# budgets.md says no busy minute may cross); 3 if a ceiling is crossed.
# Missing a (stricter) target prints WARN but does not fail — that is the
# honest state of 0.3.0, documented in budgets.md.
#
# Usage:  scripts/launch/footprint.sh [seconds=60] [interval=5] [/path/to/Hippocampus.app]
# Env:    HIPPO_APP, HIPPO_STORE (default ~/Library/Application Support/MCI)
#         HIPPO_NO_DISK=1 to skip the store-size measurement

set -uo pipefail

SECONDS_ARG="${1:-60}"
INTERVAL="${2:-5}"
APP="${3:-${HIPPO_APP:-/Applications/Hippocampus.app}}"
APP="${APP%/}"
STORE="${HIPPO_STORE:-$HOME/Library/Application Support/MCI}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hippo-footprint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/hippo_footprint"
CSV="$WORK/sample.csv"
SUMMARY="$WORK/summary.txt"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=; GRN=; YEL=; DIM=; RST=; }

echo "Hippocampus footprint — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "App bundle: $APP"

# ── Machine facts for the budget math. ──────────────────────────────────
NCPU="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)"
MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
MEM_MB=$(( MEM_BYTES / 1048576 ))
MEM_CEIL_MB=$(awk -v m="$MEM_MB" 'BEGIN{printf "%d", m*0.05}')   # 5% of RAM
POWER="battery"
if pmset -g ps 2>/dev/null | grep -qiE "AC Power"; then POWER="plugged"; fi
CPU_TARGET_ONECORE=$([[ "$POWER" == plugged ]] && echo 5 || echo 3)  # §1: 5% one core plugged, 3% battery
echo "Machine: ${NCPU} logical cores, ${MEM_MB} MB RAM, on ${POWER} power"
echo "CPU ceiling = 5% of the machine = $((5*NCPU))% of one core; target = ${CPU_TARGET_ONECORE}% of one core"
echo "Memory ceiling = 5% of RAM = ${MEM_CEIL_MB} MB; target = 300 MB p95 / 200 MB steady"
echo

# ── Compile the content-free sampler. ───────────────────────────────────
if ! clang -O2 -o "$BIN" "$SCRIPT_DIR/hippo_footprint.c" 2>"$WORK/cc.log"; then
  echo "${RED}FAIL${RST} could not compile hippo_footprint.c:"; cat "$WORK/cc.log"; exit 1
fi

# ── Store size before (sizes only — never contents). ────────────────────
disk_kb_before=0; have_disk=0
if [[ "${HIPPO_NO_DISK:-0}" != 1 && -d "$STORE" ]]; then
  disk_kb_before="$(du -sk "$STORE" 2>/dev/null | awk '{print $1}')"
  have_disk=1
fi

# ── Sample. ─────────────────────────────────────────────────────────────
echo "Sampling ${SECONDS_ARG}s at ${INTERVAL}s intervals (content-free)…"
"$BIN" "$SECONDS_ARG" "$INTERVAL" "$APP/" >"$CSV" 2>"$SUMMARY"

rows="$(awk 'NR>1' "$CSV" | grep -c . 2>/dev/null || echo 0)"
if [[ "$rows" -eq 0 ]]; then
  echo "${RED}FAIL${RST} no sample rows — the sampler saw no processes under $APP/"; exit 1
fi
maxprocs="$(awk -F, 'NR>1 && $2>m{m=$2} END{print m+0}' "$CSV")"
if [[ "$maxprocs" -eq 0 ]]; then
  printf '%bNOTE%b Hippocampus does not appear to be running — nothing to measure.\n' "$YEL" "$RST"
  echo "Start the app and re-run for a live footprint."
  exit 0
fi

# ── Store size after. ───────────────────────────────────────────────────
disk_delta_mb="n/a"
if [[ "$have_disk" -eq 1 ]]; then
  disk_kb_after="$(du -sk "$STORE" 2>/dev/null | awk '{print $1}')"
  disk_delta_mb="$(awk -v a="$disk_kb_before" -v b="$disk_kb_after" 'BEGIN{printf "%.2f", (b-a)/1024.0}')"
fi

# mean p95 max of a CSV column.
stats_col() {
  awk -F, -v c="$2" 'NR>1{v[n++]=$c+0; s+=$c}
    END{ if(n==0){print "0 0 0"; exit}
      for(i=0;i<n;i++)for(j=i+1;j<n;j++)if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t}
      idx=int(0.95*(n-1)+0.5); mx=v[n-1];
      printf "%.2f %.2f %.2f", s/n, v[idx], mx }' "$1"
}

read -r cpu1_mean cpu1_p95 _ <<<"$(stats_col "$CSV" 3)"   # % of one core
read -r cpum_mean cpum_p95 _ <<<"$(stats_col "$CSV" 4)"   # % of the machine
read -r _ mem_p95 _ <<<"$(stats_col "$CSV" 7)"           # phys_footprint MB (sum of procs)
peak_proc="$(awk -F, 'NR>1 && $8>m{m=$8} END{printf "%.0f", m}' "$CSV")"  # largest single-process peak
dwrite_mb="$(awk -F, 'NR>1{s+=$11} END{printf "%.2f", s}' "$CSV")"
neural_p95="$(stats_col "$CSV" 9 | awk '{print $2}')"

echo
echo "== Measured (${SECONDS_ARG}s snapshot, ${rows} intervals, up to ${maxprocs} processes) =="

fail=0
# verdict helper: $1 measured $2 target $3 ceiling -> sets global VERD
verdict() {
  local val="$1" tgt="$2" ceil="$3"
  awk -v v="$val" -v t="$tgt" -v c="$ceil" 'BEGIN{
    if (v>c) { print "OVER-CEILING"; exit }
    if (v>t) { print "over-target"; exit }
    print "ok" }'
}

row() { # label measured target ceiling unit note
  local label="$1" meas="$2" tgt="$3" ceil="$4" unit="$5" note="${6:-}"
  local v; v="$(verdict "$meas" "$tgt" "$ceil")"
  local color="$GRN"; local tag="OK"
  case "$v" in
    OVER-CEILING) color="$RED"; tag="OVER CEILING"; fail=1 ;;
    over-target)  color="$YEL"; tag="over target" ;;
  esac
  printf '  %-26s %10s %-5s  target %-8s ceiling %-8s  %b%-12s%b %s%s%s\n' \
    "$label" "$meas" "$unit" "$tgt$unit" "$ceil$unit" "$color" "$tag" "$RST" "$DIM" "$note" "$RST"
}

printf '  %-26s %10s %-5s  %-15s %-16s %-12s\n' "METRIC" "MEASURED" "" "TARGET" "CEILING" "VERDICT"
# CPU in % of one core (Activity Monitor units)
row "CPU mean (1 core)"   "$cpu1_mean" "$CPU_TARGET_ONECORE" "$((5*NCPU))" "%"
row "CPU p95 (1 core)"    "$cpu1_p95"  "20"                  "$((5*NCPU))" "%" "p95 target 20% one core (busy minute)"
# CPU in % of the machine ("5% of the computer")
row "CPU mean (machine)"  "$cpum_mean" "1"                   "5"  "%" "5% of the computer = the ceiling"
row "CPU p95 (machine)"   "$cpum_p95"  "1"                   "5"  "%"
# Memory
row "Memory p95 (all procs)" "$mem_p95" "300" "$MEM_CEIL_MB" "MB"
row "Memory peak 1 proc"     "$peak_proc" "300" "$MEM_CEIL_MB" "MB" "OCR worker dominates while reading"
echo
echo "  ${DIM}CPU energy (CPU-only): $(awk '/CPU energy/{print $4, $5}' "$SUMMARY")${RST}"
[[ "$(awk 'BEGIN{print ('"$neural_p95"'>0)}')" == 1 ]] && echo "  ${DIM}Neural Engine footprint p95: ${neural_p95} MB${RST}"
echo "  ${DIM}Disk bytes written by Hippocampus during the window: ${dwrite_mb} MB${RST}"
if [[ "$disk_delta_mb" != "n/a" ]]; then
  echo "  Store growth over the window: ${disk_delta_mb} MB   ${DIM}(target ≈100 MB/active day; a 60s idle sample is usually ~0)${RST}"
else
  echo "  ${DIM}Store growth: not measured (store dir absent or HIPPO_NO_DISK=1)${RST}"
fi

echo
echo "${DIM}Sampler summary (hippo_footprint stderr):${RST}"
sed 's/^/  /' "$SUMMARY"

echo
if [[ "$fail" -eq 0 ]]; then
  printf '%bFOOTPRINT WITHIN CEILINGS%b for this %ss snapshot. See over-target (yellow) rows for budgets.md gaps.\n' "$GRN" "$RST" "$SECONDS_ARG"
  exit 0
else
  printf '%bFOOTPRINT OVER A CEILING%b — a red row above crossed a never-cross line. Expected while the OCR reader runs; confirm with the scripted hour (budgets.md §5.1).\n' "$RED" "$RST"
  exit 3
fi
