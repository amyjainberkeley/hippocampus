# ADR-0010 — Event/episode is the retrieval & index unit; min-max Convex Combination fusion; query router

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #6)
- Owner: Director-Brain
- Reviewers: CTO; CSO (embedding leakage line of thought is protected-set adjacent)
- Phase: 0

## Context

`docs/AGENT_QUESTIONS.md` fork #6 (verbatim Recommendation): "*A. Architecture (SQLite+FTS5+sqlite-vec hybrid) stays; the **unit of retrieval** and **fusion function** change. Highest-leverage quality decision in the brain; dominates embedding-model and tuning gains. → DESIGN.md §8/§12 edit.*"

Primary-source basis (RESEARCH_DIGEST Stream C, all verified in the Verification pass): **MIRIX arXiv:2507.07957** Table 1 — flat embed-the-chunk RAG baseline scored 44.10% @ 15.07 GB; structured episodic scored 59.50% @ 15.89 MB. DESIGN.md §8 as drafted is the weak baseline that loses by ~15 points. **LongMemEval arXiv:2410.10813 (ICLR 2025)**: event-level indexing wins; key-expansion (summary/entities stored alongside text) = **+9.4% recall@5**; time-aware query expansion = **+6.8–11.3% temporal recall**. **Bruch et al. arXiv:2210.11934 (ACM TOIS 2023)**: **min-max Convex Combination beats RRF** in- and out-of-domain. **Lifelog Search Challenge review arXiv:2506.06743 (Dec 2025)**: recall (not precision) is the dominant success predictor (r=0.75); hybrid wins.

Verification-pass errata to apply verbatim:
- **Late Chunking arXiv:2409.04701** gain is **~2.7–3.6% relative / 1.5–1.9% absolute** (not the earlier "+5–15%" misquote). Not load-bearing for the decision, but ADR must cite the correct figure.
- **NEMORI arXiv:2508.03341** cognitive basis = **Predictive Coding / Free Energy Principle**, NOT "Event Segmentation Theory." Use only as flavor; the time-gap + content-shift episode-segmentation heuristic stands on its own.

CEO ratified 2026-05-18.

## Decision

1. **The retrieval and index unit is the event** (a state-transition moment in the capture stream), **not** the 200–500-token chunk that DESIGN.md §8 originally proposed. Chunks remain as a sub-unit only for over-long events.
2. **Schema changes (DESIGN.md §12):**
   - `events` table gains two columns:
     - `summary TEXT` — short on-device-LLM-generated summary of the event (idle-batch generated, never on the hot path).
     - `entities TEXT` — JSON-encoded list of extracted named entities (people, apps, URLs, file paths, error strings).
   - New `episodes` table: `id, ts_start, ts_end, app_bundle, summary, entities` — a contiguous app/task run, segmented from the event stream by a heuristic: **time-gap > T_gap** OR **content-shift proxy** (dHash distance + embedding-cosine drop over a sliding window). Cheap; no LLM in the segmenter.
   - Each event carries `episode_id` (nullable; backfilled by the segmenter).
3. **Embedding-time context header.** Event text is embedded with a prepended context header `[app=… | title=… | url=… | ts=…]\n<text>`. The header is part of the embedded string, not metadata-filtered later. This is the "key expansion" lift from LongMemEval.
4. **Sub-chunking** only when an event's `text` exceeds the embedder's effective context (e.g., > ~1500 tokens for arctic-embed-s). Sub-chunk on semantic / paragraph boundaries; each sub-chunk inherits the parent event's context header.
5. **Fusion = min-max Convex Combination, not Reciprocal Rank Fusion.** For a query:

   ```text
   score(e) = w_sem · sem_hat(e)
            + w_lex · lex_hat(e)
            + w_rec · 0.99^Δt_hours(e)
            + w_src · src(e)

   where:
     sem_hat  = min-max-normalize(semantic cosine over candidate pool) → [0, 1]
     lex_hat  = min-max-normalize(BM25 / FTS5 rank over candidate pool) → [0, 1]
     Δt_hours = age of the event from query time, in hours
     src(e)   = source-quality prior in [0, 1] (e.g., extension > AX > OCR)
     starting weights: w_sem=0.5, w_lex=0.3, w_rec=0.15, w_src=0.05
   ```

   Starting weights are calibrated against the eval in step 7 below; this is the *initial* set, not a frozen one.
6. **Query router** in the recall API:
   - **Anchor-then-window** for "right before X" / "right after X" queries: locate X via the standard hybrid, then walk the timeline ±N minutes.
   - **LLM time-range extraction** for natural-language temporal queries ("last Tuesday afternoon", "yesterday around 3pm"). On-device LLM only (see ADR-0001 NG3).
   - **Plain hybrid recall** for everything else.
7. **Eval gate.** Before locking the embedder choice (ADR-0011) in production code, Director-Brain builds a LongMemEval / ScreenshotVQA-style retrieval eval on consented real capture, with **Recall@k and NDCG@k as primary metrics** plus an LLM-judge secondary and a forgetting-aware check. The eval is the source of truth for tuning the fusion weights in step 5.

## Consequences

- Positive: ~15-point absolute-recall lift on the closest published analog (MIRIX). The single highest-leverage retrieval decision in MCI; dominates any embedder-tuning or chunk-size tuning gain.
- Positive: the hybrid-store architecture (SQLite + FTS5 + sqlite-vec) is unchanged; this is a schema + indexing-discipline change, not an engine swap. ADR-0008's store choice is unaffected.
- Negative / tradeoffs: `summary` and `entities` require an on-device LLM in the brain pipeline (idle-time, batched). Cost: bytes per event (small), occasional idle CPU bursts. Acceptable under the footprint SLO because everything is deferred to idle/charging (DESIGN.md §7, §10).
- Negative / tradeoffs: the eval is not free — it requires consented real-capture corpora. CRS Telemetry-Gap analyst owns measurement infra (AGENT_PROTOCOL §6: research agents propose; do not edit production code).
- Forces: ADR-0009's `event_vectors` schema is unchanged; embedding the *event text with context header* uses the same 384-d column. ADR-0011's embedder swap is unaffected.

## Alternatives considered

- **B — keep flat-chunk + Reciprocal Rank Fusion as in DESIGN.md.** Rejected — measurably ~15 points worse on MIRIX (44.10% vs 59.50%) and parameter-sensitive per Bruch (TOIS 2023). DESIGN.md as drafted is the baseline this decision beats.
- **Late Chunking only, no event-unit change.** Rejected — Late Chunking is a real but small lift (~2.7–3.6% relative per the corrected Verification figure) and does not address the *unit* of retrieval, which is what dominates per MIRIX.

## References

- DESIGN.md §8 (brain), §12 (data model) — both edited in the same PR per the AGENT_QUESTIONS Recommendation.
- docs/AGENT_QUESTIONS.md fork #6 (2026-05-18, ratified `accept recommendation`)
- docs/RESEARCH_DIGEST.md Stream C + Verification pass items 5 (Late-Chunking correction) and 6 (NEMORI basis correction)
- arXiv:2507.07957 (MIRIX), arXiv:2410.10813 (LongMemEval, ICLR 2025), arXiv:2210.11934 (Bruch, ACM TOIS 2023), arXiv:2506.06743 (Lifelog review), arXiv:2508.03341 (NEMORI; Predictive Coding / Free Energy)
- ADR-0009 (384-d pin), ADR-0011 (embedder)
