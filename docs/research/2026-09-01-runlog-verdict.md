# Runlog Verdict For Hippocampus

## Decision

Do not merge Runlog into Hippocampus and do not make it the retrieval engine. Adapt five local concepts behind Hippocampus interfaces: source-backed claims, retractions, the identity ladder, watermarked consolidation, and typed bounded retrieval.

Runlog is an enterprise document-intelligence system built around Go, Firestore, GCS, Pub/Sub, hosted model calls, and cloud deployment. Hippocampus is a user-owned macOS evidence ledger. Combining the runtimes would weaken the product boundary without repairing Runlog's correctness gaps.

## Why The Current Runlog Path Does Not Work Reliably

### 1. It is not vectorless

Runlog stores 768-dimensional Gemini embeddings and calls Firestore `FindNearest` with cosine distance in `/Users/amy/runlog-code/libs/go/service/entity.go`. Its Firestore configuration declares a vector index in `/Users/amy/runlog-code/firebase/firestore.indexes.json`.

The accurate claim is “no separate vector-database vendor.” The inaccurate claim is “does not rely on vector search.” Semantic vectors are one of its candidate generators and can be a blocking dependency in the current query path.

### 2. A required vector index is not deployed

`/Users/amy/runlog-code/Performance/roadmap/atlas-correctness.md` records the required entity-vector index as absent in development and production. A retrieval path that assumes an undeployed index can work in tests or small scans and fail when it reaches the real service boundary.

### 3. The one-seed graph search has no demonstrated completion path

The pathfinder records a result when a frontier reaches a node owned by another source in `/Users/amy/runlog-code/libs/go/retrieval/spine_pathfinder.go`. The initial state in `spine_state.go` begins from one source, and there is no one-source regression test proving a useful path can be committed. The algorithm can explore without satisfying its own completion condition.

This is especially dangerous because graph search often looks sophisticated while quietly returning no evidence. Hippocampus should first use bounded SQL expansion over known episode/entity edges and add a more complex walk only after a benchmark demonstrates a missing capability.

### 4. Candidate fusion compares scores with different meanings

`/Users/amy/runlog-code/libs/go/service/entity_recall.go` combines semantic, lexical, and deterministic candidate scores by taking a maximum. A cosine similarity, BM25 score, and name-signature score are not calibrated probabilities. `max` lets whichever subsystem emits numerically larger values dominate even when it is less reliable.

Runlog's own correctness roadmap asks for rank fusion. Hippocampus should use reciprocal-rank or evaluated feature fusion, preserve each leg's score, and publish per-leg ablations.

### 5. Expensive and fragile work happens before the dependable fallback

The general query path in `/Users/amy/runlog-code/libs/go/service/query_entities.go` performs model-based entity extraction and embedding before lexical recall. If embedding fails, the cheap lexical path can be blocked even though it could have answered the query. This raises latency, cost, and outage blast radius.

Hippocampus should parse deterministic filters and run FTS first, then add semantic candidates and graph evidence within a budget. Model failure must produce `degraded` retrieval, not no retrieval.

### 6. Result order and evidence packing are not stable

Map iteration in `/Users/amy/runlog-code/libs/go/retrieval/spine_state.go` can make equal-score behavior nondeterministic. The budget packer in `/Users/amy/runlog-code/libs/go/retrieval/budget.go` stops at the first oversized item instead of skipping it and considering smaller high-value evidence. Identical requests can therefore produce different packets or unnecessarily sparse packets.

Hippocampus requires deterministic tie-breaks by score, timestamp, and stable ID. Evidence packing should continue past oversized items and record what was omitted.

### 7. Typed internal truth disappears at the public boundary

Runlog models outcomes such as matched, nothing matched, and degraded internally, but the public API and MCP surfaces do not consistently preserve that distinction. A caller cannot reliably distinguish “there is no evidence” from “a dependency failed.”

Hippocampus will make the typed outcome part of every retrieval and context-packet response. This is essential for agent trust and abstention.

### 8. Security configuration is operational rather than enforced by tests

Firestore rules and indexes require manual deployment, local emulation does not load the full production policy, and administrative clients bypass normal rules. Passing local tests therefore does not prove tenant isolation or index availability.

Hippocampus keeps the first product local and tests its SQLCipher, file-permission, key-custody, deletion, and client-configuration boundaries on the same machine where they ship.

## What Is Genuinely Strong

1. **Source factions:** preserve which source asserted a fact instead of flattening everything into a summary.
2. **Faithful conflicts:** contradictory claims coexist with timestamps and evidence.
3. **Incremental projection:** content-addressed changes update derived knowledge without reprocessing the entire corpus.
4. **Identity ladder:** exact identifiers and cheap lexical/signature matches run before semantic similarity.
5. **Watermarked operating memory:** compact current state is derived from a known evidence frontier and can be rebuilt.
6. **Typed outcomes:** a retrieval system should admit when it found nothing or ran in degraded mode.

## Hippocampus Adaptation Boundary

The local interface is:

```rust
pub trait MemoryProjector {
    fn project(&self, event: &EventEnvelope) -> Result<MemoryDelta, ProjectError>;
    fn retract(&self, event_id: EventId) -> Result<MemoryDelta, ProjectError>;
}

pub struct MemoryDelta {
    pub claim_upserts: Vec<MemoryClaim>,
    pub evidence_links: Vec<EvidenceRef>,
    pub retractions: Vec<ClaimId>,
    pub watermark: ProjectionWatermark,
    pub projector_version: String,
}
```

The projector runs beside the existing episode/entity pipeline first. Its results remain shadow data until the synthetic work-memory benchmark proves improved provenance, temporal correctness, contradiction handling, and abstention without unacceptable latency.

