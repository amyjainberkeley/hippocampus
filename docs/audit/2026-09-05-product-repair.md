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

## Production Evidence And Focus Repair

- The second repaired installed app is `17a5fdd`, source digest
  `861bc2d9f6f209d827604c35c9166139ae3528f36d7df1743e482915d59f54e9`.
  Its signed/stapled DMG SHA-256 is
  `52586e95c3815350712ca0c1cc70977272b6bcfd80619d3d3d784da1a8b54ead`.
- Event 1626 at `2026-09-05T10:53:09.008Z` is actual focused-window OCR and
  encrypted pixels from the synthetic corpus, not an import. Native Search
  found it after clearing a persisted GitHub-only filter. The native image
  viewer authenticated and displayed it. Proof screenshot:
  `/tmp/hippocampus-production-image-proof-20260905.jpeg`.
- A normal restart saved event 1627 at `2026-09-05T11:05:59.838Z`. The real
  Codex Hippocampus MCP tool returned the focused token with event 1627 and
  `source_kind=screen_ocr`. The packet abstained on decisions and open loops,
  with `observations_only` and `evidence_verifier_unavailable` truth state.
- The scripted production proof has six positive checks but remains incomplete:
  its bounded negative query hit the recall limit, and it has no authenticated
  screenshot RPC. The native viewer separately proves authenticated pixels.
  No success status or negative-query threshold was weakened to hide this.
- A standalone content-free probe reproduced stale
  `NSWorkspace.shared.frontmostApplication` reads on a background timer, even
  after main-thread initialization. A main-actor probe followed switches.
  Production now queries the AX focused process freshly, checks bundle/PID
  continuity, and fails closed on uncertainty. One serial OS query may remain
  outstanding; each caller waits at most 50 ms and never receives its late value.
  Independent static review found no blocker; live AX/TCC behavior is pending.
- Saved pixels revealed fixed 1920x1080 letterboxing. Capture configuration now
  derives the canvas from the selected window and pixel scale at startup,
  rebind, and recovery, with a 1920-pixel maximum edge and finite-size guards.
  Same-window aspect changes may still letterbox until rebind. The integrated
  release capture suite passed 651 tests with zero failures.
- Recall has a narrower sidebar, useful Sources/Settings layouts, and direct
  links to real capture/privacy/AI-context preferences. Parent launch owns and
  initializes one preferences dependency set before handling these URLs.
  Eighteen focused release workspace tests and 25 parent debug routing tests
  pass; installed routing remains to be verified.
- A real installed Claude hook returned the 149-byte oversized failure envelope.
  Direct retrieval at 600 tokens/four sources returned 2,332 bytes with the
  fixture. The repaired hook uses that budget and one smaller same-focus retry
  within the original deadline. The new regression failed before the change
  and passed after it. Independent static review found no blocker. No owner
  integration settings were changed while the automatic hook was broken.

## Installed Continuity, Agent Delivery, And Browser Capability

- Notarized `bea62b3` captured event 1629 at `2026-09-05T11:32:45.934Z`.
  The native authenticated image viewer displayed the focused fixture without
  the old black canvas margins. Proof:
  `/tmp/hippocampus-focus-repair-image-proof-20260905.jpeg`.
- A contending fresh AX PID reader could return nil immediately while another
  reader ran, creating false unknown-focus generations. `c6d23c0` serializes
  each fresh read within the original 50 ms deadline, with no cached answer.
  Its regression failed before the correction. All 652 optimized capture tests
  passed after correcting an older asynchronous test to await the actual write
  and drain, rather than assuming 100 ms was always enough. Privacy assertions
  remain unchanged. The installed signed validation build subsequently captured
  event 1646 at `2026-09-05T12:05:56.285Z`; real Codex MCP returned its fixture
  text and `screen_ocr` citation. This build is not yet notarized.
