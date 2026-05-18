# ADR-0009 — Pin `sqlite-vec` dimension = 384 in the Phase 0 schema

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2; implements ratified fork #5)
- Owner: Director-Brain
- Reviewers: CTO; CSO (embed-side leakage line of thought is protected-set adjacent)
- Phase: 0

## Context

`docs/AGENT_QUESTIONS.md` fork #5 (verbatim Recommendation): "*A. DESIGN.md already commits MiniLM/384; re-embedding is a bounded, known migration. Simplicity in P0 beats a hypothetical model swap.*"

CRS Verification verdict (verbatim from `docs/AGENT_QUESTIONS.md`): "*Pin-384 CONFIRMED and stronger — the recommended embedder `snowflake-arctic-embed-s` is also 384-d, so the schema is unchanged while retrieval improves ~24%. Add a zero-cost Matryoshka hedge to the ADR: store vectors L2-normalized; prefer MRL-capable models for any future swap so a dimension change is a truncation, not a re-train.*"

CEO ratified 2026-05-18.

## Decision

1. **The Phase 0 `event_vectors` schema fixes the `sqlite-vec` column to `embedding(384)`** (`float32[384]` until binary quantization kicks in past the scaling threshold in ADR-0011 / Stream D). This matches both `all-MiniLM-L6-v2` (the prior DESIGN.md choice) and `snowflake-arctic-embed-s` (the ADR-0011 swap), so the schema is unchanged across the swap.
2. **Vectors are stored L2-normalized.** Normalization happens in the embedder wrapper before insert; the index path never sees an unnormalized vector. This makes cosine similarity == dot product and makes any future Matryoshka-style swap (`prefer MRL-capable models for future swaps`) a truncation rather than a re-train.
3. **Schema versioning.** The `meta` table (DESIGN.md §12) carries `schema_version` (integer, monotonic). The store layer refuses to open a database with `schema_version` higher than it knows. A re-embed migration is a bumped `schema_version` + a documented walker that recomputes embeddings on the current model.
4. **Documented re-embed migration recipe** (lives in `docs/migrations/embedder-swap.md` when first needed): pause capture, drop `event_vectors`, re-create with new (or same) dimension, walk `chunks` + new embedder, upsert, bump `schema_version`. Migration runs offline (recall UI shows "rebuilding brain"); deltas in `sync_log` stay valid because vectors are not synced (DESIGN.md §12 — they're derived from chunks).

## Consequences

- Positive: zero schema churn at the moment of the ADR-0011 embedder swap. The retrieval-quality lift (~+24% MTEB-R per CRS Stream D) lands without a migration.
- Positive: L2-normalization is free at embed time and unlocks a future Matryoshka truncation path without a re-embed.
- Positive: the migration recipe makes the "model swap" risk bounded and known — not a one-way door.
- Negative / tradeoffs: pinning 384 at P0 is a soft commitment. Any future model exceeding 384 forces a migration (which we now know how to run; see above). The Matryoshka hedge mitigates this for MRL-capable swaps.
- Forces: the `events` / `event_vectors` / `chunks` schemas in `core/store/` must be authored to honor this dimension and the `schema_version` discipline. The `meta.schema_version` write happens in the same transaction as schema creation.

## Alternatives considered

- **B (dimension-agnostic / out-of-table embeddings until Phase 3).** Rejected — DESIGN.md already commits a 384-d model; pretending we don't know the dimension adds P0 complexity to defer a decision that's already been made. ADR-0011 reaffirms 384 via a different model, so the deferral would have been pointless.

## References

- DESIGN.md §8 (brain), §12 (data model — `event_vectors` + `meta` rows), §13 (tech stack)
- docs/AGENT_QUESTIONS.md fork #5 (2026-05-18, ratified `accept recommendation`) + CRS Verification verdict
- docs/RESEARCH_DIGEST.md Stream D (sqlite-vec confirmation), Verification pass item 7
- ADR-0011 (embedder = snowflake-arctic-embed-s, 384-d)
