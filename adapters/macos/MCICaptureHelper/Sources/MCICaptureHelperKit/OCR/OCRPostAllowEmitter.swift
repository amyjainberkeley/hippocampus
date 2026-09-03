// SPDX-License-Identifier: TBD-private
//
// OCRPostAllowEmitter — ADR-0016 P3.6 cascade-twice orchestrator.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. LOAD-BEARING per ADR-0016 §4.
//
// The trust boundary that turns the P3.5 OCR worker + the
// `SuppressionCascade.decideOcr(text:context:)` §6 re-cascade + the
// IPC wire frame emission into ONE coherent path. Called from
// `SCStreamCaptureSession.stream(_:didOutputSampleBuffer:of:)` AFTER
// `SCStreamPipeline.process(...)` returns `.encoded(seq:_:)` — i.e.
// the pixel-time cascade (§1–§5 + §7) returned `.allow`.
//
// Sequence per cleared-once-on-pixels frame:
//   1. Submit `(CVPixelBuffer, dirtyRectsBoundingROI)` to the OCR worker.
//   2. Worker returns `OCRResult` (recognizedLines + durationMs + timedOut).
//   3. Join `result.recognizedLines.text` into a single string. Timeout,
//      engine-error, empty, and whitespace-only results stop here: no event
//      and no visual retention.
//   4. Re-run cascade via `cascade.decideOcr(text:context:)`.
//        - `.suppress(reason: .ocrTimeSecret)` ⇒ emit
//          `PrivacyTombstone(reason: 6)`. NO OCR text bytes reach the
//          wire. NO `OCREvent` is emitted.
//        - `.allow` ⇒ encode `OCREvent` with the OCR text, subject to
//          the 64 KB cap (`maxOCRTextBytes`). Over-cap fails closed
//          per ADR-0013 §7: emit `PrivacyTombstone(reason: 7)` instead.
//   5. Write the chosen bytes to the `FrameSink`.
//
// Cascade-twice invariant (ADR-0016 §4.2): an `OCREvent` reaches the
// wire ONLY if BOTH cascade passes returned `.allow`. The IPC seam
// structurally cannot deliver a `PrivacyTombstone` to the brain
// ingestor (`Routed::OCREvent` vs `Routed::Tombstone` enum dispatch
// in `core/src/ipc/connection.rs`).
//
// Condensed keyframe retention is reachable only after both privacy
// approvals and zero-hash wire validation. The retention coordinator
// publishes an authenticated blob durably before this emitter places
// its digest in the OCREvent.

import CoreGraphics
import CoreVideo
import Foundation

/// Tells the capture baseline whether this exact visual should be considered
/// handled. Empty/timed-out/dropped OCR is retryable; every emitted event or
/// privacy tombstone is terminal for the visual.
public enum OCRPostAllowDisposition: Sendable, Equatable {
    case finalized
    case retryableNoContent
}

/// Protocol indirection so headless tests can substitute a stub
/// emitter. Production impl is `CascadeTwiceOCREmitter`.
public protocol OCRPostAllowEmitter: Sendable {
    /// Called from `SCStreamCaptureSession` after `pipeline.process`
    /// returns `.encoded` (the pixel-time cascade returned `.allow`).
    ///
    /// The emitter returns after OCR submission. Completion work is handed to
    /// an emitter-owned bounded serial coordinator; no free task may outlive
    /// the capture session.
    ///
    /// Drop-oldest overflow emits no wire frame. The disposition-aware
    /// overload reports the drop as retryable so the exact capture baseline
    /// can be reopened without weakening the privacy cascade.
    func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput
    ) async

    func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?
    ) async

    func processAfterAllow(
        captureOrdinal: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?
    ) async

    func processAfterAllow(
        captureOrdinal: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?,
        disposition: @Sendable @escaping (OCRPostAllowDisposition) -> Void
    ) async

    func stopAndDrain() async
}

