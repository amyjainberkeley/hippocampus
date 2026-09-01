# Task 5 R2 Repair Report: Governed Source-Backed Memory

## Status

- Repair commit: this focused commit.
- R2 P1/P2/P3 code findings: repaired with focused regressions.
- Accepted baseline: unchanged at
  `35fbebff470f957caf7ea17b456ba0708d48521858061470a2c51dfccc7691c9`.
- Fixed lexical and absolute quality thresholds: unchanged.
- Canonical result: `complete=false`, `publishable=false`,
  `launch_qualified=false`.
- Residual blocker: the frozen evidence critic remains scientifically
  unqualified. Production therefore returns typed degradation instead of
  promoting related context to authority.

## R2 Repairs

### Typed retrieval authority

`RetrievalOutcome` remains typed through the MCP wire:

- `matched` contains evidence-qualified `hits` only.
- `nothing_matched` contains a reason and no hits.
- `degraded` contains a named degradation, keeps `hits` empty, and may expose
  non-authoritative rows only as `related_context`.

The no-embedder live path now returns `EmbeddingsUnavailable`, including when
FTS finds rows. A simultaneous FTS failure is
`LexicalAndEmbeddingsUnavailable`. The chunker-to-store-to-MCP integration
test enforces the same wire contract. The public legacy `Retriever::retrieve`
API now rejects every degradation, including
`EvidenceSufficiencyUnqualified`, rather than returning fallback rows as hits.

### Canonical identities and source governance

- Evidence, claims, deltas, transitions, and retractions are verified inside
  the projection transaction against their deterministic payload identities.
- Existing same-ID rows are compared with their immutable payload. A mutated
  collision aborts the transaction and preserves the original row.
- Transition IDs use the public canonical constructor, and every explicit
  transition must be owned by its enclosing delta source event.
- Evidence locator, source scope, observation time, and content hash are
  recomputed from the stored canonical event at commit time.
- Initial active claims require attribution, same-event evidence, and a scope
  no broader than every evidence source scope.
- Tests cover mutation, forged IDs, wrong transition ownership, persisted
  collisions, reversed evidence order, and reversed delta replay while
  inspecting durable rows.

### Retraction, correction, and deletion lifecycle

Migration 0006 contains the durable `memory_event_retractions` ledger. Every
projection consults it, including retract-before-project and replay under a
new projector version.

Corrections may supersede only a claim active at
`(new_claim.valid_from_us, delta.asserted_at_us)`. Tests cover proposed,
superseded, retracted, and contradicted targets, plus backdated terminal
transitions and independent valid/transaction time.

Single deletion, range deletion, retention purge, and full wipe now remove
dependent memory rows in the same transaction before deleting events. The
dependency closure includes recursive corrections. Deleting secondary
evidence invalidates the complete affected source delta, including sibling
claims and transition rows, so persisted deterministic payloads cannot retain
missing evidence. Unrelated events and projections remain intact.

### Determinism, fairness, and exact schema

- Split-conformal calibration rejects unattainable coverage/sample-size
  combinations and uses the valid order statistic at the minimum sample size.
- Critic ties and all FTS/vector cutoff ties end in stable event identity.
- Plain and anchor retrieval preserve typed embedder, vector, lexical, and
  combined degradations.
- Expansion preflights each seed, so oversized evidence cannot consume a
  one-node budget and starve a later admissible seed.
- Schema version 7 transactionally rebuilds populated v6 memory tables with
  explicit scalar `NOT NULL PRIMARY KEY` constraints while preserving deltas,
  evidence, correction chains, links, transitions, and retractions.
- Validation compares exact column type/null/default/PK shape, the complete FK
  action set, exact custom-index uniqueness/partial/column shape, PK and UNIQUE
  indexes, and the exact CHECK count. Regressions cover missing scalar and
  composite PKs, wrong index uniqueness, extra CHECK constraints with altered
  spacing, rollback, and populated v6-to-v7 migration.

### Mandatory accepted baseline

Canonical work-memory runs cannot omit the accepted baseline. The runner
rejects `--no-baseline`, fails before execution when the baseline is absent,
and always forwards
`--baseline docs/eval/work-memory-baseline.json`. The binary independently
records a failed regression when a canonical invocation lacks the baseline.

