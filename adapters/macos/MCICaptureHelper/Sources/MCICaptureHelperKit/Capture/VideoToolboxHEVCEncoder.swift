// SPDX-License-Identifier: TBD-private
//
// VideoToolboxHEVCEncoder — the HEVC keyframe encode call-site
// (DOGFOOD_V1 #3). PROTECTED-SET per AGENT_PROTOCOL §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ THE STRUCTURAL FACTS THAT MAKE THIS SAFE                         │
// │                                                                  │
// │ 1. `FrameEncoder` is invoked ONLY from `SCStreamPipeline.process` │
// │    on the `.allow` branch — i.e. AFTER the ADR-0013              │
// │    `SuppressionCascade` returned `.allow`. A `.suppress` decision │
// │    returns before that branch, so the encoder is, by             │
// │    construction, UNREACHABLE for a suppressed event (Amendment 1 │
// │    §3(a)/(c)).                                                   │
// │                                                                  │
// │ 2. The pipeline's single top-level `defer { lease.release() }`   │
// │    releases the IOSurface back to the SCStream pool on EVERY     │
// │    exit — including a throwing `encodeAllowedFrame(...)`. The    │
// │    encoder may take a bounded session-internal retain on the     │
// │    `CVPixelBuffer` for the duration of the encode call but the   │
// │    OS pool-lease is freed promptly. Amendment 1 §3(d) is         │
// │    preserved.                                                    │
// │                                                                  │
// │ 3. DEFAULT-OFF (Amendment 1 §4). This encoder is wired into the  │
// │    `--capture` dev path only (`main.swift`). Flipping            │
// │    `CaptureLaunchOptions.captureEnabled` to default-ON requires  │
// │    the §7 corpus + CSO sign-off — that is NOT this PR.           │
// │                                                                  │
// │ 4. Encoded `CMSampleBuffer`s are handed to `EncodedSampleSink`   │
// │    (in-memory queue in DOGFOOD #3) — they are NOT persisted to   │
// │    disk anywhere in this PR. The next-PR OCR worker wire-up      │
// │    (DOGFOOD #4) consumes from that sink.                         │
// └──────────────────────────────────────────────────────────────────┘
//
// Encoder configuration policy (HEVC, low-latency, screen content):
//   - HEVC (H.265): smaller than H.264 at equal quality → §4 footprint.
//   - keyframe-only (`MaxKeyFrameInterval = 1`): every produced sample
//     is an IDR. No P/B inter-frame prediction → each recall frame is
//     independently decodable, AND no pixel data from a suppressed
//     neighbour can leak via a P/B reference.
//   - `AllowFrameReordering = false`: bounded latency + reinforces the
//     no-cross-frame-reference property above.
//   - `MaxFrameDelayCount = 0` (CRS arxiv/OSS scout, cycle 8.8): the
//     encoder may not buffer frames before emitting — required for the
//     "encode → sink within one async hop" lifecycle the pipeline
//     `defer` lease release depends on.
//   - `MaximizePowerEfficiency = true`: §4 footprint over an all-day
//     session.
//   - `RealTime = false`: capture is event-driven (~10⁰–10¹ Hz), not a
//     live video call; the non-realtime path is more efficient.
//   - `ProfileLevel = HEVC_Main_AutoLevel`: broad decoder compatibility;
//     auto-level keeps the encoder from rejecting unusual screen sizes.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// HEVC keyframe-encode configuration policy. Pure value type — no
/// `VTCompressionSession` is created to read these, so the policy is
/// reviewable and unit-testable headlessly.
public struct HEVCEncodeConfig: Sendable, Equatable {
    /// HEVC (H.265). DESIGN.md §5.3 — HEVC keyframes for the recall
    /// timeline; smaller than H.264 at equal quality ⇒ footprint.
    public let codec: CMVideoCodecType
    /// Keyframe-only: every stored frame is an IDR. No inter-frame
    /// prediction ⇒ each recall frame is independently decodable and
    /// no pixel data from a suppressed neighbour can leak via a P/B
    /// reference. (Also why `allowFrameReordering` MUST be false.)
    public let keyframeOnly: Bool
    /// No B-frames / no reordering — bounded latency + the
    /// no-cross-frame-reference property above.
    public let allowFrameReordering: Bool
    /// Prefer the power-efficient (ProRes/ANE-assisted) path — the §4
    /// footprint budget over an all-day session.
    public let maximizePowerEfficiency: Bool
    /// Not realtime: capture is event-driven (~10⁰–10¹ Hz), not a
    /// live video call; the non-realtime path is more efficient.
    public let realtime: Bool
    /// Maximum encoder-internal frame delay before an emit. `0` keeps
    /// the encoder from buffering frames, so the per-frame output
    /// handler fires inside the encode call — the lifecycle the
    /// pipeline's `defer { lease.release() }` depends on.
    public let maxFrameDelayCount: Int

