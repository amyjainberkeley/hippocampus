#!/usr/bin/env bash
# SPDX-License-Identifier: TBD-private
#
# footprint_measure.sh — sample helper RSS + CPU at fixed intervals,
# emit CSV. PREREQUISITE TOOLING for Track B · Step 3 (the ADR-0013
# Amendment 1 §2 G2 footprint proof; AGENT_PROTOCOL §4 / §9).
#
# Steady-state budget per §4: ≤ ~1–2% of one CPU core sustained AND
# ≤ ~250 MB RAM over an all-day session. The G2 measurement MUST be
# real (per §9, never auto-passed / never fabricated / human-only).
# This script is the read-only observability harness — it does not
# decide the verdict, it only records samples a human reads.
#
# This tool touches NO protected-set code (AGENT_PROTOCOL §5). It
# only invokes `ps` against an externally-managed helper PID and
# writes a CSV with one row per sample. Read-only with respect to
# everything except its output CSV.
#
# Usage:
#   tools/footprint_measure.sh <helper-pid> [interval-seconds] [output-csv]
#
#   helper-pid       PID of an already-running mci-capture-helper.
#                    The script polls this PID and exits when it dies.
#   interval-seconds Sampling interval, seconds (default: 5).
#                    Don't go below 1; ps invocation cost dominates.
#   output-csv       Path to write the CSV. Default: stdout.
#
# Output schema (CSV with header):
#   ts_unix,helper_pid,rss_kb,cpu_pct
#
#   ts_unix     Unix epoch seconds (integer) at sample time.
#   helper_pid  The PID being sampled (constant across rows).
#   rss_kb     Resident-set size in kilobytes from `ps -o rss`.
#   cpu_pct    Process CPU% from `ps -o %cpu` (single-core
#              percentage — 100% means saturating one core).
#
# Quick analysis (median + max), assumes CSV is in $CSV:
#   awk -F, 'NR>1 {r[NR]=$3; c[NR]=$4} END {
#     n=NR-1; asort(r); asort(c);
#     print "median rss_kb:", r[int(n/2)+1];
#     print "max rss_kb:   ", r[n];
#     print "median cpu_pct:", c[int(n/2)+1];
#     print "max cpu_pct:   ", c[n];
#   }' "$CSV"
#
# §4 budget mapping (informational — the verdict is the human's):
#   ≤ 250 MB ≡ rss_kb ≤ 256000
#   ≤  2% one core ≡ cpu_pct ≤ 2.0   (sustained, not single-sample peak)

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  cat >&2 <<EOF
usage: $0 <helper-pid> [interval-seconds=5] [output-csv=/dev/stdout]

  Samples \`ps -o rss,%cpu\` for <helper-pid> every interval-seconds
  and writes a CSV to <output-csv>. Exits when the PID terminates.

  Step-3 G2 footprint observability harness — does NOT decide the
  verdict; only records samples a human reads.
EOF
  exit 2
fi

PID="$1"
INTERVAL="${2:-5}"
OUT="${3:-/dev/stdout}"

# Sanity: PID must be currently running.
if ! ps -p "$PID" >/dev/null 2>&1; then
  echo "footprint_measure: PID $PID is not running" >&2
  exit 3
fi

# Sanity: interval must be a positive integer.
case "$INTERVAL" in
  ''|*[!0-9]*) echo "footprint_measure: interval must be a positive integer (got '$INTERVAL')" >&2; exit 4 ;;
esac
if [ "$INTERVAL" -lt 1 ]; then
  echo "footprint_measure: interval must be >= 1" >&2
  exit 4
fi

# Header (overwrite output file).
echo "ts_unix,helper_pid,rss_kb,cpu_pct" > "$OUT"

# Poll loop. Each iteration: one ps invocation, one append, one sleep.
# ps `-o rss=,%cpu=` strips column headers and emits raw "RSS CPU".
# macOS `ps` emits leading whitespace; awk normalizes the split.
while ps -p "$PID" >/dev/null 2>&1; do
  TS=$(date +%s)
  # awk handles whitespace + missing-column edge cases cleanly.
  SAMPLE=$(ps -o rss=,%cpu= -p "$PID" 2>/dev/null | awk '{printf "%s,%s", $1, $2}')
  if [ -z "$SAMPLE" ]; then
    # PID disappeared between the outer ps check and the sample read;
    # exit cleanly.
    break
  fi
  echo "${TS},${PID},${SAMPLE}" >> "$OUT"
  sleep "$INTERVAL"
done

echo "footprint_measure: helper PID $PID exited; samples in $OUT" >&2
