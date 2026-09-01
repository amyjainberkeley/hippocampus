# Task 5 Report: Governed Source-Backed Memory

## Status

- Code commit: `462060a67066799506805d38d6ee7a48fc2e907a`
- Required commit subject: `feat: add governed source-backed memory`
- Launch status: **blocked**
- Canonical Task 3 result: `complete=false`, `publishable=false`, `launch_qualified=false`
- Reason: the independently calibrated evidence-sufficiency critic failed its held-out qualification gate. Production hybrid retrieval therefore reports `EvidenceSufficiencyUnqualified` with ranked fallback evidence; it does not manufacture `Matched` or `NothingMatched` decisions.

## Delivered

### Governed memory

- Append-only `memory_deltas`, evidence, claims, claim-evidence links, and transitions.
- Stable content-derived identifiers and replay-idempotent projection.
- Source-backed activation: an active claim must have extant evidence and its evidence set must include the delta's `source_event_id`. This prevents a detached arbitrary source anchor.
- Unsupported model statements remain `Proposed` and do not appear as current facts.
- Corrections preserve subject/predicate identity, cannot broaden scope, cannot remove attribution, and supersede only the explicitly named active claim.
- Retraction and contradiction append audit state; they do not delete claims or source events.
- Projection is deterministic and transactional. The transaction contains no model, network, filesystem, or clock calls.
- Expansion across episodes, entities, and identities is deterministic and bounded. Oversized evidence sets cannot starve later eligible items.

### Bitemporal semantics

`memory_claim_transitions` stores transaction time and valid time separately:

- `asserted_at_us`: when Hippocampus learned/asserted the transition.
- `effective_at_us`: when the transition is valid in the modeled world.

As-of reads filter claims and transitions by both dimensions and select transitions deterministically by `asserted_at_us`, then `effective_at_us`, then transition ID. Auto-supersession uses the delta assertion time independently from the correction claim's `valid_from_us`. `MemoryRetraction` likewise requires explicit assertion and effective times.

The committed regression fixture proves this history:

- Original claim known at `t20`.
- Correction asserted at `t100`, effective at `t30`.
- At asserted `t50` / valid `t40`, the old claim remains visible.
- At asserted `t110` / valid `t40`, the correction is visible.
- At asserted `t110` / valid `t25`, the old claim remains visible.

Migration `0006` upgrades and reopens every prior schema fixture (`0001` through `0005`) and has a rollback test proving a failed upgrade leaves no partial Task 5 schema.

### Retrieval contract

- Rank fusion is deterministic and rank-aware; tied raw scores share rank and event ID is the final stable tie-breaker.
- Raw semantic cosine and top-1/top-2 margin remain separate cross-query signals. Per-query min-max fused score is never used as confidence.
- Source-quality ordering is documented and monotone: user-authored `1.00`, structured app `0.95`, local artifact `0.88`, browser `0.80`, accessibility `0.68`, OCR `0.52`.
- Typed production outcomes are `Matched`, `NothingMatched`, and `Degraded` with named capability failures.
- An unqualified critic yields `Degraded { EvidenceSufficiencyUnqualified, fallback_matches }`, never a match or abstention.
- The legacy/search `Retriever::retrieve` API unwraps those ranked fallback hits so ordinary evidence search and the existing UI do not blank. Operational degradation such as unavailable embeddings remains an error.
- A qualified negative critic yields `NothingMatched`; only a qualified critic may divide hybrid results into `Matched` and `NothingMatched`.
- The Task 3 benchmark consumes the typed outcome and rejects degradation. It does not score fallback ranking as answerable evidence.

## Independent Calibration

### Provenance

- Fixture: `eval/relevance-calibration/v1.json`
- Dataset ID: `hippocampus-evidence-sufficiency-calibration-v1`
- Fixture SHA-256: `4767463f1ca003c8f018aa6b375e4241db71ff982187b898bd2774f8adba2fbf`
- Frozen policy: `eval/relevance-calibration/v1-policy.json`
- Composition: 18 everyday-life cases, split into 6 fit, 6 calibration, and 6 untouched validation cases. Each case has supporting and close-but-insufficient evidence.
- Independence: it reuses no Task 3 questions, entities, sessions, or answer types.

