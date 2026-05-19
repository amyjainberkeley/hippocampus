// SPDX-License-Identifier: TBD-private
//
// SCStreamPipeline — the ScreenCaptureKit wiring SHAPE (PRIORITY-REDIRECT P2).
//
// LAUNCH-BLOCKER per AGENT_PROTOCOL §4 / R5. PROTECTED-SET per §5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ HEADLESS-VERIFICATION HONESTY                                     │
// │                                                                  │
// │ Everything that touches a live screen — `SCShareableContent`,    │
// │ `SCStream`, the real `SCStreamOutput` callback, IOSurface pool   │
// │ retains, VideoToolbox encode — CANNOT be runtime-verified on a   │
// │ headless / CI machine. Those members are marked                  │
// │ `// UNVERIFIED — needs live macOS; do not claim working`.        │
// │ This cycle delivers the *structure + call order* and an          │
// │ OS-free test that the suppression cascade runs BEFORE any        │
// │ encode call site (ADR-0013 §5). It does NOT and MUST NOT claim   │
// │ a working capture, a footprint number, or an ADR-0013 §7 result. │
// └──────────────────────────────────────────────────────────────────┘
//
// Binding ordering (ADR-0013 §5 — the whole reason this file exists):
//
//   SCStream callback
//     → SmartCaptureFilter (4-stage; cheap reject)
//       → SuppressionCascade.decide(context:)        ← MUST run here
//         → .suppress  ⇒ PrivacyTombstone, surface released, NO encode
//         → .allow     ⇒ FrameEncoder.encode(...)    ← only reachable
//                                                       after .allow
//
// The encoder is injected behind `FrameEncoder`. Its production
// VideoToolbox impl is a cycle-3 `// UNVERIFIED` stub here — per the
// PRIORITY REDIRECT we do NOT add a VideoToolbox encode that emits a
// stored frame; the encode call SITE is wired with the cascade
// unconditionally in front of it, and the OS-free test injects a spy
// encoder to prove the gate.

import Foundation
import ScreenCaptureKit

/// Builds the `SCStreamConfiguration` from the reviewed [`StreamPolicy`].
///
/// `showsCursor = false` is the single load-bearing footprint line
/// (RESEARCH_DIGEST Stream A); it is copied straight from the policy
/// and asserted by `SCStreamPipelineTests` so a future edit cannot
/// flip it silently.
public enum SCStreamConfigFactory {
    /// Construct an `SCStreamConfiguration` from `policy`.
    ///
    /// Pure value construction — no OS session is created here, so
    /// this *is* unit-testable headlessly (the type is from the SDK
    /// but instantiating the config object touches no screen).
    public static func makeConfiguration(policy: StreamPolicy = .default) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = policy.showsCursor // MUST be false (SLO).
        cfg.queueDepth = policy.queueDepth
        // 5 fps default → minimumFrameInterval = 1/5 s. CMTime with a
        // 1000-tick timescale keeps the ms policy exact.
        cfg.minimumFrameInterval = CMTime(
            value: CMTimeValue(policy.minimumFrameIntervalMs),
            timescale: 1000
        )
        return cfg
    }
}

/// Builds the `SCContentFilter` with the parsed [`Denylist`] app
/// bundles **actually installed as exclusions** (ADR-0013 §1 — the
/// source-level primitive; before P2 the denylist was parsed-but-
/// unused at the SCStream layer).
///
/// `// UNVERIFIED — needs live macOS; do not claim working`:
/// `SCShareableContent.current` is an async OS call that enumerates
/// real windows/displays and cannot run headlessly. The exclusion
/// *selection logic* (which running apps match the denylist) is the
/// reviewable part; it is factored into the pure
/// `excludedBundleIDs(...)` helper that IS unit-tested.
public enum SCContentFilterFactory {
    /// Pure selection: of the running-application bundle IDs the OS
    /// reports, which ones the denylist forbids capturing. Headlessly
    /// testable — no OS call.
    public static func excludedBundleIDs(
        runningBundleIDs: [String],
        denylist: Denylist
    ) -> [String] {
        runningBundleIDs.filter { denylist.appIsDenied(bundleId: $0) }
    }

