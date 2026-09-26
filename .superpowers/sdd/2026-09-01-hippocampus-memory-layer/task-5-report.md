# Task 5 R3 Repair Report: Governed Source-Backed Memory

## Status

- Repair commit: this focused commit.
- R3 P1/P3 findings: repaired with focused regressions.
- Accepted baseline: unchanged at
  `35fbebff470f957caf7ea17b456ba0708d48521858061470a2c51dfccc7691c9`.
- Accepted dataset: unchanged at
  `96d43502f52d186cafc905dca81737ae2c07c00264d0faf2468c29b912fa131f`.
- Fixed lexical, regression, and absolute quality thresholds: unchanged.
- Canonical result: `complete=false`, `publishable=false`,
  `launch_qualified=false`.
- Residual scientific blocker: the frozen evidence critic remains
  unqualified. Production returns typed degradation instead of promoting
  related context to authority.

## R3 Repairs

### Accepted baseline identity

The canonical runner rejects every caller-provided `--baseline` form before
executing the benchmark, including `--baseline PATH`, `--baseline=PATH`, and
duplicates in update mode. It supplies exactly one repository baseline.

The binary independently rejects duplicate baseline arguments and binds every
canonical report to both:

- the canonicalized path `docs/eval/work-memory-baseline.json`; and
- the pinned SHA-256
  `35fbebff470f957caf7ea17b456ba0708d48521858061470a2c51dfccc7691c9`.

A missing, copied, replaced, or tampered baseline creates a failed regression
and forces `complete=false`, `publishable=false`, and
`launch_qualified=false`. Tests cover runner override attempts, update-mode
attempts, duplicates, a byte-identical copy at another path, and content
tampering while inspecting all three report booleans. No accepted artifact or
threshold was regenerated or weakened.

### Delta-owned deletion provenance

Claims and explicit claim transitions now persist a nullable, constrained
`delta_id`. Fresh projection writes this ownership transactionally; collision
checks include ownership. Schema v8 rebuilds populated v6/v7 memory tables and
backfills ownership only when the legacy source and assertion coordinates
identify exactly one delta. Ambiguous legacy rows remain unowned rather than
being guessed.

Privacy deletion now stages the requested events, affected claims, explicitly
owned deltas, correction descendants, transition dependencies, and only the
evidence in that closure. It no longer expands from one affected claim to all
claims sharing a source event, and it no longer globally deletes unlinked
evidence. Source-event deletion still removes all deltas sourced by the event,
as required.

Regressions cover two independent deltas sharing one source event, unrelated
orphan evidence, same-delta siblings, secondary evidence, mixed correction and
explicit-transition graphs, and single/range/retention/wipe paths. Each test
inspects durable rows after deletion.

### Exact migration shape

Schema validation now uses `PRAGMA table_xinfo` and `PRAGMA index_xinfo`.
Before stamping version 8 it verifies:

- every table column's CID, name, type, nullability, default, PK position, and
  hidden/generated status;
- inherited per-column collation through a transient index;
- the complete foreign-key action set;
- every canonical index's key columns, BINARY collation, and ASC order;
- index uniqueness, partial status, origin, and auxiliary row shape; and
- the canonical CHECK constraints.

Adversarial tests reject scalar IDs using `NOCASE`, comment-obfuscated
non-indexed collations, generated columns, and `NOCASE DESC` secondary indexes.
Migration rollback and populated legacy preservation remain covered.

### Determinism and typed authority retained

- `RetrievalOutcome` remains typed through MCP as `matched`,
  `nothing_matched`, or `degraded`; degraded related context is never an
  ordinary hit.
- No-embedder lexical output remains
  `degraded/embeddings_unavailable`.
- Evidence, claim, transition, delta, and retraction identities remain
  deterministic and transactionally collision-checked.
- Corrections still require the superseded claim to be active at both the
  correction's valid-time and transaction-time coordinates.
- Split-conformal validity, deterministic critic and retrieval ties, typed
  anchor degradation, and one-node expansion fairness remain covered.
- The public legacy retrieval escape hatch continues to reject degradation.

The R3 refactor also removes the Task 5 full-Clippy findings without lint
allows: oversized retrieval, expansion, migration, deletion, and schema
validation functions were decomposed into focused helpers. The all-target
brain benchmark was updated for the typed `Event.tab_id` field.

## Independent Calibration

- Fixture: `eval/relevance-calibration/v1.json`
- Fixture SHA-256:
  `e18aba01ab344da3a1ee4ab58003e28bb86c041e99107b223073bfa7830ead5d`
