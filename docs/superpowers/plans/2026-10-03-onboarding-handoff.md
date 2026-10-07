# Hippocampus onboarding and handoff implementation plan

> Execute natively with the executing-plans workflow. Owner authorization is the October 3 request to flesh out the standalone memory/MCI product end to end.

**Goal:** Make capture failures visible and give the desktop app an explicit, cited project handoff.

**Architecture:** Keep the local encrypted store, Swift desktop UI and Rust agent. Repair permission-log delivery without changing capture policy. Invoke the existing project handoff compiler with refresh disabled from Recall; a selected project is required, and context is previewed before copying. The compiler may record a content-free local delivery receipt when a writer lease is available. A Git folder resolves to the whole repository and related worktrees; the UI discloses that scope and possible screen observations from the same work session.

**Tech stack:** SwiftUI, SwiftPM/XCTest, Rust, SQLCipher.

**Product boundary:** Hippocampus is memory/recall/MCI. Superapp is the independent OneKit-derived app. No shared branding, releases, data, site or provider configuration. Website/email work is deferred by the owner.

## Design

Native keyboard-first controls, quiet system materials, one primary action per step. Setup must distinguish permission granted, a key available, actual saved evidence and AI connection. A skipped shortcut exercise must not claim the shortcut worked. Project context shows source citations, freshness and uncertainty; it must never imply predictive intelligence from a static mockup. Copy/export is explicit.

## Review focus

- Permission logs appended to an existing file must reach the UI without a directory change.
- Rotation, partial lines, stop/restart and delayed tasks must not deliver stale permission events.
- A fresh service heartbeat with weeks-old evidence must not look like current capture.
- A skipped keyboard exercise is different from observing the chord.
- A project folder with spaces, no evidence, or a failed local agent must produce bounded, recoverable UI; no fallback to unrelated global context.

## Tasks

- [x] Reproduce existing-file permission log delivery in a temporary directory; repair the file watcher and verify lifecycle/rotation.
- [x] Add freshness-aware Recall status and tests; preserve explicit privacy suppression reasons.
- [x] Separate skipped and observed shortcut states; remove premature completion claims from onboarding.
- [x] Add project-scoped command construction and a native handoff preview using the existing compiler with `--no-refresh`; validate paths and failures.
- [x] Run affected Swift suites/builds in an allowlisted environment and inspect synthetic native handoff UI. Keep real memory out of artifacts. Full first-run UI qualification remains separate.
- [ ] Verify permitted live capture, retrieval and handoff separately. Record blockers rather than substituting mock proof.
- [x] Publish verified source checkpoint to canonical GitHub with exact remote SHA; keep signed installation/public release qualification separate. Source `75e5e38b17cbd3ca265c684dcdd6c1cc5d124042` was verified on the remote; draft PR #27 targets the existing public development branch.
