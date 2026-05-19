# tools/ — read-only observation harness

Non-protected-set (AGENT_PROTOCOL §5) helpers. They parse/observe; they
change no `core/**` or `adapters/macos/**` capture/crypto/sync code, so
this directory carries **no CSO gate**. The *runtime results* they
produce feed the ADR-0013 §7 / Amendment-1 gate decisions, so the
durable artifact is the committed audit note, not these scripts.

## Track B · Step 1 — live SCStream runtime verification

Verifies the merged `// UNVERIFIED` shapes on a real screen:

- **PR-1** — live `SCShareableContent`/`SCStream`/`startCapture`, the
  `SCStreamOutput` callback, `extractSynchronously` (CMSampleBuffer
  attachments, pixel-buffer lock, 9×8 luma → dHash).
- **PR-2** — `CVPixelBufferRetainedSurface` retain → `SurfaceLease`
  release on every frame, **no IOSurface pool-stall over the run**.

It does **not** verify PR-3 (`VideoToolboxHEVCEncoder`'s live
`VTCompressionSession` — `main.swift` uses the no-op
`DeferredVideoToolboxEncoder`; wiring the real one is a CSO-gated
default flip behind the green §7 corpus). It is **not** the ADR-0013 §7
secure-surface corpus and **not** the G2 footprint proof.

### Predicted observable

Empty denylist + no Phase-2 context join ⇒ `appBundleId == nil` ⇒
cascade fail-closes ⇒ a steady stream of **PrivacyTombstone** frames,
`reason = 7 (failsafe-unknown)`, `appBundle = ""`, contiguous `seq`,
and **zero** `StateTransitionEvent (0x0010)`.

### Runbook (you run; ~30 min mixed, with early-abort)

1. **Rebuild:**
   ```
   cd adapters/macos/MCICaptureHelper && swift build
   ```
2. **Grant Screen Recording to Terminal.app.** First `--capture` run
   triggers the TCC prompt, or silently yields no content. System
   Settings → Privacy & Security → **Screen & System Audio Recording**
   → enable **Terminal** → **fully quit & relaunch Terminal** (TCC is
   re-evaluated at process start). macOS 26 Tahoe re-prompts
   periodically — just re-grant.
3. *(Optional, for Step 2)* Also grant **Terminal → Accessibility** now
   (Step 1's fail-safe path makes the AX answer moot; the §7 corpus
   needs it). Skipping it does not affect Step 1.
4. **Run** (terminal A), then start the footprint pre-read (terminal B):
   ```
   # A
   .build/debug/mci-capture-helper --capture --output /tmp/mci-step1.bin --heartbeat-seconds 5
   # B
   tools/step1_footprint_preread.sh
   ```
   Do normal mixed work for ~30 min: switch apps, type, scroll, open
   windows, lock/unlock. Ctrl-C both when done.
5. **EARLY-ABORT (first ~1–2 min):** if the helper prints
   `live capture start failed …` repeatedly, or crashes, or
   `/tmp/mci-step1.bin` stays empty, or it stalls immediately — STOP,
   fix the wiring, restart the 30-min clock. Do not burn 30 min on
   broken wiring.
6. **Decode:**
   ```
   python3 tools/wire_decode.py /tmp/mci-step1.bin
   ```

### How to read it (mechanical, not vibes)

`wire_decode.py` prints a **STEP-1 SHAPE VERDICT**:

- **zero `0x0010`** — no pixels/event ever crossed IPC.
- **all tombstone `reason == 7`** — fail-closed on real pixels.
- **contiguous tombstone `seq`, no gaps** — a gap means a `seq` was
  allocated with no frame written = an `.allow` decision happened.
  Fail-safe predicts **zero**; any gap is a loud red flag.

Interpretation nuances (documented so you don't misread):

- **`SmartCaptureFilter` drops idle/duplicate frames *before* the
  cascade** — those produce no tombstone and no `seq`. A quiet/static
  screen legitimately yields few tombstones; that's the footprint
  filter working, **not** a stall. Judge "no stall" during the
  **active** periods (typing/app-switching) — tombstones should flow
  then, and `seq` should keep climbing.
- **A true PR-2 IOSurface pool-stall** manifests as the tombstone
  stream **halting during active use** after ~`queueDepth` frames and
  never resuming — distinct from the filter quietly idling.
- **`HelperHealth` frames report `framesDelivered=0/framesSuppressed=0`
  in this build** — the `--capture` pipeline has its own separate
  counters that are never emitted. Ignore HelperHealth counters as a
  capture-activity signal; the tombstone stream is ground truth.

### Record it

Fill `docs/audit/2026-05-19-step1-live-scstream.md` with the decoder
output, the footprint pre-read summary, stderr, and your sign-off. That
note is the durable artifact — explicitly a **soft pre-read**, not the
§7 corpus and not G2.
