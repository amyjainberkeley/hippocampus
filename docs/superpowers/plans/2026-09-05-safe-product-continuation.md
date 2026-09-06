# Safe Product Continuation Implementation Plan

> For agentic workers: use subagent-driven development for independent slices;
> keep capture runtime integration and installed verification with the main agent.

**Goal:** Continue the owner's approved local screen-memory product, fixing
privacy and reliability before extending usefulness and distributability.

**Architecture:** Keep the signed native Swift app/helper, encrypted Rust brain,
bounded local context compiler and explicit client opt-ins. Derived knowledge
must retain evidence, distinguish observations from inference, and never execute
instructions found in captured content. No always-on remote inference.

**Tech stack:** Swift/AppKit/SwiftUI/ScreenCaptureKit, Rust, SQLCipher, existing
Core ML retrieval artifact; pinned existing dependency ecosystem.

**Spec:** `docs/audit/2026-09-05-product-repair.md`, Remaining Acceptance Gates,
and the owner's follow-up approval to continue all gaps with safety first.

## Global Constraints

- Preserve production memory, user changes, keys, OS permissions and consent.
- No keylogging, protection bypass, unapproved external sharing or autogrants.
- No claim of zero bugs, virus-free software, trusted answers or universal capture.
- Test behavioral failures before fixes; retain failing qualification results.
- macOS 14 remains the deployment floor. Do not introduce new dependencies
  without a justified source/integrity and compatibility review.
- Keep the installed `fe285ee` artifact until an integrated successor passes
  relevant tests, build provenance, signing and native downstream verification.
- No public release or remote upload of memory without the separate release and
  consent gates. Public model inputs and second-Mac proof remain explicit gates.

## 1. Capture Stops And Recovery

Files: `SCStreamCaptureSession.swift`, its lifetime tests, and parent
`ProcessSupervisor.swift` / `ProcessSupervisorTests.swift`.

- [x] Reproduce delayed retired-stream classification without trusting frame counters.
- [x] Restrict generic fatal callbacks to live owned streams; preserve real current-stream
  failure visibility and terminal handling when an intentional OS stop fails.
- [x] Classify ScreenCaptureKit's `SCStreamErrorUserStopped` separately. Helper
  exit code 82 means explicit user stop; 81 remains generic runtime failure.
- [x] Add the parent behavioral regression:
  `topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 82)`
  must persist capture off, quiesce the topology and never schedule capture retry.
- [x] A failed persistence/teardown while disabling capture must not roll back
  to capture-on. Failure remains visible and requires an explicit new enable.
- [x] Run both focused suites, then complete optimized capture and parent suites.
- [ ] Prove normal window switches/closure and restart using synthetic windows
  on the signed app. Explicit OS stop/revoke tests require owner UI action.

## 2. Useful Evidence Briefs

Files: `core/brief/src/extractive_author.rs`, corresponding brief/eval tests,
`apps/agent/src/brief_worker.rs` only when author integration requires it.

- [x] Add behavioral cases for repeated OCR, Finder chrome, useful work facts,
  conflicting statements, malicious instructions and missing evidence.
- [x] Rank and organize source-preserving draft extracts; do not manufacture
  paraphrases, commitments, completion status or time worked.
- [x] Keep citations resolvable, output bounded, and authoring entirely local.
- [x] Run fixed historic and new quality checks separately, reporting both.
- [ ] Inspect the resulting native brief using a synthetic workday.

## 3. Release And Dependency Hygiene

Files: audit workflow, scoped security scripts and a new supply-chain report.

- [x] Run available lockfile advisory checks without uploading private content.
- [x] Audit scanner pinning, stale ignore rules, failure propagation and reports.
- [x] Reproduce and repair silent-green checks with fixture tests; unavailable
  scanners must be reported as unavailable, not clean.
- [x] Report dependency changes separately before applying upgrades. Preserve
  production lockfile compatibility and verify each selected upgrade.
- [ ] Check downloaded-model integrity, package provenance, signed nested
  executables and no credentials in packaged/client configuration.

## 4. Measured Activity