    /// Build the display-scoped filter excluding every denylisted
    /// running application's windows.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public static func makeDisplayFilter(
        denylist: Denylist
    ) async throws -> SCContentFilter {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw SCStreamPipelineError.noDisplay
        }
        let runningIDs = content.applications.map(\.bundleIdentifier)
        let excludedIDs = Set(excludedBundleIDs(runningBundleIDs: runningIDs, denylist: denylist))
        let excludedApps = content.applications.filter {
            excludedIDs.contains($0.bundleIdentifier)
        }
        // §1: denylisted apps' windows never enter the capture surface.
        return SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
    }
}

/// Errors the SCStream pipeline surfaces.
public enum SCStreamPipelineError: Error, Equatable {
    /// `SCShareableContent` reported no display.
    case noDisplay
    /// An encode was attempted without a prior `.allow` decision —
    /// an internal invariant breach. Should be impossible by
    /// construction; asserted so a refactor can't regress the gate.
    case encodeBeforeCascade
}

/// An owned, opaque lease on one captured surface.
///
/// Replaces the documentation-only `'static` placeholder note in
/// `core::capture` *on the Swift side*: the helper holds the
/// `CMSampleBuffer` / IOSurface pool retain for exactly as long as the
/// ADR-0007 per-frame ack discipline requires, then `release()`s it so
/// the OS pool does not stall (the §4 footprint failure mode).
///
/// `// UNVERIFIED — needs live macOS; do not claim working`: the real
/// retain/relinquish is exercised only against a live `SCStream`. The
/// lease *lifecycle* (exactly-once release; release-on-suppress) is
/// modeled with an injected `SurfaceReleasing` so it can be unit-tested
/// without a pool.
public protocol SurfaceReleasing: Sendable {
    /// Relinquish the OS surface retain. MUST be called exactly once
    /// per delivered sample buffer (on encode-done OR on suppression).
    func releaseSurface()
}

public final class SurfaceLease: @unchecked Sendable {
    private let releaser: any SurfaceReleasing
    private var released = false
    private let lock = NSLock()

    public init(releaser: any SurfaceReleasing) {
        self.releaser = releaser
    }

    /// Idempotent at the API surface but logs a soft invariant breach
    /// in debug if called twice — exactly-once is the contract.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else {
            assertionFailure("SurfaceLease released twice — ADR-0007 ack discipline breach")
            return
        }
        released = true
        releaser.releaseSurface()
    }

    public var isReleased: Bool {
        lock.lock(); defer { lock.unlock() }
        return released
    }
}

/// The encode seam. Production impl = VideoToolbox HEVC keyframe
/// encode (cycle 3). Per the PRIORITY REDIRECT this file does NOT
/// add that encoder — only the call site, unconditionally behind the
/// cascade. Tests inject a spy.
public protocol FrameEncoder: Sendable {
    /// Encode an allowed frame. Called ONLY after
    /// `SuppressionCascade.decide(...)` returned `.allow`.
    func encodeAllowedFrame(seq: UInt64, context: WorkflowContext) async throws
}

/// Cycle-3 production encoder placeholder.
///
/// `// UNVERIFIED — needs live macOS; do not claim working`. It
/// deliberately does nothing and is NOT wired into a runnable path
/// that stores a frame — wiring real VideoToolbox here without the
/// cascade in front would violate the PRIORITY REDIRECT. It exists so
/// the call site type-checks; cycle 3 replaces the body.
public struct DeferredVideoToolboxEncoder: FrameEncoder {
    public init() {}
    public func encodeAllowedFrame(seq _: UInt64, context _: WorkflowContext) async throws {
        // UNVERIFIED — needs live macOS; do not claim working.
        // Intentionally empty: cycle 3 lands the VideoToolbox HEVC
        // keyframe encode here, gated by the cascade above this call.
    }
}

/// The capture pipeline: the SCStream callback path with the cascade
/// wired unconditionally in front of the encode call site.
///
/// `process(...)` is the OS-free core of the callback — it takes the
/// already-extracted filter inputs + workflow context (the real
/// `stream(_:didOutputSampleBuffer:of:)` adapter, which IS
/// `// UNVERIFIED`, just extracts those from the `CMSampleBuffer` and
/// calls this). Keeping the decision path OS-free is what makes the
/// ADR-0013 §5 ordering testable headlessly.
public struct SCStreamPipeline: Sendable {
    private let filter: SmartCaptureFilter
    private let cascade: SuppressionCascade
    private let encoder: any FrameEncoder
    private let counters: HelperHealthCounters
    private let sequence: FrameSequence
    private let sink: any FrameSink

