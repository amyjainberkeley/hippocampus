# SDD ledger — plan: docs/superpowers/plans/2026-09-01-hippocampus-memory-layer.md

Workspace: `/Users/amy/hippo-work/hippocampus/.worktrees/hippocampus-v1`
Branch: `codex/hippocampus-v1`
Spec commit: `feb768a`

## Pre-flight Interface Scan

| Tasks | Shared file/interface | Finding and ruling |
|---|---|---|
| 1 / 6 | `README.md` | Task 1 owns product truth; Task 6 may add only client-connection usage after Task 1. |
| 2 / 6 | `mci_agent.rs`, MCP registration | Task 2 owns key-reference transport; Task 6 consumes it and must not reintroduce raw secrets. |
| 3 / 5 | retrieval report and gates | Task 3 establishes the baseline; Task 5 must preserve or improve it before its implementation is retained. |
| 4 / 7 | `TimelineStripView.swift` | Task 4 owns thumbnail behavior; Task 7 owns layout and styling around the shared `EvidenceThumbnail`. |
| 1 / 8 | release inputs | Task 1 defines clean-clone requirements; Task 8 turns them into blocking CI and E2E gates. |
| 1 | internal consistency | Tests, documentation, and build inputs agree. No conflict. |
| 2 | internal consistency | Keychain and capture changes are independent but both are security gates. Execute in one reviewed task because they share supervisor state. |
| 3 | internal consistency | Synthetic benchmark reuses LongMemEval shape and extends reporting without changing public dataset compatibility. |
| 4 | internal consistency | Condensation happens only after suppression; thumbnail decode is read-only. |
| 5 | internal consistency | Claims are derived and retractable; raw evidence remains canonical. |
| 6 | internal consistency | Context packets are read-only MCP outputs; client configuration remains secret-free. |
| 7 | internal consistency | Native materials are structural; no forced dark appearance or decorative nested glass. |
| 8 | internal consistency | Credential creation remains owner-only; code and prerequisite checks continue without publishing. |

Ruling: The new app icon is an independent user-visible priority and may be implemented alongside Tasks 1-3, but its commit remains part of Task 7 review.

Ruling: Runlog is not a dependency. Only the interfaces named in Task 5 may be adapted locally, because importing the cloud stack violates the product boundary and would not fix Runlog's uncalibrated fusion.

Ruling: Significant product, privacy, retrieval, and visual decisions require three-source triangulation recorded in the spec or task report; mechanical implementation choices follow tests and platform contracts.

## Baseline

- `cargo test --workspace` reached all functional suites but failed three `core/brain/tests/tier2_footprint.rs` wall-clock assertions while four implementation workers and fresh compilation were active.
- Observed: 1,000 filter passes in 9.866 s (9,866 us/call, ceiling 5,000), 60 passes in 476 ms (ceiling 300), 10 passes in 112 ms (ceiling 100).
- Isolated debug rerun on the same host passed all three tests: 1,000 passes in 1.321 s (~1,321 us/call), 60 passes in 79.745 ms, and 10 passes in 13.377 ms.
- Release-profile comparison did not reach the tests because `mci-core` intentionally rejects the `insecure-test-keywrap` feature in release builds. That compile-time CSO guard remains intact; it is not a performance failure and must not be disabled for the benchmark.
- Ruling: the original wall-clock failures were host-contention sensitive rather than a reproduced functional regression. Task 8 still owes a full quiet-host workspace run and must record the release-profile security tripwire separately from performance evidence.

## Review Gates

- Task 1 initial commit failed review: the changelog had no `0.1.0` section for the shipped What's New parser, and the canonical status audit SHA was stale. Repair `f6f2b30` passed independent final review; Task 1 accepted.
- Task 2 initial commit failed review: supervisor compile break, non-transactional live capture toggle, secret in Keychain-write argv, unsafe Keychain error collapse, stale MCP tests/copy, and incomplete child-process key resolution. Repair `a821f65` plus responsiveness follow-up `96496ed` failed R2; `2f602dc` failed R3; and `3e8248a` failed R4 because partial TOML scanning could authorize capture, release copy promised unimplemented deletion/security behavior, lifecycle proof stopped below the composed AppKit boundary, and active seed/docs claims drifted. The focused R4 repair now has 45/45 Rust integration tests, all agent bins, a full agent test compile, eight standalone Swift behavior lanes including real-process `.stopped`/restart/reply composition, both custody/stop scripts, whole-document TOML validation, generated legal drift gates, the Hippocampus and onboarding package builds, and changed-source parsing green. Full XCTest remains a full-Xcode gate. R4 named Task 5 drift in both `chunker_event_wire.rs` and `wire_e2e_fixture.rs`; preserved concurrent Task 5 commits `dd960ad` and `1f2bc12` repair them respectively. Final independent review is still required.
- Task 3 commits `235107e`, `04b9b8c`, `14ee1d0`, `f9a255e`, `240b156`, and `fb07174` passed third-round independent final review. The 24-case benchmark is accepted as reproducible and publishable; hybrid still fails launch qualification with 3/3 false positives (FPR@5 100%), which is now the explicit Task 5 abstention gate.
- Task 7 initial commit failed review: capture status was inferred from historical event count, a static footer presented itself as status, keyframe/event units drifted, a shortcut conflicted, and full-day capture was hard-coded.
- Task 7 repairs `460d610` and `e118100` passed independent final review. The workspace and icon are accepted; unknown capture coverage is modeled explicitly and no live/completeness claim is inferred from stored events.
- Task 7 brand follow-up commits `c44e056`, `d02706b`, and `506276c` passed independent final review in `3735718`. The app and DMG now share the light layered-memory identity, the installer arrow points app-to-Applications, and the build plus a focused shell test enforce canonical icon identity.
- Task 8a commit `8395073` passed independent final review. The fail-closed SwiftPM wrapper is accepted: 25 shell assertions, all three package manifests, signal cleanup, exit-code preservation, and installed-toolchain hash checks passed. Full XCTest and release signing remain Task 8 work and still require full Xcode/signing credentials.
- Task 6 implements deterministic evidence-backed context packets and direct, ownership-safe Claude/Codex registration. Focused Rust tests, reconstructed-command E2E, strict agent Clippy, both affected Swift package builds, and an installed Codex CLI format probe pass. The signed-bundle Keychain smoke remains an explicit Task 8 gate because this host has no valid code-signing identity or full Xcode installation.
