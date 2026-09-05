# Product Repair: Screen to Usable Memory

Owner request: make the installed Mac product usable, with screen evidence,
search, a visual day, and current agent context. External reviews are leads,
not proof. Source baseline: e7be6f0.

## Independently Observed Baseline

- Installed production bundle matches this checkout, not /Users/amy/mci.
- Latest production drain: 5,169 non-health frames, zero ingested events.
- Production blobs directory is empty. The menu app/helper are not running at
  initial inspection; an orphan ingest process remains.
- A signed bundled allowlist exists (the external audit's empty-list claim is
  wrong). It does not include Codex or TextEdit. Production separately excludes
  browser pixels. AX uncertainty can also suppress otherwise eligible apps.
- The current helper already resolves the Keychain key and writes encrypted
  keyframes. Old missing-key messages do not describe the installed source.
- The local retention file still selects seven days; a purge removed 1,747
  events and 119 episodes. Fresh-install defaults alone cannot repair that.
- Earlier live proof used an isolated corpus with a special allowlist. It did
  not establish useful capture under the owner's actual production settings.

## Execution Order and Acceptance Evidence

1. Repair production admission for ordinary identifiable apps while preserving
   secure-input, secure-field, explicit exclusion, and focus-boundary checks.
   Seed sensitive exclusions. Prove a real ordinary window reaches committed
   screen events and encrypted screenshot files under the installed app.
2. Make capture state reflect committed memory, show suppression/staleness,
   and keep pause/resume and process lifetime reliable. Test relaunch continuity.
3. Repair acquisition provenance and retention review/defaults. Imported history
   must never claim to be screenshots. Preserve existing records and keys.
4. Show real screenshots with source/time/OCR, automatic refresh, date navigation,
   a visual day and honest observed-time totals. Exercise the actual UI.
5. Add supported browser capture only with positive normal-window classification;
   private/unknown cases must explain their exclusion. Add measured idle/active
   signals without keylogging, grounded commitment candidates and agent startup
   context through existing client mechanisms.
6. Run production capture/search/thumbnail/context/pause/restart proofs, review
   failures, fix and repeat. Build and sign the app, install it, and leave its
   usable memory window open. Report remaining limitations precisely.

Progress claims require downstream readback. Helper frame counters, successful
builds, synthetic imports, or notarization alone do not prove capture works.

## Ownership

- Main: capture policy, native live proof, integration, installation.
- capture-status-20260905: menu/supervisor status and Swift retention controls.
- memory-data-20260905: Rust source provenance, committed capture receipts,
  retention semantics, date-range FFI.
- capture-ux-20260905: Recall screenshots, visual day, automatic refresh.

## Additional Runtime Findings

- The old installed menu process grew to about 40 GB physical footprint.
  `/tmp/hippocampus-menubar-20260905.sample.txt` shows SwiftUI menu-label
  updates. The periodic animated icon was removed and native image creation
  bounded by a nine-entry cache. Installed post-repair measurement is pending.
- The orphan agent retained about 4.5 GB total footprint and blocked runtime
  teardown in Qwen/Core ML inference; see
  `/tmp/hippocampus-agent-orphan-20260905.sample.txt`. Daemon teardown now waits
  at most two seconds for blocking work after EOF. Background Qwen NER is off
  unless explicitly enabled, and both automatic brief paths are extractive.
- Rust and the Recall bridge used different minimum macOS versions, causing
  duplicate native dependency builds. `.cargo/config.toml` now supplies the
  same macOS 14 default used by the bridge.

## Verification So Far

- Recall: 53 focused XCTest cases and three context-handoff tests passed.
  The follow-up receipt/day/brief run passed 27 cases.
