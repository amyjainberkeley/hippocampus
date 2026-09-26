# Hippocampus Memory Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a verified macOS memory MVP with explicit capture, encrypted evidence, useful retrieval, agent handoff, a complete light native UI, and reproducible release artifacts.

**Architecture:** Preserve the SQLCipher event ledger as canonical, add governed derived memory and context packets above it, and keep capture, retrieval, and presentation behind existing interfaces. Runlog contributes selected projection concepts but no runtime dependency.

**Tech Stack:** Rust 2021, SQLCipher/SQLite FTS5, Swift 6, SwiftUI/AppKit, ScreenCaptureKit, Vision OCR, Core ML, MCP over stdio, Bash release tooling.

**Spec:** `docs/superpowers/specs/2026-09-01-hippocampus-memory-layer-design.md`

## Global Constraints

- macOS 14 remains the minimum deployment target; newer Liquid Glass APIs require availability fallbacks.
- Raw permitted evidence is canonical; summaries and claims never replace source rows.
- Disabled capture must not construct or start an `SCStream`.
- No reusable database key may be written to agent-client configuration.
- All primary UI destinations must work in light and dark appearances without a forced color scheme.
- No production privacy claim may exceed the shipped implementation.
- Every task uses failing tests first and leaves its focused test suite green.

---

### Task 1: Canonical Status, Honest Claims, And Release Inputs

**Files:**
- Create: `docs/STATUS.md`
- Create: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `docs/DESIGN.md`
- Modify: `apps/hippocampus/Resources/build-app.sh`
- Test: `apps/hippocampus/Tests/HippocampusKitTests/BuildAppScriptTests.swift`

**Interfaces:**
- Produces: one status source of truth and a clean-clone build contract consumed by every later task.

- [ ] **Step 1: Add failing build-script tests** asserting that the build either finds a committed changelog and pinned model manifest or exits with one actionable message naming the reconstruction command.
- [ ] **Step 2: Run** `cargo build -p mci-brain-ffi && swift test --package-path apps/hippocampus --filter BuildAppScriptTests` and confirm the new assertions fail.
- [ ] **Step 3: Write `docs/STATUS.md`** with current commit, working surfaces, disabled/unverified surfaces, release gates, benchmark status, and owner-only credential actions.
- [ ] **Step 4: Correct README and DESIGN claims** to CPU Core ML, Rust cosine vector scan, Keychain target state, row deletion plus vacuum, actual Mail/Messages persistence, and capture default-off semantics.
- [ ] **Step 5: Add a real changelog and deterministic model-input checks** to `build-app.sh`; errors must name `scripts/convert_embedder.py`, `scripts/convert_ner.py`, or the documented download command.
- [ ] **Step 6: Re-run focused tests and** `git diff --check`.
- [ ] **Step 7: Commit** `docs: establish truthful release status`.

### Task 2: Keychain Custody And True Capture-Off

**Files:**
- Modify: `apps/hippocampus/Sources/HippocampusKit/KeyStore.swift`
- Modify: `apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift`
- Modify: `apps/hippocampus/Sources/HippocampusKit/RuntimeConfig.swift`
- Modify: `apps/hippocampus/Sources/Hippocampus/PreferencesWindow.swift`
- Modify: `apps/hippocampus/Package.swift`
- Modify: `apps/agent/src/bin/mci_agent.rs`
- Create: `apps/agent/src/key_resolver.rs`
- Modify: `apps/agent/src/lib.rs`
- Test: `apps/hippocampus/Tests/HippocampusKitTests/RuntimeConfigTests.swift`
- Test: `apps/hippocampus/Tests/HippocampusKitTests/ProcessSupervisorTests.swift`
- Create: `apps/hippocampus/Tests/HippocampusKitTests/KeyStoreTests.swift`
- Create: `apps/agent/tests/key_resolver.rs`

**Interfaces:**
- Produces: `KeychainKeyStore`, `RuntimeConfig.captureEnabled`, and `resolve_database_key()`.
- Consumes: existing `KeyStore` protocol, supervisor launch plan, and MCP registration path.