    public static let `default` = HEVCEncodeConfig(
        codec: kCMVideoCodecType_HEVC,
        keyframeOnly: true,
        allowFrameReordering: false,
        maximizePowerEfficiency: true,
        realtime: false,
        maxFrameDelayCount: 0
    )

    public init(
        codec: CMVideoCodecType,
        keyframeOnly: Bool,
        allowFrameReordering: Bool,
        maximizePowerEfficiency: Bool,
        realtime: Bool,
        maxFrameDelayCount: Int = 0
    ) {
        self.codec = codec
        self.keyframeOnly = keyframeOnly
        self.allowFrameReordering = allowFrameReordering
        self.maximizePowerEfficiency = maximizePowerEfficiency
        self.realtime = realtime
        self.maxFrameDelayCount = maxFrameDelayCount
    }

    /// The `VTCompressionSession` property dictionary this policy maps
    /// to. PURE — builds a dictionary of VideoToolbox property-key
    /// constants; creates no session. Unit-tested.
    public func sessionProperties() -> [CFString: Any] {
        var props: [CFString: Any] = [
            kVTCompressionPropertyKey_AllowFrameReordering: allowFrameReordering as CFBoolean,
            kVTCompressionPropertyKey_MaximizePowerEfficiency: maximizePowerEfficiency as CFBoolean,
            kVTCompressionPropertyKey_RealTime: realtime as CFBoolean,
            kVTCompressionPropertyKey_MaxFrameDelayCount: maxFrameDelayCount as CFNumber,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
        ]
        if keyframeOnly {
            // Every emitted frame is a keyframe (IDR). Belt-and-braces
            // with the per-frame `kVTEncodeFrameOptionKey_ForceKeyFrame`
            // set at encode time.
            props[kVTCompressionPropertyKey_MaxKeyFrameInterval] = 1 as CFNumber
        }
        return props
    }
}

/// Encoder error surface. Any non-zero `OSStatus` from VideoToolbox is
/// surfaced as `.encodeFailed`; the missing-sample-buffer success-with-
/// nil edge case becomes `.noSampleBuffer`. Both propagate out of
/// `encodeAllowedFrame(...)` so the pipeline's `defer` runs and the
/// lease releases (Amendment 1 §3(d) — proven by
/// `RetainedSurfaceLifecycleTests`).
public enum HEVCEncoderError: Error, Equatable {
    /// `VTCompressionSessionCreate` returned non-zero.
    case sessionCreateFailed(OSStatus)
    /// `VTCompressionSessionEncodeFrame` returned non-zero (immediate
    /// or via the per-frame output handler).
    case encodeFailed(OSStatus)
    /// The output handler reported success but the sample buffer was
    /// `nil` — should not happen in practice; surfaced rather than
    /// silently swallowed so the pipeline's encode-error path runs.
    case noSampleBuffer
}

/// The production HEVC encoder.
///
/// `@unchecked Sendable`: the only mutable state is the lazily-created
/// session + observable counters, all `NSLock`-guarded.
public final class VideoToolboxHEVCEncoder: FrameEncoder, @unchecked Sendable {
    public let config: HEVCEncodeConfig
    private let sink: any EncodedSampleSink

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var sessionWidth: Int = 0
    private var sessionHeight: Int = 0
    private var allowedFrames: Int = 0
    private var emittedSamples: Int = 0

    /// Construct an encoder that delivers IDR samples to `sink`.
    ///
    /// The session is NOT created in `init` — it is created lazily on
    /// the first non-nil `EncoderInput`, sized from that input's
    /// pixel-buffer dimensions, and re-created on dimension change. A
    /// pre-created session for "no dimensions yet" would either pick a
    /// wrong shape or block the constructor on an OS call neither of
    /// which fits the pipeline's hot path.
    public init(
        config: HEVCEncodeConfig = .default,
        sink: any EncodedSampleSink
    ) {
        self.config = config
        self.sink = sink
    }

    deinit {
        // Best-effort: invalidate the session so VideoToolbox releases
        // its internal pool retains before this encoder vanishes. The
        // pipeline lease lifecycle is the authoritative discipline; this
        // is only the per-process teardown.
        if let s = session {
            VTCompressionSessionInvalidate(s)
        }
    }

