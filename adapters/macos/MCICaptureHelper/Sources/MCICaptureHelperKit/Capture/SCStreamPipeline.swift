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
    ///
    /// ADR-0031: this factory is preserved as the fallback for sessions
    /// that have not been wired to a `FocusTracker` yet (legacy /
    /// headless test paths). The production capture path uses
    /// `makeFocusedWindowFilter(...)` so the captured pixel surface
    /// matches the cascade's attribution model.
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

    /// ADR-0031 Option (a) — focused-window-scoped capture filter.
    ///
    /// PROTECTED-SET per AGENT_PROTOCOL §5. Load-bearing privacy
    /// invariant per `docs/research/capture-scope-window-vs-display-
    /// 2026-05-29.md` §5.1: the SCStream's captured pixel surface IS
    /// the focused window, not the whole display. This is the
    /// structural fix for the cycle 8.17 cross-window leak — once the
    /// captured surface is one window's pixels, the cascade's
    /// bundle-keyed gate is structurally correct, ADR-0030 §3
    /// Messages+Mail redaction operates on the right bytes, and
    /// ADR-0017 §3.1 allowlist-as-content-filter holds as designed.
    ///
    /// Returns `nil` when:
    ///   1. The supplied `windowId` is not present in the live
    ///      `SCShareableContent.current.windows` enumeration (the
    ///      focused window was closed or moved off-screen between the
    ///      `FocusTracker` poll and this call).
    ///   2. The matched `SCWindow`'s owning application is on the
    ///      ADR-0013 §1 denylist. The caller (`SCStreamCaptureSession`)
    ///      treats `nil` as "do not rebind the SCStream filter" — the
    ///      prior filter (or no filter, on first bind) stays active.
    ///      This preserves §1's source-level exclusion: a denylisted
    ///      app's window can NEVER become the SCStream's bound window.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    /// The OS-touching `SCShareableContent.current` call requires a
    /// real screen + Screen-Recording TCC grant; the pure selection
    /// logic is factored into `selectFocusedWindow(...)` which IS
    /// unit-tested below.
    public static func makeFocusedWindowFilter(
        windowId: CGWindowID,
        denylist: Denylist
    ) async throws -> SCContentFilter? {
        let content = try await SCShareableContent.current
        // Find the SCWindow whose `windowID` matches. The enumeration
        // is small (O(visible windows on screen) — tens, not
        // thousands); a linear scan is fine.
        guard let scWindow = content.windows.first(where: { $0.windowID == windowId })
        else {
            return nil
        }
        // ADR-0013 §1 denylist composition: a denylisted app's window
        // never becomes the SCStream's bound window. The `owningApplication`
        // is `SCRunningApplication?`; nil collapses to "do not bind"
        // (the safe direction — we cannot verify the bundle is allowed).
        guard let owner = scWindow.owningApplication else {
            return nil
        }
        if denylist.appIsDenied(bundleId: owner.bundleIdentifier) {
            return nil
        }
        // `SCContentFilter(desktopIndependentWindow:)` is Apple's
        // documented API for single-window capture. The captured
        // surface IS the window's pixels — no display compositing, no
        // adjacent-window content. This is the load-bearing OS API
        // boundary the §7 falsifiability corpus rests on.
        return SCContentFilter(desktopIndependentWindow: scWindow)
    }

    /// OS-free shape describing one candidate window for the
    /// focused-window filter selection. Mirrors the subset of
    /// `SCWindow` fields the pure selection logic needs, so
    /// `selectFocusedWindow(...)` can be exercised without standing up
    /// a live `SCShareableContent` enumeration.
    public struct WindowDescriptor: Sendable, Equatable {
        public let windowId: CGWindowID
        public let bundleId: String

        public init(windowId: CGWindowID, bundleId: String) {
            self.windowId = windowId
            self.bundleId = bundleId
        }
    }

    /// Pure selection helper: of the supplied window descriptors, which
    /// one (if any) is the focused window AND not denylisted. Returns
    /// the matched descriptor or `nil` for either failure mode.
    ///
    /// Mirrors the decision the live `makeFocusedWindowFilter(...)`
    /// makes after enumerating `SCShareableContent`; the OS call is
    /// the difference, the *logic* is identical and is the auditable
    /// part. Used by the §7 corpus runner + headless unit tests.
    public static func selectFocusedWindow(
        from descriptors: [WindowDescriptor],
        windowId: CGWindowID,
        denylist: Denylist
    ) -> WindowDescriptor? {
        guard let matched = descriptors.first(where: { $0.windowId == windowId })
        else { return nil }
        if denylist.appIsDenied(bundleId: matched.bundleId) {
            return nil
        }
        return matched
    }

    // MARK: - V2-P1 third-lift scaffold (multi-window include-set) —
    //         `SCContentFilter(display:including:exceptingWindows:)`
    //
    // Per ADR-0031 §Status "Lift condition (third time)" + the
    // 2026-05-31 CEO ratification (FORK 3 = B) + the 2026-06-01
    // redesign memo (`docs/research/v2-p1-redesign-architecture-
    // 2026-06-01.md`) §1.1 the include-set form is BINDING: the
    // captured surface is the union of a non-empty include-set of
    // `SCWindow` values, minus the (usually empty) `exceptingWindows:`
    // subtraction list.
    //
    // This scaffold lands the FACTORY + the pure OS-free selection
    // helper. It does NOT wire the factory into `SCStreamCaptureSession`
    // (no `main.swift` change; no `killOcrEmit` flip; no rebind path
    // yet). Phase 7 PR 13 lands the wiring + the live-Mac corpus per
    // the redesign memo §2.3 + §3; Phase 7 PR 14 is the standalone M4
    // lift.
    //
    // The scaffold is intentionally scope-fenced to CODE READY TO BE
    // FLIPPED — no default flip yet. This is the ADR-0031 §Status
    // discipline "no compounding under any circumstance": memo → PR 13
    // wiring → PR 14 lift, each a separate PR.

    /// Pure selection helper for the multi-window include-set — the
    /// V2-P1 third-lift equivalent of `selectFocusedWindow(...)` above,
    /// extended to a set of windows.
    ///
    /// Input:
    /// - `descriptors`: the visible windows on the target display
    ///   (mirrors what `SCShareableContent.current.windows` returns at
    ///   the live call site).
    /// - `focusedWindowId`: the seed of the include-set. MUST be present
    ///   in `descriptors` and MUST NOT be denylisted, else `nil` is
    ///   returned (fail-closed; the caller does not rebind — see
    ///   `makeMultiWindowFilter(...)` below).
    /// - `coViewWindowIds`: the ordered co-view candidates the include-set
    ///   heuristic (redesign memo §1.3.1) proposes alongside the focused
    ///   seed. Descriptors NOT in this list are ignored; descriptors that
    ///   ARE in this list but are denylisted are silently dropped (the
    ///   redesign memo §1.3.1 step 4 "denylist subtract" — a denylisted
    ///   window never enters the include-set at all).
    /// - `denylist`: ADR-0013 §1 source-level denylist.
    ///
    /// Returns the ordered include-set descriptors (seed FIRST, co-view
    /// candidates in the caller-supplied order after, all
    /// non-denylisted) or `nil` if the seed cannot be admitted. The
    /// returned array is GUARANTEED non-empty (≥1 element: the seed);
    /// this preserves the redesign memo §1.1 invariant that
    /// `SCContentFilter(display:including:exceptingWindows:)` never
    /// receives an empty `including:` list — the cycle 8.27 `-3815`
    /// antipattern.
    ///
    /// Headlessly unit-testable — no OS call. Used by the (future)
    /// live-Mac corpus runner + the unit tests in this scaffold.
    public static func selectMultiWindowIncludingSet(
        from descriptors: [WindowDescriptor],
        focusedWindowId: CGWindowID,
        coViewWindowIds: [CGWindowID],
        denylist: Denylist
    ) -> [WindowDescriptor]? {
        // Seed the include-set with the focused window; fail closed if
        // the focused window is missing or denylisted (mirrors
        // `selectFocusedWindow(...)`).
        guard let seed = selectFocusedWindow(
            from: descriptors,
            windowId: focusedWindowId,
            denylist: denylist
        ) else {
            return nil
        }
        // Denylist-subtract every co-view candidate. Preserve the
        // caller-supplied order for determinism; skip candidates that
        // are missing from `descriptors` (window closed between the
        // heuristic recompute and this call — bounded race, treated as
        // "no longer a candidate").
        var result: [WindowDescriptor] = [seed]
        for candidateId in coViewWindowIds {
            // Skip the seed if the caller passed it as a co-view too.
            if candidateId == focusedWindowId { continue }
            guard let candidate = descriptors.first(where: { $0.windowId == candidateId })
            else { continue }
            if denylist.appIsDenied(bundleId: candidate.bundleId) { continue }
            result.append(candidate)
        }
        // Post-condition: result is non-empty (contains at least the
        // seed). Explicit invariant assert — a future refactor that
        // regresses this is a §5 protected-set breach.
        precondition(!result.isEmpty, "include-set must be non-empty post-select")
        return result
    }

    /// ADR-0031 V2-P1 third-lift — multi-window include-set capture
    /// filter. PROTECTED-SET per AGENT_PROTOCOL §5.
    ///
    /// BINDING API SHAPE (redesign memo §1.1): the captured surface is
    /// the union of the `including:` list minus `exceptingWindows:`,
    /// per Apple's `SCContentFilter(display:including:exceptingWindows:)`
    /// initializer. The `including:` list MUST be non-empty at the call
    /// site — an empty list is the cycle 8.27 `-3815` antipattern
    /// ("Failed to find any displays or windows to capture"; PR #264
    /// mis-used `exceptingWindows:` to the same effect).
    ///
    /// This factory REFUSES TO CONSTRUCT and returns `nil` when:
    ///   1. `SCShareableContent.current.displays` is empty (no display
    ///      to bind against — throws `noDisplay`).
    ///   2. The pure selection helper (`selectMultiWindowIncludingSet`)
    ///      returns `nil` — the focused window is not present in the
    ///      live enumeration OR its owning app is on the ADR-0013 §1
    ///      denylist. The caller (`SCStreamCaptureSession` in Phase 7
    ///      PR 13) treats `nil` as "do not rebind"; the prior installed
    ///      filter stays active and the race gate trips on every frame
    ///      until focus returns to an allowed window.
    ///   3. The resolved include-set would be empty (would throw
    ///      `emptyIncludeSet`; unreachable via the selection helper's
    ///      non-empty post-condition, but defended structurally — a
    ///      future refactor that removes the seed-fail-closed rule must
    ///      trip this check before reaching the Apple constructor).
    ///
    /// This scaffold is NOT wired into the live capture path yet. It
    /// exists as CODE READY TO BE FLIPPED per the ADR-0031 §Status
    /// discipline. Phase 7 PR 13 lands the wiring at `main.swift` and
    /// the live-Mac corpus; Phase 7 PR 14 is the standalone M4 lift.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`. The
    /// OS-touching `SCShareableContent.current` call requires a real
    /// screen + Screen-Recording TCC grant; the pure selection logic is
    /// factored into `selectMultiWindowIncludingSet(...)` which IS
    /// unit-tested. The Apple constructor call itself is covered by the
    /// live-Mac corpus §3.2 harnesses (out of scope for this scaffold).
    public static func makeMultiWindowFilter(
        focusedWindowId: CGWindowID,
        coViewWindowIds: [CGWindowID],
        denylist: Denylist
    ) async throws -> SCContentFilter? {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw SCStreamPipelineError.noDisplay
        }
        // Build the pure selection over the OS-enumerated visible
        // windows. The descriptor form is the same shape
        // `selectFocusedWindow(...)` accepts; we hydrate it from the
        // live `SCShareableContent`.
        let descriptors: [WindowDescriptor] = content.windows.compactMap { w in
            guard let bundleId = w.owningApplication?.bundleIdentifier else {
                return nil
            }
            return WindowDescriptor(windowId: w.windowID, bundleId: bundleId)
        }
        guard let selected = selectMultiWindowIncludingSet(
            from: descriptors,
            focusedWindowId: focusedWindowId,
            coViewWindowIds: coViewWindowIds,
            denylist: denylist
        ) else {
            // Fail-closed: focused window missing or denylisted. The
            // caller MUST NOT rebind; the prior filter (or display
            // fallback) stays installed.
            return nil
        }
        // Materialize the `SCWindow` values for the selected descriptors.
        // Skip any descriptor whose live `SCWindow` disappeared between
        // the descriptor build and this pass (bounded race).
        let scWindowById: [CGWindowID: SCWindow] = Dictionary(
            uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) }
        )
        let includingSet: [SCWindow] = selected.compactMap { scWindowById[$0.windowId] }
        // Refuse-to-construct discipline (redesign memo §1.1 + third-
        // lift condition 1): an empty include-set is forbidden. The
        // selection helper's post-condition already guarantees ≥1
        // element under normal flow; this check catches any residual
        // bounded-race window where every selected window vanished
        // between the descriptor build and the SCWindow materialization.
        if includingSet.isEmpty {
            throw SCStreamPipelineError.emptyIncludeSet
        }
        // The BINDING form per ADR-0031 §Status FORK 3 = B:
        // `SCContentFilter(display:including:exceptingWindows:)` with a
        // non-empty include list. `exceptingWindows:` stays empty —
        // ADR-0013 §1 denylist is enforced via the selection helper's
        // denylist-subtract path (redesign memo §1.3.1 step 4), NOT via
        // `exceptingWindows:` (per the memo's "cleaner semantic" note).
        return SCContentFilter(
            display: display,
            including: includingSet,
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
    /// V2-P1 third-lift: `makeMultiWindowFilter(...)` was asked to
    /// construct an `SCContentFilter(display:including:exceptingWindows:)`
    /// but the resolved include-set was empty. Refusing to construct
    /// (per ADR-0031 §Status third-lift condition 1 + redesign memo
    /// §1.1) — an empty include-set is the cycle 8.27 `-3815` antipattern
    /// class. The caller MUST NOT swallow this into a "capture nothing"
    /// state; the discipline is fail-closed = fall back to the prior
    /// installed filter, NOT degrade silently.
    case emptyIncludeSet
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
            // call site in the helper. The top-level `defer` releases
            // the surface on every path including the encoder catch arm.
            // DOGFOOD #3: `encoderInput` carries the live frame's
            // retained `CVPixelBuffer`. A `nil` input keeps the
            // headless / OS-free test path unchanged (the encoder is
            // expected to no-op on nil); the live `SCStreamCapture`
            // callback always supplies a non-nil input.
            //
            // ADR-0016 §4.2 — OCR emission is gated on cascade-twice
            // on pixels (and §6 on text), NOT on encode-success. The
            // cascade decision above is the structural gate that
            // protects user content; the encoder's role is to produce
            // an HEVC blob for the recall timeline (post-§7-corpus /
            // post-key-plumbing). A VideoToolbox failure on this `.allow`
            // frame must not silently mute the OCR brain — that was
            // the ocr-emit-silence regression closed by docs/research/
            // ocr-emit-silence-2026-05-28.md. Treat encoder errors as
            // content-free observables: increment the
            // `framesEncoderFailed` counter (surfaced on the wire by
            // the 0x06 → 0x07 HelperHealth bump) and still return
            // `.encoded(seq:_)` so SCStreamCaptureSession dispatches
            // the cascade-twice OCR emitter.
            //
            // ADR-0013 Amendment 1 §3 audit after this change:
            //   (a) cascade-before-encode — unchanged. The cascade
            //       still runs before the do/catch even exists.
            //   (b) fail-closed default — unchanged. The catch arm
            //       converts a throw into a counter; it cannot widen
            //       any `.allow` decision (the outer `switch decision`
            //       above is the only place `.allow` is granted).
            //   (c) no suppressed event emitted — unchanged. We are
            //       in the `.allow` arm; cascade said allow, so
            //       returning `.encoded(...)` is the documented shape.
            //   (d) no surface-lease leak — unchanged. The top-level
            //       `defer { lease.release() }` runs on the catch arm
            //       exactly as it ran on the prior throw-propagation
            //       arm.
            let seq = await sequence.allocate()
            do {
                try await encoder.encodeAllowedFrame(
                    input: encoderInput,
                    seq: seq,
                    context: context
                )
            } catch {
                await counters.recordEncodeFailed()
            }
            return .encoded(seq: seq, forcedByFloor: forcedByFloor)
        }
    }

    /// ADR-0031 §5.3 — emit a `focusRaceDropped` tombstone for a frame
    /// whose attribution cannot be trusted because the focus generation
    /// observed at SCStream callback time did NOT match the generation
    /// the live SCStream's `SCContentFilter` was rebound under.
    ///
    /// Routed through the pipeline's existing sink + sequence + counters
    /// so the wire-frame shape is identical to a normal
    /// `.suppress(reason: ...)` decision — the difference is that this
    /// path does NOT consult the cascade. The cascade reads
    /// `(focused.bundleId, ...)`; under a focus-race, no consistent
    /// `bundleId` exists at the SCStream sample timestamp, so the safe
    /// direction is to fail closed before the cascade is even asked.
    ///
    /// Amendment 1 §3 audit (the §5 protected-set CSO sign-off
    /// asserts on every commit that touches the pipeline):
    ///   (a) cascade-before-encode — unchanged. The race gate fires
    ///       BEFORE this method is called; there is no encode on this
    ///       path.
    ///   (b) fail-closed preserved — STRENGTHENED. A frame whose
    ///       attribution is structurally untrustworthy now emits a
    ///       distinct tombstone (`focusRaceDropped`) instead of
    ///       running the cascade under a stale generation; pre-V2-P1
    ///       behavior would have run the cascade against the
    ///       (mismatched) focused-window snapshot.
    ///   (c) no stored/emitted suppressed event — unchanged. A
    ///       `focusRaceDropped` tombstone IS the documented suppress
    ///       shape; nothing else is emitted.
    ///   (d) no surface-lease leak — unchanged. The supplied
    ///       `SurfaceLease` is released by the top-level `defer`
    ///       below, exactly once.
    public func emitFocusRaceDropped(
        tsUs: UInt64,
        appBundle: String,
        lease: SurfaceLease
    ) async throws {
        defer { lease.release() }
        await counters.recordDelivered()
        await counters.recordSuppressed()
        await counters.recordFocusRaceDropped()
        let seq = await sequence.allocate()
        let bytes = encodePrivacyTombstone(
            seq: seq,
            tombstone: PrivacyTombstone(
                tsUs: tsUs,
                appBundle: appBundle,
                reason: .focusRaceDropped
            )
        )
        try await sink.write(bytes)
    }
}