public extension OCRPostAllowEmitter {
    func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate _: KeyframeEvidenceCandidate?
    ) async {
        await processAfterAllow(tsUs: tsUs, context: context, input: input)
    }

    func processAfterAllow(
        captureOrdinal _: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?
    ) async {
        await processAfterAllow(
            tsUs: tsUs,
            context: context,
            input: input,
            evidenceCandidate: evidenceCandidate
        )
    }

    func processAfterAllow(
        captureOrdinal: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?,
        disposition: @Sendable @escaping (OCRPostAllowDisposition) -> Void
    ) async {
        await processAfterAllow(
            captureOrdinal: captureOrdinal,
            tsUs: tsUs,
            context: context,
            input: input,
            evidenceCandidate: evidenceCandidate
        )
        disposition(.finalized)
    }

}

/// Production `OCRPostAllowEmitter` that wires `VisionOCRWorker` +
/// `SuppressionCascade` + `FrameSink` + `FrameSequence` together per
/// ADR-0016 §1.6 + §4.2.
public struct CascadeTwiceOCREmitter: OCRPostAllowEmitter {
    /// CSO escalation 2026-05-29 — capture-scope cross-window leak
    /// kill-switch (Phase A interim mitigation, option M4 in
    /// `docs/research/capture-scope-window-vs-display-2026-05-29.md`).
    ///
    /// `true` ⇒ every `processAfterAllow` invocation emits a
    /// `PrivacyTombstone(failsafeUnknown)` instead of submitting the
    /// pixel buffer to the Vision OCR worker. While `true`, no OCR
    /// text bytes from the SCStream sample reach the brain — the
    /// cross-window leak documented in the memo cannot occur because
    /// the OCR pipeline is short-circuited at the emit-or-suppress
    /// fork.
    ///
    /// History:
    ///   - 2026-05-29 PR #232: shipped with `true` (Phase A mitigation).
    ///   - 2026-05-29 V2-P1 PR #239: lifted to `false`. The
    ///     architectural fix (Option (a) — focused-window
    ///     `SCContentFilter(desktopIndependentWindow:)` via
    ///     `SCContentFilterFactory.makeFocusedWindowFilter(...)`) +
    ///     FocusTracker + `(frame_ts, focus_ts)` race-consistency gate
    ///     shipped in Commits 1–3; the §7 falsifiability corpus
    ///     (`docs/audit/2026-05-29-focused-window-corpus.md`) passed
    ///     5/5 GREEN (Commit 4); ADR-0031 §6 CSO sign-off was authored
    ///     (Commit 5); the lift was Commit 6.
    ///   - **2026-05-30 EMERGENCY RE-FLIP back to `true`.** Production
    ///     probe of the cycle 8.25 DMG (live SHA
    ///     `abd06f540c52d4e2924b6e6a54ebe7fd0abef3a44ab390c2a59d9dd392230303`)
    ///     surfaced an OCREvent tagged
    ///     `app_bundle_id=com.apple.systempreferences, title=Full Disk
    ///     Access` whose `text_snippet` contained a `+1 (201) 508`
    ///     phone number plus the prefix of a personal message
    ///     (`From my side:`) — i.e. Messages.app content leaking into a
    ///     System Preferences event despite V2-P1's focused-window
    ///     `SCContentFilter`. PR #222's `bundle_is_in_scope` per-app
    ///     redaction gates on the EVENT-level `app_bundle_id` and is
    ///     bypassed when leaked content lands inside another app's
    ///     event. The §7 corpus passed 5/5 GREEN in dev but the result
    ///     does NOT generalize to production — the leak is alive in
    ///     shipped builds. Same §5 escalation pattern as PR #233 → PR
    ///     #232. M4 re-engaged pending diagnostic of the production-leak
    ///     root cause (separate dispatch
    ///     `v2-p1-production-leak-diag`). The second lift condition is:
    ///     that diagnostic's fix + a production-realistic corpus that
    ///     includes overlapping-window scenarios passes 5/5. The V2-P1
    ///     focused-window `SCContentFilter` stays installed — under
    ///     `killOcrEmit == true` the cascade-twice OCR-emit arm is a
    ///     no-op, but the filter still applies as defense in depth.
    ///     ADR-0031 §Status amended in lockstep with this RE-FLIP.
    ///   - **2026-05-30 M4 SECOND LIFT REVERTED — back to `true`.**
    ///     PR #264 wired `FocusedWindowStore` + `FocusTracker` into
    ///     `main.swift` and lifted M4 a second time. The cycle 8.27
    ///     production probe (cycle 8.27 DMG, not merged) showed
    ///     `SCStream stopped with error: Code=-3815 "Failed to find
    ///     any displays or windows to capture"` on a ~30s restart loop
    ///     with 73% `frames_focus_race_dropped` (155 / 211 delivered).
    ///     Root cause (memo
    ///     `docs/research/v2-p1-production-leak-2026-05-30.md` §3 H1,
    ///     confirmed):
    ///     `SCContentFilter(display:exceptingWindows:[focusedWindow])`
    ///     is an EXCLUDE filter, not an INCLUDE-ONLY filter — passing
    ///     the single focused window as the `exceptingWindows` list
    ///     excludes the only window we want to capture, so SCStream
    ///     has nothing left and emits -3815. The §7 corpus's 5/5 GREEN
    ///     did not catch this because the synthetic harness mocked the
    ///     `SCContentFilter` constructor rather than exercising the
    ///     real Apple API. The V2-P1 production wiring is reverted to
    ///     nil defaults so `SCStreamCaptureSession.start()` falls back
    ///     to `makeDisplayFilter(...)` — the cycle 8.17 full-display
    ///     capture path that has worked in production for 11+ cycles.
    ///     M4 stays re-engaged (`killOcrEmit = true`) so OCR-text
    ///     emit is structurally closed at the cascade-twice emit gate.
    ///     V2-P1 will need a redesign with an
    ///     `includingWindows`-correct API + a production-realistic
    ///     corpus that exercises the real Apple API before the second
    ///     lift can succeed; tracked: follow-on memo
    ///     `v2-p1-redesign-includingwindows`. ADR-0031 §Status amended
    ///     in lockstep with this REVERT.
    ///
    /// PROTECTED-SET per AGENT_PROTOCOL §5.
    ///
    /// Declared `var` (not `let`) only so existing cascade-twice unit
    /// tests in `CascadeTwiceOCREmitterTests` can scope-override it
    /// to exercise the OCR-emit path (setUp forces `false` for the
    /// cascade-twice mechanics tests; the kill-switch BRANCH test
    /// `testKillSwitchEmitsTombstoneForAllowFrames` explicitly forces
    /// `true`). Production code paths never mutate this — both the
    /// V2-P1 lifts and the re-flip ship as single-line source edits,
    /// not runtime mutations. The `nonisolated(unsafe)` annotation is
    /// required by Swift 6 strict concurrency for a static `var`;
    /// safe here because writes are confined to test setup/teardown
    /// and reads in production are pure load.
    nonisolated(unsafe) internal static var killOcrEmit: Bool = true

