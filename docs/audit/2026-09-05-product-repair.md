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
  New receipt-detail/copy follow-up tests are still running.
- Capture: 20 focused browser, ordinary-app, self-exclusion, and process-lifetime
  tests passed. Self-exclusion failed before the fix and passed after it.
  The broader debug suite passed 624/625: its combined black-grid update timing
  test measured 106,883 ns/call against 100,000 under concurrent native builds.
  Optimized release-profile coverage is running with the same threshold.
- Agent: 367 library tests passed, one ignored; 17 binary tests, 16 context
  tests, 30 MCP tests, and eight data-correctness tests passed. Five Qwen opt-in
  tests passed in the subsequent targeted run.
- Brain: 100 focused storage, source, graph, and identity tests passed.
- Recall FFI: 95 focused tests passed, including old-date filtering,
  acquisition provenance, read-only behavior, and encrypted-blob deletion.
- Onboarding: 20 focused tests passed after correcting async protocol dispatch
  for legacy retention review. Cross-language persistence test is being rerun
  with distinct default and explicit-choice fixture cases.
- Standalone session-hook and static-menu behavior checks passed. Sixteen pure
  installed-production-proof validator tests passed.
- Desktop control successfully read the real synthetic fixture's accessibility
  tree and pixels. Actual installed Recall UI and captured-blob readback remain
  pending; this fixture view alone is not capture proof.
- All six shipping executables built successfully from the repaired source.

No production success is inferred from these tests. The release must still
capture the fixture through the normal installed policy, save encrypted pixels,
show those pixels in Recall, and return the same event through recall/context.
