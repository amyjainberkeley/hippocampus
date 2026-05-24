// SPDX-License-Identifier: TBD-private
//
// EncoderIO — the Sendable input/output value types for the
// `FrameEncoder` seam (enabler PR-3 wiring). PROTECTED-SET per
// AGENT_PROTOCOL §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ WHY THESE EXIST                                                  │
// │                                                                  │
// │ Pre-DOGFOOD#3 the `FrameEncoder` seam carried no pixel buffer    │
// │ (see PR #18 header). To plug in a real `VTCompressionSession`    │
// │ the encoder needs the captured surface AND a place to hand the   │
// │ produced `CMSampleBuffer` (the HEVC IDR keyframe) to so the      │
// │ next-PR OCR worker (DOGFOOD #4) can consume it. `EncoderInput`   │
// │ is the input value type; `EncodedSampleSink` is the output       │
// │ contract; `EncodedSample` is the value that crosses it. All      │
// │ three are `Sendable` (`@unchecked` for the CV/CM ref types,      │
// │ matching `OCREngineInput`'s convention) so the encoder can run   │
// │ from inside the `SCStreamPipeline.process(...)` task without an  │
// │ isolation escape hatch.                                          │
// │                                                                  │
// │ STRUCTURAL GUARANTEE (Amendment 1 §3(a)/(c)) preserved by        │
// │ construction: the only producer of an `EncoderInput` is the      │
// │ `SCStreamCaptureSession` callback; the only consumer is the      │
// │ pipeline's single encode call site behind `.allow`. A            │
// │ suppressed frame never builds an input; an allow-path encode    │
// │ that throws still releases the surface lease via the pipeline's │
// │ top-level `defer { lease.release() }` (Amendment 1 §3(d)).      │
// └──────────────────────────────────────────────────────────────────┘

import CoreMedia
import CoreVideo
import Foundation

/// One frame's pixel input to the encoder. `@unchecked Sendable`
/// because `CVPixelBuffer` is a reference type; the wrapper documents
/// the ownership rule — the pipeline transfers the buffer to the
/// encoder for the duration of one `encodeAllowedFrame(...)` call, and
/// the encoder must not mutate it. This mirrors `OCREngineInput`.
///
/// `widthPx` / `heightPx` are sourced from the buffer at construction
/// so the encoder does not need to read CoreVideo metadata on its hot
/// path; it sizes its `VTCompressionSession` from these values and
/// re-creates the session on dimension change (lazy create per shape).
public struct EncoderInput: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let widthPx: Int
    public let heightPx: Int

    public init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        self.widthPx = CVPixelBufferGetWidth(pixelBuffer)
        self.heightPx = CVPixelBufferGetHeight(pixelBuffer)
    }
}

/// One encoded HEVC keyframe + the original `(seq, context)` so the
/// downstream sink can correlate to the cascade's allow decision.
/// `@unchecked Sendable` for the same reason as `EncoderInput`:
/// `CMSampleBuffer` is reference-typed but the wrapper is one-shot
/// — the encoder produces it, hands it to the sink, never touches
/// it again.
public struct EncodedSample: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let seq: UInt64
    public let context: WorkflowContext
    public let widthPx: Int
    public let heightPx: Int

    public init(
        sampleBuffer: CMSampleBuffer,
        seq: UInt64,
        context: WorkflowContext,
        widthPx: Int,
        heightPx: Int
    ) {
        self.sampleBuffer = sampleBuffer
        self.seq = seq
        self.context = context
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// Downstream consumer of encoded keyframes. DOGFOOD #3 ships the
/// `InMemoryEncodedSampleQueue` impl below as the default; DOGFOOD #4
/// (next PR) wires this to the Vision OCR worker. The seam is here
/// so the encoder is testable in isolation without dragging in the
/// OCR stack.
///
/// `Sendable`: the encoder runs from inside the pipeline's async task
/// path; the sink must be safe to call from any actor.
public protocol EncodedSampleSink: Sendable {
    /// Receive one encoded keyframe. MUST NOT throw — the encoder
    /// fire-and-forwards; sink-side back-pressure is the sink's
    /// concern (drop-oldest, queue cap, etc.).
    func handle(_ sample: EncodedSample) async
}

/// The default in-memory sink. Bounded ring buffer; on overflow the
/// oldest sample is dropped (so the encoder is never the back-pressure
/// surface — the §4 footprint budget is the sink's hard cap, not the
/// encoder's hot path).
///
/// `drain()` / `count()` are observability hooks for the next-PR OCR
/// wire-up to pull from. NOT on the wire; NOT persisted to disk in
/// DOGFOOD #3 (that's gated by ADR-0013 Amendment 1 §4).
public actor InMemoryEncodedSampleQueue: EncodedSampleSink {
    private var samples: [EncodedSample] = []
    private let maxBacklog: Int

    public init(maxBacklog: Int = 256) {
        self.maxBacklog = maxBacklog
    }

    public func handle(_ sample: EncodedSample) async {
        samples.append(sample)
        if samples.count > maxBacklog {
            samples.removeFirst(samples.count - maxBacklog)
        }
    }

    /// How many samples are currently buffered. Test/observability.
    public func count() -> Int { samples.count }

    /// Pull every buffered sample and clear the queue. The next-PR
    /// OCR consumer calls this on its own cadence; until then it is
    /// a test hook.
    public func drain() -> [EncodedSample] {
        let s = samples
        samples.removeAll(keepingCapacity: true)
        return s
    }
}
