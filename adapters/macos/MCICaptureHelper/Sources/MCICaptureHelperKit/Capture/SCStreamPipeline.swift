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
/// encode (`VideoToolboxHEVCEncoder.swift`). Tests inject a spy.
///
/// The `input: EncoderInput?` argument carries the retained pixel
/// buffer for one frame. `nil` means "OS-free / headless test path"
/// — the encoder may record that an allow decision reached its call
/// site but MUST NOT attempt to encode (there is nothing to encode).
/// The live `SCStreamCaptureSession` callback constructs an
/// `EncoderInput` from the borrowed `CVPixelBuffer` and passes it on
/// every `.allow` frame.
public protocol FrameEncoder: Sendable {
    /// Encode an allowed frame. Called ONLY after
    /// `SuppressionCascade.decide(...)` returned `.allow`. The pipeline's
    /// top-level `defer { lease.release() }` (Amendment 1 §3(d)) runs
    /// AFTER this call returns — including on `throws` — so a throwing
    /// encoder cannot leak the IOSurface lease.
    func encodeAllowedFrame(
        input: EncoderInput?,
        seq: UInt64,
        context: WorkflowContext
    ) async throws
}

/// Default-OFF placeholder. Retained because `main.swift` may wire it
/// when the operator omits `--capture`, and headless tests use it as a
/// zero-cost stand-in for the production encoder. Replacing it with
/// `VideoToolboxHEVCEncoder` is itself NOT a default flip — flipping
/// the §4 default-ON capture gate requires the §7 corpus + CSO
/// sign-off (`CaptureLaunchOptions.swift`). DOGFOOD #3 wires the real
/// encoder ONLY inside the `--capture` dev branch in `main.swift`.
public struct DeferredVideoToolboxEncoder: FrameEncoder {
    public init() {}
    public func encodeAllowedFrame(
        input _: EncoderInput?,
        seq _: UInt64,
        context _: WorkflowContext
    ) async throws {
        // Intentionally empty: the `.allow` branch is reached but no
        // frame is encoded or stored. Used by the default (no-flag) path
        // and by OS-free tests that exercise the pipeline's structural
        // gate without pulling in VideoToolbox.
    }
}

