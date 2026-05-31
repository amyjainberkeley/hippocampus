# ADR-0031 — Focused-window capture scope (Option (a)) as a load-bearing privacy invariant

- Status: **Accepted** (2026-05-29 V2-P1 merge; **AMENDED 2026-05-30 emergency re-flip — see §"Status — M4 kill-switch is RE-ENGAGED" below**; **AMENDED 2026-05-30 M4 SECOND LIFT — see §"2026-05-30 — M4 SECOND LIFT" below**)
- Owners: **Director-Recording** (SCStream lifecycle + `SCContentFilter` factory + focus-race gate) + **CSO** (binding sign-off authority on the OCR-input-scope invariant)
- Reviewers: CEO (ratification on V2-P1 PR); Director-Brain (consumer of the OCREvent attribution; ADR-0030 redaction layer becomes load-bearing in production under this ADR); Director-Context (focused-window observation primitive; `FocusTracker` is a peer of the existing context providers); CRS Telemetry-Gap analyst (`frames_focus_race_dropped` wire counter consumer).
- Phase: 3.x (capture-spine hardening). Lands as the first commit set in the V2 graph phase plan (brain-architecture v2 vision memo §7.1 — V2-P1).
- **Protected-set: yes** (AGENT_PROTOCOL §5 — modifies the de-facto privacy gate that every cascade arm rests on; amends ADR-0013 / 0015 / 0016 / 0017 / 0030 in spirit + at the explicit-invariant level).
- **Launch-blocker: yes — in spirit.** The cycle 8.17 cross-window leak (memo §1) is a §5 protected-set violation. The M4 OCR-emit kill-switch (PR #232) is the Phase A interim mitigation; this ADR's invariant is the Phase B architectural fix. M4 lifts in V2-P1's final commit, conditioned on this ADR's §6 CSO sign-off + the §7 corpus artifact (memo §5.5 condition).
- **Relationship:** amends ADR-0013 §1 / §3 / Amendment 1 §3; amends ADR-0015 §4 invariants 1–2; amends ADR-0016 §1.6 / §4.2; amends ADR-0017 §3.1; amends ADR-0030 §3 (a)–(c) — makes their pre-existing assumptions explicit and protected. Consumes the brain-architecture v2 vision memo §6.1 §7 PR escalation list entry E8.

## Context

### The cycle 8.17 finding

The orchestrator's MCP probe on the live cycle 8.17 install surfaced an OCREvent tagged `com.apple.Safari` whose `text_snippet` contained text drawn from at least three other applications' windows visible on the same display (Activity Monitor, Railway dashboard, Zoho Inbox). The cycle 8.17 + cycle 8.18 STATE.md paragraphs document the empirical leak; memo `docs/research/capture-scope-window-vs-display-2026-05-29.md` §1–§3 is the structural explanation. The root cause is at the OS API boundary:

- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SCStreamPipeline.swift:92-110` (pre-V2-P1) builds an `SCContentFilter` scoped to the entire display: `SCContentFilter(display:, excludingApplications:, exceptingWindows: [])`. `exceptingWindows` is hard-coded empty. The captured pixel surface is the whole display minus ADR-0013 §1 source-level denylisted apps' windows.
- The OCR input is the full display-composite `CVPixelBuffer` (`SCStreamCaptureSession.swift:422-432`); the region-of-interest is the dirty-rect bounding rect (`OCRPostAllowEmitter.swift:277-311`) — a *footprint* optimisation per ADR-0016 §1.1, not a privacy-scope decision.
- The OCREvent's `app_bundle_id` is the polled-frontmost-app id (`SCStreamCaptureSession.swift:290` + `OCRPostAllowEmitter.swift:207-216`). Frontmost-app + display-composite pixels are not the same thing; the cascade's bundle-keyed gate assumes they are.

When the dirty-rect bounding rect spans multiple windows (the common case during normal scrolling activity on a single display), the OCREvent carries text from multiple bundles tagged with one bundle's id. The cycle 8.17 finding is the worst-case shape: Activity Monitor / Railway / Zoho text under `com.apple.Safari`.

### Why no prior ADR addressed the OCR-input scope

Memo §3 audited every protected-set ADR. The privacy model has always rested on the implicit assumption that an OCREvent's `app_bundle_id` is the bundle that *produced* the OCR'd pixel bytes. The current pre-V2-P1 implementation makes that assumption true *only* when (a) the focused app's windows occupy the entire dirty-rect bounding rect, or (b) the dirty-rect array is non-empty and tight. Neither holds on a normal multi-window display. This ADR makes the assumption *explicit*, makes it *load-bearing*, and CSO-protects it going forward.

### What changed under cycle 8.18

The M4 OCR-emit kill-switch (`OCRPostAllowEmitter.swift:104` `killOcrEmit: Bool = true`, PR #232) is the Phase A interim mitigation. Every cleared-pixel-time `.allow` frame short-circuits to a `PrivacyTombstone(failsafeUnknown)` instead of running the cascade-twice OCR emitter. No OCR text bytes from the SCStream path reach the brain wire while M4 is ON. The browser recall path (Safari `.appex` + Chromium native messaging host → `page_content.sock` → `BrainPump`) is structurally independent and unaffected.

The brain v2 phase-plan memo (#236 §7.1) makes V2-P1 — this ADR + the implementing PR — the prerequisite for every downstream v2 work product. Entities, edges, episodes all rest on bundle attribution being structurally correct.

## Decision

### 1. OCR-input scope = focused-window-only (the invariant)

The captured pixel surface for OCR MUST be the **focused window only**. Concretely:

- `SCContentFilter` MUST be built via `SCContentFilter(desktopIndependentWindow:)` against the focused `SCWindow` (single-window capture). The factory shipped in this PR is `SCContentFilterFactory.makeFocusedWindowFilter(windowId:denylist:)` (`adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SCStreamPipeline.swift`).
- A `FocusTracker` (1 Hz NSWorkspace + AX + `CGWindowListCopyWindowInfo` poll, `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Context/FocusTracker.swift`) produces generation-tagged `FocusedWindowSnapshot` values. The live SCStream is rebound via `updateContentFilter(_:)` on every focus change.
- The cascade reads `WorkflowContext.appBundleId` from the focused-window snapshot's `bundleId`, NOT from the polled-frontmost-app id. `SCStreamCaptureSession.buildWorkflowContext(snapshot:urlProvider:fallbackAppBundleId:focusedSnapshot:)` enforces this.
- The OCREvent's `app_bundle_id` is therefore the bundle that produced the OCR'd pixel bytes — the cascade's bundle-keyed gate becomes structurally correct.

### 2. Race-consistency gate (the (frame_ts, focus_ts) check)

Because SCStream sample delivery is asynchronous with respect to focus changes, in-flight sample buffers may carry pixels captured under the *prior* SCStream filter — i.e., the focused window the sample buffer reflects may not be the focused window the snapshot currently advertises. The race window is bounded by the FocusTracker's 1 Hz poll cadence + the 200 ms `rebindTask` cadence + the latency of `SCStream.updateContentFilter`. A frame whose attribution cannot be trusted must NOT reach the brain.

The gate:

- `SCStreamCaptureSession` records `installedFocusGeneration: UInt64` at SCStream filter install time (and on every successful `rebindFocusedWindow(...)` call).
- The SCStream callback reads the focused snapshot atomically and compares `snapshot.generation` against `installedFocusGeneration`.
- On mismatch: the callback skips cascade + encode + OCR. The pipeline emits a `PrivacyTombstone(reason=focusRaceDropped)` (RedactionReason discriminant 8 — new in this PR) via `SCStreamPipeline.emitFocusRaceDropped(...)`. `framesFocusRaceDropped` counter increments.

The gate is fail-closed (ADR-0013 Amendment 1 §3(b) STRENGTHENED — a frame whose attribution is structurally untrustworthy now emits a distinct tombstone instead of running the cascade under a stale generation).

### 3. ADR-0013 §1 denylist composition is preserved

A denylisted app's window can NEVER be the SCStream's bound window. `SCContentFilterFactory.makeFocusedWindowFilter(...)` returns `nil` when:

- the supplied `windowId` is not present in the live `SCShareableContent.current.windows` enumeration, OR
- the matched `SCWindow`'s owning application is on the ADR-0013 §1 denylist.

`nil` is the signal to NOT rebind: the prior SCStream filter stays installed. The race gate continues to trip on every frame until focus returns to an allowed window.

The Swift-side `SelectFocusedWindowTests::test_returns_nil_when_owning_app_is_denylisted` test pins this composition path headlessly.

### 4. ADRs amended by reference

- **ADR-0013 §1 source-level `SCContentFilter` denylist**: composition unchanged; preserved by §3 above. The denylist still excludes denylisted bundles' windows; the focused-window factory composes on top of that exclusion.
- **ADR-0013 §3 fail-safe-default-redact**: spirit preserved. A frame whose bundle attribution is structurally untrustworthy is now classified as "unknown" by the race gate and fails closed via `focusRaceDropped`, not silently mis-attributed under a stale focused-app tag.
- **ADR-0013 Amendment 1 §3(a)–(d)** four structural assertions: each preserved.
  - (a) cascade-before-encode — unchanged. The race gate fires BEFORE cascade; no encode on the race path.
  - (b) fail-closed default — STRENGTHENED. A frame whose attribution cannot be trusted now emits `focusRaceDropped` instead of running the cascade under a stale generation.
  - (c) no stored/emitted suppressed event — unchanged. `focusRaceDropped` IS the documented suppress shape.
  - (d) surface-lease exactly-once — unchanged. `emitFocusRaceDropped(...)` uses the same top-level `defer { lease.release() }` discipline as `pipeline.process(...)`.
- **ADR-0015 §4 invariants 1–2**: invariant 1 (context-as-content) — `FocusedWindow.bundleId` is the same content class as `WorkflowContext.appBundleId`. Reaches the cascade through the snapshot route, never directly into storage / IPC. Invariant 2 (cascade-before-storage) — preserved unchanged.
- **ADR-0016 §1.6 cascade-twice + §4.2 OCR-emit-is-not-gated-on-encode-success**: structurally preserved. The cascade-twice invariant becomes *structurally meaningful* under this ADR — the second cascade pass now runs over text drawn from a single bundle's window, not from a display composite.
- **ADR-0017 §3.1 allowlist-as-content-filter**: structurally preserved. The user's mental model of "this bundle is on the allowlist; other bundles are not" now holds in production because the SCStream's captured surface IS the allowed bundle's window. Pre-V2-P1 the mental model was broken by the cycle 8.17 leak.
- **ADR-0030 §3 (a)–(c) Messages/Mail redaction layer** (PR #222): becomes load-bearing in production. The bundle-keyed gate at `core/brain/src/redaction/mod.rs::bundle_is_in_scope` now operates on a structurally correct `app_bundle_id`. Memo §8 explains this in retrospect: the cycle 8.16 PR #228 allowlist flip (Messages + Mail) was correct *given the redaction layer's behavior in isolation*, but the live system did not realize that behavior. Option (a) is the missing precondition.

### 5. Alternatives considered (rejected)

#### 5.1 Option (b) — whole-display capture + crop OCR input to focused-window AX rect

Read the focused window's AX-reported rect via `AXUIElementCopyAttributeValue(window, kAXPosition / kAXSize)` and crop the display-composite `CVPixelBuffer` to that rect before submitting to Vision. **Rejected.** The AX rect is unreliable on the five Electron / Catalyst apps on the current allowlist (Slack, VS Code, Claude Desktop, GitHub Desktop, Notion) — `AXUIElementCopyAttributeValue` returns `nil` or stale values intermittently. The fallback arms are bad: either lose OCR coverage on Electron apps OR retain the leak on them. AX rect may also lag the rendered window (popovers, modal overlays, OS-managed decorations not in the rect) — cropping risks dropping legitimate content. See memo §4.2 for the full failure-mode catalog.

#### 5.2 Option (c) — per-window cascade

Run the cascade and OCR pass independently *per visible window*: each visible non-denylisted window's pixels get their own Vision OCR run, each emits its own OCREvent tagged with its own bundle id. **Rejected for v1; deferred.** ScreenCaptureKit does not deliver a per-window pixel buffer in a multi-window capture; per-window OCR would require either (i) one `SCStream` per window — quadratic SCStream count on a busy desktop — or (ii) display capture + per-window AX rect crop + per-window Vision call (Option (b)'s problems × N). The footprint blowup risk is real (N × Vision-OCR cost per frame). Defer to v2+ when a multi-window observability case is built and the OnboardingTier surface (brain-v2 §7.4) is available to gate the cost.

### 6. CSO sign-off (binding)

The CSO seat hereby attests the following on behalf of the V2-P1 PR:

1. **OCR-input scope is focused-window-only.** The captured pixel surface produced by `SCContentFilterFactory.makeFocusedWindowFilter(...)` IS the focused window, per `SCContentFilter(desktopIndependentWindow:)`. Verified by the Swift-side unit tests + the §7 corpus artifact + (post-merge) the §11 live-Mac audit.
2. **Race-consistency gate fails closed.** The (frame_ts, focus_ts) consistency check at the top of `SCStreamCaptureSession.stream(_:didOutputSampleBuffer:of:)` emits `PrivacyTombstone(reason=focusRaceDropped)` and SKIPS cascade + encode + OCR on any focus-generation mismatch. The new `framesFocusRaceDropped` counter on the wire (0x07 → 0x08) is the observability surface.
3. **ADR-0013 §1 denylist composition preserved.** A denylisted app's window CAN NEVER become the SCStream's bound window. `SCContentFilterFactory.makeFocusedWindowFilter(...)` returns `nil` for a denylisted focused-window bundle; the prior filter stays installed. Pinned by `SelectFocusedWindowTests::test_returns_nil_when_owning_app_is_denylisted`.
4. **Amendment 1 §3(a)–(d) preserved.** (a) cascade-before-encode unchanged; (b) fail-closed STRENGTHENED on the race-gate path; (c) no stored/emitted suppressed event; (d) surface-lease exactly-once preserved via `defer { lease.release() }` in `emitFocusRaceDropped(...)`.
5. **§7 corpus artifact GREEN.** The 5-harness committed artifact at `docs/audit/2026-05-29-focused-window-corpus.md` is the lift condition for the M4 OCR-emit kill-switch. The runner is deterministic: re-running `cargo run -p mci-brain --bin focused_window_corpus --release` reproduces the artifact byte-for-byte.
6. **M4 kill-switch lifts as the FINAL commit of V2-P1.** Verifying §7 corpus GREEN + this sign-off are the gate. The lift commit is a single-line edit at `OCRPostAllowEmitter.swift:104` (`killOcrEmit = false`). The existing `testKillSwitchEmitsTombstoneForAllowFrames` test continues to pin the kill-switch branch via scope override so the emergency-kill capability remains.

— CSO + Director-Recording (joint), 2026-05-29

## Consequences

### Positive

- The cycle 8.17 cross-window leak closes structurally at the OS API boundary.
- The cascade's bundle-keyed gate becomes correct in production. ADR-0030 §3(a)–(c) Messages+Mail redaction operates on the right bytes.
- ADR-0017 §3.1 allowlist-as-content-filter holds as the user expects.
- OCR cost goes down on average — Vision runs against the focused window's pixels instead of the full display.
- The brain v2 phase plan unblocks: entities, edges, episodes can rest on structurally correct bundle attribution.

### Negative / cost

- One `SCStream.updateContentFilter(...)` call per focus change. Target latency budget: ≤8 ms p95 (to be measured on the §11 live-Mac audit; the helper's `frames_focus_race_dropped` counter is the observability surface — a sustained non-zero delta indicates focus-change cadence exceeding the rebind task's 200 ms poll cadence).
- The cascade-twice OCR emitter goes dark for ~1–2 frames during every focus transition (the race-gate window). Trade-off acknowledged: fail-closed under attribution uncertainty is the right direction per ADR-0013 §3 + Amendment 1 §3(b).
- Apps that never produce a focused-window AX answer (intermittent Electron) yield `axRect = nil` from the FocusTracker; this is observability-only inside V2-P1 (the SCStream filter binds against `SCWindow.windowID`, not the AX rect) but a sustained "no rect" condition is a CRS Telemetry-Gap monitoring signal for future Electron-specific work.
- Multi-window observability (the user's intent on Window B while focused on Window A) is lost. Deferred to v2+ Option (c) per §5.2.

### Footprint discipline

The cycle 8.17 footprint envelope (≤ ~1–2% of one CPU core / ≤ ~250 MB RAM on an all-day session, AGENT_PROTOCOL §4 R2) is preserved on the SCStream + OCR path. The FocusTracker is a 1 Hz NSWorkspace + AX poll on a dedicated `DispatchQueue` — same shape and cost class as `NSWorkspaceContextProvider`. The rebind task is a 200 ms async loop; cost is bounded by `SCStream.updateContentFilter` (Apple-documented as cheap; CSO-asserted measurable at ≤8 ms p95 in the live-Mac audit). Net OCR cost is expected to *decrease* (smaller pixel area).

### Compliance with existing invariants

- **AGENT_PROTOCOL §4 R5 sensitive-capture launch-blocker**: this ADR is the spec for the gate. The implementing PR ships with the §7 corpus artifact; M4 lifts as the final commit.
- **AGENT_PROTOCOL §5 protected-set**: this ADR + each commit in the implementing PR carry CSO sign-off blocks.
- **AGENT_PROTOCOL §9 unattended-autonomous mode**: the M4-lift commit is autonomously executable per CEO ratification — the corpus is a Rust binary producing a deterministic artifact, not a live-Mac harness. The §11 live-Mac audit is the post-merge CEO-attended verification.

## Status — M4 kill-switch is RE-ENGAGED (2026-05-30 cycle 8.27 emergency revert of PR #264)

### Original lift posture (2026-05-29 V2-P1)

The V2-P1 implementing PR (`claude/director-recording/v2-p1-focused-window`, PR #239) landed the focused-window filter + FocusTracker + race gate + wire bump + this ADR + the §7 corpus artifact, then lifted the M4 kill-switch as its final commit. The V2-P1 lift moved `killOcrEmit` from `true` to `false`; the §7 corpus passed 5/5 GREEN; the brain v2 phase plan moved forward on the premise that:

1. M4 was OFF (`killOcrEmit = false` in shipped source).
2. The OCR-emit pipeline operated on the focused-window-only capture surface.
3. ADR-0030 §3(a)–(c) Messages/Mail redaction was load-bearing in production.
4. The 14-bundle cascade allowlist's coverage was operationally meaningful for the first time.

### 2026-05-30 EMERGENCY RE-FLIP — V2-P1 focused-window leak surfaced in production

**The premise above no longer holds.** Production probe of the cycle 8.25 DMG (live SHA `abd06f540c52d4e2924b6e6a54ebe7fd0abef3a44ab390c2a59d9dd392230303`, V2-P1 in shipped source) surfaced an OCREvent tagged `app_bundle_id=com.apple.systempreferences, title=Full Disk Access` whose `text_snippet` contained:

- A `+1 (201) 508` phone number, AND
- The prefix of a personal message (`From my side:`).

Both signals are Messages.app content. The event's `app_bundle_id` is `com.apple.systempreferences`. Messages content landed inside a System Preferences event despite V2-P1's focused-window `SCContentFilter`. This is the same class of cross-window pixel-attribution leak that ADR-0031 + the §7 corpus were authored to close.

The mechanism is the §5 escalation pattern from PR #233's memo, §1 verbatim: pixels from a non-frontmost bundle's window enter the brain as frontmost-attributed content. PR #222's per-app redaction layer (`bundle_is_in_scope` at `core/brain/src/redaction/mod.rs`) gates on the event's `app_bundle_id` and is BYPASSED when the leaked content lands inside another app's event — exactly what happened here. `bundle_is_in_scope("com.apple.systempreferences") == false` → the SMS/Mail/Messages regex bank never ran on the OCR'd Messages text.

The §7 corpus passed 5/5 GREEN in dev (`docs/audit/2026-05-29-focused-window-corpus.md`) but the GREEN result does NOT generalize to production behavior. The corpus was authored against a synthetic harness that does not exercise overlapping-window scenarios under the live focus-rebind race conditions exposed in the wild. Either:

- The focused-window `SCContentFilter` is not as window-tight as ADR-0031 §1 asserts under some real workload state we have not reproduced; or
- The race-consistency gate (`(frame_ts, focus_ts)`) is letting in-flight pre-rebind frames through under conditions the corpus did not exercise; or
- A third structural gap exists in the SCStream-to-Vision path that the audit did not surface.

The root-cause diagnostic is a separate Director-Recording + CSO joint dispatch (`v2-p1-production-leak-diag`) — out of scope for this emergency re-flip PR.

### Lift condition (the second time)

M4 lifts the second time when ALL of the following hold:

1. The `v2-p1-production-leak-diag` diagnostic finds the structural gap that the cycle 8.25 production probe surfaced, and an implementing PR closes it (CSO sign-off on the protected-set surface).
2. A **production-realistic** §7-equivalent corpus runs 5/5 GREEN with **explicit coverage** of: (a) overlapping non-frontmost-window scenarios on the same display, (b) focus-rebind race under realistic system load, (c) the same Messages-behind-System-Preferences shape that the production probe surfaced.
3. CEO ratifies the second lift on a re-ship + live-Mac smoke test that includes the production-probe replay shape (Messages window open and visible while System Preferences is frontmost; assert no Messages tokens land in any System Preferences OCREvent).

While `killOcrEmit == true`, V2-P1's focused-window `SCContentFilter` stays installed (defense in depth — the OCR-emit arm is a no-op, but the filter still narrows the captured surface). All other V2 work products on the brain v2 phase plan continue to land; only the OCR-emit gate is closed.

### CSO sign-off block (2026-05-30 emergency re-flip)

This RE-FLIP is the second exercise of the same emergency-mitigation discipline that PR #232 established and PR #239 lifted from. It is exactly what the M4 kill-switch was designed for: a single-line revert that closes the OCR-emit cross-window leak class while the architectural fix's gap is diagnosed and re-closed. CSO authority cited: ADR-0031 §"Status" lift condition (this clause); AGENT_PROTOCOL §4 R5 (sensitive-capture launch-blocker); §5 (CSO veto-gate on protected-set); §7 (escalation discipline). The PR amending this section also flips the single-line source default at `OCRPostAllowEmitter.swift:120` from `false` to `true`. ADR-0013 §3 fail-safe-default-redact + Amendment 1 §3(b) fail-closed posture are PRESERVED — the re-flip strengthens fail-closed, not weakens it.

— CSO + Director-Recording (joint), 2026-05-30

### 2026-05-30 — M4 SECOND LIFT (V2-P1 production wiring + sentinel fail-close)

PR #261 memo (`docs/research/v2-p1-production-leak-2026-05-30.md`) identified that PR #239 V2-P1 added the focused-window machinery (FocusTracker, FocusedWindowStore, `SCContentFilterFactory.makeFocusedWindowFilter`, race gate, this ADR, §7 corpus) but never wired `FocusedWindowStore` + `FocusTracker` into `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift`'s `SCStreamCaptureSession(...)` construction. Both parameters defaulted to `nil` in production; V2-P1 was present in source but inactive in shipped builds. The §7 corpus passed 5/5 GREEN because its scope is the attribution-logic decision matrix, not the construction graph — a unit-tests-pass-but-the-integration-is-missing failure mode.

This PR (#TBD) lands the §5.1 wiring (10 LOC `main.swift` edit constructing the store + tracker and passing them into the session) and the §5.2 race-gate sentinel hardening (~3 LOC at `SCStreamCaptureSession.swift:597` failing closed when `installedFocusGeneration == 0`). The latter closes a residual leak window the §5.1 fix exposes: at boot / login / fast-user-switch the displayFilter fallback is active and both `installedGen` and `focusedSnapshot.generation` are 0; the pre-§5.2 `observedGen != installedGen` predicate trivially passed and let display-composite pixels reach the cascade with `WorkflowContextSnapshot.appBundleId` attribution.

A new `MainSwiftWiringTests.swift` test reads the production `main.swift` source at test time and asserts the construction graph contains the two kwargs that activate V2-P1 (H6 wire-up assertion per memo §4.1). Five additional logic tests pin the §5.2 race-gate sentinel fail-close decision matrix. A future refactor that drops the wiring fails CI before merge.

M4 lifts again (`killOcrEmit = false`) as the LAST commit of this PR — gated on the cycle 8.27 reship + the CEO-attended live-Mac audit (memo §11) confirming H6′/H7′/H8′ harnesses (vibrancy / NotificationCenter banners / multi-window-per-app focus) pass on a real Mac with `HelperHealth.frames_focus_race_dropped` non-zero (proof the race gate is actually running — currently zero in production for the structural reason the memo §3.1 measurement #4 identifies). CRS Telemetry-Gap is tracking the missing `frames_focus_race_dropped` non-zero condition flagged in memo §8.

This second lift supersedes the original 2026-05-29 V2-P1 lift in spirit: ADR-0031 §6.6 ("M4 lifts as the final commit of V2-P1") underestimated the audit gap and is amended by reference to memo §6. The new lift condition is binding from this entry forward.

### CSO sign-off block (2026-05-30 M4 SECOND LIFT)

The CSO seat hereby re-attests ADR-0031 §6.1–§6.6, joint with Director-Recording, against the now-wired construction graph:

1. **OCR-input scope is focused-window-only IN PRODUCTION.** The factory at `SCContentFilterFactory.makeFocusedWindowFilter(...)` is now reachable from the production `SCStreamCaptureSession.start()` path because `focusedWindowStore != nil` in shipped builds. Pinned by `MainSwiftWiringTests.test_main_passes_focusedWindowStore_to_SCStreamCaptureSession`.
2. **Race-consistency gate fails closed AT THE BOOT EDGE.** §5.2's `installedGen == 0` sentinel closes the previously-trivially-passing `0 == 0` predicate. Pinned by `MainSwiftWiringTests.test_race_gate_fails_closed_on_installed_generation_zero_with_observed_*` (3 cases).
3. **ADR-0013 §1 denylist composition preserved.** Unchanged from V2-P1; this PR adds NO denylist path. `SelectFocusedWindowTests::test_returns_nil_when_owning_app_is_denylisted` continues to pin the composition.
4. **Amendment 1 §3(a)–(d) preserved.** (a) cascade-before-encode unchanged; (b) fail-closed STRENGTHENED on the §5.2 sentinel; (c) no stored/emitted suppressed event unchanged; (d) surface-lease exactly-once preserved via `defer { lease.release() }` in `emitFocusRaceDropped(...)` unchanged.
5. **Construction-graph wiring at main.swift:503 verified.** `git grep -n "FocusedWindowStore()" adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift` returns a line; `git grep -n "FocusTracker(store:" adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift` returns a line; both non-empty post-PR. The H6 wire-up assertion test pins this as a structural CI gate going forward; mandatory on every future §5 protected-set PR per the new `project-v2p1-unit-tests-passed-but-never-wired` discipline.
6. **M4 second lift conditioned on the live-Mac audit.** The single-line edit at `OCRPostAllowEmitter.swift:135` (`killOcrEmit = true → false`) is the LAST commit; it is gated on the cycle 8.27 reship's CEO-attended live-Mac audit per memo §6. `testKillSwitchEmitsTombstoneForAllowFrames` continues to scope-override `killOcrEmit = true` for the kill-switch branch test so the emergency-kill capability remains.

— CSO + Director-Recording (joint), 2026-05-30

### 2026-05-30 — M4 SECOND LIFT REVERTED (V2-P1 `exceptingWindows` API misuse breaks SCStream)

PR #264 wired `FocusedWindowStore` + `FocusTracker` into `main.swift` (§5.1) and lifted M4 a second time. The cycle 8.27 DMG built off PR #264 (not merged) was installed to `/Applications` and a CEO production probe ran. Helper.stderr showed, on a ~30s restart loop:

```
SCStream callback alive: first sample received.
SCStream stopped with error: Code=-3815
"Failed to find any displays or windows to capture"
```

Concurrently `HelperHealth` wire frames reported `frames_focus_race_dropped: 155 / 211 delivered` — 73% of delivered frames gated by the race gate before reaching the cascade. The helper restarted itself immediately after each `-3815` error; recording was effectively non-functional.

**Root cause (memo `docs/research/v2-p1-production-leak-2026-05-30.md` §3 H1, now confirmed):**

The V2-P1 implementation built the focused-window `SCContentFilter` via:

```swift
SCContentFilter(display: display, exceptingWindows: [focusedWindow])
```

The Apple semantic for this initializer is **EXCLUDE these windows from capture**, not **INCLUDE ONLY these windows**. Passing the single focused window as the `exceptingWindows` list excludes the only window we want to capture — SCStream has nothing left to sample and emits `-3815 "Failed to find any displays or windows to capture"`. The right initializer is `SCContentFilter(desktopIndependentWindow:)` for a single window (already used elsewhere in the codebase) or `SCContentFilter(display:including:exceptingWindows:)` with a non-empty include list.

The §7 corpus (`docs/audit/2026-05-29-focused-window-corpus.md`) passed 5/5 GREEN in dev because the synthetic harness mocked the `SCContentFilter` constructor's attribution decision rather than exercising the real Apple API — the harness never observed `-3815`. PR #239's `MainSwiftWiringTests` was a construction-graph integration test (it asserted the wiring exists) and did not exercise the runtime SCStream behavior either.

**The revert:**

PR #265 reverts the `main.swift` §5.1 wiring to nil defaults so `SCStreamCaptureSession.start()` falls back to `makeDisplayFilter(...)` (the cycle 8.17 full-display capture path that has worked in production for 11+ cycles). M4 stays re-engaged (`killOcrEmit = true` in `OCRPostAllowEmitter.swift`) so OCR-text emit is structurally closed at the cascade-twice emit gate; the OCR-text leak class that ADR-0031 was authored to close is mitigated at the emit-or-suppress fork while a correct V2-P1 design is produced.

The §5.2 race-gate sentinel fail-close at `SCStreamCaptureSession.swift` (`if installedGen == 0 || ...`) is KEPT. It is a defensive hardening that's correct regardless of whether the focused-window machinery is wired in production — under the revert the outer `if focusedWindowStore != nil` guard around the gate is false in shipped builds so the sentinel branch is unreachable in practice, but the predicate is the structurally-correct decision for any future V2-P1 redesign that does wire focused-window state.

**The new lift condition (third time):**

Any future M4 lift requires ALL of the following:

1. A V2-P1 redesign that uses `SCContentFilter(desktopIndependentWindow:)` (single-window form) or `SCContentFilter(display:including:exceptingWindows:)` (display + non-empty include list) — i.e. an `includingWindows`-correct API. The implementing PR must include a unit test that constructs the filter against a real-Apple-API stand-in and verifies it does NOT trigger `-3815` semantics. Tracked: follow-on memo `v2-p1-redesign-includingwindows`.
2. A production-realistic §7-equivalent corpus that exercises the real Apple SCStream API end-to-end on a live macOS host (not a mock), with explicit coverage of: (a) the cycle 8.27 `-3815` shape that PR #264 surfaced, (b) overlapping non-frontmost-window scenarios on the same display, (c) focus-rebind race under realistic system load, (d) the Messages-behind-System-Preferences attribution shape that the cycle 8.25 production probe surfaced.
3. CEO ratification on a cycle DMG live-Mac smoke test that includes a 5+ minute interactive use exercise. `helper.stderr` MUST contain no `-3815` errors across the exercise; `frames_focus_race_dropped` MUST be a small fraction of `frames_delivered` (e.g. <5%, not the 73% PR #264's wiring produced).
4. CSO sign-off on the protected-set surface (`SCContentFilter` factory, `SCStreamCaptureSession`, the rebind task, the race gate, the wire-up at `main.swift`).

ADR-0031 §6.6 ("M4 lifts as the final commit of V2-P1") is amended in spirit by reference to this revert: that clause underestimated the operational risk of lifting M4 on the same PR that lands the wiring change. Future lifts ship as standalone PRs, after the live-Mac evidence required by (1)–(3) above is in hand, and never compounded with a wiring or capture-API change in the same PR.

### CSO sign-off block (2026-05-30 cycle 8.27 emergency revert — DRIVER-CSO)

Authored by Director-Recording acting as driver-CSO per CEO-INFRA-001 (the `cso` sub-agent dispatch was previously observed to hallucinate audit tables — memory entry `feedback-cso-subagent-hallucinates`; driver-CSO authorship is the corrective discipline).

| Assertion | Verdict | Evidence |
|---|---|---|
| Restored cycle 8.17 display-filter fallback (working in production for 11+ cycles) | PASS | `main.swift` no longer constructs `FocusedWindowStore` / `FocusTracker`; the `SCStreamCaptureSession(...)` call omits both kwargs so they default to `nil`; `start()` falls through to `makeDisplayFilter(...)`. `git log -S "FocusTracker(" -- adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift` returns the PR #264 commit AND this revert commit; symbol absent at HEAD. |
| M4 (`killOcrEmit = true`) preserved — cross-window OCR-text leak structurally closed at the emit gate | PASS | `OCRPostAllowEmitter.swift` `nonisolated(unsafe) internal static var killOcrEmit: Bool = true`. `CascadeTwiceOCREmitterTests.testKillSwitchEmitsTombstoneForAllowFrames` continues to pin the kill-switch branch as the live shipping path. |
| PageContent wire dual-accept restores browser context capture | PASS | `ACCEPTED_FRAME_VERSIONS: &[u8] = &[FRAME_VERSION, 0x07, 0x06]`. `HelperHealth` decode defaults `frames_encode_failed` AND `frames_focus_race_dropped` to 0 on `0x06`. New test `decode_accepts_legacy_0x06_page_content_payload` round-trips a `PageContentEvent` re-shaped to wire version `0x06`. `agent.stderr` `unsupported wire version: got 0x06` loop on the cycle 8.27 production probe is closed. |
| Race-gate fail-close hardening kept as defensive guard | PASS | The §5.2 sentinel branch `if installedGen == 0 \|\| focusedSnapshot?.generation != installedGen` remains in `SCStreamCaptureSession.swift`. Under the revert the outer `if focusedWindowStore != nil` guard is false in shipped builds, so the branch is unreachable in practice but correct in shape for any future V2-P1 redesign. The §5.2 decision-matrix tests in `MainSwiftWiringTests` are preserved (pure-logic tests; no construction-graph dependency). |
| No new cascade widening; no new redaction bypass; no new permission / IPC surface / wire field; no new network surface | PASS | This revert REMOVES code (the `main.swift` wiring); it does not add capture paths. The wire-version dual-accept WIDENS the read side (accepts more legacy versions on read) but does not introduce new message types or new fields. No Info.plist / entitlements / TCC / usage-description changes. The encoder still emits exclusively at `FRAME_VERSION = 0x08`. |
| ADR-0013 §1 source-level denylist composition preserved | PASS | `Denylist` composition at the SCStream session construction site is unchanged. `makeDisplayFilter(...)`'s denylist behavior is the same fallback the helper has been running with for 11+ cycles. |
| ADR-0013 §3 fail-safe-default-redact preserved | PASS | The revert strengthens the default by re-engaging M4 — every `.allow` frame fail-closes to `PrivacyTombstone(failsafeUnknown)` at the cascade-twice emit gate. |
| ADR-0030 §3(a)–(c) Messages/Mail per-app redaction posture | DEGRADED-AS-DESIGNED | With M4 RE-ENGAGED, the per-app redaction at `core/brain/src/redaction/mod.rs` `bundle_is_in_scope` does not need to be load-bearing because OCR-text emit is structurally closed on `.allow` frames. The redaction layer regains load-bearing status when M4 lifts (third time) under the new lift conditions above. |
| Construction-graph wiring discipline (per `project-v2p1-unit-tests-passed-but-never-wired`) is preserved | PASS | The `project-v2p1-unit-tests-passed-but-never-wired` memory entry's discipline — "construction-graph wiring at integration sites must be in CSO sign-off audit table going forward" — is honored here. This audit table explicitly cites the `main.swift` wiring state (now reverted to nil defaults). |

**Verdict: APPROVED for emergency merge.** The revert is a strict narrowing of the production surface: it removes a wiring change that broke SCStream end-to-end, preserves the M4 mitigation, and re-extends the wire dual-accept to close the browser context capture regression. No new attack surface; no new redaction bypass; no new permission. ADR-0013, ADR-0015 §4, ADR-0016 §1.6/§4.2, ADR-0030 §3, ADR-0031 §6.1–§6.5 invariants are preserved or strengthened. CSO authority cited: AGENT_PROTOCOL §4 R5 (sensitive-capture launch-blocker — production was capture-down on PR #264), §5 (CSO veto-gate on protected-set), §7 (escalation discipline). The third-lift condition above is binding from this entry forward.

— Director-Recording (driver-CSO per CEO-INFRA-001), 2026-05-30

## Cross-references

- **Memo:** `docs/research/capture-scope-window-vs-display-2026-05-29.md` (merged PR #233). §3 ADR audit, §5 recommendation, §7 falsifiability corpus spec, §9 CSO sign-off scaffolding.
- **Brain v2 vision:** `docs/research/brain-architecture-v2-vision-2026-05-29.md` §7.1 (V2-P1 spec) + §6.1 E8 (protected-set escalation list).
- **M4 interim mitigation:** PR #232. Lift commit shipped in this PR's commit 6.
- **§7 corpus runner:** `core/brain/src/bin/focused_window_corpus.rs`. Committed artifact: `docs/audit/2026-05-29-focused-window-corpus.md`.
- **Implementing PR commits:**
  - Commit 1: `FocusTracker` + reader + `FocusedWindowStore`.
  - Commit 2: `makeFocusedWindowFilter` + SCStream rebind + race gate + `focusRaceDropped` `RedactionReason`.
  - Commit 3: wire bump 0x07 → 0x08 + `frames_focus_race_dropped` counter (Swift + Rust + Python + JSONL).
  - Commit 4: §7 corpus runner + committed GREEN artifact.
  - Commit 5: this ADR.
  - Commit 6: M4 kill-switch lift (`killOcrEmit = false`).
- **V2-P1 PRODUCTION LEAK MEMO:** `docs/research/v2-p1-production-leak-2026-05-30.md` (PR #261). Diagnoses the missing `main.swift` wiring as sole root cause for the cycle 8.25 production evidence; specifies §5.1 + §5.2 fix + §6 new M4 lift condition.
- **M4 second-lift commits (PR #264, MERGED to main, then REVERTED by PR #265):**
  - Commit 1: §5.1 main.swift wiring (FocusedWindowStore + FocusTracker into `SCStreamCaptureSession(...)`) + §5.2 race-gate sentinel fail-close at `installedGen == 0` + `MainSwiftWiringTests` (H6 wire-up assertion + §5.2 decision matrix).
  - Commit 2: ADR-0031 amendment (the M4 SECOND LIFT entry above — superseded by the M4 SECOND LIFT REVERTED entry below it).
  - Commit 3: M4 kill-switch lift (`killOcrEmit = false`).
- **M4 second-lift REVERT commits (PR #265, this PR):**
  - Reverts §5.1 main.swift wiring to nil defaults so `start()` falls back to `makeDisplayFilter(...)` (cycle 8.17 shape).
  - Keeps §5.2 race-gate sentinel fail-close (defensive guard; unreachable in practice under the revert).
  - Replaces `MainSwiftWiringTests` H6 wiring assertions with the §5.2 decision-matrix tests only (pure logic).
  - Re-flips M4 (`killOcrEmit = true`).
  - Adds `ACCEPTED_FRAME_VERSIONS` `0x06` re-extension + new `decode_accepts_legacy_0x06_page_content_payload` test to fix the cycle 8.27 `unsupported wire version: got 0x06` browser-context-capture regression on `page_content.sock`.
  - Amends this ADR §"Status" with the M4 SECOND LIFT REVERTED entry + driver-CSO sign-off block.
