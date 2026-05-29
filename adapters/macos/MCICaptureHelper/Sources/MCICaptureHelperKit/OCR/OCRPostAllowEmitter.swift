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
// P3.6.5: keyframe blob writes are now wired. When a
// `KeyframeBlobWriter` is present, the emitter encodes the captured
// CVPixelBuffer as a downscaled encrypted JPEG, puts the sha256 in
// the OCREvent.keyframeHash field, and fire-and-forgets the file
// write via the blob writer's drop-oldest queue.

import CoreGraphics
import CoreVideo
import CryptoKit
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
    /// CSO escalation 2026-05-29 — capture-scope cross-window leak
    /// kill-switch (Phase A interim mitigation, option M4 in
    /// `docs/research/capture-scope-window-vs-display-2026-05-29.md`).
    ///
    /// `true` ⇒ every `processAfterAllow` invocation emits a
    /// `PrivacyTombstone(failsafeUnknown)` instead of submitting the
    /// pixel buffer to the Vision OCR worker. While `true`, no OCR
    /// text bytes from the whole-display `SCStream` sample reach the
    /// brain — the cross-window leak documented in the memo cannot
    /// occur because the OCR pipeline is short-circuited at the
    /// emit-or-suppress fork.
    ///
    /// Flips back to `false` in a single-line edit when the §7
    /// falsifiability corpus in the memo is green and CSO signs off
    /// on the architectural fix (Option (a) — focused-window
    /// `SCContentFilter`) landing. ADR-0013 §3 fail-safe-default-
    /// redact + Amendment 1 §3(b) fail-closed posture preserved
    /// structurally — the tombstone IS the redact path.
    ///
    /// PROTECTED-SET per AGENT_PROTOCOL §5.
    ///
    /// Declared `var` (not `let`) only so existing cascade-twice unit
    /// tests in `CascadeTwiceOCREmitterTests` can scope-override it
    /// to exercise the OCR-emit path. Production code paths never
    /// mutate this — flipping the kill-switch off ships as a single-
    /// line source edit, not a runtime mutation. The
    /// `nonisolated(unsafe)` annotation is required by Swift 6 strict
    /// concurrency for a static `var`; safe here because writes are
    /// confined to test setup/teardown and reads in production are
    /// pure load.
    nonisolated(unsafe) internal static var killOcrEmit: Bool = true

    private let worker: VisionOCRWorker
    private let cascade: SuppressionCascade
    private let sink: any FrameSink
    private let sequence: FrameSequence
    private let counters: HelperHealthCounters
    /// P3.6.5: encrypted keyframe blob writer. `nil` when no DbKey
    /// is available (MCI_DB_KEY_HEX not set) — OCREvents carry
    /// `keyframeHash = [0; 32]` ("no blob"). CSO invariant: blob
    /// writes happen ONLY on .allow paths (ADR-0016 §4.8).
    private let blobWriter: KeyframeBlobWriter?
    /// P3.6.5: 32-byte DbKey material for per-blob HKDF key derivation.
    /// Read from `MCI_DB_KEY_HEX` at helper launch, never logged.
    private let blobKeyMaterial: [UInt8]

    public init(
        worker: VisionOCRWorker,
        cascade: SuppressionCascade,
        sink: any FrameSink,
        sequence: FrameSequence,
        counters: HelperHealthCounters,
        blobWriter: KeyframeBlobWriter? = nil,
        blobKeyMaterial: [UInt8] = []
    ) {
        self.worker = worker
        self.cascade = cascade
        self.sink = sink
        self.sequence = sequence
        self.counters = counters
        self.blobWriter = blobWriter
        self.blobKeyMaterial = blobKeyMaterial
    }

    public func processAfterAllow(
        tsUs: UInt64,
        context: WorkflowContext,
        input: OCREngineInput
    ) async {
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
            return
        }

        let cascadeSnapshot = cascade
        let sinkSnapshot = sink
        let sequenceSnapshot = sequence
        let countersSnapshot = counters
        let blobWriterSnapshot = blobWriter
        let blobKeySnapshot = blobKeyMaterial
        // P3.6.5: capture the pixel buffer reference for the blob
        // writer. OCREngineInput is @unchecked Sendable; the pixel
        // buffer stays alive until the job completes (held by the
        // worker's Job struct + this captured reference).
        let inputSnapshot = input
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
                    counters: countersSnapshot,
                    pixelBuffer: inputSnapshot.pixelBuffer,
                    blobWriter: blobWriterSnapshot,
                    blobKeyMaterial: blobKeySnapshot
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
        counters: HelperHealthCounters,
        pixelBuffer: CVPixelBuffer? = nil,
        blobWriter: KeyframeBlobWriter? = nil,
        blobKeyMaterial: [UInt8] = []
    ) async {
        let text = result.recognizedLines.map(\.text).joined(separator: "\n")
        let decision = cascade.decideOcr(text: text, context: context)
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
            // Both cascades cleared — emit OCREvent, subject to the
            // 64 KB cap. Over-cap fails closed per ADR-0013 §7.

            // P3.6.5: encode + encrypt the keyframe blob. Best-effort;
            // failure → keyframeHash = [0; 32] (graceful degradation).
            // The blob is written ONLY on .allow paths (ADR-0016 §4.8).
            var keyframeHash = [UInt8](repeating: 0, count: 32)
            if let pb = pixelBuffer,
               let bw = blobWriter,
               !blobKeyMaterial.isEmpty
            {
                if let blob = KeyframeBlobEncoder.encodeAndEncrypt(
                    pixelBuffer: pb,
                    blobKeyMaterial: blobKeyMaterial
                ) {
                    keyframeHash = blob.sha256
                    // Fire-and-forget: queue the file write. Drop-oldest
                    // protects against disk I/O backpressure.
                    await bw.queueWrite(sha256: blob.sha256, ciphertext: blob.ciphertext)
                }
            }

            let seq = await sequence.allocate()
            let evt = OCREvent(
                seq: seq,
                tsUs: tsUs,
                appBundleId: context.appBundleId ?? "",
                windowTitle: context.windowTitle ?? "",
                url: context.url ?? "",
                ocrText: text,
                keyframeHash: keyframeHash
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
