# Task 5 Repair Report: Governed Source-Backed Memory

## Status

- Repair commit: this commit.
- Review findings 2 through 10: repaired with focused regressions.
- Accepted Task 3 baseline: unchanged.
- Fixed product gates: unchanged.
- Canonical result: `complete=false`, `publishable=false`,
  `launch_qualified=false`.
- Residual blocker: the independent evidence critic remains scientifically
  unqualified. It therefore degrades explicitly instead of emitting ordinary
  hits. This is an honest remaining qualification failure, not acceptance of
  the failed retention gate.

## Repairs

### Typed production boundary

`RetrievalOutcome` now reaches the MCP wire without relabeling:

- `matched`: supported rows appear only in `hits`.
- `nothing_matched`: includes a reason and empty `hits`/`related_context`.
- `degraded`: includes the named degradation, keeps `hits` empty, and may put
  safe fallback rows in `related_context`.

The live reader uses `retrieve_outcome`, and MCP tests cover matched,
nothing-matched, and every degradation variant. In particular,
`EvidenceSufficiencyUnqualified` fallback evidence is never an ordinary hit.

### Transactional identities and replay

- Evidence, claim, and delta IDs are recomputed at the transaction boundary.
- Claim identity includes source event, confidence, initial status, evidence
  IDs, validity, attribution, scope, fact, and supersession identity. Evidence
  input order and projector version remain replay metadata.
- Existing same-ID rows are read and compared against their full immutable
  payload. A conflict aborts the transaction; no `INSERT OR IGNORE` path can
  silently retain different provenance.
- Regressions cover forged IDs, post-construction mutation, persisted
  same-ID/different-payload evidence and claims, reversed evidence input, and
  reversed delta replay. Tests inspect persisted rows after failure/replay.

### Durable retraction and bitemporal correction

- Migration 0006 adds append-only `memory_event_retractions` and its target
  index.
- Retractions are recorded even when no claim exists yet. Every projection
  consults the ledger and deterministically appends the applicable retracted
  state, including retract-before-project and newer-projector replay.
- Corrections resolve the target claim at
  `(new_claim.valid_from_us, delta.asserted_at_us)` and require it to be active
  at that exact bitemporal point.
- Regressions cover proposed, superseded, retracted, and contradicted targets,
  plus backdated terminal transitions.

### Determinism, degradation, fairness, and migration shape

- Split-conformal calibration rejects unattainable sample-size/coverage pairs;
  90% one-sided coverage requires at least nine positive calibration rows.
- Critic semantic and lexical ties end with stable candidate identity.
- Plain and anchor retrieval name embedder, vector, lexical, and combined
  capability failures while preserving only safe typed fallback context.
- Expansion preflights evidence admissibility so an oversized first claim
  cannot consume a one-node budget and starve a later admissible claim.
- Migration success validates exact columns, required foreign keys, CHECK
  constraints, and index column order before stamping schema 6. A
  column-compatible but constraint-incompatible schema rolls back to v5.

### Benchmark accounting

The benchmark still seeds and queries the production SQLCipher store and typed
retrieval path. Index size now uses SQLite `dbstat` page accounting for the
retrieval structures (`events`, event indexes, `events_fts*`,
`event_vectors`, and `chunks`). Unrelated memory-projection schema growth no
longer masquerades as retrieval-index bloat. Tests prove unrelated data leaves
the metric unchanged and indexed-content growth increases it.

The accepted baseline and all lexical/absolute thresholds were not regenerated
or weakened.

## Independent Calibration

- Fixture: `eval/relevance-calibration/v1.json`
- Dataset ID: `hippocampus-evidence-sufficiency-calibration-v1`
- Fixture SHA-256:
  `e18aba01ab344da3a1ee4ab58003e28bb86c041e99107b223073bfa7830ead5d`
- Composition: 27 independent everyday-life cases: 12 fit, 9 calibration,
  and 6 untouched validation.
- Feature schema: v2, six generic numeric features: raw semantic cosine,
  semantic margin, bidirectional lexical coverage, lexical/semantic agreement,
  and novel-term specificity.
- Frozen threshold: `0.31316441644765064`.

