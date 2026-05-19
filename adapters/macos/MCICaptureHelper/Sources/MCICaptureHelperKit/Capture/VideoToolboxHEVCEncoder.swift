// SPDX-License-Identifier: TBD-private
//
// VideoToolboxHEVCEncoder — the HEVC keyframe encode call-site
// (enabler PR-3). PROTECTED-SET per AGENT_PROTOCOL §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ THE ONE STRUCTURAL FACT THAT MAKES THIS SAFE                     │
// │                                                                  │
// │ This type conforms to `FrameEncoder`. The ONLY caller of any     │
// │ `FrameEncoder` in the codebase is `SCStreamPipeline.process`'s   │
// │ `case .allow:` branch (landed PR #15) — i.e. AFTER the ADR-0013  │
// │ `SuppressionCascade` returned `.allow`. There is no other call   │
// │ site. A `.suppress` decision returns before that branch, so the  │
// │ encoder is, by construction, UNREACHABLE for a suppressed event  │
// │ (Amendment 1 §3(a)/(c)). PR-3 changes only WHICH `FrameEncoder`  │
// │ implementation exists; it adds no new call site and does not     │
// │ touch the cascade.                                               │
// │                                                                  │
// │ The live `VTCompressionSession` create / encode is              │
// │ `// UNVERIFIED — needs live macOS; do not claim working`. The    │
// │ encode CONFIGURATION POLICY (HEVC, keyframe-only, no frame       │
// │ reordering, power-efficient) is pure and IS unit-tested.         │
// │                                                                  │
// │ DEFAULT-OFF (Amendment 1 §4): this encoder is NOT wired into any │
// │ default or `--capture` path. `main.swift` still constructs the   │
// │ no-op `DeferredVideoToolboxEncoder`. Making this the live        │
// │ encoder that emits stored bytes is a CSO-gated default flip      │
// │ behind the green §7 corpus — NOT an autonomous change.           │
// └──────────────────────────────────────────────────────────────────┘

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

    public static let `default` = HEVCEncodeConfig(
        codec: kCMVideoCodecType_HEVC,
        keyframeOnly: true,
        allowFrameReordering: false,
        maximizePowerEfficiency: true,
        realtime: false
    )

    public init(
        codec: CMVideoCodecType,
        keyframeOnly: Bool,
        allowFrameReordering: Bool,
        maximizePowerEfficiency: Bool,
        realtime: Bool
    ) {
        self.codec = codec
        self.keyframeOnly = keyframeOnly
        self.allowFrameReordering = allowFrameReordering
        self.maximizePowerEfficiency = maximizePowerEfficiency
        self.realtime = realtime
    }

    /// The `VTCompressionSession` property dictionary this policy maps
    /// to. PURE — builds a dictionary of VideoToolbox property-key
    /// constants; creates no session. Unit-tested.
    public func sessionProperties() -> [CFString: Any] {
        [
            kVTCompressionPropertyKey_AllowFrameReordering: allowFrameReordering as CFBoolean,
            kVTCompressionPropertyKey_MaximizePowerEfficiency: maximizePowerEfficiency as CFBoolean,
            kVTCompressionPropertyKey_RealTime: realtime as CFBoolean,
        ]
    }
}

/// The production HEVC encoder SHAPE.
///
/// `@unchecked Sendable`: the only mutable state is the lazily-created
/// session + an observable counter, both `NSLock`-guarded.
public final class VideoToolboxHEVCEncoder: FrameEncoder, @unchecked Sendable {
    public let config: HEVCEncodeConfig

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var allowedFrames: Int = 0

    public init(config: HEVCEncodeConfig = .default) {
        self.config = config
    }

    /// Called ONLY on the cascade's `.allow` branch (see the header).
    ///
    /// The `FrameEncoder` seam deliberately carries NO pixel buffer:
    /// the retained surface (PR-2's `SurfaceLease`) is threaded to the
    /// encoder by a later wiring step (live integration / PR-4), under
    /// the §7-corpus gate. Until then this method has nothing to
    /// encode and emits nothing — so even on the dev `--capture` path
    /// it stores no frame (Amendment 1 §3(c) / §4). It records that an
    /// allowed frame reached the encode call site, which is the
    /// observable the OS-free pipeline tests assert.
    public func encodeAllowedFrame(seq _: UInt64, context _: WorkflowContext) async throws {
        recordAllowedFrame()

        // UNVERIFIED — needs live macOS; do not claim working.
        //
        // Live wiring (gated; NOT this PR): lazily
        // `VTCompressionSessionCreate` with `config.sessionProperties()`
        // for the captured dimensions, then
        // `VTCompressionSessionEncodeFrame(session, retainedPixelBuffer,
        // …, forceKeyframe: true)` and hand the resulting
        // `CMSampleBuffer` (one IDR) to the IPC `FrameSink`. No pixel
        // buffer is in scope here by design, so this branch is
        // unreachable in every current build — there is nothing to
        // store and nothing to leak.
    }

    // Locked mutation lives in a non-async helper: `NSLock` is
    // unavailable from async contexts under Swift 6 strict concurrency.
    private func recordAllowedFrame() {
        lock.lock(); allowedFrames += 1; lock.unlock()
    }

    /// Test/observability hook: how many allowed frames reached the
    /// encode call site. Used by the OS-free pipeline tests to prove
    /// the encoder is invoked on `.allow` and NEVER on `.suppress` /
    /// filtered-out.
    public func allowedFrameCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return allowedFrames
    }
}