    /// Called ONLY on the cascade's `.allow` branch (see the header).
    ///
    /// `input == nil` is the headless / OS-free path — the call site
    /// records that an allowed frame reached the encoder (the observable
    /// the OS-free pipeline tests assert) and returns. No
    /// `VTCompressionSession` is created and no sample is emitted.
    ///
    /// `input != nil` is the live path — lazily create / re-create the
    /// `VTCompressionSession` for the input's dimensions, submit one
    /// keyframe-only encode, await the per-frame output handler, hand
    /// the resulting `CMSampleBuffer` to the sink. Throws on any
    /// VideoToolbox error so the pipeline's `defer` runs.
    public func encodeAllowedFrame(
        input: EncoderInput?,
        seq: UInt64,
        context: WorkflowContext
    ) async throws {
        recordAllowedFrame()
        guard let input else { return }

        let session = try ensureSession(width: input.widthPx, height: input.heightPx)

        // Presentation timestamp threaded from `seq` so the produced
        // sample buffer carries a monotonically increasing PTS even
        // though the capture cadence is irregular. Resolution 1µs.
        let pts = CMTime(value: CMTimeValue(seq), timescale: 1_000_000)
        let frameProperties: CFDictionary = [
            kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!,
        ] as CFDictionary

        // Wrap the per-frame output handler in a one-shot continuation
        // so the encoder's `async throws` shape stays clean. The
        // handler MUST resume exactly once: an immediate failure from
        // `VTCompressionSessionEncodeFrame` means the handler never
        // fires, so we resume on the immediate-error path; a successful
        // submit means the handler fires (synchronous-ish under
        // `MaxFrameDelayCount = 0`) and resumes there.
        let sampleBox: SampleBox = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SampleBox, Error>) in
            let latch = OneShotLatch()
            var infoFlags = VTEncodeInfoFlags(rawValue: 0)
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: input.pixelBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: frameProperties,
                infoFlagsOut: &infoFlags
            ) { handlerStatus, _, sampleBuffer in
                latch.fire {
                    if handlerStatus != noErr {
                        cont.resume(throwing: HEVCEncoderError.encodeFailed(handlerStatus))
                    } else if let sb = sampleBuffer {
                        cont.resume(returning: SampleBox(sb))
                    } else {
                        cont.resume(throwing: HEVCEncoderError.noSampleBuffer)
                    }
                }
            }
            if status != noErr {
                // The per-frame handler is NOT invoked on immediate
                // failure (VideoToolbox documents the handler as
                // contingent on the encode being accepted). Resume the
                // continuation directly. The latch guards against the
                // theoretical handler-already-fired race.
                latch.fire {
                    cont.resume(throwing: HEVCEncoderError.encodeFailed(status))
                }
            }
        }

        recordEmittedSample()
        await sink.handle(EncodedSample(
            sampleBuffer: sampleBox.buffer,
            seq: seq,
            context: context,
            widthPx: input.widthPx,
            heightPx: input.heightPx
        ))
    }

    /// Test/observability hook: how many allowed frames reached the
    /// encode call site. Used by the OS-free pipeline tests to prove
    /// the encoder is invoked on `.allow` and NEVER on `.suppress` /
    /// filtered-out.
    public func allowedFrameCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return allowedFrames
    }

    /// Test/observability hook: how many encoded `CMSampleBuffer`s
    /// were handed to the sink. Distinct from `allowedFrameCount()`
    /// because a `nil` `EncoderInput` (OS-free path) increments the
    /// former but not the latter.
    public func emittedSampleCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return emittedSamples
    }

    /// Test-only: tear down the session so a subsequent encode forces
    /// a fresh `VTCompressionSessionCreate`. Used by the size-change
    /// regression test.
    internal func invalidateSessionForTest() {
        lock.lock(); defer { lock.unlock() }
        if let s = session {
            VTCompressionSessionInvalidate(s)
        }
        session = nil
        sessionWidth = 0
        sessionHeight = 0
    }

    // MARK: - Internals

    private func recordAllowedFrame() {
        lock.lock(); allowedFrames += 1; lock.unlock()
    }

    private func recordEmittedSample() {
        lock.lock(); emittedSamples += 1; lock.unlock()
    }

    /// Return the active `VTCompressionSession`, creating (or
    /// re-creating on dimension change) it under the lock.
    private func ensureSession(width: Int, height: Int) throws -> VTCompressionSession {
        lock.lock()
        defer { lock.unlock() }

        if let existing = session, sessionWidth == width, sessionHeight == height {
            return existing
        }
        if let existing = session {
            VTCompressionSessionInvalidate(existing)
            session = nil
        }

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: config.codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,   // per-frame output handler at encode time
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let created = newSession else {
            throw HEVCEncoderError.sessionCreateFailed(status)
        }

        for (key, value) in config.sessionProperties() {
            // Best-effort property apply. A property the running OS
            // does not recognize is silently skipped — the encoder
            // still produces frames; the policy degrades, not fails.
            VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        sessionWidth = width
        sessionHeight = height
        return created
    }
}

/// Exactly-once gate around the per-frame output continuation. The
/// `VTCompressionSessionEncodeFrame` handler is contractually called
/// at most once per encode, but a defensive latch lets us reason
/// locally about the immediate-error path resuming the continuation
/// without colliding with a (theoretically-impossible) handler call.
private final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ block: () -> Void) {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        lock.unlock()
        block()
    }
}

/// `@unchecked Sendable` envelope so the throwing continuation can
/// resume with a `CMSampleBuffer` across the encoder's async
/// boundary. The buffer is a reference type but is single-owner
/// here — produced by the per-frame handler, immediately handed to
/// the sink, never touched again.
private struct SampleBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}
