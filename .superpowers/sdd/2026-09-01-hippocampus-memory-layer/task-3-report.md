# Task 3 Report: Synthetic Work-Memory Benchmark

## Status And Provenance

Task 3 runs the production lexical and Core ML hybrid retrieval paths against the 24-case synthetic work-memory corpus. The final-review repairs are complete. The benchmark artifact is execution-complete and publishable as a reproducible measurement, but it remains not launch-qualified because the hybrid arm returns evidence for every unanswerable query.

- Exact code commit executed: `f9a255e6679ec5f5e8513b30b07f619714198602`
- Git dirty at benchmark start: `false`
- Branch: `codex/hippocampus-v1`
- Captured at: `2026-09-01T09:42:39Z`
- Dataset: `eval/work-memory/synthetic-v1.json`
- Dataset id: `synthetic-work-memory-v1`
- Dataset SHA-256: `96d43502f52d186cafc905dca81737ae2c07c00264d0faf2468c29b912fa131f`
- Model: `installed-model://ArcticEmbedS_INT8.mlmodelc`
- Model SHA-256: `f782f7f4a13c69a4399345f1d6a4b8de8f4327c131e537a1ea6bf9fdeaeaeef8`
- Model family: `snowflake-arctic-embed-s-int8`
- Compute mode: `coreml_cpu_only`
- Requested arms: `lexical`, `hybrid`
- Requested k values: `1`, `3`, `5`, `10`
- Original/evaluated instances: `24/24`
- Limit: none
- Command identity: `cargo run -q -p mci-agent --bin mci-bench --`
- Normalized arguments: `--dataset eval/work-memory/synthetic-v1.json --arm both --out docs/eval/work-memory-baseline.next.json`
- Toolchain: `rustc 1.96.0 (ac68faa20 2026-05-25)`, `cargo 1.96.0 (30a34c682 2026-05-25)`
- Host: macOS 26.5 build 25F71, arm64, Mac15,13, Apple M3, 17179869184 bytes RAM

Path-bearing metadata is repository-relative or uses stable logical labels. The baseline and report contain no canonical home-directory or temporary-directory paths.

## Dataset Construction

The dataset remains exactly 24 cases, with three cases in each required category:

- exact recall
- paraphrase
- temporal
- cross-session synthesis
- changed fact
- contradiction
- source attribution
- unanswerable

GitHub, terminal, browser, Slack, Linear, and file evidence are represented. Every event carries source metadata so provenance coverage is scored from retrieved evidence.

The three unanswerable questions are plausible in-domain negatives sharing projects, people, tools, and vocabulary with their haystacks while asking for absent facts:

- who approved PR 431 after the rollback
- the exact duration of the work-memory benchmark test
- Priya's due date for HIPP-201

The dataset bytes and checksum are unchanged by this repair.

## Final-Review Repairs

### Self-validating thresholds

Ordinary lower-bound metrics retain the nonnegative floor. Abstention separation uses a dedicated signed floor bounded to `[-1, 1]`. The measured hybrid separation@1 is `-0.047619` and its derived regression minimum is `-0.097619`.

A unit test checks every derived hit, recall, provenance, false-positive, separation, MRR, latency, and index-size threshold against the exact source summary. A full rerun against the generated artifact also recorded `regression.passed=true` with no failures.

### Canonical baseline promotion

`--update-baseline` pins `eval/work-memory/synthetic-v1.json` and rejects forwarded `--dataset` arguments before invoking the benchmark. Promotion now requires:

- `complete=true`
- `publishable=true`
- repository-relative canonical dataset path
- dataset id `synthetic-work-memory-v1`
- clean source tree
- no limit
- arms exactly `lexical` and `hybrid`
- k values exactly `1,3,5,10`
- exactly 24 original and 24 evaluated cases
- benchmark exit status 0 or the documented quality-gate status 7

A trap removes the candidate on every rejected path. Invalid candidates never replace an existing output.

### Direct-binary publication scope

The `mci-bench` binary now applies the canonical publication contract itself,
independently of the shell promotion wrapper. A report is publishable only
when its logical dataset path is `eval/work-memory/synthetic-v1.json`, its
dataset id is `synthetic-work-memory-v1`, both original and evaluated counts
are exactly 24, both arms ran, the k set is `1,3,5,10`, no limit was applied,
the tree was clean, and the model was checksummed.

A direct two-arm binary regression with an unrelated zero-case envelope now
records `complete=true`, `publishable=false`, `launch_qualified=false`, and
`0/0` original/evaluated cases. A deterministic scope unit test separately
proves the canonical path/id/24/24 case is accepted and rejects wrong path,
wrong id, zero cases, partial evaluation, single-arm runs, and noncanonical k.
The baseline artifact was not regenerated because this repair changes only
publication eligibility for noncanonical inputs; canonical metrics, schema,
thresholds, and provenance are unchanged.

### Scratch isolation and cleanup

Every process creates a unique scratch child directory using process, timestamp, and atomic sequence identity. Per-instance database names remain stable hashes inside that private directory.

A per-database scope guard owns the SQLite main file, `-wal` sidecar, and `-shm` sidecar. The guard removes all three on success or error; the run-level guard removes the unique directory tree. Concurrent run tests force two guards to overlap while using the same database basename and verify isolation plus cleanup.

### Real index footprint

The last store handle is closed before size measurement. The benchmark then sums any live SQLite main, WAL, and SHM artifacts before cleanup. A tiny-versus-large content test proves the reported footprint grows with indexed content.

The old constant 4096-byte measurement was the open main-file stub and is no longer used.

## Metric Definitions

- hit, recall, MRR, and provenance coverage use answerable instances only.
- false-positive rate uses unanswerable instances only.
- abstention separation is answerable hit rate minus unanswerable false-positive rate, or `TPR - FPR`.
- every summary records explicit answerable and unanswerable denominators.
- metrics with zero eligible denominator serialize as `null`.

