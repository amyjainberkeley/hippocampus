# Work Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver demonstrably useful, inspectable local work memory with distinct native views, relevant retrieval, scoped learning, and qualified capture.

**Architecture:** Preserve the encrypted evidence store and native Swift applications. Repair acquisition and retrieval before deriving additional understanding. Reuse canonical evidence and claim identities for summaries, corrections, and agent delivery; measure activity independently of image frequency.

**Tech Stack:** Swift/AppKit/SwiftUI, ScreenCaptureKit, Vision, Rust, SQLCipher, local MCP.

**Spec:** `docs/research/2026-09-08-local-memory-product-plan.md`; acceptance authority `docs/audits/2026-09-07-observable-gates.md` and `docs/STATUS.md`.

## Global Constraints

- User approved implementation on September 9. The optional corner companion is deferred.
- Preserve personal memory, keys, permissions, policy, and unrelated edits.
- No private capture content, secrets, environment values, or diagnostic dumps in GitHub.
- Tests run with a constructed environment, not inherited provider credentials.
- Never weaken admission, deadlines, redaction, or source attribution to pass a test.
- No time totals inferred from screenshot counts or gaps between screenshots.
- No external provider inference or account configuration without the existing explicit boundary.
- Main owns integration, commits, installation, and source publication. Workers do not commit or touch shared status docs.
- Fresh capture, authenticated image, restart readback, privacy/recovery, and real-client delivery remain independent gates.

## Task 1: Capture Qualification And Recovery

**Ownership:** Main. Capture helper, parent supervision, live-proof scripts, installation and receipts.

**Files:** Inspect `scripts/live-capture/ScreenProofWindow.swift`, `ScreenProofExposure.swift`, `ScreenProofReceipt.swift`, `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SCStreamCaptureSession.swift`, and the parent health/supervision types. Production edits require a reproduced cause and a failing regression; do not select a speculative fix in advance.

**Interfaces:** Preserve the helper wire protocol and installed encrypted brain. Proof exposes only phrase hash and numeric foreground identity until actual recorder retrieval supplies the phrase.

- [x] Match source, installed provenance, process topology, current capture health, and store identity.
- [x] Run the existing screen-only fixture using the approved native UI tool, without copying or logging its phrase. Both attempts remained inactive; no phrase was generated and the proof did not pass.
- [ ] Require new screen-origin evidence, matching authenticated screenshot, restart readback, and a fresh client read.
- [ ] If absent, trace the failing acquisition boundary with content-free diagnostics. Write a failing regression for the demonstrated condition, then make the narrow correction.
- [x] Run focused regression and complete affected package tests with an allowlisted environment. The final optimized helper suite passes 817 cases twice; the live proof is still open.

The controlled static-screen regression exposed immediate retry exhaustion while
Vision was still quarantined. A bounded availability wait repairs that path;
the real-foreground capture proof remains separate from this fixture result.

Headless proof regression:

```sh
env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" bash scripts/live-capture/test-screen-proof.sh
```

## Task 2: Query-Centered Search Evidence

**Ownership:** Search worker. Only `adapters/macos/mci-brain-ffi/src/lib.rs`, a private sibling helper if needed, and its scoped tests.

**Interfaces:** Preserve serialized Hit fields and public FFI signatures. Lexical results must show the matching body text, not a transcript prefix. Recent-history formatting must remain unchanged. Relevant metadata-only matches must not fabricate a body match.

- [x] Add a failing regression where a search term occurs beyond the initial excerpt and verify the current prefix behavior fails it.
- [x] Cover Unicode boundaries, context headers, multiple words, empty queries, punctuation, and title-only matches.
- [x] Implement bounded query-centered excerpts using existing FTS tokenization/sanitization semantics where available.
- [x] Run FFI tests and formatting, checking unchanged search ordering and identity.
- [x] Return exact changes, red/green output, and any unsupported matching modes for integration review.

Behavioral contract:

```text
body = 600 characters of unrelated text + "needle launch decision"
lexical result for "needle" includes "needle launch decision"
recent result preserves current recent-history formatting
result identity, source kind, and image link remain unchanged
```

## Task 3: Distinct Native Views And Evidence-Led Review

**Ownership:** UI worker. `apps/recall-ui/Sources` and `apps/recall-ui/Tests` only. No Rust, helper, or parent edits.

**Interfaces:** Existing BrainReader, DailyMemoryViewModel and DailyReview. Any proposed activity interface must first be coordinated with main; do not fabricate activity records or ship an unconnected chart.

- [x] Add tests for Today/Search/History navigation and a blank-query search that does not replay history.
- [x] Collapse Sessions into History and make brief/handoff an action of Today; retain legacy navigation compatibility.
- [x] Improve result and evidence presentation while preserving native controls, accessibility, and visible keyboard focus.
- [x] Add useful, grounded work-review organization from actually available evidence; do not label lexical observations as semantic conclusions or task completions.
- [x] Keep future interval summaries separate until a real data source is connected. Support unknown and unavailable states explicitly.
- [x] Run targeted and complete Recall tests. Provide synthetic preview/test entry points for main's visual qualification.