Files: helper context/IPC, Rust IPC/ingestion/store, Recall bridge/day view.

- [ ] Specify a narrow versioned activity-sample contract after reading the
  existing wire/storage boundaries. No schema shortcut through OCR text.
- [x] Use a read-only system idle-duration query, never an event tap or key log.
- [ ] Admit samples only through the same foreground identity/consent/privacy
  boundaries. Unknown or absent readings never imply active work.
- [ ] Bound sampling, retention and storage; do not derive hours from sparse
  screenshots or carry state across sleep, pauses, large gaps or app switches.
- [ ] Prove cross-language decoding, deletion/retention, timestamp limits and
  native active/idle/unknown presentation with deterministic clock fixtures.

## 5. Reviewable Commitments

- [ ] Inspect existing claim/entity/episode stores before selecting a schema.
- [ ] Separate source-quoted candidates from user-confirmed commitments.
- [ ] Test quoted third-party promises, negations, hypothetical text, conflicting
  dates, prompt injection and source deletion before presenting suggestions.
- [ ] Add explicit confirm/dismiss/done controls. No automatic reminders or
  external actions based only on a guessed obligation.
- [ ] Bind every candidate to viewable source evidence; measure false positives
  on held-out synthetic workdays and retain abstention.

## 6. Browser And Permission Qualification

- [ ] Owner handles any exact Hippocampus-to-browser Automation consent prompt.
- [ ] Distinct normal/private synthetic markers verify both retention and
  exclusion; unsupported/ambiguous cases remain visibly withheld.
- [ ] Owner-controlled permission revoke/restore verifies stopped capture and
  subsequent legitimate recovery, with no reset/grant by automation.

## 7. Client Continuity And Sharing Boundary

- [ ] Re-run bounded Claude startup delivery and actual Codex retrieval against
  fresh retained evidence. Do not infer successful model use from hook delivery.
- [ ] Test malformed client config, missing binaries, timeouts and uninstall;
  preserve unrelated settings and never export raw keys.
- [ ] Keep sharing explicitly initiated, source-previewed and bounded. A local
  archive/installer is not permission to upload the owner's memory or release.

## 8. Integrated Release

- [ ] Independent correctness and security review of the complete diff.
- [ ] Run affected suites, full compatibility gates, resource measurements and
  installed screen/search/image/context loop from the exact assembled source.
- [ ] Sign/notarize/staple app and DMG, preserve prior installation, verify
  provenance after copying, and leave the usable native app open.
- [ ] Refresh `docs/STATUS.md` and the owner-facing built/gaps ledger only with
  observed evidence. Second-Mac and public release gates remain unqualified
  until actually exercised.

## Integration Evidence, September 6

Complete optimized suites: capture 674, parent 307, Recall 402 XCTest plus three
Swift Testing handoff tests passed. Brief generation has 17 agent integration
tests; the unchanged eight-day corpus and the new ten-case extractive corpus
pass. The latter improved from 2/10 on the baseline to 10/10 on its finite
source-containment/noise/formatting checks. It does not establish semantic truth.
Oversized-input regressions also bound escaped brief bodies to 16 KB without
truncating evidence sentences. Strict Clippy passed for brief/eval targets.

The first broad debug Rust run stopped at two existing tier2 footprint timing
checks while native compilers were running. It is retained as a failure, not
counted as a complete passing workspace run; quiet/optimized recheck is pending.

The activity reader currently drives bounded quiet-input sampling only. It
admits first/new-window samples and resumes ordinary cadence on input; it does
not discard passive reading/meetings or persist measured work time. Phase 4's
wire/store/UI contract is still unbuilt.

The source-link native UI parses only the versioned extractive format, treats
captured markup as inert text and opens the existing authenticated source
viewer. Empty/overflow/malformed citations have regression coverage. Live
installed proof is pending this integration's signed successor.

Subagent review was unavailable due to account limits. Main-agent inspection
and tests are not an independent security review. A capture-off persistence
failure is visibly latched for the running parent, but cannot guarantee that
intent survives a future relaunch if the disk write itself failed.
