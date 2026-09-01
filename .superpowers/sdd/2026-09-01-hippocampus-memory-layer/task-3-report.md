# Task 3 Report: Synthetic Work-Memory Benchmark

## Status And Provenance

Task 3 now runs the production lexical and Core ML hybrid retrieval paths against a 24-case synthetic work-memory corpus. The benchmark is execution-complete and publishable as a reproducible measurement, but it is not launch-qualified because the hybrid arm returns evidence for every unanswerable query.

- Exact code commit executed: `04b9b8c1e39042b41dc64a1b7f4f986eb41583be`
- Git dirty at benchmark start: `false`
- Branch: `codex/hippocampus-v1`
- Captured at: `2026-09-01T09:06:51Z`
- Dataset: `eval/work-memory/synthetic-v1.json`
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

Path-bearing metadata is repository-relative or uses stable logical labels. The baseline contains no canonical home-directory or temporary-directory paths.

## Dataset Construction

The dataset remains exactly 24 cases, with three cases in each promised category:

- exact recall
- paraphrase
- temporal
- cross-session synthesis
- changed fact
- contradiction
- source attribution
- unanswerable

GitHub, terminal, browser, Slack, Linear, and file evidence are represented. Every event carries source metadata so provenance coverage is scored from retrieved evidence.

The three unanswerable questions are plausible in-domain negatives that share projects, people, tools, and vocabulary with their haystacks while asking for absent facts:

- who approved PR 431 after the rollback
- the exact duration of the work-memory benchmark test
- Priya's due date for HIPP-201

These replace the previous nonsense-token probes and include GitHub, terminal/file, Slack, and Linear pressure. Answer-session labels remain empty for all three.

## Production Path

`brain_ingest::prepare_event_content` is shared by production OCR ingestion and benchmark seeding. It calls the public `compose_context_header`, runs the production `EventChunker`, returns the exact bytes stored in `events.text`, and selects the same first chunk used for synchronous document embedding. FTS, extraction, and hybrid retrieval therefore see production-identical seeded text.

The benchmark arms use the production `SqlCipherBrainStore`, `FtsSanitizingStore`, `HybridRetriever`, and shared Core ML embedder loader. Scratch database names are derived from stable hashes, and malformed IDs containing separators, controls, or traversal text are rejected before filesystem access.

## Metric Definitions

- hit, recall, MRR, and provenance coverage use answerable instances only.
- false-positive rate uses unanswerable instances only.
- abstention separation is answerable hit rate minus unanswerable false-positive rate, or `TPR - FPR`.
- every summary records explicit answerable and unanswerable denominators.
- metrics with zero eligible denominator serialize as `null`; they are never coerced to zero.

## Baseline Metrics

Both arms have 21 answerable and 3 unanswerable instances.

Lexical:

- hit@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- recall@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- provenance@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- false-positive@1/3/5/10: `0.0000 / 0.0000 / 0.0000 / 0.0000`
- abstention separation@1/3/5/10: `0.3333 / 0.3333 / 0.3333 / 0.3333`
- MRR: `0.3333`
- outcomes: matched 7, missed 14, abstained 3, false positive 0
- latency: p50 `4.275 ms`, p95 `9.770 ms`, mean `5.144 ms`
- index size: p50/p95 `4096 B / 4096 B`

Hybrid:

- hit@1/3/5/10: `0.9524 / 1.0000 / 1.0000 / 1.0000`
- recall@1/3/5/10: `0.8810 / 1.0000 / 1.0000 / 1.0000`
- provenance@1/3/5/10: `0.9524 / 1.0000 / 1.0000 / 1.0000`
- false-positive@1/3/5/10: `1.0000 / 1.0000 / 1.0000 / 1.0000`
- abstention separation@1/3/5/10: `-0.0476 / 0.0000 / 0.0000 / 0.0000`
- MRR: `0.9762`
- outcomes: matched 21, missed 0, abstained 0, false positive 3
- latency: p50 `35.442 ms`, p95 `49.646 ms`, mean `39.511 ms`
- index size: p50/p95 `4096 B / 4096 B`

Undefined-slice behavior is visible in the artifact: the unanswerable slice has null hit/recall/MRR/provenance/separation, while answerable-only slices have null false-positive/separation.

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

Hybrid had no answerable misses, but produced false positives for all three unanswerable cases:

- `unanswerable-pr-431-approver`
- `unanswerable-benchmark-test-duration`
- `unanswerable-hipp-201-due-date`

## Gates

Regression thresholds remain relative to the measured baseline and catch material declines. Baseline validation refuses incomplete or nonpublishable artifacts, dataset ID/checksum mismatches, missing requested arms, missing k thresholds, dirty or abbreviated baseline commits, and incompatible hybrid model family/checksum/compute identity.

Absolute launch targets are separate so poor baseline behavior cannot bless itself:

- hybrid hit@5 at least `0.90`
- hybrid recall@5 at least `0.90`
- hybrid provenance@5 at least `0.90`
- hybrid false-positive@5 at most `0.10`
- hybrid abstention separation@5 at least `0.80`
- hybrid MRR at least `0.85`

The current artifact fails the absolute gate on false-positive@5 (`1.00`) and abstention separation@5 (`0.00`). It records `complete=true`, `publishable=true`, `launch_qualified=false`.

Limited runs are smoke reports with `complete=false` and `publishable=false`. They exit nonzero by default. `--allow-smoke` may make a limited smoke command exit zero, but the runner rejects it for baseline generation.

## Files

Code/dataset/test/runner repair commit:

- `apps/agent/src/brain_ingest.rs`
- `apps/agent/src/bench_longmemeval.rs`
- `apps/agent/src/bin/mci_bench.rs`
- `apps/agent/tests/work_memory_bench.rs`
- `eval/work-memory/synthetic-v1.json`
- `eval/work-memory/README.md`
- `scripts/eval/work-memory/run.sh`
- `docs/eval/README.md`

Baseline/report artifact commit:

- `docs/eval/work-memory-baseline.json`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-3-report.md`

No Task 1, Task 2, or Task 7 files were staged by this implementation.

## Tests And Runs

- `cargo test -p mci-agent --test work_memory_bench -- --nocapture`: 9 passed
- production header parity unit test: 1 passed
- path normalization unit test: 1 passed
- `bash -n scripts/eval/work-memory/run.sh`: passed
- full runner invoked from outside the repository without baseline update: completed both arms; exited 7 on the absolute quality gate
- full baseline generation from the exact clean code commit: completed both arms; wrote the publishable artifact; exited 7 on the same absolute quality gate

Coverage includes outside-CWD execution, limited-run completeness and exit status, missing-arm rejection, incompatible identity rejection, undefined denominator nulls, production header byte parity, path traversal IDs, and external path redaction.

## Decisions And Risks

- A complete benchmark and a launch-qualified benchmark are intentionally separate states. The corpus and run are reproducible even when retrieval quality is unacceptable.
- The hybrid arm is a launch blocker until retrieval can abstain or enforce an evidence threshold on plausible absent facts.
- Lexical retrieval remains weak on paraphrase, synthesis, changed facts, contradiction, and source attribution. Its low baseline is descriptive, not a launch target.
- The corpus is intentionally small and synthetic. It protects contracts and catches regressions but does not establish broad real-world quality.
- The benchmark measures retrieval and provenance, not generated-answer correctness.
