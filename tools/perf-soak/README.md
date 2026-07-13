# tools/perf-soak — MCI footprint regression harnesses

Two complementary harnesses live under this directory. Both emit JSONL
and hold the same footprint SLO contract (DESIGN.md G2, ratified
2026-05-31): steady-state ≤10-15% CPU / ≤2 GB RSS on the default tier,
≤1-2% CPU / ≤250 MB on the opt-in Performance tier.

## 1. Brain-store harness — `run.sh` + `src/main.rs` (Rust, #108)

Drives N concurrent `put_event` + recall queries against an ephemeral
`SqlCipherBrainStore` (tempfile-backed, disposed after run) for T
seconds. Samples RSS + CPU every 5 s. Writes JSONL to stdout. Exits 1
if any sample exceeds the SLO.

## 2. Agent-process harness — `agent-soak.sh` + `analyze.py` (CRS G6 interim)

Spawns `mci-agent --drain-stdin` with a `/dev/null` stdin (warm-agent
baseline; no live capture pipeline — that is V2-P1-blocked), samples
CPU + RSS at 1 Hz via `ps(1)`, emits JSONL, then hands off to
`analyze.py` which scores against the pinned `expected-baseline.json`
(cycle 8.30 posture: 0.25% CPU / ~37 MB RSS).

Purpose per CRS telemetry-gap 2026-07-07 scan §G6: measure MCI's
real-world footprint under a reproducible synthetic load without
requiring the V2-P1 M4-lift (PR #28-blocked, awaits Amy's Mac). Closes
G1 partially — we cannot yet measure "M4-lifted state", but we CAN
measure "cycle 8.30 posture" baseline reproducibly.

### Quick start (agent harness)

```bash
# Default 5-minute soak, human-readable score card.
cargo build --release -p mci-agent
tools/perf-soak/agent-soak.sh

# 30 s dry-run (results land in a tempdir, not committed).
tools/perf-soak/agent-soak.sh --duration 30 --dry-run

# 60 s CI-friendly mode: exit 1 on drift beyond envelope. NOT yet
# wired into .github/workflows/ — that is a cycle 8.45+ dispatch.
tools/perf-soak/agent-soak.sh --ci

# Point at a specific binary (e.g. debug build during iteration).
tools/perf-soak/agent-soak.sh --agent ./target/debug/mci-agent
```

Output lands under `tools/perf-soak/out/` (gitignored). Do NOT commit
real telemetry runs — the score card is the shareable artifact.

### Comparing across cycles

`expected-baseline.json` pins the cycle 8.30 sample plus a ±3x drift
envelope. `analyze.py` renders a score card that answers three
questions on every run:

1. Are p95 CPU + RSS within the steady-state SLO (default tier)?
2. Are p95 CPU + RSS within the Performance-tier SLO (opt-in)?
3. Is the run within ±3x of the pinned cycle 8.30 baseline?

Anything worse than the envelope trips `--strict` (CI mode). Envelope
is deliberately loose because a warm-agent measurement is
noise-dominated — the harness catches class-shifts (0.25% → 5%), not
micro-drift. Once V2-P1 M4 lifts, add a second baseline entry for the
M4-lifted posture.

## SLO thresholds

| Metric   | Limit      | Source                     |
|----------|------------|----------------------------|
| RSS      | 250 MB     | DESIGN.md G2 / STATE.md §4 |
| CPU p95  | 5% 1 core  | DESIGN.md G2 (sustained)   |

## Quick start

```bash
# Default: 4 writers, 2 readers, 60 s
tools/perf-soak/run.sh

# Heavy 5-min soak, save JSONL
tools/perf-soak/run.sh -w 8 -r 4 -d 300 --output soak.jsonl

# Direct binary (after cargo build --release -p mci-perf-soak)
./target/release/mci-perf-soak --help
```

## Output

**stdout** — one JSONL line per sample:

```json
{"elapsed_s":5.0,"rss_kb":12340,"cpu_pct":1.23,"ops_total":245,"errors_total":0}
```

**stderr** — progress banner + final summary with median / p95 / max
and PASS/FAIL verdict.

## Interpreting results

- `rss_kb` is the process RSS from `ps(1)`. Includes the encrypted
  SQLite WAL, all worker threads, and the Rust runtime.
- `cpu_pct` is interval-based (delta `getrusage(RUSAGE_SELF)` /
  delta wall clock). 100 = saturating one core.
- `ops_total` counts completed `put_event` + `fts5_search` +
  `vec_search` calls.
- `errors_total` should stay 0. Non-zero means the store hit an
  unexpected failure under load.

## CSO sign-off checklist

- Synthetic-only workload (no real user content).
- Tempfile-backed brain, disposed after run.
- SLO assertion is the safety check.
- Agent-soak spawns `mci-agent --drain-stdin` with `/dev/null` stdin —
  no capture pipeline, no user content ever enters the process.

## CI integration

See `.github-snippet.yml` for a ready-to-paste workflow job for the
brain-store harness. The agent-soak `--ci` mode is intentionally NOT
wired into `.github/workflows/` yet — that is a cycle 8.45+ follow-up
dispatch once the pinned baseline has been sampled across a few cycles.
