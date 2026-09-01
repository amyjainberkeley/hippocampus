# Hippocampus Memory Layer Design

**Status:** Approved for implementation by the owner on 2026-09-01.

## Product Definition

Hippocampus is a private, source-linked work-continuity layer for macOS. It captures permitted work context, preserves the evidence locally, compiles it into episodes and briefs, and gives the same evidence-backed context to the human and to local AI clients such as Claude Code and Codex.

The primary promise is: **resume any project, with any agent, from evidence in under a minute.** Hippocampus is not an all-in-one chat workspace, a generic recorder, or a cloud memory API.

## Product Boundary

### V1: dependable personal memory

- One signed macOS application with explicit capture state, exclusions, retention, and deletion.
- Automatic import of supported local coding-agent histories.
- ScreenCaptureKit capture only after explicit opt-in; disabled means no screen stream is initialized.
- Local OCR, deduplication, encrypted evidence, real thumbnails, hybrid search, episodes, briefs, and read-only MCP.
- Automatic detection and registration for supported local agent clients without embedding the database key in their configuration files.
- Search, Timeline, Episodes, Brief, Sources, and Privacy as complete user workflows.

### V2: governed derived memory

- Versioned source-backed claims for decisions, commitments, changed facts, people, projects, and open loops.
- Retractions and corrections propagate through episodes, briefs, context packets, and retrieval.
- Query planning uses deterministic filters and FTS first, vectors as candidate generation, bounded graph expansion, and evidence budgets.
- Retrieval returns a typed outcome: `matched`, `nothingMatched`, or `degraded`; weak evidence is never presented as certainty.
- Optional browser and local-file enrichers use the same evidence and deletion contracts.

### V3: computer-to-agent coordination

- A local context broker can deliver project packets to multiple agents and record what each agent learned or changed.
- Daily and project briefs explain what changed, why it matters to the user, and which source supports each statement.
- Workflow suggestions are derived from repeated evidence but never execute without a visible user-controlled policy.
- Optional encrypted sync and team views transport only owner-approved derived memory and evidence references.

## Architecture

Hippocampus uses seven explicit layers:

1. **Capture envelope:** source, application, window, URL, time, capture policy, and content digest.
2. **Encrypted evidence ledger:** raw permitted text and keyframes, immutable except for user deletion and retention.
3. **Episodes:** bounded work sessions assembled from time, application, project, and entity continuity.
4. **Evidence anchors:** stable references to event IDs, files, URLs, messages, source spans, and thumbnails.
5. **Derived memory:** versioned claims, identities, decisions, commitments, contradictions, retractions, and confidence.
6. **Compiled context:** daily briefs, project briefs, and token-budgeted agent packets.
7. **Retrieval planner:** query intent, filters, FTS candidates, semantic candidates, temporal and graph expansion, evidence packing, and abstention.

Raw evidence is canonical. Derived memory never overwrites evidence. Contradictions coexist. Human corrections append a superseding claim. Deleting evidence removes blobs and causes every dependent derivative to be retracted or rebuilt.

## Capture And Condensation

- Capture is explicit and visible. `capture_enabled = false` prevents `--capture` from being passed and prevents `SCStream` construction.
- The helper applies the suppression cascade before serialization. Denylisted applications, secure input, private browsing, and screen sharing fail closed.
- Consecutive frames are deduplicated using perceptual similarity and window identity before OCR or durable storage.
- A keyframe is retained when the active work changes materially, a task boundary is detected, or an evidence-bearing state would otherwise be lost.
- OCR and structured application metadata are stored as evidence. A compact summary may be generated later, never substituted for the source.
- The UI decodes actual keyframes and labels placeholders honestly when a source has no visual evidence.

## Retrieval And Runlog Adaptation

Runlog is not merged as a dependency. Its cloud services, Firestore indexes, LLM-first query path, and graph walker are incompatible with the local trust boundary.

The following ideas are adapted behind local Rust interfaces:

- `MemoryDelta`: versioned entity and claim upserts, evidence links, retractions, and watermarks.
- Identity ladder: exact identifier, normalized lexical match, scalar signature narrowing, then semantic similarity.
- Source-backed conflicting claims rather than last-write-wins summaries.
- Incremental consolidation with periodic full re-derivation to bound drift.
- Typed retrieval outcomes and bounded graph expansion.

Vector similarity is a recall signal, not truth. Scores from different candidate legs are combined by rank-aware fusion or calibrated features, never an unqualified `max` over incomparable values.

## Agent Handoff

