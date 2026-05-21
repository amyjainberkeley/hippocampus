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
//   3. Join `result.recognizedLines.text` into a single string.
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
// Keyframe blob writes are vacuous in P3.6: `keyframeHash = [0u8; 32]`
// signals "no blob yet"; the blob writer lands at P3.6.5.

import CoreGraphics
import CoreVideo
import Foundation

/// Protocol indirection so headless tests can substitute a stub
/// emitter. Production impl is `CascadeTwiceOCREmitter`.
public protocol OCRPostAllowEmitter: Sendable {
    /// Called from `SCStreamCaptureSession` after `pipeline.process`
    /// returns `.encoded` (the pixel-time cascade returned `.allow`).
    ///
    /// Fire-and-forget shape: the emitter returns as soon as the OCR
    /// submission is queued. The OCR completion callback drives the
    /// §6 re-cascade + wire emission on a Task spawned from the OCR
    /// worker's consumer queue.
    ///
    /// Drop-oldest queue overflow in the OCR worker means the
    /// completion callback may never fire for this submission. That
    /// is the documented fire-and-forget arm (`ocr_dropped_count`
    /// telemetry surface; ADR-0016 §3); the emitter does NOT emit any
    /// wire frame for a dropped submission. This is correct per the
    /// privacy invariants — a frame the helper could not OCR is
    /// indistinguishable from a frame whose OCR text was empty; either
    /// way nothing usable flows downstream.
    func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput
    ) async
}

/// Production `OCRPostAllowEmitter` that wires `VisionOCRWorker` +
/// `SuppressionCascade` + `FrameSink` + `FrameSequence` together per
/// ADR-0016 §1.6 + §4.2.
public struct CascadeTwiceOCREmitter: OCRPostAllowEmitter {
    private let worker: VisionOCRWorker
    private let cascade: SuppressionCascade
    private let sink: any FrameSink
    private let sequence: FrameSequence
    private let counters: HelperHealthCounters

    public init(
        worker: VisionOCRWorker,
        cascade: SuppressionCascade,
        sink: any FrameSink,
        sequence: FrameSequence,
        counters: HelperHealthCounters
    ) {
        self.worker = worker
        self.cascade = cascade
        self.sink = sink
        self.sequence = sequence
        self.counters = counters
    }

    public func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput
    ) async {
        let cascadeSnapshot = cascade
        let sinkSnapshot = sink
        let sequenceSnapshot = sequence
        let countersSnapshot = counters
        await worker.submit(input: input) { result in
            // Completion is `@Sendable`; spawn a Task to drive the
            // §6 re-cascade + wire emission in an async context.
            Task {
                await CascadeTwiceOCREmitter.handleOCRResult(
                    tsUs: tsUs,
                    context: context,
                    result: result,
                    cascade: cascadeSnapshot,
                    sink: sinkSnapshot,
                    sequence: sequenceSnapshot,
                    counters: countersSnapshot
                )
            }
        }
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
        counters: HelperHealthCounters
    ) async {
        let text = result.recognizedLines.map(\.text).joined(separator: "\n")
        let decision = cascade.decideOcr(text: text, context: context)
        switch decision {
        case .suppress(let reason):
            // §6 fired — never emit OCREvent on this path. Tombstone
            // carries the reason (.ocrTimeSecret); no OCR text bytes
            // reach the wire.
            await emitTombstone(
                tsUs: tsUs,
                context: context,
                reason: reason,
                sink: sink,
                sequence: sequence,
                counters: counters
            )

        case .allow:
            // Both cascades cleared — emit OCREvent, subject to the
            // 64 KB cap. Over-cap fails closed per ADR-0013 §7.
            let seq = await sequence.allocate()
            let evt = OCREvent(
                seq: seq,
                tsUs: tsUs,
                appBundleId: context.appBundleId ?? "",
                windowTitle: context.windowTitle ?? "",
                url: context.url ?? "",
                ocrText: text
            )
            switch encodeOCREvent(seq: seq, event: evt) {
            case .success(let bytes):
                try? await sink.write(bytes)
            case .failure:
                // Over-cap or field overflow ⇒ fail closed: tombstone
                // with reason 7 (catchall). The same arm both ADR-0013
                // §7 and ADR-0016 §4.9 mandate.
                await emitTombstone(
                    tsUs: tsUs,
                    context: context,
                    reason: .failsafeUnknown,
                    sink: sink,
                    sequence: sequence,
                    counters: counters
                )
            }
        }
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