The generic features are raw semantic cosine, raw top-1/top-2 semantic margin, query-to-document lexical coverage, document-to-query lexical coverage, and lexical/semantic top-1 agreement. There are no query terms, requested-slot branches, date/duration/approver/owner/count rules, or Task 3 entity rules in production or calibration code.

The calibrator fits a fixed five-feature logistic model on only the fit split: 20,000 deterministic full-batch steps, learning rate `0.02`, L2 `0.01`. The threshold is the lower positive-score quantile needed for the predeclared `0.90` positive-coverage target, selected only from the positive calibration examples. Calibration negatives, validation examples, and Task 3 outcomes do not select the threshold.

Frozen values:

- Means: `[0.7870435466, 0.1704107324, 0.6194444547, 0.4008928637, 1.0]`
- Scales: `[0.0382084599, 0.0576958453, 0.1038235110, 0.0860705877, 0.000001]`
- Weights: `[0.8685495661, 0.5719168871, 0.2660645936, -2.9515814248, 0.0]`
- Intercept: `-0.085427480`
- Threshold: `0.0000023630626`

Predeclared validation requirements were coverage `>=0.90` and false-positive rate `<=0.10`.

| Split | Positive coverage | False-positive rate | Qualified |
|---|---:|---:|---|
| Calibration | 1.000 | 0.833 | No |
| Validation | 0.667 | 0.500 | **No** |

The critic is therefore frozen with `validation_qualified=false`. The tiny threshold is reported as an observed consequence of failed calibration, not accepted as a usable confidence boundary.

This design follows the supplied primary-source constraints: conformal/selective boundaries require independent calibration; semantic relevance is not evidential utility; sufficiency needs an explicit gap decision; and retrieval can harm abstention on unanswerable queries. The local deterministic critic did not satisfy those requirements, so the launch gate remains blocked.

## Run Ledger

### Calibration runs

1. Initial independent-fixture generation. Purpose: fit and measure the proposed generic critic after removing the leaked Task 3 rules.
2. Artifact-schema regeneration. Purpose: add explicit `validation_qualified` output. Model parameters and threshold were byte-for-byte unchanged; no Task 3 result was consulted.
3. Final reproducibility run after the retrieval-contract correction. Purpose: generate `/tmp/hippo-task5-policy-repro.json` and compare it with the committed policy using `cmp`. The comparison passed with no artifact change.

No calibration rerun changed a feature, threshold, model parameter, or decision based on the 24-case evaluation corpus.

### Invalidated runs

All Task 3 runs made before removal of `MIN_RAW_SEMANTIC_COSINE`, `requested_slot_supported`, and the evaluation-shaped slot patterns are invalid. Their metrics are not acceptance evidence and are not claimed anywhere in this report.

### Canonical Task 3 acceptance

Exactly one canonical acceptance run was made after policy freeze and code commit, from a clean detached worktree at `462060a67066799506805d38d6ee7a48fc2e907a`:

```text
MCI_ARCTIC_MODEL_PATH=/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc \
cargo run -q -p mci-agent --bin mci-bench -- \
  --dataset eval/work-memory/synthetic-v1.json \
  --arm both --k 1,3,5,10 \
  --out /tmp/task5-task3-acceptance.json
```

- Dataset SHA-256: `96d43502f52d186cafc905dca81737ae2c07c00264d0faf2468c29b912fa131f`
- Git dirty at start: `false`
- Model checksum: `f782f7f4a13c69a4399345f1d6a4b8de8f4327c131e537a1ea6bf9fdeaeaeef8`
- Compute: CoreML CPU-only, Apple M3
- Process exit: `5`

| Arm | Instances scored | Hit@5 | Recall@5 | Provenance@5 | FPR@5 | Separation@5 | MRR |
|---|---:|---:|---:|---:|---:|---:|---:|
| Lexical | 24 | 0.3333 | 0.3333 | 0.3333 | 0.0000 | 0.3333 | 0.3333 |
| Hybrid | 0 | undefined | undefined | undefined | undefined | undefined | undefined |

