# Task 5 Final Scientific/Code Review

## Findings

No P0 findings.

1. **P1 - The implementation was retained after failing Task 5's explicit acceptance and Task 3 preservation gates.**

   Task 5 permits retention only if both Task 3 arms run through the typed production path, lexical does not materially regress, and hybrid reaches the absolute abstention gate (`task-5-brief.md:25`). The submitted report instead records zero scored hybrid instances, every hybrid metric undefined, and `complete=false`, `publishable=false`, `launch_qualified=false` (`task-5-report.md:120-138`). Its canonical command omits `--baseline` (`task-5-report.md:104-112`), so it never applies the accepted Task 3 regression thresholds.

   I reran the clean two-arm benchmark with the accepted baseline. It exited 5 with `regression.passed=false`: all hybrid metrics were undefined, and lexical index p95 was `253952`, above the accepted `252928` maximum at `docs/eval/work-memory-baseline.json:5061`. The report itself records the same `253952` size (`task-5-report.md:125`). This is a failed retention gate, not an acceptable blocked-launch completion.

   Required repair: use the accepted baseline in the canonical acceptance command; restore a complete, publishable hybrid arm that clears the fixed absolute gate; and bring lexical/index behavior inside the accepted regression envelope (or obtain an explicit independent revision of that envelope rather than regenerating it around this result).

2. **P1 - Production MCP recall silently relabels the unqualified critic's degraded fallback as ordinary hits.**

   `HybridRetriever::retrieve` converts `Degraded { EvidenceSufficiencyUnqualified, fallback_matches }` into `Ok(Vec<RetrievalHit>)` at `core/brain/src/hybrid_retriever.rs:564`. The live MCP path calls that legacy method at `apps/agent/src/mcp/live.rs:366` and serializes the returned values as normal `hits`, with no degradation field. This directly violates the requirement that degradation never be relabeled or silently collapsed at the MCP boundary (`task-5-brief.md:35`). It also contradicts the report's claim that fallback preserves answerability honesty (`task-5-report.md:161-163`). The focused MCP test at `apps/agent/tests/mcp_server.rs:789` requires nonempty hits and never asserts a degradation marker, so it locks in the wrong wire behavior.

   Required repair: carry `RetrievalOutcome` through `LiveBrainReader` and the MCP response. Expose `EvidenceSufficiencyUnqualified` explicitly; if fallback evidence is returned, type it as related/degraded context rather than supported hits. Add MCP end-to-end tests for all three outcomes and every degradation variant.

3. **P1 - Public, unchecked IDs plus `INSERT OR IGNORE` can persist different provenance from the provenance that passed validation.**

   `EvidenceRef.id` and all evidence identity fields are publicly mutable (`core/brain/src/memory_delta.rs:58-72`), yet validation checks the in-memory event reference before `insert_evidence` silently ignores an existing ID (`core/brain/src/memory_projector.rs:153-166`, `core/brain/src/memory_projector.rs:230-245`). The claim is then linked to that pre-existing evidence row at `core/brain/src/memory_projector.rs:53`. A stale or forged ID can therefore validate against the delta source event but persist a link to a different event, defeating the report's source-anchor guarantee (`task-5-report.md:16-17`).

   Claim identity is also order-dependent: the derived ID omits source event, evidence, confidence, initial status, and projector version (`core/brain/src/memory_delta.rs:168-179`), while conflicting claim rows are ignored at `core/brain/src/memory_projector.rs:254`. Two deltas with the same computed IDs but different omitted fields can produce first-writer-wins state rather than deterministic replay.

   Required repair: make stable IDs opaque or recompute and verify them at the transaction boundary; reject any ID conflict whose full immutable payload differs; and define claim identity so source/status/confidence/evidence changes cannot silently alias. Add collision, mutated-ID, reversed-input, and conflicting-replay tests that inspect persisted evidence, not only the input object.

4. **P1 - Event retraction is not durable and can be bypassed by replay or later projection.**

   Retraction queries only claims that already reference the target event and appends transitions to those rows (`core/brain/src/memory_projector.rs:89-123`). Migration 0006 has no event-retraction ledger; its only retraction representation is a claim transition (`core/brain/migrations/0006_memory_claims.sql:66-80`). A retraction issued before projection records nothing, and a claim projected from the same event after retraction receives no retracted transition because `apply_delta` never checks a durable event state (`core/brain/src/memory_projector.rs:29-77`). Replaying a newer projector can therefore resurrect active claims from withdrawn evidence.

   Required repair: append a durable event/evidence retraction record independent of current claims, consult it during every projection, and deterministically apply it to claims discovered later. Add retract-before-project, project-after-retract, and projector-version replay-after-retract tests.

5. **P1 - Corrections do not prove that the superseded claim is active at the correction's bitemporal point.**

   Correction validation reads the target row and checks subject, predicate, scope, attribution, and the new claim's status (`core/brain/src/memory_projector.rs:169-190`), but never evaluates the target's effective status at `(claim.valid_from_us, delta.asserted_at_us)`. It consequently accepts corrections of proposed, already superseded, contradicted, or retracted claims. The report's statement that corrections supersede only an explicitly named active claim is false (`task-5-report.md:19`).

   Required repair: resolve the target status with the same bitemporal semantics used by as-of reads and reject unless it is active at the correction's valid/transaction coordinates. Cover proposed and every terminal status, including backdated transitions.

