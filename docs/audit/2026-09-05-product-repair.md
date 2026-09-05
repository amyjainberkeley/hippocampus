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