- [ ] **Step 1: Add failing Swift tests** proving capture defaults false, the supervisor omits `--capture` while false, includes it while true, and production key storage uses a Keychain service/account rather than `dev.key`.
- [ ] **Step 2: Add failing Rust tests** proving MCP configuration contains a key reference but no `MCI_DB_KEY_HEX` and key resolution accepts an injected Keychain reader.
- [ ] **Step 3: Run focused Swift and Rust tests** and confirm failures are behavioral rather than environment-only.
- [ ] **Step 4: Implement `RuntimeConfig.captureEnabled`** with an atomic TOML update and mode `0644` because it contains no secret.
- [ ] **Step 5: Implement `KeychainKeyStore`** using Security.framework generic-password APIs; retain `FileKeyStore` only for tests and explicit development mode.
- [ ] **Step 6: Refactor supervisor launch planning** into a pure tested function and pass `--capture` only when `captureEnabled` is true.
- [ ] **Step 7: Change MCP registration and agent key resolution** to use a Keychain service/account reference; never serialize the database key into Claude or Codex configuration.
- [ ] **Step 8: Add a visible capture toggle** with status text explaining that off means no screen access.
- [ ] **Step 9: Run focused tests, `cargo test -p mci-agent`, and `git diff --check`.**
- [ ] **Step 10: Commit** `fix: secure key custody and capture gating`.

### Task 3: Synthetic Work-Memory Benchmark

**Files:**
- Create: `eval/work-memory/synthetic-v1.json`
- Create: `eval/work-memory/README.md`
- Modify: `apps/agent/src/bench_longmemeval.rs`
- Modify: `apps/agent/src/bin/mci_bench.rs`
- Create: `apps/agent/tests/work_memory_bench.rs`
- Create: `scripts/eval/work-memory/run.sh`
- Create: `docs/eval/work-memory-baseline.json`
- Modify: `docs/eval/README.md`

**Interfaces:**
- Produces: reproducible lexical and hybrid reports using the production store, embedder, and retriever.

- [ ] **Step 1: Add a 24-case synthetic dataset** covering exact recall, paraphrase, temporal questions, cross-session synthesis, changed facts, contradiction, source attribution, and unanswerable queries across GitHub, terminal, browser, Slack, Linear, and files.
- [ ] **Step 2: Add failing parser and scoring tests** for provenance coverage, false-positive rate, and typed abstention in addition to hit@k, recall@k, and MRR.
- [ ] **Step 3: Run** `cargo test -p mci-agent --test work_memory_bench` and confirm the new metrics are absent.
- [ ] **Step 4: Extend the benchmark report** without changing LongMemEval compatibility; partial runs set `complete=false` and exit nonzero.
- [ ] **Step 5: Write the one-command runner** using the installed ArcticEmbedS model through `MCI_ARCTIC_MODEL_PATH` when present.
- [ ] **Step 6: Run lexical and hybrid arms** and save the exact environment, commit, metrics, misses, latency, and index size to `docs/eval/work-memory-baseline.json`.
- [ ] **Step 7: Add benchmark regression thresholds** that fail only on material declines from the measured baseline.
- [ ] **Step 8: Commit** `test: add reproducible work-memory benchmark`.

### Task 4: Visual Evidence And Capture Condensation

**Files:**
- Modify: `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift`
- Modify: `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/SCStream/SCStreamPipeline.swift`
- Create: `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/SCStream/KeyframePolicy.swift`
- Create: `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/KeyframePolicyTests.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/HitRow.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/TimelineStripView.swift`
- Create: `apps/recall-ui/Sources/RecallUI/EvidenceThumbnail.swift`
- Modify: `apps/recall-ui/Tests/RecallUIKitTests/TimelineStripTests.swift`
- Modify: `apps/recall-ui/Tests/RecallUIKitTests/HitThumbnailWireTests.swift`

**Interfaces:**
- Produces: deterministic `KeyframePolicy.shouldRetain(previous:current:)` and one shared thumbnail decoder.
- Consumes: existing suppression cascade, keyframe blob writer, and `thumbnailPath` wire fields.

