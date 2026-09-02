# ADR-0039: Runlog adoption boundary

- Status: Accepted (2026-09-02)
- Runlog audit baseline: `d3bab5c783f1aa13ee87aec1a84272e50ab41527`
- Scope: architecture and selective concept adoption

## Context

Runlog and Hippocampus both turn heterogeneous work artifacts into retrievable
context, but they own different trust boundaries. Runlog is a cloud document
intelligence system built around Firestore, Google Cloud Storage, Pub/Sub,
Cloud Run, service accounts, and Gemini. Hippocampus is a local macOS memory
layer whose canonical evidence, indexes, vectors, and derived artifacts remain
inside one SQLCipher store and its managed encrypted blob directory.

Runlog does use vectors. Its `Faction` schema stores 768-dimensional Gemini
embeddings, its Firestore configuration declares a vector index, and its
retrieval service executes cosine nearest-neighbor search. Its stronger idea is
not avoiding vectors; it is merging semantic, lexical/BM25, and deterministic
signature candidate generators.

The audit also found a provenance break that Hippocampus must not reproduce.
Runlog's schema says a durable `Cell` claim cites source `Faction` records, but
its agent `memory_write` tool can persist a Cell without those citations. Its
query expansion can add model-generated general knowledge before retrieval,
and its MCP response drops an internal degraded/empty distinction. Those paths
can make generated or weakly retrieved material look like stored evidence.

## Decision

Hippocampus will not merge the Runlog codebase, adopt its cloud storage stack,
or make Runlog a runtime dependency. Runlog remains an independently audited
source of hypotheses. A concept enters Hippocampus only when it can be
reimplemented locally behind an existing ownership boundary, benchmarked
against a simpler baseline, and kept subordinate to canonical source evidence.

The following concepts are approved for local evaluation:

1. Multiple independent candidate generators with per-arm benchmark reporting.
2. Exact source-region anchors when a source format exposes stable locations.
3. Deterministic visual or window signatures for recurring-state association.
4. Watermarked regeneration of derived episode or project digests.
5. Ordered progressive capture acknowledgements with first-failure visibility.

Several of these already exist in partial or stronger form. Hippocampus hybrid
recall measures lexical, semantic, entity, recency, and source arms. Screen
capture uses dHash and focused-window identity before encrypted keyframe
retention. Alias resolution and consolidation use change-detection watermarks.
MCP preserves typed matched, contradicted, empty, and degraded outcomes, and
focused context packets now retain that status through agent handoff. New work
must extend these primitives rather than create parallel Runlog-shaped stacks.

The following are explicitly rejected:

- Firestore, Firebase, GCS, Pub/Sub, Cloud Run, or remote canonical memory.
- Agent-written durable claims without canonical evidence IDs.
- Model-generated general knowledge mixed into a source-memory query.
- URL-carried capability keys or reusable database keys in client config.
- Eventual or best-effort deletion presented as complete deletion.
- The A*-style graph walk without a locked equal-cost retrieval benchmark.
- Authoritative summaries that cannot be regenerated from surviving evidence.

## Consequences

The repositories remain separate. There is no code transplant milestone and no
dual source of truth. Hippocampus continues to optimize for automatic local
capture, inspectable evidence, reversible derived memory, and safe agent
handoff. Runlog-inspired work is accepted only as small benchmarked changes,
not as a platform migration.

The next approved experiment is not a graph rewrite. It is to add region-level
provenance where structured sources expose it, then measure whether that
improves the locked semantic-verifier and work-memory corpora without widening
the capture or cloud trust boundary.

## Audit references

The audited Runlog snapshot was the local sibling repository at the commit
above. Relevant paths were:

- `README.md`
- `protos/fc.proto`
- `firebase/firestore.indexes.json`
- `libs/go/service/entity.go`
- `libs/go/service/entity_recall.go`
- `libs/go/retrieval/bm25/bm25.go`
- `libs/go/retrieval/query_entities.go`
- `libs/go/retrieval/spine_pathfinder.go`
- `libs/go/service/memorydigest.go`
- `relay/internal/agenttools/tools.go`
- `relay/internal/handlers/project_file.go`
- `libs/go/service/deletion.go`
- `extension/offscreen.js`