- A context packet contains a project summary, recent changes, decisions, open loops, relevant people, and compact evidence citations.
- MCP tools remain read-only for V1. Agent-produced changes return through explicit import paths and become new evidence rather than silently mutating memory.
- Client registration writes executable and broker identifiers only. It never writes `MCI_DB_KEY_HEX` or another reusable secret to Claude, Codex, Cursor, or shell configuration.
- Unsupported clients receive a generated local configuration preview and an explicit install action.

## Visual System

### Subject and job

The subject is the user's recent work. The main window's job is to answer: **what happened, what matters now, and where is the evidence?**

### Palette

- Snow canvas `#F6F8FB`
- Clear surface `#FFFFFF`
- Ink `#18212B`
- Graphite `#5F6975`
- Cobalt action `#3568D4`
- Coral change marker `#D96C5F`

Source colors may identify applications in tiny markers, but no hue dominates the workspace. Dark appearance remains supported through semantic colors; the app does not force dark mode.

### Structure

- `NavigationSplitView` with a hideable translucent sidebar.
- Primary destinations: Now, Search, Timeline, Episodes, Briefs.
- Privacy, Sources, and Settings live below the primary workflow or in the toolbar, not as equal tabs.
- The top content edge shows a real keyframe filmstrip; content can extend beneath system navigation materials.
- Standard macOS controls, SF Symbols, materials, hover states, focus rings, reduced-transparency handling, and reduced-motion handling are mandatory.
- Glass is used for navigation and controls, not as nested decorative cards.

### Icon

The icon is a neutral layered-memory mark: simple bold translucent panes over a light dimensional base. It contains no face silhouette, brain squiggle, text, or neon mint field and remains legible at 16 points.

## Benchmark

The repository ships a synthetic technical-work corpus with multiple applications, projects, decisions, changed facts, contradictions, temporal questions, and unanswerable questions. It contains no user data.

The benchmark reports:

- hit rate and recall at 1, 3, 5, and 10
- mean reciprocal rank
- temporal and contradiction slices
- source/provenance coverage
- unanswerable false-positive rate and abstention separation
- latency and index size

Lexical and production hybrid arms are reported separately. A missing model or partial run is a failure, never a silently downgraded result.

## Security And Release Invariants

- Database keys are generated and stored in macOS Keychain. Development file keys are allowed only behind an explicit development mode and are never the production default.
- Product copy states implemented cryptography precisely. No Secure Enclave, Neural Engine, sqlite-vec, crypto-shred, or zero-knowledge claim appears unless the shipped path proves it.
- Deletion has a machine-verifiable receipt listing removed evidence and rebuilt or retracted derivatives.
- Build inputs, model artifacts, changelog, checksums, appcast, signing, and notarization are reproducible from a clean clone.
- Clippy, Rust tests, Swift tests, privacy invariant tests, and clean-install smoke tests are blocking release gates.

## Acceptance Criteria

1. On a clean Mac, the owner can install, initialize, import agent history, optionally enable capture, create evidence, search, inspect a thumbnail, open an episode, read a brief, and use MCP.
2. Capture-off tests prove no ScreenCaptureKit stream construction path is reached.
3. No reusable database key is present in client configuration or process arguments.
4. Synthetic benchmark results and failure cases are committed as reproducible artifacts.
5. The recall UI opens in a light adaptive appearance with the new icon and contains no placeholder product surfaces in the primary workflow.
6. Source links are visible on every search result, episode claim, and brief assertion.
7. The signed application can be notarized using the owner's credentials without modifying source files.

## Decision Evidence

- Native design and navigation follow Apple's Liquid Glass overview, adoption guide, and sidebar HIG: https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass, https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass, https://developer.apple.com/design/human-interface-guidelines/sidebars
- Capture uses Apple's ScreenCaptureKit contract and is constrained by multimodal routing and memory-safety research: https://developer.apple.com/documentation/screencapturekit, https://arxiv.org/abs/2606.07402, https://arxiv.org/abs/2603.11768
- Memory hierarchy and retrieval planning are supported by MemoryOS, LongMemEval-V2, and temporal graph memory work: https://arxiv.org/abs/2506.06326, https://arxiv.org/abs/2605.12493, https://arxiv.org/abs/2501.13956
- Product interaction choices are triangulated against HeyClicky's official product and changelog, screenpipe's open capture platform, and Obsidian's local ownership model: https://www.hiclicky.com/, https://www.heyclicky.com/changelog, https://screenpipe.com/, https://obsidian.md/privacy

