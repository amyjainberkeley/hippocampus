# OCR, Summary Export, and Self-Service Plan

> **For agentic workers:** Use superpowers:executing-plans to carry each task through its test and review gate.

**Goal:** Improve literal screen-text fidelity, export a reviewable day with sources, and prepare a truthful self-service website without weakening public-release gates.

**Architecture:** Keep Apple Vision on its existing bounded on-device lane. Reuse BriefPresentation for strict source-marker parsing and move explicit exports into VisualMemoryExport. Keep the informational website separate from private memory and point future downloads at the existing verified release pipeline.

**Tech Stack:** Swift, Apple Vision, XCTest, SwiftUI, Vinext/React, Sites hosting.

**Spec:** Amy's September 6 request: better OCR, whole summaries, premium download website, self-service onboarding, local/private evidence, and honest remaining gaps. Existing product boundary remains in docs/STATUS.md.

## Constraints
- No remote inference, memory upload, automatic permission grants, silent gate bypass, or invented verified claims.
- Preserve existing screenshots and key custody; never replace uncertain OCR with generated facts.
- Site owner alone changes /Users/amy/hippocampus-website and manages its publication.
- Existing unowned task report and scripts/__pycache__ are outside scope.

## Execution
- [x] Render synthetic code/prose in memory at 12/16/24 pt; run corrected/raw accurate and fast baselines. Regression reproduces inserted spaces.
- [x] Disable OCR language correction; use recognized candidate confidence. Keep privacy ROI checks and deadline lane untouched.
- [x] Add bounded day/brief exports preserving date, Draft status, author, observations warning, and parsed local event links. Escape captured Markdown and cap payload size.
- [x] Guard day exports by selected day, loaded generation, explicit event IDs, cancellation, and available evidence. Support a saved brief with no screenshot.
- [x] Keep required permission denials reachable; synchronize Settings grant/revoke outcomes; gate preparation and completion on actual key readiness.
- [x] Correct updater defaults without resetting the user's stored opt-in. Run contract regression and parent suite.
- [x] Create a light product website, setup guide, privacy overview, and honest release-status page. Use only synthetic screenshot evidence. No signups, analytics, payment claims, or memory API.
- [x] Validate and publish the website privately for owner review. Public audience change requires approval; a public installer remains blocked by independent-Mac qualification and distribution/legal packaging.
- [x] Run affected native suites, inspect source diff, then build/sign/notarize an owner candidate. Preserve the currently installed notarized build until replacement is verified.
- [x] Update STATUS and the owner ledger with actual evidence, separate source-tested from installed proof, and keep remaining vision visible.
- [ ] Obtain fresh installed capture -> encrypted screenshot -> actual MCP proof on 224466d. Owner foreground-fixture confirmation is pending; no privacy bypass.
- [ ] Qualify the installed whole-day export beyond source tests and visible native controls. Do not expose private day content in website proof.

## Reproduction
Native test commands run from each Swift package:
```sh
swift test -c release -j 2 --filter VisionOCRQualityTests
swift test -c release -j 2 --filter 'SummaryExportTests|DailyMemory'
swift test -c release -j 2 --filter 'PreparationGateTests|PrepareBrainViewModelTests|PermissionRecoveryTests|PermissionsSlideChoreographyTests'
swift test -c release -j 2 --filter UpdaterPreferenceContractTests
```
Website: `npm install`, `npm audit`, `npm run build`, then package and privately deploy the exact validated source through Sites. Build cache is isolated at /tmp/hippocampus-site-npm-cache because the user's shared npm cache contains inaccessible entries.

## Still Outside This Proof
Semantic summarization quality, commitments, measured active time, browser-private-window qualification, OS permission revoke/restore, overnight reliability, second-Mac installation/update/Keychain continuity, final legal-owner review, and public release provisioning.