Required outcomes:

```text
Search + blank query => search entry, not a second timeline
History => chronological evidence and nested sessions
Today => interpretation/resume/handoff; not a duplicate evidence feed
Selecting any assertion => its canonical evidence
```

## Task 4: Scoped Learning And Sequential Evaluation

**Ownership:** Learning worker. `core/brain/src/memory_delta.rs`, `memory_projector.rs`, related claim tests, and new evaluation files under `eval/` or the existing evaluation crate. Coordinate any store schema/module export changes before editing.

**Interfaces:** Existing MemoryClaim, ClaimTransition, MemoryDelta, and SqlCipherBrainStore projection APIs. Preserve source verification and authority distinctions. No UI/FFI/client changes without coordination.

- [x] Establish which explicit correction, supersession, and as-of scope behavior already exists; do not duplicate it.
- [x] Write failing tests for a concrete missing correction/expiry/isolation behavior, then repair it without broadening trust.
- [x] Build an isolated, versioned sequential fixture with stale-state, cross-project, malicious-instruction, and deletion cases.
- [x] Compare stateless, simple-context, and governed-memory policies with equivalent inputs. Label deterministic policy tests as such; do not claim real-agent learning from them.
- [ ] Define and exercise a real-client evaluation boundary when locally available without sending personal data or using provider credentials from the test environment.
- [x] Report absolute success, harmful reuse, and cost/call information separately; retain failures.

The client protocol has subprocess-fixture coverage, not a completed real-client
experiment. Its actual-client checkbox remains open.

Sequential contract:

```text
project A confirmed correction => later A task uses the correction
project B task => A correction never widens into B
A rule superseded => new task uses new state; historical query retains old state
deleted evidence => no dependent claim or packet remains admissible
```

## Task 5: Measured Activity And Integration

**Ownership:** Main after capture diagnosis; coordinate explicit interfaces with UI worker before shared changes.

**Files:** Existing `UserActivityReader.swift`, `CaptureActivitySchedule.swift`, helper wire, brain ingestion/store, FFI/BrainReader, and DailyReview integration as required by the established data path.

- [x] Trace existing active/idle signals and choose the smallest durable interval representation in the encrypted store.
- [x] Specify before writing production code how foreground transition, lock, pause, permission loss, clock discontinuity, and crash close or invalidate intervals.
- [x] Add tests that reconcile overlapping intervals, retain unknown time, and prevent excluded app metadata from leaking.
- [x] Wire actual capture signals through storage to Today and test round trips, retention/deletion, and restart behavior. This is source and injected-fixture coverage, not a measured live day.
- [x] Add measured distribution and drill-down only after the round trip is proven.
- [ ] Verify useful review and handoff with the same retained evidence; never infer task completion from focus.

## Task 6: Review, Installation, And Observable Closeout

- [x] Review each worker's diff for specification compliance and quality; resolve findings with focused regressions.
- [x] Run affected full suites, regression contracts, formatting, static checks, and the synthetic evaluation with sanitized environments. Final local results pass; historical OCR failures and unmet live/distribution gates remain explicit.
- [x] Exercise native synthetic navigation, interval drill-down and the handoff sheet; inspect the compact layout. This preview does not establish active keyboard focus or live screenshot readback.
- [ ] Complete actual source-image, keyboard, empty/error-state and responsiveness qualification on the installed candidate.
- [x] Build the exact `fb73f77` release-profile owner candidate. Verify nested identities, notarization, stapled tickets, Gatekeeper, startup/onboarding and mounted-DMG provenance.
- [ ] Obtain verified shutdown, preserve a consistent encrypted pre-upgrade recovery copy, then install the verified candidate. The old app alone is not a schema-safe rollback.
- [ ] Repeat live gates on the installed revision. External second-Mac evidence remains unqualified until actually observed.
- [x] Publish reviewed source `fb73f77` to the canonical branch and existing draft PR25; update the PR with features, tests and remaining gates.
- [x] Record exact candidate, installed, website and public-release states. The new hosted OCR failure remains explicit and unwaived.

## Integration Review

| Tasks | Shared boundary | Resolution |
| --- | --- | --- |
| 1 / 5 | Capture helper and wire | Main owns both; activity additions follow acquisition diagnosis |
| 2 / 3 | Hit JSON | No public schema change needed for centered excerpts |
| 2 / 5 | FFI | Search worker finishes or coordinates before activity FFI changes |
| 3 / 5 | BrainReader and DailyReview | Main sends exact interval contract before wiring; no placeholder chart |
| 4 / 5 | Brain store | Learning worker must coordinate schema changes; independent tests preferred |
| 1-6 | Tests and publication | Isolated test outputs; only main changes STATUS or Git history |

This plan is a dependency map, not evidence of completion. Every unchecked task remains open until its corresponding behavior and verification are recorded.