    /// M4-LIFT activator — the ONE production entry point that flips
    /// `killOcrEmit` from the explicit `--capture` argv decision. Called
    /// exactly once per helper process from `main.swift`.
    ///
    /// This method exists so the executable target (`MCICaptureHelper`)
    /// can flip the internal `killOcrEmit` gate without loosening its
    /// `internal` scope (the field stays `internal` so tests keep the
    /// only other legitimate write path via `@testable import`). The
    /// method name is verbose so a grep for the M4-lift runtime
    /// activation lands here immediately.
    ///
    /// - Parameter enabled: `true` ⇒ flip `killOcrEmit = false` so the
    ///   cascade-twice OCR-emit path is armed. `false` ⇒ engage the
    ///   kill-switch (restore pre-M4-lift behavior). Callers that pass
    ///   `false` here are exercising a rollback drill.
    public static func activateM4Lift(enabled: Bool) {
        Self.killOcrEmit = !enabled
    }
    // macOS-15 SDK migration (2026-07-15): restore the `worker` stored
    // property. The initializer assigns `self.worker` and `processAfterAllow`
    // calls `worker.submit(...)`, but the declaration had been dropped
    // (an incomplete earlier refactor), so the file no longer compiled.
    private let worker: VisionOCRWorker
    private let cascade: SuppressionCascade
    private let sink: any FrameSink
    private let sequence: FrameSequence
    private let counters: HelperHealthCounters
    private let keyframeRetainer: (any KeyframeRetaining)?
    private let completionCoordinator: OrderedCaptureDispatcher