    public init(
        filter: SmartCaptureFilter = SmartCaptureFilter(),
        cascade: SuppressionCascade,
        encoder: any FrameEncoder,
        counters: HelperHealthCounters = HelperHealthCounters(),
        sequence: FrameSequence = FrameSequence(),
        sink: any FrameSink
    ) {
        self.filter = filter
        self.cascade = cascade
        self.encoder = encoder
        self.counters = counters
        self.sequence = sequence
        self.sink = sink
    }

    /// What `process(...)` did with one candidate — returned so the
    /// OS-free test can assert the ordering invariant.
    public enum Outcome: Sendable, Equatable {
        /// Filter chain rejected the frame as not-new-content. No
        /// cascade, no encode, surface released.
        case filteredOut
        /// Cascade suppressed. Tombstone emitted, NO encode, surface
        /// released.
        case suppressed(reason: RedactionReason)
        /// Cascade allowed. Encoder invoked, then surface released.
        case encoded(seq: UInt64)
    }

    /// The OS-free decision + dispatch core. The live SCStream adapter
    /// calls this after extracting `frame` + `context` from the
    /// `CMSampleBuffer`.
    ///
    /// The surface `lease` is released **exactly once on every exit
    /// path** — via a single top-level `defer`. That covers the early
    /// filter-reject path, the suppress path, the allow path, AND the
    /// error paths where `sink.write` or `encoder.encodeAllowedFrame`
    /// throws. A dropped, suppressed, or failed frame can therefore
    /// never stall the IOSurface pool (§4); a throwing encoder no
    /// longer leaks the surface lease (PRE-LAND CYCLE item 3). The
    /// error still propagates — `defer` runs, then the throw unwinds.
    /// `SurfaceLease.release()` is itself exactly-once-guarded, so the
    /// single `defer` cannot double-release.
    public func process(
        frame: CandidateFrame,
        context: WorkflowContext,
        nowUs: UInt64,
        lease: SurfaceLease
    ) async throws -> Outcome {
        // Exactly-once release on EVERY path, including a throwing
        // `sink.write` / `encoder.encodeAllowedFrame`. Must be the
        // first statement so no early return / thrown error can
        // bypass it.
        defer { lease.release() }

        await counters.recordDelivered()

        // Stage 1: cheap filter chain. Only `.forward` /
        // `.forwardTieBreak` are genuine new content; every `drop*`
        // never reaches the cascade or the encoder — the top-level
        // `defer` releases the surface so a dropped frame can't stall
        // the pool.
        switch filter.decide(frame: frame) {
        case .forward, .forwardTieBreak:
            break
        case .dropIdle, .dropStatus, .dropNoDirtyRects, .dropNearDuplicate:
            return .filteredOut
        }

        // Stage 2: ADR-0013 cascade — UNCONDITIONALLY before encode.
        let decision = cascade.decide(context: context)
        switch decision {
        case .suppress(let reason):
            await counters.recordSuppressed()
            let seq = await sequence.allocate()
            let bytes = encodePrivacyTombstone(
                seq: seq,
                tombstone: PrivacyTombstone(
                    tsUs: nowUs,
                    appBundle: context.appBundleId ?? "",
                    reason: reason
                )
            )
            // If this throws, `defer` still releases the surface and
            // the error propagates — no leak on the suppress path.
            try await sink.write(bytes)
            // Suppressed frame: encoder NEVER called; surface released
            // by the top-level `defer`.
            return .suppressed(reason: reason)

        case .allow:
            // ONLY reachable after `.allow`. This is the single encode
            // call site in the helper. If the encoder throws, the
            // top-level `defer` releases the surface and the error
            // propagates — the allow-path lease leak this item fixes.
            let seq = await sequence.allocate()
            try await encoder.encodeAllowedFrame(seq: seq, context: context)
            return .encoded(seq: seq)
        }
    }
}