- Capture: 20 focused browser, ordinary-app, self-exclusion, and process-lifetime
  tests passed. Self-exclusion failed before the fix and passed after it.
  The broader debug suite passed 624/625: its combined black-grid update timing
  test measured 106,883 ns/call against 100,000 under concurrent native builds.
  The optimized release suite passed 625 with the same threshold, then 628
  including the full-window OCR and system-dialog regressions. The expanded
  display-binding run is being finalized.
- Agent: 367 library tests passed, one ignored; 17 binary tests, 16 context
  tests, 30 MCP tests, and eight data-correctness tests passed. Five Qwen opt-in
  tests passed in the subsequent targeted run.
- Brain: 100 focused storage, source, graph, and identity tests passed.
- Recall FFI: 95 focused tests passed, including old-date filtering,
  acquisition provenance, read-only behavior, and encrypted-blob deletion.
- Onboarding: 20 focused tests passed after correcting async protocol dispatch
  for legacy retention review. Cross-language persistence passed with distinct
  default and explicit-choice cases. Fifteen automatic-brief tests passed.
- Standalone session-hook and static-menu behavior checks passed. Sixteen pure
  installed-production-proof validator tests passed.
- Desktop control successfully read the real synthetic fixture's accessibility
  tree and pixels. Actual installed Recall UI and captured-blob readback remain
  pending; this fixture view alone is not capture proof.
- All six shipping executables built successfully from the repaired source.

No production success is inferred from these tests. The release must still
capture the fixture through the normal installed policy, save encrypted pixels,
show those pixels in Recall, and return the same event through recall/context.

## Installed Findings And Follow-Up

- The first repair artifact (`0fe7922`, source digest
  `d8b1e1da11df6856a60dc7acbbdddb3bdb6b5eb089a3cecf4f5f2907d66519f8`)
  passed Apple notarization, stapling, distribution assessment and installed
  provenance verification. The prior app remains at
  `/Applications/Hippocampus Before Capture Repair 2026-09-05.app`.
- Automated fixture clicks did not leave the fixture foreground in the real
  desktop session. A fresh OS app-identity read still identified Recall;
  its denylist receipt was therefore correct. Opening the existing fixture
  through Finder did change real foreground identity. No speculative change
  to the NSWorkspace reader or privacy gate was made.
- The ordinary-window positive test still did not produce the expected token.
  A separately launched diagnostic helper used Codex's responsible-process
  identity and triggered an OS screen-recording prompt. The diagnostic exited;
  the owner was asked to dismiss the prompt. No additional OS access was granted.
  The installed app captured that permission dialog as event 1625, revealing a
  real missing exclusion, not proving useful capture. The next build excludes
  `com.apple.UserNotificationCenter` and `com.apple.SecurityAgent`.
- Code inspection found two independent capture defects. All production filter
  transitions used the multi-window factory, which chose `displays.first` even
  for a focused window elsewhere. Production now uses the existing
  desktop-independent focused-window factory. This supersedes the historical
  focused-only-via-multi-window implementation; co-view capture remains off.
  The full JPEG could also be retained after only dirty-region OCR. Whenever
  visual evidence is eligible, the emitter now scans the entire retained
  surface before the OCR secret gate, including retries. A regression showed
  a secret outside the dirty region previously reached retention; it now
  produces only a privacy tombstone. Text-only OCR retains its bounded ROI.
- Static independent review found no new blocker in these three fixes. It did
  not validate ScreenCaptureKit runtime behavior, real Vision accuracy, or
  multi-monitor/TCC recovery. Installed proof is still required.
- Fresh 36-task benchmark output:
  `docs/eval/agent-handoff-2026-09-05-repair.json`. Both quality gates pass;
  hybrid capability pass rate is 100%, lexical 97.2%, and lexical handoff
  success 75%. Generated/trusted-answer qualification remains false. The first
  rerun's duplicate-OCR metric was zero because the fixture seeder discarded
  acquisition provenance. Only explicit screen locators now assert screen
  origin, independently of app names, question tags and expected answers.
  Seven harness regressions pass; the pinned corpus and thresholds did not change.
