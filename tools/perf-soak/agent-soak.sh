#!/usr/bin/env bash
# tools/perf-soak/agent-soak.sh — CRS G6 interim mci-agent footprint harness.
#
# Spawns `mci-agent --drain-stdin` (warm-agent baseline; no live capture
# pipeline — that is V2-P1-blocked) with a synthetic stdin event stream,
# samples CPU + RSS at 1 Hz via ps(1), emits JSONL to an output dir that
# is gitignored. Companion analyzer `analyze.py` computes summary stats
# and compares against `expected-baseline.json`.
#
# Modes:
#   default        — 5 minute soak, human-readable tail summary
#   --dry-run      — writes to /tmp, does not persist under out/
#   --ci           — 60 s measurement, pass/fail vs pinned baseline,
#                    exits 1 on drift beyond envelope. NOT wired into CI
#                    yet — that is a cycle 8.45+ follow-up dispatch.
#
# Usage:
#   tools/perf-soak/agent-soak.sh [--duration SECS] [--dry-run] [--ci]
#                                 [--agent PATH] [--out DIR]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DURATION=300
DRY_RUN=0
CI_MODE=0
AGENT_BIN=""
OUT_DIR="$SCRIPT_DIR/out"

while [ $# -gt 0 ]; do
  case "$1" in
    --duration)  DURATION="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --ci)        CI_MODE=1; DURATION=60; shift ;;
    --agent)     AGENT_BIN="$2"; shift 2 ;;
    --out)       OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$AGENT_BIN" ]; then
  if [ -x "$REPO_ROOT/target/release/mci-agent" ]; then
    AGENT_BIN="$REPO_ROOT/target/release/mci-agent"
  elif [ -x "$REPO_ROOT/target/debug/mci-agent" ]; then
    AGENT_BIN="$REPO_ROOT/target/debug/mci-agent"
  else
    echo "agent-soak: no mci-agent binary; build with 'cargo build -p mci-agent' or pass --agent PATH" >&2
    exit 2
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  OUT_DIR="$(mktemp -d -t perf-soak-dry.XXXXXX)"
fi
mkdir -p "$OUT_DIR"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
JSONL="$OUT_DIR/agent-soak-$RUN_ID.jsonl"
LOG_PATH="$OUT_DIR/helper-health-$RUN_ID.jsonl"
DEVID_PATH="$OUT_DIR/device-id-$RUN_ID"

echo "agent-soak: bin=$AGENT_BIN duration=${DURATION}s out=$JSONL" >&2

# Isolated HOME + unset MCI_DB_KEY_HEX keeps the agent in the WARM-IDLE
# posture (no brain-key → drain-stdin no-op loop, no embedder / NER /
# idle-batch workers, no CEO dev.key pickup, no live-production store
# reads). This is the "cycle 8.30 posture" the harness measures against.
SOAK_HOME="$OUT_DIR/fake-home-$RUN_ID"
SOAK_DB="$SOAK_HOME/mci.sqlite"
mkdir -p "$SOAK_HOME/Library/Application Support/MCI"

# FIFO holds stdin open — drain-stdin exits on EOF, so /dev/null would
# collapse the agent immediately.
FIFO="$OUT_DIR/soak-stdin-$RUN_ID.fifo"
mkfifo "$FIFO"
sleep $((DURATION + 10)) > "$FIFO" &
FIFO_PID=$!

env -u MCI_DB_KEY_HEX \
    HOME="$SOAK_HOME" \
    MCI_DB_PATH="$SOAK_DB" \
    MCI_EMBEDDER_DISABLED=1 \
  "$AGENT_BIN" --drain-stdin \
    --device-id-path "$DEVID_PATH" \
    --log-path "$LOG_PATH" \
    < "$FIFO" > "$OUT_DIR/agent-stdout-$RUN_ID.log" 2>&1 &
AGENT_PID=$!

cleanup() {
  if kill -0 "$AGENT_PID" 2>/dev/null; then
    kill "$AGENT_PID" 2>/dev/null || true
    wait "$AGENT_PID" 2>/dev/null || true
  fi
  if [ -n "${FIFO_PID:-}" ] && kill -0 "$FIFO_PID" 2>/dev/null; then
    kill "$FIFO_PID" 2>/dev/null || true
    wait "$FIFO_PID" 2>/dev/null || true
  fi
  [ -n "${FIFO:-}" ] && [ -p "$FIFO" ] && rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

# Give the agent 500ms to spawn and settle before first sample.
sleep 0.5
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  echo "agent-soak: mci-agent exited before first sample; see $OUT_DIR/agent-stdout-$RUN_ID.log" >&2
  exit 2
fi

# 1 Hz sampler. ps(1) rss= is KB on macOS; %cpu= is percentage of a
# single core (BSD semantics — one saturated core = 100%).
START=$(date +%s)
: > "$JSONL"
while :; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  [ "$ELAPSED" -ge "$DURATION" ] && break
  if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "agent-soak: mci-agent died at t=${ELAPSED}s" >&2
    break
  fi
  # rss= (KB), %cpu= (float, one core = 100)
  read -r RSS_KB CPU_PCT < <(ps -o rss=,%cpu= -p "$AGENT_PID" 2>/dev/null || echo "0 0")
  printf '{"t_s":%d,"rss_kb":%s,"cpu_pct":%s,"pid":%d}\n' \
    "$ELAPSED" "${RSS_KB:-0}" "${CPU_PCT:-0}" "$AGENT_PID" >> "$JSONL"
  sleep 1
done

cleanup
trap - EXIT INT TERM

echo "agent-soak: wrote $(wc -l < "$JSONL" | tr -d ' ') samples to $JSONL" >&2

# Delegate scoring to analyze.py. --ci flag turns drift into exit 1.
ANALYZE_ARGS=("$JSONL" "--baseline" "$SCRIPT_DIR/expected-baseline.json")
[ "$CI_MODE" -eq 1 ] && ANALYZE_ARGS+=("--strict")
python3 "$SCRIPT_DIR/analyze.py" "${ANALYZE_ARGS[@]}"