- The installed bounded Claude hook returned 2,564 bytes with the fixture,
  canonical event and explicit untrusted-memory warning. Native consent controls
  then enabled the owner's Claude hook and Codex instruction integration.
  An actual Claude Code startup with tools/MCP disabled emitted
  `hook_response`, `SessionStart:startup`, exit code zero, and the fixture.
  The remote API retried six times without a final answer; the bounded test
  terminated only its own process. Delivery is proven, model answering is not.
- Native Sources-to-preferences routing failed when only Recall remained alive:
  Launch Services chose Recall because it shares the parent bundle identity.
  `0bbe819` uses exact executable identity, typed content-free navigation,
  acknowledged pane opening and a parent lifetime lock. Forty-one focused tests
  pass and both release binaries built. Installed warm/cold routing is pending.
- TCC's own log at `2026-09-05T11:56:11.770Z` said Apple Events requires the
  missing Automation entitlement and policy disallows prompting `ai.hippocampus`.
  `ba87cca` adds it only to the parent and actual helper sender, preserving it
  across installer re-signing. The purpose string explains normal/private
  classification and local memory. Four tests pass, including real disposable
  code signatures; no OS access was granted or reset.
- An unanswered Apple Events request previously accumulated expired jobs on a
  serial queue. The behavioral test observed 12 executions instead of two.
  `1e5b288` limits outstanding OS work to one; contending callers include their
  wait in the original deadline and late answers are never reused. All 34
  focused browser tests pass, followed by all 654 optimized capture tests.
  Independent static review found no actionable regression. An already-running
  OS script cannot be cancelled here; it can occupy the single slot until the
  OS returns, while callers continue to time out and deny browser pixels.
  The next signed app must still be tested against real browser consent.

## Native Routing And Preview Readability

- `81e0cb6` passed app and DMG notarization, stapling and Gatekeeper assessment.
  App submission: `4caf6d3d-5c5b-4113-a71a-534e03cdef7f`; DMG submission:
  `bbb5dd43-79f0-4f86-8ea6-4abca82ef386`. DMG SHA-256:
  `6ca2ddff5abf47c15c3d23c25cc13be8aac057925acc4c63ce65654c3ee11c78`.
- Its real cold-parent navigation failed immediately, despite unit tests.
  The router's `Bundle.executableURL` check identified the child as the main
  executable. A new cached-child regression failed and the named auxiliary
  executable lookup made it pass. This behavior is consistent with the
  [CoreFoundation main-bundle initialization](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFBundle_Main.c)
  and [executable-path cache](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFBundle_Executable.c).
  The installed signed validation build `2726eaf` subsequently opened the real
  AI Context pane from Recall with the parent stopped, received acknowledgement,
  and started one parent without a second Recall window. Native pane readback
  showed both client integrations still configured.
- Native Capture Off/On controls were exercised. Off produced a fresh
  `capture_disabled` receipt; resume cleared that reason and restored enabled
  UI state after the supervised restart. This does not prove browser capture.
- The native Today cards revealed internal metadata instead of OCR because
  the bridge truncated text to 80 characters before display could remove the
  longer indexing header. `1e19cb1` strips one complete header before the
  timeline cap; malformed headers remain intact. Search-to-card mapping and
  the fallback timeline reader share that display-body contract, and cards no
  longer strip again. Full detail/search hit snippets keep their existing wire
  semantics. Stored records, index text and citations are untouched.
  Rust regressions failed first; all 109 bridge tests then passed. The Swift
  mapping regression also failed first; 79 focused optimized Recall tests pass.
- Browser qualification is waiting on owner handling of a foreground macOS
  security dialog. The agent cannot operate it. A separate temporary metadata
  diagnostic encountered a Gatekeeper prompt and was terminated; no protection
  was bypassed or permission granted. That diagnostic is not required setup.

## Final Installed Repair Evidence

- Artifact source: `fe285eecb926340750d1f441cb1d74879d85e071`; product digest:
  `07e27a1c7abf88f92d9af58bb617550a994e68054aa9f39a08a39fd5f58c05fa`.
  Product source was frozen during assembly and installer generation. This
  documentation refresh does not change that pinned artifact identity.