- [ ] **Step 1: Add failing policy tests** for unchanged frames, changed window, material perceptual change, maximum silence interval, and protected surfaces.
- [ ] **Step 2: Add failing UI tests** proving a valid image path renders evidence while missing or invalid paths render a neutral source placeholder.
- [ ] **Step 3: Run capture-helper and RecallUIKit focused tests** and confirm failures.
- [ ] **Step 4: Implement bounded keyframe condensation** after privacy approval and before OCR persistence; protected frames never reach the policy.
- [ ] **Step 5: Implement one asynchronous thumbnail loader** with cancellation, image downsampling, aspect-fill cropping, and no full-resolution retention in view state.
- [ ] **Step 6: Replace the timeline placeholder** with decoded evidence and meaningful app/time metadata.
- [x] **Step 6a: Complete privacy deletion.** Event, range, scheduled retention, and full-brain deletion remove their unreferenced encrypted blobs; every retention cycle safely reconciles canonical crash orphans and stale temp files after a one-hour grace period.
- [ ] **Step 7: Run focused suites and a 30-minute synthetic soak** to measure frame, OCR, retained-keyframe, CPU, and disk counters.
- [ ] **Step 8: Commit** `feat: retain and render useful visual evidence`.

### Task 5: Governed Memory Projection

**Files:**
- Create: `core/brain/migrations/0006_memory_claims.sql`
- Create: `core/brain/src/memory_delta.rs`
- Create: `core/brain/src/memory_projector.rs`
- Modify: `core/brain/src/lib.rs`
- Modify: `core/brain/src/sqlcipher_brain_store.rs`
- Modify: `core/brain/src/hybrid_retriever.rs`
- Create: `core/brain/tests/memory_projection.rs`
- Create: `core/brain/tests/retrieval_outcomes.rs`

**Interfaces:**
- Produces: `MemoryDelta`, `MemoryClaim`, `ClaimStatus`, `EvidenceRef`, `RetrievalOutcome`, `project_event`, and `retract_event`.
- Consumes: canonical events, entities, identities, episodes, and existing retrieval hits.

- [ ] **Step 1: Add failing migration and projector tests** for source-backed claims, coexistence of contradictions, superseding corrections, event retraction, and idempotent replay.
- [ ] **Step 2: Add failing retrieval tests** for `matched`, `nothingMatched`, and `degraded` outcomes with evidence coverage.
- [ ] **Step 3: Run** `cargo test -p mci-brain --test memory_projection --test retrieval_outcomes` and confirm failures.
- [ ] **Step 4: Add append-only claim and evidence tables** with foreign keys, validity timestamps, confidence, projector version, and retraction state.
- [ ] **Step 5: Implement deterministic `MemoryDelta` application** in a transaction; no model call occurs inside the transaction.
- [ ] **Step 6: Add typed retrieval outcomes and bounded episode/entity expansion** with an explicit node and token budget.
- [ ] **Step 7: Replace source score `0`** with a documented source-quality feature and rank-aware fusion measured by Task 3.
- [ ] **Step 8: Run brain tests and benchmark; retain the change only if provenance and retrieval gates pass.**
- [ ] **Step 9: Commit** `feat: add governed source-backed memory`.

### Task 6: Context Packets And Automatic Agent Registration

**Files:**
- Create: `apps/agent/src/context_packet.rs`
- Modify: `apps/agent/src/mcp_aggregator.rs`
- Modify: `apps/agent/src/bin/mci_agent.rs`
- Create: `apps/agent/src/client_registry.rs`
- Create: `apps/agent/tests/context_packet.rs`
- Create: `apps/agent/tests/client_registry.rs`
- Modify: `README.md`

**Interfaces:**
- Produces: `compile_context_packet(project, budget)`, MCP tool `mci_context`, and idempotent client detection/registration.
- Consumes: typed retrieval outcomes, episodes, claims, open loops, and evidence references.

- [x] **Step 1: Add failing tests** for deterministic token budgets, citation preservation, weak-evidence abstention, idempotent Claude/Codex registration, and no serialized secret.
- [x] **Step 2: Run focused tests** and confirm failures.
- [x] **Step 3: Implement context packets** ordered as current state, changes, decisions, open loops, people, and evidence.
- [x] **Step 4: Add the read-only `mci_context` MCP tool** with typed outcome metadata.
- [x] **Step 5: Implement local client discovery and atomic configuration updates** preserving unrelated user configuration.
- [x] **Step 6: Add `mci-agent connect --all` and make `init` call it after the key and brain are ready.**
- [x] **Step 7: Run focused tests and an isolated-HOME end-to-end registration smoke test.**
- [x] **Step 8: Commit** `feat: deliver evidence-backed agent context`.