    public init(
        worker: VisionOCRWorker,
        cascade: SuppressionCascade,
        sink: any FrameSink,
        sequence: FrameSequence,
        counters: HelperHealthCounters,
        keyframeRetainer: (any KeyframeRetaining)? = nil
    ) {
        self.worker = worker
        self.cascade = cascade
        self.sink = sink
        self.sequence = sequence
        self.counters = counters
        self.keyframeRetainer = keyframeRetainer
        self.completionCoordinator = OrderedCaptureDispatcher(
            capacity: VisionOCRWorker.defaultCapacity
        )
    }

    public func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput
    ) async {
        await processAfterAllow(
            captureOrdinal: tsUs,
            tsUs: tsUs,
            context: context,
            input: input,
            evidenceCandidate: nil
        )
    }

    public func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?
    ) async {
        await processAfterAllow(
            captureOrdinal: evidenceCandidate?.captureOrdinal ?? tsUs,
            tsUs: tsUs,
            context: context,
            input: input,
            evidenceCandidate: evidenceCandidate
        )
    }

    public func processAfterAllow(
        captureOrdinal: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?
    ) async {
        await processAfterAllow(
            captureOrdinal: captureOrdinal,
            tsUs: tsUs,
            context: context,
            input: input,
            evidenceCandidate: evidenceCandidate,
            disposition: { _ in }
        )
    }

    public func processAfterAllow(
        captureOrdinal: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?,
        disposition: @Sendable @escaping (OCRPostAllowDisposition) -> Void
    ) async {
        // PR #226 §5.1 (2) — MCI_OCR_TRACE=1 env-gated trace at the
        // post-allow entry. Only the kill-switch state is emitted; bundle ID,
        // title, URL, and OCR text stay out of diagnostics.
        OCRTrace.emit(
            "ocr-post-allow-entry",
            "kill_ocr_emit=\(Self.killOcrEmit)"
        )
        // CSO escalation 2026-05-29 — capture-scope cross-window leak
        // (see `Self.killOcrEmit` + `docs/research/capture-scope-
        // window-vs-display-2026-05-29.md`). Short-circuit the OCR
        // worker submission and emit a fail-safe tombstone instead.
        // The tombstone path is identical in shape to the existing
        // §6 ocrTimeSecret tombstone and the over-cap failsafeUnknown
        // tombstone — same wire frame, same sequence allocation, same
        // counters increment. No OCR text bytes reach the wire.
        //
        // The .appex socket path (Safari/Chrome URL + page_content →
        // BrainPump) is structurally independent of this emitter and
        // remains unaffected.
        if Self.killOcrEmit {
            await Self.emitTombstone(
                tsUs: tsUs,
                context: context,
                reason: .failsafeUnknown,
                sink: sink,
                sequence: sequence,
                counters: counters
            )
            disposition(.finalized)
            return
        }

        let cascadeSnapshot = cascade
        let sinkSnapshot = sink
        let sequenceSnapshot = sequence
        let countersSnapshot = counters
        let keyframeRetainerSnapshot = keyframeRetainer
        // P3.6.5: capture the pixel buffer reference for the blob
        // writer. OCREngineInput is @unchecked Sendable; the pixel
        // buffer stays alive until the job completes (held by the
        // worker's Job struct + this captured reference).
        let inputSnapshot = input
        await Self.submitOCRAttempt(
            worker: worker,
            completionCoordinator: completionCoordinator,
            attemptsRemaining: 1,
            captureOrdinal: captureOrdinal,
            tsUs: tsUs,
            context: context,
            input: inputSnapshot,
            evidenceCandidate: evidenceCandidate,
            cascade: cascadeSnapshot,
            sink: sinkSnapshot,
            sequence: sequenceSnapshot,
            counters: countersSnapshot,
            keyframeRetainer: keyframeRetainerSnapshot,
            disposition: disposition
        )
    }

    /// Retry one OCR job against the same retained pixels. ScreenCaptureKit's
    /// `.idle` status explicitly means no new frame was generated, so waiting
    /// for a later callback cannot recover a static window. Keeping the retry
    /// inside the owned worker/coordinator pair bounds work and preserves the
    /// original privacy snapshot, context, evidence identity, and ROI.
    private static func submitOCRAttempt(
        worker: VisionOCRWorker,
        completionCoordinator: OrderedCaptureDispatcher,
        attemptsRemaining: Int,
        captureOrdinal: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?,
        cascade: SuppressionCascade,
        sink: any FrameSink,
        sequence: FrameSequence,
        counters: HelperHealthCounters,
        keyframeRetainer: (any KeyframeRetaining)?,
        disposition: @Sendable @escaping (OCRPostAllowDisposition) -> Void
    ) async {
        await worker.submit(
            input: input,
            onDrop: {
                Self.scheduleRetryOrFinish(
                    worker: worker,
                    completionCoordinator: completionCoordinator,
                    attemptsRemaining: attemptsRemaining,
                    captureOrdinal: captureOrdinal,
                    tsUs: tsUs,
                    context: context,
                    input: input,
                    evidenceCandidate: evidenceCandidate,
                    cascade: cascade,
                    sink: sink,
                    sequence: sequence,
                    counters: counters,
                    keyframeRetainer: keyframeRetainer,
                    disposition: disposition
                )
            }
        ) { result in
            let resultDisposition = Self.disposition(for: result)
            // VisionOCRWorker invokes completions serially in submission
            // order. The owned coordinator preserves that order while
            // bounding retry and post-OCR persistence/publication work.
            completionCoordinator.submit(
                captureOrdinal: captureOrdinal,
                operation: {
                    if resultDisposition == .retryableNoContent,
                       attemptsRemaining > 0
                    {
                        OCRTrace.emit(
                            "ocr-post-allow-retry",
                            "reason=no_content attempts_remaining=\(attemptsRemaining - 1)"
                        )
                        await Self.submitOCRAttempt(
                            worker: worker,
                            completionCoordinator: completionCoordinator,
                            attemptsRemaining: attemptsRemaining - 1,
                            captureOrdinal: captureOrdinal,
                            tsUs: tsUs,
                            context: context,
                            input: input,
                            evidenceCandidate: evidenceCandidate,
                            cascade: cascade,
                            sink: sink,
                            sequence: sequence,
                            counters: counters,
                            keyframeRetainer: keyframeRetainer,
                            disposition: disposition
                        )
                        return
                    }
                    await Self.handleOCRResult(
                        tsUs: tsUs,
                        context: context,
                        result: result,
                        cascade: cascade,
                        sink: sink,
                        sequence: sequence,
                        counters: counters,
                        pixelBuffer: input.pixelBuffer,
                        keyframeRetainer: keyframeRetainer,
                        evidenceCandidate: evidenceCandidate
                    )
                    disposition(resultDisposition)
                },
                onDrop: {
                    Self.scheduleRetryOrFinish(
                        worker: worker,
                        completionCoordinator: completionCoordinator,
                        attemptsRemaining: attemptsRemaining,
                        captureOrdinal: captureOrdinal,
                        tsUs: tsUs,
                        context: context,
                        input: input,
                        evidenceCandidate: evidenceCandidate,
                        cascade: cascade,
                        sink: sink,
                        sequence: sequence,
                        counters: counters,
                        keyframeRetainer: keyframeRetainer,
                        disposition: disposition
                    )
                }
            )
        }
    }

    private static func scheduleRetryOrFinish(
        worker: VisionOCRWorker,
        completionCoordinator: OrderedCaptureDispatcher,
        attemptsRemaining: Int,
        captureOrdinal: UInt64,
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput,
        evidenceCandidate: KeyframeEvidenceCandidate?,
        cascade: SuppressionCascade,
        sink: any FrameSink,
        sequence: FrameSequence,
        counters: HelperHealthCounters,
        keyframeRetainer: (any KeyframeRetaining)?,
        disposition: @Sendable @escaping (OCRPostAllowDisposition) -> Void
    ) {
        guard attemptsRemaining > 0 else {
            disposition(.retryableNoContent)
            return
        }
        completionCoordinator.submit(
            captureOrdinal: captureOrdinal,
            operation: {
                OCRTrace.emit(
                    "ocr-post-allow-retry",
                    "reason=queue_drop attempts_remaining=\(attemptsRemaining - 1)"
                )
                await Self.submitOCRAttempt(
                    worker: worker,
                    completionCoordinator: completionCoordinator,
                    attemptsRemaining: attemptsRemaining - 1,
                    captureOrdinal: captureOrdinal,
                    tsUs: tsUs,
                    context: context,
                    input: input,
                    evidenceCandidate: evidenceCandidate,
                    cascade: cascade,
                    sink: sink,
                    sequence: sequence,
                    counters: counters,
                    keyframeRetainer: keyframeRetainer,
                    disposition: disposition
                )
            },
            onDrop: {
                disposition(.retryableNoContent)
            }
        )
    }

    private static func disposition(for result: OCRResult) -> OCRPostAllowDisposition {
        let text = result.recognizedLines.map(\.text).joined(separator: "\n")
        if result.timedOut || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .retryableNoContent
        }
        return .finalized
    }

    /// Close result ingress first, then cancel/drain OCR. A late completion
    /// from a cancellation-resistant engine observes a terminated coordinator
    /// and cannot publish. After both awaits return, neither OCR nor post-OCR
    /// persistence remains live.
    public func stopAndDrain() async {
        await completionCoordinator.cancelAndDrain()
        await worker.stopAndDrain()
    }

    /// Pure (modulo actor I/O) emit logic. `internal` (not `private`)
    /// so headless tests can drive the §6 re-cascade + wire emission
    /// matrix without standing up a real `VisionOCRWorker`.
    ///
    /// Cascade-twice invariant verified structurally here:
    ///   - `.suppress(reason: .ocrTimeSecret)` ⇒ tombstone, NO
    ///     `OCREvent` emitted.
    ///   - `.allow` + over-cap ⇒ tombstone with `failsafeUnknown`,
    ///     NO `OCREvent` emitted.
    ///   - `.allow` + within cap ⇒ `OCREvent` emitted.
    ///
    /// Every `OCREvent` byte that reaches the wire passed BOTH cascade
    /// passes. There is no other call site that emits `OCREvent` in
    /// the helper.
    static func handleOCRResult(
        tsUs: UInt64,
        context: WorkflowContext,
        result: OCRResult,
        cascade: SuppressionCascade,
        sink: any FrameSink,
        sequence: FrameSequence,
        counters: HelperHealthCounters,
        pixelBuffer: CVPixelBuffer? = nil,
        keyframeRetainer: (any KeyframeRetaining)? = nil,
        evidenceCandidate: KeyframeEvidenceCandidate? = nil
    ) async {
        let text = result.recognizedLines.map(\.text).joined(separator: "\n")
        guard !result.timedOut,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            OCRTrace.emit(
                "ocr-post-allow-result",
                "decision=no_content "
                    + "ocr_len=\(text.utf8.count) "
                    + "ocr_lines=\(result.recognizedLines.count)"
            )
            return
        }
        let decision = cascade.decideOcr(text: text, context: context)
        // PR #226 §5.1 (2) — MCI_OCR_TRACE=1 trace at the post-allow
        // OCR completion. Logs cascade-twice §6 decision + OCR text LENGTH
        // (the spec explicitly permits the length
        // count as a non-content signal; recognized lines counted as
        // a coarse signal of how much text the OCR produced — useful
        // for diagnosing "OCR ran but produced nothing" silences
        // without leaking the actual content). NEVER the text itself.
        OCRTrace.emit(
            "ocr-post-allow-result",
            "decision=\(decision.traceLabel) "
                + "ocr_len=\(text.utf8.count) "
                + "ocr_lines=\(result.recognizedLines.count)"
        )
        switch decision {
        case .suppress(let reason):
            // §6 fired — never emit OCREvent on this path. Tombstone
            // carries the reason (.ocrTimeSecret); no OCR text bytes
            // reach the wire. NO blob written (ADR-0016 §4.8).
            await emitTombstone(
                tsUs: tsUs,
                context: context,
                reason: reason,
                sink: sink,
                sequence: sequence,
                counters: counters
            )

        case .allow:
            // Validate the complete event with the zero-hash sentinel before
            // screenshot policy, encoding, or disk I/O becomes reachable.
            let seq = await sequence.allocate()
            let zeroHash = [UInt8](repeating: 0, count: ocrEventKeyframeHashLen)
            let zeroEvent = OCREvent(
                seq: seq,
                tsUs: tsUs,
                appBundleId: context.appBundleId ?? "",
                windowTitle: context.windowTitle ?? "",
                url: context.url ?? "",
                ocrText: text,
                keyframeHash: zeroHash
            )
            let zeroBytes: Data
            switch encodeOCREvent(seq: seq, event: zeroEvent) {
            case .success(let validated):
                zeroBytes = validated
            case .failure:
                await emitTombstone(
                    tsUs: tsUs,
                    context: context,
                    reason: .failsafeUnknown,
                    sink: sink,
                    sequence: sequence,
                    counters: counters
                )
                return
            }

            guard !Task.isCancelled,
                  let pixelBuffer,
                  let evidenceCandidate,
                  let keyframeRetainer
            else {
                try? await sink.write(zeroBytes)
                return
            }
            let retention: KeyframeRetention
            do {
                guard let retained = try await keyframeRetainer.retain(
                    input: KeyframePixelInput(pixelBuffer: pixelBuffer),
                    candidate: evidenceCandidate
                ) else {
                    try? await sink.write(zeroBytes)
                    return
                }
                retention = retained
            } catch {
                reportKeyframeCleanupFailure()
                try? await sink.write(zeroBytes)
                return
            }
            guard retention.digest.count == ocrEventKeyframeHashLen,
                  !retention.digest.allSatisfy({ $0 == 0 }),
                  !Task.isCancelled
            else {
                do {
                    try await keyframeRetainer.discard(retention)
                } catch {
                    reportKeyframeCleanupFailure()
                }
                try? await sink.write(zeroBytes)
                return
            }

            let retainedEvent = OCREvent(
                seq: seq,
                tsUs: tsUs,
                appBundleId: zeroEvent.appBundleId,
                windowTitle: zeroEvent.windowTitle,
                url: zeroEvent.url,
                ocrText: zeroEvent.ocrText,
                keyframeHash: retention.digest
            )
            guard case .success(let retainedBytes) = encodeOCREvent(
                seq: seq,
                event: retainedEvent
            ) else {
                do {
                    try await keyframeRetainer.discard(retention)
                } catch {
                    reportKeyframeCleanupFailure()
                }
                try? await sink.write(zeroBytes)
                return
            }

            do {
                try await sink.write(retainedBytes)
                await keyframeRetainer.confirm(retention)
            } catch {
                do {
                    try await keyframeRetainer.discard(retention)
                } catch {
                    reportKeyframeCleanupFailure()
                }
                try? await sink.write(zeroBytes)
            }
        }
    }

    private static func reportKeyframeCleanupFailure() {
        FileHandle.standardError.write(
            Data("mci-capture-helper: keyframe cleanup failed after bounded retries\n".utf8)
        )
    }

    private static func emitTombstone(
        tsUs: UInt64,
        context: WorkflowContext,
        reason: RedactionReason,
        sink: any FrameSink,
        sequence: FrameSequence,
        counters: HelperHealthCounters
    ) async {
        let seq = await sequence.allocate()
        let bytes = encodePrivacyTombstone(
            seq: seq,
            tombstone: PrivacyTombstone(
                tsUs: tsUs,
                appBundle: context.appBundleId ?? "",
                reason: reason
            )
        )
        try? await sink.write(bytes)
        await counters.recordSuppressed()
        if reason == .failsafeUnknown {
            await counters.recordRedactedByFailsafe()
            // Phase 6 PR 6 — per-app cascade-silence attribution
            // (PR #226 §5.1 (1)). The cap-8 LRU is enforced inside
            // `recordFailsafeByApp`. Bundle id is content-free under
            // the cap-8 discipline — see HelperHealthCounters docs.
            await counters.recordFailsafeByApp(bundleId: context.appBundleId ?? "")
        }
    }
}