- App notarization `5f6bad15-d904-4048-a7de-e6b8f06c4509` and DMG notarization
  `258c0782-e500-48ce-bfff-5ae642639c36` both returned Accepted. Both tickets
  are stapled. Installed provenance, codesign deep/strict, stapler and Gatekeeper
  checks passed. The prior validation app was preserved; the production database
  and Keychain item were not replaced.
- Durable installer:
  `/Users/amy/hippo-work/releases/2026-09-05-fe285ee/Hippocampus-0.1.0.dmg`.
  SHA-256: `b29eaee8058bb5671d17038fb5d2e48c333904212b98281f8ee3fe0361ed74a5`.
  Apple submission receipts are preserved beside it. No public updater release
  or App Store submission was performed.
- The full optimized Recall suite passed 396 XCTest cases plus three context
  handoff tests. Combined with the 654 optimized capture tests, 109 Rust bridge
  tests and targeted signing/hook regressions, this covers the modified paths;
  it is not a claim that every repository lane ran again on this artifact.
- Final installed Today cards display the actual OCR body instead of a chopped
  indexing header. Its authenticated viewer opened stored event 1666 correctly.
  Both cold and warm AI Context navigation received their acknowledgements;
  one parent and one Recall process remained. Capture restarted normally.
- The final artifact then stored event 1679 at `2026-09-05T12:50:07.106Z` from
  the synthetic focused fixture under the owner's ordinary production policy.
  The real Codex MCP connection returned that exact event and marker. The native
  viewer displayed event 1679's authenticated screenshot, OCR, source and time.
  Today refreshed to 55 retained screen records and 15 screenshots. This is a
  downstream positive proof, not an injected event or helper-frame count.
  Image evidence:
  `/Users/amy/hippo-work/releases/2026-09-05-fe285ee/hippocampus-final-fresh-screen-proof-20260905.jpeg`.
- Browser qualification was interrupted by protected OS consent UI; subsequent
  ordinary-app capture resumed. The browser test did not pass, and no consent
  was approved or reset through automation. Do not describe the whole capture
  pipeline as currently blocked solely because that browser gate is pending.
- Shutdown/focus-window transitions still produced logged
  `streamStoppedUnexpectedly` restarts. The supervisor recovered, and the
  committed receipt advanced to 64 screen records and 16 screenshots at
  `2026-09-05T12:52:40.260Z`. This does not qualify uninterrupted capture or a
  final-artifact soak; investigate restart frequency during lifecycle testing.

## Remaining Acceptance Gates

| Priority | Capability | Current truth and next proof |
| --- | --- | --- |
| 1 | Browser coverage | Owner resolves the exact Hippocampus-to-browser Automation prompt; prove normal-page retention and private-window exclusion with distinct synthetic markers. |
| 2 | Permission recovery | Owner-controlled revoke/restore cycle, with no silent data loss and honest native status throughout. |
| 3 | Daily understanding | Current briefs are citation-preserving extracts, not useful semantic summaries yet. Score importance, duplication, contradictions and personal/work separation on held-out days. |
| 4 | Actual active time | Current visual episodes report observed spans. Add measured idle/active signals before presenting time worked. |
| 5 | Commitments | No qualified commitment extraction or automatic closure exists. Require explicit source-bound candidates, corrections and abstention before reminders. |
| 6 | Agent continuity | Codex retrieval and real Claude SessionStart delivery passed. A remote Claude answer did not complete; cross-client ongoing awareness is not universal. |
| 7 | Public distribution | This Mac has a working notarized artifact. Immutable hosted model inputs, second-Mac install/update/Keychain continuity and release qualification remain. |
| 8 | Larger vision | Team context, remote control, multi-device memory and autonomous actions are not shipped by this repair. |

The earlier run optimized component completion without proving the installed
positive loop soon enough. The external review correctly called out that failure,
but its empty-allowlist and missing-key diagnoses were not accurate for the
installed source. Fixes were driven by reproduced failures and downstream
readback, not by accepting the review's proposed implementation wholesale.