### Task 7: Native Light Recall Experience And New Icon

**Files:**
- Modify: `assets/branding/AppIcon-template.svg`
- Modify: `assets/branding/AppIcon.svg`
- Regenerate: `assets/branding/AppIcon.iconset/*`
- Regenerate: `assets/branding/AppIcon.icns`
- Modify: `assets/branding/colors.json`
- Modify: `apps/recall-ui/Sources/RecallUIKit/DesignSystem/MCIDesignSystem.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/BrandTheme.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/MCIRecallApp.swift`
- Create: `apps/recall-ui/Sources/RecallUI/MemoryWorkspaceView.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/SearchView.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/TimelineStripView.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/EpisodesView.swift`
- Modify: `apps/recall-ui/Sources/RecallUI/BriefView.swift`
- Modify: `apps/recall-ui/Tests/RecallUIKitTests/MCIDesignSystemTests.swift`
- Create: `apps/recall-ui/Tests/RecallUIKitTests/MemoryWorkspaceTests.swift`

**Interfaces:**
- Produces: adaptive semantic tokens and a `NavigationSplitView` workspace over existing view models.

- [ ] **Step 1: Add failing token tests** for the approved palette, zero letter spacing, adaptive appearance, and non-mint icon source.
- [ ] **Step 2: Add failing workspace tests** for primary navigation, status visibility, source access, and removal of placeholder primary surfaces.
- [ ] **Step 3: Run RecallUIKit tests** and confirm failures.
- [ ] **Step 4: Replace the icon source** with the layered neutral memory mark and regenerate every size from one canonical 1024 image.
- [ ] **Step 5: Replace forced-dark TabView** with a hideable `NavigationSplitView`; primary destinations are Now, Search, Timeline, Episodes, and Briefs.
- [ ] **Step 6: Apply native materials to navigation and controls only** with macOS 14 fallbacks; extend real keyframe content under the top bar.
- [ ] **Step 7: Finish hover, selection, empty, loading, error, reduced-motion, reduced-transparency, keyboard, and resize states.**
- [ ] **Step 8: Build and capture screenshots** at 1440x900, 1024x700, and 760x520 in light and dark appearances; inspect for overlap, clipped labels, blank thumbnails, and hierarchy.
- [ ] **Step 9: Commit** `feat: redesign Hippocampus as a native memory workspace`.

### Task 8: Clean Release And End-To-End Verification

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `apps/hippocampus/Resources/Info.plist`
- Modify: `apps/hippocampus/Sources/HippocampusKit/Updater.swift`
- Modify: `scripts/check.sh`
- Modify: `scripts/build-installer.sh`
- Create: `scripts/e2e-clean-home.sh`
- Create: `docs/release/OWNER_SIGNING.md`
- Create: `docs/release/RELEASE_CHECKLIST.md`

**Interfaces:**
- Produces: one blocking check command, one clean-home smoke test, and one owner signing path.
- Consumes: all previous task deliverables.

- [ ] **Step 1: Add failing CI contract checks** that reject `continue-on-error` for Clippy, missing model reconstruction, mismatched appcast URLs, placeholder signing keys, and absent changelog.
- [ ] **Step 2: Fix the current Clippy compile error** and make Clippy blocking.
- [ ] **Step 3: Align the Sparkle feed, release publication path, version, checksums, and changelog.**
- [ ] **Step 4: Add clean-home E2E** for install, initialize, import synthetic history, enable capture in test mode, search, timeline, episode, brief, MCP context, deletion, uninstall, and no residual secret in client config.
- [ ] **Step 5: Run** `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`, every Swift package test, `scripts/check.sh`, and `scripts/e2e-clean-home.sh`.
- [ ] **Step 6: Build the unsigned app and DMG** and verify launch, resources, helper versions, updater feed, and icon.
- [ ] **Step 7: Document the owner-only Xcode login, Developer ID certificate, notary profile, Sparkle key, and GitHub secret names without recording secret values.**
- [ ] **Step 8: Run signing and notarization prerequisite checks; record any credential-only action as owner-required rather than a code failure.**
- [ ] **Step 9: Commit** `release: make Hippocampus reproducible and verifiable`.
