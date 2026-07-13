# core/brain/

The `mci-brain` crate: OS-free traits + production impls for the
memory/retrieval/entities pipeline that turns captured events into a
searchable brain. Phase 3+ per ADR-0016.

## Contents

- `src/` — crate root. Load-bearing modules:
  - `sqlcipher_brain_store.rs` — the encrypted SQLite store.
  - `arctic_embed_s.rs` — Snowflake Arctic-Embed-S (ADR-0011).
  - `hybrid_retriever.rs` — FTS + vector + graph fusion.
  - `event_chunker.rs`, `episode_segmenter.rs`, `consolidator.rs` —
    event → episode pipeline (ADR-0010).
  - `graph.rs` — entity graph.
  - `extraction/` — tier-1 regex + tier-2 NER extractors.
  - `redaction/` — sensitive-content redaction (ADR-0030).
  - `alias_resolver.rs`, `integrity_scheduler.rs`,
    `retention_purger.rs` — background maintenance.
  - `bin/` — corpus-gate binaries (ADR-0029).
- `benches/` — retrieval + embedding benchmarks.
- `migrations/` — SQLCipher migrations for the brain store.
- `tests/` — integration tests (event/episode, retriever, redaction).
- `Cargo.toml` — the `mci-brain` package manifest.

## Related

- `../` — parent `mci-core` crate.
- `../../adapters/macos/mci-brain-ffi/` — C-ABI FFI shim for Swift
  recall-ui consumers.
- `../../docs/decisions/0010-event-episode-retrieval-unit-cc-fusion.md`,
  `0011-embedding-model-snowflake-arctic-embed-s.md`,
  `0016-phase-3-ocr-brain.md`.

## When to edit here

Any change to embedding, retrieval, chunking, extraction, redaction,
or the brain store schema. Schema/migration changes are CSO-gated
(they touch the encrypted store). If the change is OS-specific
(e.g., a Core ML model wrapper), it belongs in
`../../adapters/<os>/mci-embed-<os>/`, not here.