6. **P2 - The advertised 90% split-conformal threshold is mathematically unattainable with six calibration positives.**

   The fixture declares 90% target coverage (`eval/relevance-calibration/v1.json:4`) and the policy records only six calibration positives (`eval/relevance-calibration/v1-policy.json:39-43`). At `apps/agent/src/bin/mci_calibrate_evidence.rs:203-211`, `floor((n+1)*(1-coverage))` is zero, but `saturating_sub(1)` silently maps that unattainable rank to the minimum observed score. With six exchangeable calibration scores, the minimum finite order statistic supplies only `6/7 = 85.7%` one-sided rank coverage in the no-tie case, not 90%. Thus the procedure named at `task-5-report.md:67` is invalid even though the failed validation flag currently prevents promotion.

   Required repair: reject unattainable `(n, coverage)` configurations or use a formally valid conservative boundary, expand the independently frozen positive calibration set to a size that supports 90%, and unit-test quantile ranks at and below the sample-size limit.

7. **P2 - Evidence-critic decisions are nondeterministic for tied semantic candidates.**

   Feature extraction explicitly uses input order as the semantic tie-break (`core/brain/src/evidence_sufficiency.rs:59-63`). Production builds that input by iterating a randomized `HashSet<EventId>` (`core/brain/src/hybrid_retriever.rs:669-702`). Equal semantic scores can therefore select different top text, lexical agreement, coverage, score, and eventually `Matched` versus `NothingMatched` across processes. This contradicts the report's deterministic critic/ranking claims (`task-5-report.md:45`, `task-5-report.md:86`).

   Required repair: sort critic candidates by raw cosine and stable event ID before feature extraction, make the tie-break part of the feature schema, and add repeated-process/equal-score tests.

8. **P2 - The typed outcome boundary is incomplete for anchor-shaped retrieval failures.**

   In `anchor_then_window_outcome`, a vector-search failure is converted directly to `RetrieveError::Backend` at `core/brain/src/hybrid_retriever.rs:970-973`, while the plain path maps the same missing capability to `Degraded::EmbeddingsUnavailable`. Thus not every production degradation is named as promised by `task-5-brief.md:18` and `task-5-report.md:48`.

   Required repair: route anchor embedding/vector failures through the typed degradation path, preserving any safe lexical fallback, and add anchor-query tests for embedder failure, vector-store failure, lexical failure, and combined failure.

9. **P2 - An oversized first claim can still starve later admissible evidence under the node budget.**

   Expansion consumes a claim node before inspecting its evidence (`core/brain/src/memory_projector.rs:430-460`). If the first hash-sorted seed has oversized evidence and `max_nodes == 1`, it consumes the only node, skips its evidence, and prevents a later small seed from being considered. The existing test uses `max_nodes == 4`, so it does not establish the report's unconditional non-starvation claim (`task-5-report.md:22`).

   Required repair: preflight or schedule admissible evidence before irrevocably spending the limiting node budget, define the intended fairness rule, and add a one-node oversized-first regression.

10. **P3 - Migration success can stamp schema 6 over a structurally incompatible pre-existing table.**

    Migration 0006 uses `CREATE TABLE IF NOT EXISTS` throughout and unconditionally stamps version 6 (`core/brain/migrations/0006_memory_claims.sql:7`, `core/brain/migrations/0006_memory_claims.sql:82`). The rollback fixture catches a severely incomplete `memory_claims` table because later index creation fails, but a table with the referenced columns and missing checks/foreign keys can survive all statements and still be stamped current.

    Required repair: validate the live 0006 table/index/foreign-key shapes before stamping, and add a compatible-column/incompatible-constraint partial-schema fixture with existing data.

## Verification

Reviewed only `462060a67066799506805d38d6ee7a48fc2e907a` and `f728dc845550ccf3bbcf7a60d1f8bb7f147f0d81` against the requested Task 5/Task 3 artifacts. Unrelated dirty capture, Swift, UI, release, and documentation work was excluded. Verification ran from a clean detached local clone at `f728dc8`; the canonical report was not overwritten.

- `cargo test -p mci-brain`: exit 0; reported suites/counts reproduced, including 324 library, 14 projection, 7 sufficiency, 8 typed-outcome, 21 retriever, and 55 SQLCipher tests.
- `cargo test -p mci-agent --test work_memory_bench -- --nocapture`: 15 passed.
- `cargo test -p mci-agent --lib bench_longmemeval::tests -- --nocapture`: 11 passed.
- `cargo test -p mci-agent --bin mci-bench -- --nocapture`: 2 passed.
- `cargo test -p mci-agent --test mcp_server mci_recall_with_embedder_calls_hybrid_retriever -- --nocapture`: 1 passed, confirming the current MCP test expects untyped fallback hits.
- Calibration reproduction to `/tmp`: byte-identical policy; coverage/FPR reproduced as `1.000/0.833` calibration and `0.667/0.500` validation.
- Canonical two-arm benchmark to `/tmp`: exit 5; lexical metrics reproduced, all 24 hybrid cases degraded, 0 hybrid instances scored, all hybrid quality metrics undefined.
- Same benchmark with the accepted Task 3 baseline: `regression.passed=false`; lexical index p95 exceeded its threshold and every hybrid regression metric was undefined.
- Leakage scan found no direct Task 3 entity, question-ID, slot-rule, or forbidden-symbol branch in the reviewed production/calibration code. The fixture/protocol/policy were introduced together in one commit, so the report's historical independence assertions are not independently auditable from these commits alone.

## Required Gate

Repair every P1 item before Task 5 can be accepted. Then repair the P2 calibration/determinism/outcome/expansion defects, add the named tests, rerun calibration without Task 3-informed tuning, and rerun both canonical Task 3 arms with `--baseline docs/eval/work-memory-baseline.json`. Acceptance requires a complete, publishable run with preserved provenance, no material lexical regression, and hybrid `false-positive@5 <= 0.10` plus `abstention separation@5 >= 0.80`.

FAIL