/// Compute the normalized OCR ROI from the captured `CVPixelBuffer`
/// and the in-callback dirty-rect set. Output is in Apple Vision's
/// expected coordinates: origin lower-left, units in [0, 1] per
/// ADR-0016 §1.1 + `OCREngineInput.roi`.
///
/// Empty dirty-rect set ⇒ full-frame ROI (`CGRect(0, 0, 1, 1)`); the
/// caller decides whether to suppress OCR on no-dirty-rect frames
/// (the smart-capture filter ladder already drops most of those
/// before the cascade runs).
public enum OCRROIComputer {
    /// `widthPx` / `heightPx` are the captured frame's pixel
    /// dimensions; `dirtyRects` are the per-frame dirty rectangles in
    /// the SAME pixel coordinate space. Origin convention matches
    /// ScreenCaptureKit's frame-info dictionaries (top-left); the
    /// helper flips to Vision's lower-left here so callers do not
    /// re-derive this every frame.
    public static func normalizedBoundingROI(
        widthPx: Int,
        heightPx: Int,
        dirtyRects: [DirtyRect]
    ) -> CGRect {
        guard widthPx > 0, heightPx > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        guard !dirtyRects.isEmpty else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var minX = UInt32.max
        var minY = UInt32.max
        var maxX: UInt32 = 0
        var maxY: UInt32 = 0
        for r in dirtyRects {
            if r.width == 0 || r.height == 0 { continue }
            minX = min(minX, r.x)
            minY = min(minY, r.y)
            maxX = max(maxX, r.x &+ r.width)
            maxY = max(maxY, r.y &+ r.height)
        }
        if minX == UInt32.max || minY == UInt32.max {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let w = CGFloat(widthPx)
        let h = CGFloat(heightPx)
        let nx = CGFloat(minX) / w
        // Vision's coordinate system is origin lower-left.
        let ny = 1.0 - (CGFloat(maxY) / h)
        let nw = CGFloat(max(0, maxX &- minX)) / w
        let nh = CGFloat(max(0, maxY &- minY)) / h
        return CGRect(
            x: max(0, min(1, nx)),
            y: max(0, min(1, ny)),
            width: max(0, min(1, nw)),
            height: max(0, min(1, nh))
        )
    }
}