| Split | Positive coverage | False-positive rate | Required | Qualified |
|---|---:|---:|---:|---|
| Calibration | 1.000 | 0.889 | coverage >= 0.90, FPR <= 0.10 | No |
| Validation | 0.833 | 0.333 | coverage >= 0.90, FPR <= 0.10 | No |

Reproduction:

```text
MCI_ARCTIC_MODEL_PATH=/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc \
cargo run -q -p mci-agent --bin mci_calibrate_evidence -- \
  eval/relevance-calibration/v1.json /tmp/task5-policy-repro.json
cmp eval/relevance-calibration/v1-policy.json /tmp/task5-policy-repro.json
```

The calibrator exited 0 and `cmp` exited 0. The production policy remains
`validation_qualified=false`. No Task 3 question/category/slot-specific branch
was added to production or calibration code.

## Canonical Benchmark

Command:

```text
MCI_ARCTIC_MODEL_PATH=/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc \
cargo run -q -p mci-agent --bin mci-bench -- \
  --dataset eval/work-memory/synthetic-v1.json \
  --arm both --k 1,3,5,10 \
  --baseline docs/eval/work-memory-baseline.json \
  --out /tmp/task5-task3-repair-final.json
```

- Process exit: `5`.
- Dataset SHA-256:
  `96d43502f52d186cafc905dca81737ae2c07c00264d0faf2468c29b912fa131f`.
- Model SHA-256:
  `f782f7f4a13c69a4399345f1d6a4b8de8f4327c131e537a1ea6bf9fdeaeaeef8`.
- Compute: Core ML CPU-only, Apple M3.
- Recorded base commit: `95ee44921ae8ff7c7036b59a76b95268a4eb7bc7`.
- Run metadata recorded `git_dirty_at_start=true` because the shared worktree
  contained this repair and concurrent unrelated task edits.

| Arm | Scored | Hit@5 | Recall@5 | Provenance@5 | FPR@5 | Separation@5 | MRR | Index p95 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Lexical | 24 | 0.3333 | 0.3333 | 0.3333 | 0.0000 | 0.3333 | 0.3333 | 45,056 B |
| Hybrid | 0 | undefined | undefined | undefined | undefined | undefined | undefined | 0 B |

Lexical outcomes were 7 matched, 14 missed, 3 abstained, and 0 false
positives. Its p95 latency was `12.48525 ms`. It clears the accepted lexical
thresholds, including the frozen `252,928`-byte index ceiling.

All 24 hybrid instances returned the typed
`EvidenceSufficiencyUnqualified` degradation. They were not scored as hits,
misses, abstentions, or false positives. Therefore hybrid absolute and baseline
metrics remain undefined, `quality_gate.passed=false`, and
`regression.passed=false`. The fixed target remains FPR@5 `<= 0.10` and
separation@5 `>= 0.80`; neither is claimed from an incomplete arm.

## Verification

- `cargo test -p mci-brain`: exit 0. Key suites include 324 library, 26
  projection, 10 evidence-sufficiency, 12 typed retrieval, 21 retriever, and
  55 SQLCipher tests; all remaining integration and doc suites passed.
- `cargo test -p mci-agent --test mcp_server -- --nocapture`: 26 passed.
- `cargo test -p mci-agent --test work_memory_bench -- --nocapture`: 15 passed.
- `cargo test -p mci-agent --lib bench_longmemeval::tests -- --nocapture`: 12
  passed.
- `cargo test -p mci-agent --bin mci-bench -- --nocapture`: 2 passed.
- `cargo test -p mci-agent --bin mci_calibrate_evidence -- --nocapture`: 5
  passed.
- Scoped Rust formatting and Task 5 `git diff --check`: run before commit.

## Residual Gate

The code-level correctness findings are repaired. Task 5 is still not
scientifically accepted because the available generic ArcticEmbedS feature
critic cannot distinguish answer-bearing from closely related insufficient
evidence at the fixed false-positive rate. The next qualifying implementation
needs a separately trained local entailment/sufficiency model or another
independently frozen critic with enough calibration data. Until then, degraded
related context is useful for search but must not authorize agent claims.