- Frozen threshold: `0.31316441644765064`
- Calibration: coverage `1.000`, FPR `0.889`
- Untouched validation: coverage `0.833`, FPR `0.333`
- Production policy: `validation_qualified=false`

The frozen calibration artifact and critic policy were not changed by R3.

## Canonical Benchmark

Reproduction:

```text
scripts/eval/work-memory/run.sh --out /tmp/hippo-task5-r3.json
```

- Process exit: `5`, the expected honest qualification failure.
- Dataset SHA-256:
  `96d43502f52d186cafc905dca81737ae2c07c00264d0faf2468c29b912fa131f`.
- Accepted baseline SHA-256:
  `35fbebff470f957caf7ea17b456ba0708d48521858061470a2c51dfccc7691c9`.
- Model SHA-256:
  `f782f7f4a13c69a4399345f1d6a4b8de8f4327c131e537a1ea6bf9fdeaeaeef8`.
- Recorded base commit: `8454ab54e66d2c6ef24bcf5c7e5fffb01e74a191`.
- Compute: Core ML CPU-only, Apple M3, macOS 26.5.
- The report records exactly one argument:
  `--baseline docs/eval/work-memory-baseline.json`.
- `git_dirty_at_start=true` because this repair and concurrent owned work were
  uncommitted when measured.

| Arm | Scored | Hit@5 | Recall@5 | Provenance@5 | FPR@5 | Separation@5 | MRR | Index p95 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Lexical | 24 | 0.3333 | 0.3333 | 0.3333 | 0.0000 | 0.3333 | 0.3333 | 45,056 B |
| Hybrid | 0 | undefined | undefined | undefined | undefined | undefined | undefined | 0 B |

Lexical outcomes were 7 matched, 14 missed, 3 abstained, and 0 false
positives. Lexical p50/p95 latency was `12.085458/22.259833 ms`.

All 24 hybrid instances returned
`EvidenceSufficiencyUnqualified`. None was relabeled or scored as a hit,
miss, abstention, or false positive. Therefore:

- `regression.passed=false` because accepted-baseline hybrid metrics are
  undefined;
- `quality_gate.passed=false` because fixed hybrid quality metrics are
  undefined; and
- `complete=false`, `publishable=false`, and `launch_qualified=false`.

Fixed targets remain FPR@5 `<= 0.10`, separation@5 `>= 0.80`, hit/recall/
provenance@5 `>= 0.90`, and MRR `>= 0.85`.

## Verification

- `cargo test -p mci-brain --locked --quiet`: exit `0`; 620 passed, 0 failed,
  1 ignored.
- `cargo test -p mci-agent --locked --test mcp_server \
  --test work_memory_bench --test wire_e2e_fixture \
  --test chunker_event_wire --bin mci-bench \
  --bin mci_calibrate_evidence -- --nocapture`: exit `0`; 61 passed,
  0 failed.
- `cargo test -p mci-agent --locked --no-run`: exit `0`; every agent target
  compiled.
- `cargo check -p mci-brain -p mci-agent --all-targets --locked`: exit `0`;
  every brain and agent target, including `hybrid_recall`, compiled.
- Scoped `rustfmt --check` over every Task 5-owned Rust file: exit `0`.
- `cargo fmt --all -- --check`: executed; the exact workspace command is
  blocked by the concurrently edited, out-of-scope `mci-brain-ffi` file.
- `cargo clippy -p mci-brain --lib --test memory_projection \
  --test sqlcipher_brain_store --locked -- -D warnings`: exit `0`.
- Task 5 evaluation/retrieval Clippy checks for `evidence_sufficiency` and
  `fts_sanitizer_against_sqlite`: exit `0`.
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: executed;
  Task 5 brain code is clean, but the exact workspace command is blocked by
  pre-existing/out-of-scope lint errors in `mci-embed-coreml`,
  `mci-coreml-bridge`, the concurrently edited `mci-brain-ffi`, and older
  non-Task-5 brain targets such as `tier2_footprint` and
  `mail_cascade_corpus`. No lint was weakened and no out-of-scope file was
  changed.
- Accepted baseline and dataset diffs: empty.
- Scoped formatting, `git diff --check`, and staged-file review are run
  immediately before commit.

## Residual Gate

The R3 code-integrity findings are repaired. Task 5 remains scientifically
unqualified because the frozen generic ArcticEmbedS critic cannot yet separate
answer-bearing evidence from closely related insufficient context at the fixed
false-positive gate. The next qualifying change needs an independently frozen
local sufficiency/entailment critic and a larger untouched validation set.
Until then, degraded related context remains useful for search but cannot
authorize agent claims.