A supplied or synthesized failed regression now forces `complete=false`,
which also forces `publishable=false` and `launch_qualified=false`. Tests
inspect all serialized booleans. No evaluation-specific production rule was
added, and no threshold or accepted baseline was changed.

## Independent Calibration

- Fixture: `eval/relevance-calibration/v1.json`
- Fixture SHA-256:
  `e18aba01ab344da3a1ee4ab58003e28bb86c041e99107b223073bfa7830ead5d`
- Frozen threshold: `0.31316441644765064`
- Calibration: coverage `1.000`, FPR `0.889`
- Untouched validation: coverage `0.833`, FPR `0.333`
- Production policy: `validation_qualified=false`

Reproduction:

```text
MCI_ARCTIC_MODEL_PATH=/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc \
cargo run -q -p mci-agent --bin mci_calibrate_evidence -- \
  eval/relevance-calibration/v1.json /tmp/task5-r2-policy-repro.json
cmp eval/relevance-calibration/v1-policy.json /tmp/task5-r2-policy-repro.json
```

Both commands exited `0`; the regenerated artifact matched byte-for-byte.

## Canonical Benchmark

Reproduction:

```text
MCI_ARCTIC_MODEL_PATH=/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc \
scripts/eval/work-memory/run.sh --out /tmp/hippo-task5-r2.json
```

- Process exit: `5`.
- Dataset SHA-256:
  `96d43502f52d186cafc905dca81737ae2c07c00264d0faf2468c29b912fa131f`.
- Model SHA-256:
  `f782f7f4a13c69a4399345f1d6a4b8de8f4327c131e537a1ea6bf9fdeaeaeef8`.
- Recorded base commit: `3e8248aac5ba8512f47b874d40cda3543ae6b684`.
- Compute: Core ML CPU-only, Apple M3, macOS 26.5.
- The run recorded `git_dirty_at_start=true` because it measured this repair
  before its focused commit and concurrent Task 2 files were present.

| Arm | Scored | Hit@5 | Recall@5 | Provenance@5 | FPR@5 | Separation@5 | MRR | Index p95 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Lexical | 24 | 0.3333 | 0.3333 | 0.3333 | 0.0000 | 0.3333 | 0.3333 | 45,056 B |
| Hybrid | 0 | undefined | undefined | undefined | undefined | undefined | undefined | 0 B |

Lexical outcomes were 7 matched, 14 missed, 3 abstained, and 0 false
positives. Lexical p50/p95 latency was `13.384625/19.567291 ms`.

All 24 hybrid instances returned
`EvidenceSufficiencyUnqualified`. None was relabeled or scored as a hit,
miss, abstention, or false positive. Therefore:

- `regression.passed=false` because accepted-baseline hybrid metrics are
  undefined.
- `quality_gate.passed=false` because all fixed hybrid quality metrics are
  undefined.
- `complete=false`, `publishable=false`, and `launch_qualified=false`.
- Fixed targets remain FPR@5 `<= 0.10`, separation@5 `>= 0.80`, hit/recall/
  provenance@5 `>= 0.90`, and MRR `>= 0.85`.

## Verification

- `cargo test -p mci-brain --quiet`: exit `0`; 613 passed, 0 failed,
  1 ignored.
- `cargo test -p mci-agent --test mcp_server --test work_memory_bench \
  --test chunker_event_wire --bin mci-bench --bin mci_calibrate_evidence \
  --quiet`: exit `0`; 54 passed, 0 failed.
- `cargo fmt --all -- --check`: exit `0`.
- Accepted baseline diff: empty.
- `git diff --check` and scoped staged-file review: run immediately before
  commit.

## Residual Gate

The R2 code-integrity findings are repaired. Task 5 remains scientifically
unqualified because the frozen generic ArcticEmbedS critic cannot yet separate
answer-bearing evidence from closely related insufficient context at the fixed
false-positive gate. The next qualifying change needs an independently frozen
local sufficiency/entailment critic and a larger untouched validation set.
Until then, degraded related context remains useful for search but cannot
authorize agent claims.