/// Mutable wall-clock state for the cascade floor.
///
/// `SCStreamPipeline` is a `Sendable` struct (all `let` fields) and
/// callers may legally share an instance across captures — so the
/// last-cascade-run wall-clock must live behind an actor. The SCStream
/// callback delivers serially on its `sampleQueue`, but the pipeline
/// is `Sendable` by contract; an actor is the most defensive choice
/// here.
///
/// STEP-2-FINDING-004 fix. See `StreamPolicy.cascadeFloorIntervalMs`
/// for the design rationale.
public actor CascadeFloorState {
    /// Wall-clock microseconds (`Date.timeIntervalSince1970 * 1e6`) of
    /// the most recent cascade evaluation — filter-passed OR floor-
    /// forced, allowed OR suppressed. Updated on EVERY cascade call.
    /// Initial value `0` means "no cascade has ever run on this
    /// pipeline" — the very first inbound frame on a filter-`.drop*`
    /// path always satisfies the floor and runs the cascade (the safe
    /// direction: any unknown surface gets a cascade verdict, not a
    /// silent filter drop).
    private var lastCascadeRunUs: UInt64 = 0

    public init() {}

    /// Decide whether a floor-forced cascade run is due.
    ///
    /// Returns `true` iff `floorIntervalMs > 0` AND
    /// `nowUs - lastCascadeRunUs >= floorIntervalMs * 1000`. The
    /// subtraction is unsigned, but `lastCascadeRunUs == 0` (initial
    /// state) and `nowUs > 0` (any real wall-clock) make the first
    /// inbound frame on a `.drop*` path return `true`, which is the
    /// safe direction (run the cascade on an unknown surface).
    public func shouldRunFloorCascade(nowUs: UInt64, floorIntervalMs: UInt64) -> Bool {
        guard floorIntervalMs > 0 else { return false }
        let floorUs = floorIntervalMs &* 1000
        // Pinned-monotonic guard: if `nowUs` is somehow earlier than the
        // recorded `lastCascadeRunUs` (clock skew, NTP step, test driver
        // feeding non-monotonic timestamps), refuse to fire. The safe
        // direction is "do not force a cascade we cannot time".
        guard nowUs >= lastCascadeRunUs else { return false }
        return (nowUs &- lastCascadeRunUs) >= floorUs
    }

    /// Stamp the most recent cascade evaluation. MUST be called by
    /// `SCStreamPipeline.process(...)` immediately after the cascade
    /// returns, on EVERY path the cascade ran on — filter-passed AND
    /// floor-forced, `.allow` AND `.suppress`. Failing to stamp on the
    /// `.suppress` path would let the floor re-fire on the very next
    /// frame, busting the configured interval.
    public func markCascadeRan(nowUs: UInt64) {
        // Pinned-monotonic: never roll the timestamp backward. A non-
        // monotonic `nowUs` is silently absorbed (last-value-wins
        // toward the future).
        if nowUs > lastCascadeRunUs {
            lastCascadeRunUs = nowUs
        }
    }

    /// In-process read of the last-cascade timestamp. Used by tests
    /// to prove the (f) invariant ("`lastCascadeRunUs` updates on
    /// EVERY cascade call, forced or not, including `.suppress`
    /// outcomes"). Not on the wire.
    public func currentLastCascadeRunUs() -> UInt64 {
        lastCascadeRunUs
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
    /// Cascade-floor heartbeat interval, in milliseconds. `0` disables
    /// the floor (legacy: cascade runs only when the filter forwards).
    /// `>= 1` runs the cascade at LEAST every `floorIntervalMs` even
    /// when the filter would drop the frame. See
    /// `StreamPolicy.cascadeFloorIntervalMs`.
    private let floorIntervalMs: UInt64
    private let floorState: CascadeFloorState

    public init(
        filter: SmartCaptureFilter = SmartCaptureFilter(),
        cascade: SuppressionCascade,
        encoder: any FrameEncoder,
        counters: HelperHealthCounters = HelperHealthCounters(),
        sequence: FrameSequence = FrameSequence(),
        sink: any FrameSink,
        floorIntervalMs: UInt64 = StreamPolicy.default.cascadeFloorIntervalMs,
        floorState: CascadeFloorState = CascadeFloorState()
    ) {
        self.filter = filter
        self.cascade = cascade
        self.encoder = encoder
        self.counters = counters
        self.sequence = sequence
        self.sink = sink
        self.floorIntervalMs = floorIntervalMs
        self.floorState = floorState
    }

    /// Test/observer read of the in-process cascade-forced state.
    /// Provided as an API surface so the headless tests can prove
    /// invariant (f) — `lastCascadeRunUs` updates on EVERY cascade
    /// call. Not on the wire; not load-bearing for production.
    public var cascadeFloor: CascadeFloorState { floorState }

    /// What `process(...)` did with one candidate — returned so the
    /// OS-free test can assert the ordering invariant.
    public enum Outcome: Sendable, Equatable {
        /// Filter chain rejected the frame as not-new-content AND the
        /// cascade floor was not due, so the cascade was not consulted.
        /// No cascade, no encode, surface released.
        case filteredOut
        /// Cascade suppressed. Tombstone emitted, NO encode, surface
        /// released. `forcedByFloor` is `true` iff the cascade ran
        /// because the floor heartbeat was due (the filter would have
        /// dropped the frame). STEP-2-FINDING-004 instrumentation —
        /// `false` preserves the pre-floor outcome shape; tests assert
        /// both paths.
        case suppressed(reason: RedactionReason, forcedByFloor: Bool)
        /// Cascade allowed. Encoder invoked, then surface released.
        /// `forcedByFloor` is `true` iff the cascade ran because the
        /// floor heartbeat was due.
        case encoded(seq: UInt64, forcedByFloor: Bool)
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
        lease: SurfaceLease,
        encoderInput: EncoderInput? = nil
    ) async throws -> Outcome {
        // Exactly-once release on EVERY path, including a throwing
        // `sink.write` / `encoder.encodeAllowedFrame`. Must be the
        // first statement so no early return / thrown error can
        // bypass it.
        defer { lease.release() }

        await counters.recordDelivered()

        // Stage 1: cheap filter chain. STEP-2-FINDING-004 — on a
        // `.drop*` decision we now consult the cascade-floor heartbeat
        // before returning `.filteredOut`. A static-screen secure
        // surface (FairPlay full-screen playback, sudo password prompt,
        // a focused `NSSecureTextField` with no surrounding motion)
        // produces a stream of `.dropNearDuplicate` / `.dropIdle` /
        // `.dropNoDirtyRects`; without a floor the cascade never sees
        // those frames and the specific cascade-layer verdict
        // (`reason=2/3/4`) cannot emit. The floor guarantees the
        // cascade runs at least once per `floorIntervalMs` so the wire
        // observer sees the verdict at signal granularity.
        //
        // Privacy invariant: this floor only WIDENS observability. The
        // floor-forced run is the EXACT same `cascade.decide(...)` the
        // filter-passed path runs — same probes, same first-match-wins
        // order, same fail-safe arm. It can only ADD `.suppress`
        // decisions; it can never widen `.allow`. Fail-closed preserved
        // (Amendment 1 §3(b)).
        let forcedByFloor: Bool
        switch filter.decide(frame: frame) {
        case .forward, .forwardTieBreak:
            forcedByFloor = false
        case .dropIdle, .dropStatus, .dropNoDirtyRects, .dropNearDuplicate:
            // Filter would drop this frame. Consult the floor: if the
            // heartbeat is due, run the cascade anyway as a "floor
            // probe". Otherwise return `.filteredOut` exactly as the
            // pre-floor behavior — preserving every existing dedup
            // outcome at frequencies above the floor.
            if await floorState.shouldRunFloorCascade(
                nowUs: nowUs,
                floorIntervalMs: floorIntervalMs
            ) {
                forcedByFloor = true
            } else {
                return .filteredOut
            }
        }

        // Stage 2: ADR-0013 cascade — UNCONDITIONALLY before encode.
        let decision = cascade.decide(context: context)
        // Stamp the wall-clock on EVERY cascade evaluation, regardless
        // of `.allow` / `.suppress` and regardless of filter-passed /
        // floor-forced. Failing to stamp on `.suppress` would let the
        // floor re-fire on the very next frame (invariant (f) test).
        await floorState.markCascadeRan(nowUs: nowUs)
        if forcedByFloor {
            await counters.recordCascadeForced()
        } else {
            await counters.recordCascadeFromFilter()
        }
        switch decision {
        case .suppress(let reason):
            await counters.recordSuppressed()
            if reason == .failsafeUnknown {
                // §7 fail-safe subcount — STRICT SUBSET of
                // framesSuppressed, never an alternative to it. Mirrors
                // `HelperMainLoop.processSyntheticTransition`'s record
                // path so the wire's `frames_redacted_by_failsafe`
                // counter (wire 0x02+) is sourced consistently whether
                // the cascade ran from the live pipeline OR from the
                // synthetic-transition test seam. STEP-2-FINDING-005:
                // before this line the live capture path NEVER
                // incremented this counter — wire field stayed 0 even
                // on a stream dominated by `reason=7` tombstones.
                await counters.recordRedactedByFailsafe()
            }
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
            return .suppressed(reason: reason, forcedByFloor: forcedByFloor)

        case .allow:
            // ONLY reachable after `.allow`. This is the single encode
            // call site in the helper. If the encoder throws, the
            // top-level `defer` releases the surface and the error
            // propagates — the allow-path lease leak this item fixes.
            // DOGFOOD #3: `encoderInput` carries the live frame's
            // retained `CVPixelBuffer`. A `nil` input keeps the
            // headless / OS-free test path unchanged (the encoder is
            // expected to no-op on nil); the live `SCStreamCapture`
            // callback always supplies a non-nil input.
            let seq = await sequence.allocate()
            try await encoder.encodeAllowedFrame(
                input: encoderInput,
                seq: seq,
                context: context
            )
            return .encoded(seq: seq, forcedByFloor: forcedByFloor)
        }
    }
}