Both arms have 21 answerable and 3 unanswerable instances.

## Baseline Metrics

Lexical:

- hit@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- recall@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- provenance@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- false-positive@1/3/5/10: `0.0000 / 0.0000 / 0.0000 / 0.0000`
- abstention separation@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- MRR: `0.3333`
- outcomes: matched 7, missed 14, abstained 3, false positive 0
- latency: min `3.448 ms`, p50 `3.775 ms`, p95 `4.035 ms`, max `8.945 ms`, mean `3.961 ms`
- index footprint: min/p50/p95/max/mean `184320 B`

Hybrid:

- hit@1/3/5/10: `0.9524 / 1.0000 / 1.0000 / 1.0000`
- recall@1/3/5/10: `0.8810 / 1.0000 / 1.0000 / 1.0000`
- provenance@1/3/5/10: `0.9524 / 1.0000 / 1.0000 / 1.0000`
- false-positive@1/3/5/10: `1.0000 / 1.0000 / 1.0000 / 1.0000`
- abstention separation@1/3/5/10: `-0.0476 / 0.0000 / 0.0000 / 0.0000`
- MRR: `0.9762`
- outcomes: matched 21, missed 0, abstained 0, false positive 3
- latency: min `34.915 ms`, p50 `37.587 ms`, p95 `50.625 ms`, max `58.462 ms`, mean `41.473 ms`
- index footprint: min/p50 `184320 B`, p95/max `192512 B`, mean `186368 B`

Retrieval, provenance, abstention outcomes, and misses are unchanged from the previous truthful run. Only latency noise, threshold derivation, and index-size measurement changed.

## Misses And False Positives

Lexical missed 14 answerable cases:

- `paraphrase-production-retriever`
- `paraphrase-embeddings-not-facts`
- `paraphrase-env-var-model-path`
- `cross-session-slack-and-pr-honesty`
- `cross-session-file-and-terminal-rerun`
- `cross-session-browser-and-linear-nonzero`
- `changed-fact-current-owner`
- `changed-fact-case-count`
- `contradiction-final-rule-partial-runs`
- `contradiction-provenance-required`
- `contradiction-cutoffs-committed`
- `source-which-slack-thread-rollback`
- `source-which-file-runner`
- `source-which-pr-complete-false`

Hybrid had no answerable misses but produced false positives for all three unanswerable cases:

- `unanswerable-pr-431-approver`
- `unanswerable-benchmark-test-duration`
- `unanswerable-hipp-201-due-date`

## Quality And Regression Gates

Absolute launch targets remain separate from measured regression thresholds:

- hybrid hit@5 at least `0.90`
- hybrid recall@5 at least `0.90`
- hybrid provenance@5 at least `0.90`
- hybrid false-positive@5 at most `0.10`
- hybrid abstention separation@5 at least `0.80`
- hybrid MRR at least `0.85`

The current artifact fails false-positive@5 (`1.00`) and abstention separation@5 (`0.00`). It records `complete=true`, `publishable=true`, and `launch_qualified=false`.

A second full run against the new baseline exited 7 only because of this absolute gate. Its baseline regression comparison passed.

## Files

Code/test/runner repair commit `f9a255e6679ec5f5e8513b30b07f619714198602`:

- `apps/agent/src/bench_longmemeval.rs`
- `apps/agent/src/bin/mci_bench.rs`
- `apps/agent/tests/work_memory_bench.rs`
- `eval/work-memory/README.md`
- `scripts/eval/work-memory/run.sh`

R2 direct-binary follow-up:

- `apps/agent/src/bin/mci_bench.rs`
- `apps/agent/tests/work_memory_bench.rs`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-3-report.md`

Baseline/report artifact commit:

- `docs/eval/work-memory-baseline.json`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-3-report.md`

No unrelated Task 1, Task 2, or Task 7 files were staged.

## Tests And Runs

- `cargo test -p mci-agent --test work_memory_bench -- --nocapture`: 15 passed
- `cargo test -p mci-agent --lib bench_longmemeval::tests -- --nocapture`: 11 passed
- `cargo test -p mci-agent --bin mci-bench -- --nocapture`: 2 passed
- `bash -n scripts/eval/work-memory/run.sh`: passed
- full runner from outside the repository without baseline comparison: both arms completed; exit 7 only on the absolute quality gate
- canonical baseline generation from exact clean code commit: promoted 24/24 artifact; exit 7 only on the absolute quality gate
- full self-baseline rerun: regression passed with no failures; exit 7 only on the absolute quality gate
- privacy scan: no canonical home or temporary paths in the baseline or report

The focused suite covers direct-binary canonical publication scope, unrelated
empty-corpus nonpublication, self-baseline threshold acceptance, dataset
override rejection, invalid candidate nonpromotion, concurrent scratch
isolation, main/WAL/SHM cleanup after failure, index growth with content,
outside-CWD execution, limited-run semantics, identity validation, undefined
denominators, production header parity, path traversal rejection, and metadata
path redaction.

## Decisions And Risks

- Complete, publishable, and launch-qualified remain separate states.
- The hybrid arm is still a launch blocker until retrieval can abstain or enforce an evidence threshold on plausible absent facts.
- Lexical retrieval remains weak on paraphrase, synthesis, changed facts, contradiction, and source attribution.
- Index size now reflects closed/checkpointed SQLite storage, but page-level allocation means small corpora can share the same footprint; growth is verified with materially larger content.
- The corpus is small and synthetic. It protects benchmark contracts and detects regressions but does not establish broad real-world quality.
- The benchmark measures retrieval and provenance, not generated-answer correctness.
