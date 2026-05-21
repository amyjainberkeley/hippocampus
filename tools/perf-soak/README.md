# mci-perf-soak — Sustained-Load Footprint Regression Harness

Drives N concurrent `put_event` + recall queries against an ephemeral
`SqlCipherBrainStore` (tempfile-backed, disposed after run) for T
seconds. Samples RSS + CPU every 5 s. Writes JSONL to stdout. Exits 1
if any sample exceeds the SLO.

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

## CI integration

See `.github-snippet.yml` for a ready-to-paste workflow job.