Lexical outcomes were 7 matched, 14 missed, 3 abstained, and 0 false positives. Lexical p95 latency was `24.767667 ms`; p95 index size was `253952 bytes`. The 14 answerable misses comprise all contradiction (3), cross-session (3), paraphrase (3), and source-attribution (3) cases plus 2 of 3 changed-fact cases.

Hybrid produced 24 named `EvidenceSufficiencyUnqualified` failures: all 21 answerable cases and all 3 unanswerable cases. These are capability failures, not matches, misses, abstentions, or false positives. Consequently the hybrid arm is incomplete and all absolute quality metrics are undefined.

Absolute quality failures:

- Hybrid hit@5 undefined.
- Hybrid recall@5 undefined.
- Hybrid provenance@5 undefined.
- Hybrid false-positive@5 undefined.
- Hybrid abstention separation@5 undefined.
- Hybrid MRR undefined.

Final benchmark flags: `complete=false`, `publishable=false`, quality gate `passed=false`, `launch_qualified=false`. The corpus was not rerun after observing this result.

## Verification

- `cargo test -p mci-brain`: passed. This includes 324 library tests, 14 memory-projection tests, 7 evidence-sufficiency tests, 8 typed-retrieval tests, 21 hybrid-retriever tests, 55 SQLCipher store tests, migration upgrade/reopen/rollback fixtures, and doc tests.
- `cargo test -p mci-agent --test work_memory_bench -- --nocapture`: 15 passed.
- `cargo test -p mci-agent --lib bench_longmemeval::tests -- --nocapture`: 11 passed.
- `cargo test -p mci-agent --bin mci-bench -- --nocapture`: 2 passed.
- Scoped Rust formatting for `mci-brain`: passed.
- Task 5 `git diff --check`: passed.
- Leakage scan: no forbidden evaluator-derived symbols or slot-specific branches in Task 5 production/tests.

Full-workspace `cargo fmt --all -- --check` is blocked by concurrent unrelated Rust edits outside Task 5. Clippy with `-D warnings` is blocked before reaching Task 5 by 34 pre-existing/unrelated `mci-core` documentation warnings. Those files were not modified to make Task 5 green.

## Changed Files

- Agent benchmark/calibration: `apps/agent/src/bench_longmemeval.rs`, `apps/agent/src/bin/mci_calibrate_evidence.rs`
- Brain schema and production: `core/brain/migrations/0006_memory_claims.sql`, `core/brain/src/evidence_sufficiency.rs`, `core/brain/src/hybrid_retriever.rs`, `core/brain/src/lib.rs`, `core/brain/src/memory_delta.rs`, `core/brain/src/memory_projector.rs`, `core/brain/src/sqlcipher_brain_store.rs`, `core/brain/src/stubs.rs`
- Brain tests: `core/brain/tests/alias_resolver_store.rs`, `core/brain/tests/evidence_sufficiency.rs`, `core/brain/tests/graph_store.rs`, `core/brain/tests/hybrid_retriever.rs`, `core/brain/tests/memory_projection.rs`, `core/brain/tests/recall_fusion.rs`, `core/brain/tests/retrieval_outcomes.rs`, `core/brain/tests/sqlcipher_brain_store.rs`
- Frozen calibration data/docs: `eval/relevance-calibration/README.md`, `eval/relevance-calibration/v1.json`, `eval/relevance-calibration/v1-policy.json`

## Tradeoffs And Next Gate

- The governed claim substrate, deterministic bitemporal projection, source linkage, ranking, and typed outcome boundary are ready for downstream use.
- The current five-feature deterministic critic is not good enough. Treating it as qualified would create unsupported answers; treating every query as no-match would blank search. The implemented degraded-with-fallback contract preserves useful evidence search while keeping answerability honest.
- Task 6 MCP context must preserve `EvidenceSufficiencyUnqualified` and may expose fallback evidence only as related context, never as a supported answer.
- Launch qualification requires a genuinely independent evidence critic that clears the frozen held-out gate without Task 3 tuning. Plausible next experiments are a separately trained local entailment/sufficiency model, negative-evidence retrieval, or a larger independent conformal calibration set. None should alter this report's canonical result.
