// SPDX-License-Identifier: TBD-private
//
// SCStreamCaptureSession — the LIVE ScreenCaptureKit session (enabler
// PR-1). PROTECTED-SET per AGENT_PROTOCOL §5. LAUNCH-BLOCKER §4/R5.
//
// ┌──────────────────────────────────────────────────────────────────┐
// │ EVERYTHING IN THIS FILE THAT TOUCHES A LIVE SCREEN IS MARKED      │
// │ `// UNVERIFIED — needs live macOS; do not claim working`.        │
// │                                                                  │
// │ It compiles against the macOS 14 SDK (CI proves that) but its    │
// │ runtime — `SCShareableContent`, `SCStream`, the real             │
// │ `SCStreamOutput` callback, the pixel-buffer read — CANNOT be     │
// │ exercised headlessly. No test in this package drives it. The     │
// │ §7 secure-surface corpus (HUMAN-ONLY, real machine) is what      │
// │ actually verifies it (ADR-0013 §7 / Amendment 1 §2).             │
// └──────────────────────────────────────────────────────────────────┘
//
// STRUCTURAL GUARANTEES THIS PR (Amendment 1 §3, asserted at CSO
// sign-off from this diff):
//
//   (a) cascade-before-encode — the callback's ONLY sink is
//       `SCStreamPipeline.process(...)` (landed PR #15), which runs the
//       ADR-0013 cascade unconditionally before its single encode call
//       site. This file adds NO path that reaches encode/store/IPC
//       ahead of, or around, the cascade.
//   (b) fail-closed preserved — this file widens no `.allow` path and
//       relaxes no probe; it only *feeds* the existing cascade.
//   (c) no stored/emitted suppressed event — there is still NO encoder
//       (the pipeline holds `DeferredVideoToolboxEncoder`, a no-op).
//       PR-2 adds the IOSurface retain (so PR-3's encoder can outlive
//       the callback) but encodes/stores NOTHING: the retained buffer
//       is freed by the lease on every path, used by no one. Only
//       `Sendable` value types cross into the async pipeline.
//   (d) no IOSurface pool-stall — PR-2 introduces the real retain via
//       `CVPixelBufferRetainedSurface`, released through
//       `PixelSurfaceReleaser` by the pipeline's single top-level
//       exactly-once `defer` on EVERY exit (filter-drop / suppress /
//       allow / throwing sink / throwing encoder). The hold is bounded
//       (cascade + no-op encoder ⇒ sub-millisecond) and well inside
//       the `minimumFrameInterval × (queueDepth−1)` pool budget.
//
// ADR-0013 Amendment 1 §4: this session only ever starts behind the
// non-default `--capture` dev flag (`CaptureLaunchOptions`). The
// default build never constructs it.

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A no-op `SurfaceReleasing`. PR-1 retains nothing past the callback,
/// so there is nothing to release; the `SurfaceLease`'s exactly-once
/// discipline still runs (the pipeline's top-level `defer`), it just
/// has no underlying OS resource yet. PR-2 replaces this with the
/// IOSurface-pool-backed releaser.
public struct BorrowedNoRetainReleaser: SurfaceReleasing {
    public init() {}
    public func releaseSurface() {
        // Intentionally empty — PR-1 holds no surface retain. The
        // existence of this type documents that the absence of a
        // pool-stall on this path is STRUCTURAL, not incidental.
    }
}

/// Value-only snapshot pulled synchronously out of one borrowed
/// `CMSampleBuffer` inside the callback. `Sendable`: it is safe to
/// outlive the surface precisely because it copies, never borrows.
public struct InCallbackSample: Sendable, Equatable {
    public let userIdle: Bool
    public let frameStatusComplete: Bool
    public let dirtyRects: [DirtyRect]
    public let frameWidth: Int
    public let frameHeight: Int
    public let dhash: DHash
    public let appBundleId: String?
    /// The 9×8 row-major luminance grid the callback already extracts
    /// from the borrowed `CVPixelBuffer` to feed `computeDHash9x8`.
    /// Surfaced here so the ADR-0013 §2 `PixelGridBlackedRegionProbe`
    /// can pre-feed itself before the cascade runs on the frame
    /// (`hasBlackedRegion()`). 72 bytes, value-typed — no surface
    /// borrow, no additional pixel read.
    public let grayscale: [UInt8]

    public init(
        userIdle: Bool,
        frameStatusComplete: Bool,
        dirtyRects: [DirtyRect],
        frameWidth: Int,
        frameHeight: Int,
        dhash: DHash,
        appBundleId: String?,
        grayscale: [UInt8]
    ) {
        self.userIdle = userIdle
        self.frameStatusComplete = frameStatusComplete
        self.dirtyRects = dirtyRects
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.dhash = dhash
        self.appBundleId = appBundleId
        self.grayscale = grayscale
    }
}

/// A terminal loss of the live ScreenCaptureKit stream after the helper has
/// become ready. This deliberately carries no framework error text: Apple
/// errors can contain host-specific detail, while the owner only needs the
/// fact that capture is no longer live.
public enum CaptureRuntimeFailure: Error, Sendable, Equatable {
    case streamStoppedUnexpectedly
}

/// The owner action for a terminal capture failure. Production uses the
/// fail-loud default, which terminates the helper nonzero so its supervisor
/// cannot continue reporting a healthy capture child. Tests inject a recorder.
public typealias CaptureRuntimeFailureHandler = @Sendable (CaptureRuntimeFailure) -> Void

/// The live SCStream session. `@unchecked Sendable`: lifecycle, stream
/// identity, focus generation, and visual-baseline state are guarded by the
/// session lock; asynchronous frame work crosses owned bounded dispatchers.
public final class SCStreamCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let pipeline: SCStreamPipeline
    private let denylist: Denylist
    private let policy: StreamPolicy
    private let sampleQueue: DispatchQueue
    private let captureDispatcher = OrderedCaptureDispatcher(
        capacity: VisionOCRWorker.defaultCapacity
    )
    /// ADR-0013 §2 probe, pre-fed in the callback before the cascade
    /// runs on the same frame. `nil` is permitted (legacy
    /// construction / headless tests that never need §2 to fire);
    /// when `nil` the cascade's `BlackedRegionProbe` is whatever the
    /// caller installed in `SuppressionCascade`, and `hasBlackedRegion`
    /// is fed by some other means (or stays false → §7 fail-safe).
    private let blackedRegionProbe: PixelGridBlackedRegionProbe?
    /// ADR-0015 §6 P2.5 — context join. The shared
    /// `WorkflowContextSnapshot` actor the background pollers
    /// (NSWorkspace / AX / per-browser AppleScript) write to. The
    /// SCStream callback reads it synchronously via `currentSync()`
    /// before the cascade runs. `nil` preserves the pre-P2.5
    /// behaviour byte-for-byte (all-nil `WorkflowContext` reaches the
    /// cascade — fail-closed under §7).
    private let contextSnapshot: WorkflowContextSnapshot?
    /// ADR-0015 §6 P2.5 — per-callback URL extraction. Invoked
    /// against the frontmost bundle id read from the snapshot. Each
    /// underlying per-browser provider has its own ≤1 s TTL cache
    /// (P2.3/P2.4) so the hot-path cost is a cache hit in the common
    /// case; misses cap at 250 ms via the provider's AppleScript
    /// timeout. `nil` preserves pre-P2.5 behaviour (no URL ever
    /// reaches the cascade).
    private let urlProvider: URLProvider?
    /// ADR-0016 §1.6 P3.6 — cascade-twice OCR emitter. Invoked after
    /// `pipeline.process(...)` returns `.encoded(seq:_:)` (the
    /// pixel-time cascade returned `.allow`). The emitter submits the
    /// retained `CVPixelBuffer` to `VisionOCRWorker`, runs cascade §6
    /// over the OCR'd text, and emits either an `OCREvent` (both
    /// cascades cleared) or a `PrivacyTombstone` (§6 fired, or 64 KB
    /// cap exceeded). `nil` preserves pre-P3.6 behaviour (no OCR
    /// invocation, no OCREvent ever reaches the wire) — used by
    /// headless tests + the live SCStream path before the OCR worker
    /// is wired up.
    private let ocrPostAllowEmitter: (any OCRPostAllowEmitter)?

    /// Invoked once when ScreenCaptureKit terminates an active stream without
    /// the session initiating the stop. The default exits the helper, which is
    /// the production owner signal available without keeping a dead capture
    /// process alive just to emit later heartbeats.
    private let runtimeFailureHandler: CaptureRuntimeFailureHandler

    /// ADR-0031 §5 V2-P1 — focused-window observation store. When
    /// non-`nil`, `start()` builds a focused-window `SCContentFilter`
    /// (Option (a)) instead of the display-scoped filter, and the
    /// SCStream callback runs the (frame_ts, focus_ts) race-consistency
    /// gate before reaching the cascade. `nil` preserves pre-V2-P1
    /// display-scoped behaviour — the legacy / headless test path.
    private let focusedWindowStore: FocusedWindowStore?

    /// ADR-0031 — companion `FocusTracker`. When supplied, `start()`
    /// calls its `start()` and `stop()` calls its `stop()`. May be
    /// `nil` even when `focusedWindowStore` is non-`nil` (tests own
    /// the store directly and feed it via `FocusTracker.tickOnce(...)`).
    private let focusTracker: FocusTracker?

    /// Cycle 8.45 audit risk #2 — TCC-revoked-mid-run monitor. When
    /// supplied, `start()` seeds the initial TCC snapshot and starts
    /// the monitor; the session registers itself as observer so a
    /// mid-run revoke of Screen Recording / Accessibility / FDA
    /// immediately pauses SCStream + emits a helper-health breadcrumb
    /// the parent app can drive the menu-bar red pill from. `nil`
    /// preserves pre-cycle-8.45 behaviour (no TCC-revoke awareness) —
    /// used by tests + any legacy build.
    private let tccStatusMonitor: TCCStatusMonitor?

    /// V2-P1 third-lift (Phase 7 PR 13 wiring). The last include-set size
    /// observed at SCStream filter (re)bind time — surfaced for the
    /// live-Mac smoke test / later inspection per the redesign memo
    /// §3.2.4 H9′ / §3.3 corpus assertion floor. In-process only (NOT
    /// on the wire); read via `lastIncludeListSizeForTest`. Guarded by
    /// `lock`. `0` = "no multi-window filter has been (re)bound yet"
    /// (the pre-M4-lift default state; also the legacy display-filter
    /// path).
    ///
    /// This is NOT a HelperHealth wire field addition — the scaffold
    /// discipline (ADR-0031 §Status + `docs/research/v2-p1-third-lift-
    /// scaffold.md` §4) forbids adding a wire slot in this PR. A future
    /// PR (Phase 7 PR 14 or later) may promote this to a wire field
    /// after the live-Mac smoke passes.
    private var lastIncludeListSize: UInt32 = 0

    /// Test-only accessor: proves the OCR emitter wire is connected.
    /// Not public API — `internal` so `@testable import` can read it.
    internal var ocrPostAllowEmitterForTest: (any OCRPostAllowEmitter)? {
        ocrPostAllowEmitter
    }

    private let lock = NSLock()
    private var priorDHash: DHash?
    private var priorDHashGeneration: UInt64 = 0
    private var priorDHashCaptureOrdinal: UInt64 = 0
    private var retryOCRGeneration: UInt64?
    private var captureOrdinal: UInt64 = 0
    private var stream: SCStream?
    /// Immutable generation provenance for every live or draining stream.
    /// Callback admission uses the callback's `SCStream` identity, never a
    /// mutable "current filter" guess.
    private var streamFocusGenerations: [ObjectIdentifier: UInt64] = [:]
    private var candidateStreams: [ObjectIdentifier: SCStream] = [:]
    /// Invalidates async stream construction across stop and TCC transitions.
    private var captureEpoch: UInt64 = 0
    private var captureLifecycleActive: Bool = false
    private var shutdownRequested: Bool = false

    /// The first unexpected delegate termination is terminal for this
    /// session. Guarded by `lock`: ScreenCaptureKit may deliver more than one
    /// error callback while its internal teardown is in flight.
    private var runtimeFailure: CaptureRuntimeFailure?

    /// Streams this session deliberately stopped for shutdown or a privacy
    /// pause. Keep a strong list until each delegate callback arrives so an
    /// expected stop cannot be mistaken for a runtime failure; strong
    /// retention also prevents `ObjectIdentifier` reuse.
    private var expectedTerminatedStreams: [SCStream] = []

    /// ADR-0031 §5.3 — the focus generation the currently-installed
    /// SCStream `SCContentFilter` was rebound under. Guarded by `lock`.
    /// Read at SCStream callback time and compared against the
    /// `FocusedWindowSnapshot.generation` observed at the same moment;
    /// a mismatch fires the race-consistency gate.
    ///
    /// `0` is the sentinel for "no focused-window filter has been
    /// installed yet" — for legacy display-filter sessions this stays
    /// `0` and the race gate is bypassed because `focusedWindowStore`
    /// is `nil`.
    private var installedFocusGeneration: UInt64 = 0

    /// ADR-0031 — background rebind task. Observes the focused-window
    /// store at a faster cadence than the FocusTracker poll so the
    /// SCStream filter follows focus changes promptly. Guarded by
    /// `lock`; cancelled on `stop()`.
    private var rebindTask: Task<Void, Never>?

    /// V2-P1 third-lift (Phase 7 PR 13 wiring): per-session count of
    /// race-gate drops observed so far. Used to throttle the stderr
    /// log breadcrumb so a sustained race storm (the cycle 8.27 shape
    /// where 73 % of frames tripped the gate) does not saturate
    /// stderr. Guarded by `lock`. Content-free — a single UInt64.
    private var focusRaceDropSeen: UInt64 = 0

    /// Set to `true` by the first invocation of
    /// `stream(_:didOutputSampleBuffer:of:)` that actually carries a
    /// screen sample. Guarded by `lock`; the callback is on the
    /// `sampleQueue`, the read on `start()` etc. is on whichever queue
    /// the caller is on. Used ONLY to emit a single one-bit stderr
    /// breadcrumb proving the callback wired up at least once — the
    /// content-free observability surface for SCSTREAM-LIVE-001
    /// re-verify (Step-1 audit, 2026-05-19). NOT a stored frame, NOT
    /// on the wire.
    private var firstSampleLogged: Bool = false

    /// Cycle 8.45 audit risk #2 — set to `true` while the TCC monitor
    /// says at least one required surface is revoked. Guarded by `lock`.
    /// While `true`, `resumeFromTCC` is a no-op until every revoked
    /// surface has restored.
    private var pausedForTCC: Bool = false

    /// The surfaces currently observed as revoked. Populated by the
    /// TCC monitor's transition callback. When empty, `pausedForTCC`
    /// flips to `false` and the SCStream is brought back up. `String`-
    /// keyed (over `TCCSurface` enum) so tests can inspect it via the
    /// internal accessor without exporting the enum outside the kit.
    private var revokedSurfaces: Set<TCCSurface> = []

    public init(
        pipeline: SCStreamPipeline,
        denylist: Denylist,
        policy: StreamPolicy = .default,
        blackedRegionProbe: PixelGridBlackedRegionProbe? = nil,
        contextSnapshot: WorkflowContextSnapshot? = nil,
        urlProvider: URLProvider? = nil,
        ocrPostAllowEmitter: (any OCRPostAllowEmitter)? = nil,
        focusedWindowStore: FocusedWindowStore? = nil,
        focusTracker: FocusTracker? = nil,
        tccStatusMonitor: TCCStatusMonitor? = nil,
        runtimeFailureHandler: @escaping CaptureRuntimeFailureHandler = { failure in
            SCStreamCaptureSession.terminateHelper(for: failure)
        }
    ) {
        self.pipeline = pipeline
        self.denylist = denylist
        self.policy = policy
        self.blackedRegionProbe = blackedRegionProbe
        self.contextSnapshot = contextSnapshot
        self.urlProvider = urlProvider
        self.ocrPostAllowEmitter = ocrPostAllowEmitter
        self.focusedWindowStore = focusedWindowStore
        self.focusTracker = focusTracker
        self.tccStatusMonitor = tccStatusMonitor
        self.runtimeFailureHandler = runtimeFailureHandler
        self.sampleQueue = DispatchQueue(label: "com.mci.capture.sample", qos: .userInitiated)
        super.init()
        // The monitor holds a weak observer, so this create-then-set
        // pattern does not create a retain cycle.
        self.tccStatusMonitor?.setObserver(self)
    }

    /// Start the live capture stream.
    ///
    /// Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
    /// `SCShareableContent.current` (inside `makeDisplayFilter`),
    /// `SCStream` construction, `startCapture()` all require a real
    /// screen + Screen-Recording TCC grant. Only reachable via the
    /// non-default `--capture` dev flag (Amendment 1 §4).
    ///
    /// ADR-0031 V2-P1 third-lift (Phase 7 PR 13 wiring): when
    /// `focusedWindowStore` was supplied, the FocusTracker is started
    /// first, an initial focused-window snapshot is read, and the
    /// SCStream filter is bound to a MULTI-WINDOW include-set via
    /// `SCContentFilterFactory.makeMultiWindowFilter(...)` — the
    /// FORK 3 = B ratified `SCContentFilter(display:including:
    /// exceptingWindows:)` shape (redesign memo §1.1 +
    /// `orchestrator-ratification-state-2026-05-31.md` §1). The include
    /// list is seeded with the focused window; co-view candidates are
    /// currently empty pending CEO §6.1 co-view-heuristic ratification
    /// — this matches redesign-memo §6.1 alternative A (focused-only-
    /// via-multi-window-API), which delivers the API-correctness value
    /// of the third lift without depending on unratified heuristics.
    ///
    /// When no focused window is observable on the initial read (login
    /// window, fast-user-switch, no eligible window), `start()` refuses
    /// to build a multi-window filter and logs one stderr breadcrumb
    /// (`helper_health: no_eligible_window`) to satisfy the task
    /// discipline "do NOT throw — this is a routine no-content case."
    /// The session falls back to the pre-V2-P1 `makeDisplayFilter(...)`
    /// so startup is never blocked; the background rebind task will
    /// swap to the multi-window filter once focus becomes observable.
    /// The race gate covers the transition (sentinel `installedFocus
    /// Generation == 0` fail-close, §5.2 hardening).
    ///
    /// When `focusedWindowStore` is `nil` the session preserves
    /// pre-V2-P1 display-filter behaviour byte-for-byte (legacy /
    /// headless test path).
    public func start() async throws {
        if let failure = currentRuntimeFailure() {
            // A terminal callback means the session is no longer a valid
            // capture owner. Requiring a fresh session prevents a caller from
            // silently turning a failed capture back into a healthy status.
            throw failure
        }
        lock.withLock { shutdownRequested = false }
        // Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
        // Force the §2 probe back to its fail-safe initial state so a
        // stale flag from a prior session cannot bleed into this one.
        blackedRegionProbe?.reset()

        // Publish one focus observation before selecting the initial filter.
        // `start()`'s immediate timer tick is asynchronous and cannot provide
        // this ordering guarantee by itself.
        await focusTracker?.refreshOnce()
        focusTracker?.start()

        // Establish the permission state before either ScreenCaptureKit API is
        // allowed to run. A denied boot surface leaves the session paused; the
        // monitor will call `resumeFromTCC` after consent is restored.
        await activateTCCMonitoring()
        guard let lifecycleEpoch = beginCaptureLifecycle() else { return }

        let filter: SCContentFilter
        let initialFocusGeneration: UInt64
        let initialIncludeListSize: UInt32
        if let store = focusedWindowStore {
            let initialSnapshot = store.currentSync()
            // Runtime guard: the initial focused-window read may miss
            // (no frontmost, login window, fast-user-switch transition,
            // lock screen, no eligible window). Do NOT construct the
            // multi-window filter with an empty include-set — that
            // would throw `emptyIncludeSet` from the factory (correct
            // fail-closed direction, but startup is not the right place
            // to surface that as an error). Instead, log a helper_health
            // stderr breadcrumb and fall back to the display filter so
            // capture is never blocked; the background rebind task will
            // pick up the first focused window observation and swap to
            // the multi-window include-set. This satisfies the task's
            // "graceful log-and-skip, not throw" discipline for the
            // no-eligible-window case.
            if let focused = initialSnapshot.focused,
               let multiWindowFilter = try await SCContentFilterFactory.makeMultiWindowFilter(
                   focusedWindowId: focused.windowId,
                   // Seed-only include-set pending CEO §6.1 co-view
                   // heuristic ratification. Redesign memo §6.1 alt A.
                   coViewWindowIds: [],
                   denylist: denylist
               )
            {
                filter = multiWindowFilter
                initialFocusGeneration = initialSnapshot.generation
                // Seed-only include-set ⇒ size 1. The factory's non-
                // empty post-condition (redesign memo §1.1 + scaffold
                // helper's precondition) guarantees ≥1.
                initialIncludeListSize = 1
            } else {
                // Runtime guard: no eligible window is observable at
                // startup. Log a helper_health breadcrumb per the
                // Phase 7 PR 13 dispatch discipline. Content-free —
                // only the reason token reaches stderr.
                FileHandle.standardError.write(
                    ("mci-capture-helper: helper_health: no_eligible_window "
                     + "at startup — falling back to display filter; the "
                     + "rebind task will swap to the multi-window include-"
                     + "set once focus is observable.\n")
                        .data(using: .utf8) ?? Data()
                )
                filter = try await SCContentFilterFactory.makeDisplayFilter(denylist: denylist)
                // Sentinel `0` — race gate will fire on every frame
                // until the rebind task installs a real focused filter
                // (§5.2 sentinel fail-close hardening).
                initialFocusGeneration = 0
                initialIncludeListSize = 0
            }
        } else {
            filter = try await SCContentFilterFactory.makeDisplayFilter(denylist: denylist)
            initialFocusGeneration = 0
            initialIncludeListSize = 0
        }
        let configuration = SCStreamConfigFactory.makeConfiguration(policy: policy)
        let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        guard registerCandidateStream(
            scStream,
            generation: initialFocusGeneration,
            epoch: lifecycleEpoch
        ) else {
            throw CancellationError()
        }
        do {
            try await scStream.startCapture()
        } catch {
            discardCandidateStream(scStream, expectingTermination: true)
            _ = await stopExpectedStream(scStream)
            throw error
        }
        let installed = commitCandidateStream(
            scStream,
            generation: initialFocusGeneration,
            epoch: lifecycleEpoch
        )
        guard installed.installed else {
            discardCandidateStream(scStream, expectingTermination: true)
            _ = await stopExpectedStream(scStream)
            return
        }
        storeIncludeListSize(initialIncludeListSize)
        startRebindTaskIfNeeded()
    }

    /// Stop the live capture stream (idempotent).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public func stop() async throws {
        // UNVERIFIED — needs live macOS; do not claim working.
        invalidateCaptureLifecycle(shutdown: true)
        let rebind = cancelRebindTask()
        focusTracker?.stop()
        let streams = takeAllStreamsExpectingTermination()
        var firstStopError: Error?
        for stream in streams {
            do {
                try await stream.stopCapture()
            } catch {
                if firstStopError == nil { firstStopError = error }
            }
        }
        await rebind?.value
        await tccStatusMonitor?.stopAndDrain()
        await captureDispatcher.finishAndDrain()
        await ocrPostAllowEmitter?.stopAndDrain()
        // No frames will arrive after `stopCapture()`; clear the §2
        // verdict so a subsequent `start()` begins from fail-safe.
        blackedRegionProbe?.reset()
        // Clear the TCC pause so a fresh `start()` on the same instance
        // can re-arm the monitor from a clean state.
        lock.withLock {
            pausedForTCC = false
            revokedSurfaces.removeAll()
        }
        if let firstStopError { throw firstStopError }
    }

    // Locked critical sections live in non-async helpers: `NSLock` is
    // unavailable from async contexts under Swift 6 strict concurrency,
    // and these are the only mutable state.
    private func beginCaptureLifecycle() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard !pausedForTCC,
              !shutdownRequested,
              runtimeFailure == nil
        else {
            return nil
        }
        captureEpoch &+= 1
        captureLifecycleActive = true
        return captureEpoch
    }

    private func invalidateCaptureLifecycle(shutdown: Bool = false) {
        lock.lock()
        captureEpoch &+= 1
        captureLifecycleActive = false
        if shutdown { shutdownRequested = true }
        installedFocusGeneration = 0
        priorDHash = nil
        priorDHashGeneration = 0
        priorDHashCaptureOrdinal = 0
        retryOCRGeneration = nil
        lock.unlock()
    }

    private func currentActiveCaptureEpoch() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard captureLifecycleActive,
              !pausedForTCC,
              !shutdownRequested,
              runtimeFailure == nil
        else {
            return nil
        }
        return captureEpoch
    }

    private func registerCandidateStream(
        _ candidate: SCStream,
        generation: UInt64,
        epoch: UInt64
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard captureLifecycleActive,
              captureEpoch == epoch,
              !pausedForTCC,
              !shutdownRequested,
              runtimeFailure == nil
        else {
            return false
        }
        streamFocusGenerations[ObjectIdentifier(candidate)] = generation
        candidateStreams[ObjectIdentifier(candidate)] = candidate
        installedFocusGeneration = generation
        priorDHash = nil
        priorDHashGeneration = generation
        priorDHashCaptureOrdinal = 0
        retryOCRGeneration = nil
        return true
    }

    private func discardCandidateStream(
        _ candidate: SCStream,
        expectingTermination: Bool
    ) {
        lock.lock(); defer { lock.unlock() }
        streamFocusGenerations.removeValue(forKey: ObjectIdentifier(candidate))
        candidateStreams.removeValue(forKey: ObjectIdentifier(candidate))
        if expectingTermination {
            expectedTerminatedStreams.append(candidate)
        }
        installedFocusGeneration = stream.flatMap {
            streamFocusGenerations[ObjectIdentifier($0)]
        } ?? 0
        priorDHash = nil
        priorDHashGeneration = installedFocusGeneration
        priorDHashCaptureOrdinal = 0
        retryOCRGeneration = nil
    }

    private func commitCandidateStream(
        _ candidate: SCStream,
        generation: UInt64,
        epoch: UInt64
    ) -> (installed: Bool, replaced: SCStream?) {
        lock.lock(); defer { lock.unlock() }
        guard captureLifecycleActive,
              captureEpoch == epoch,
              !pausedForTCC,
              !shutdownRequested,
              runtimeFailure == nil,
              streamFocusGenerations[ObjectIdentifier(candidate)] == generation
        else {
            return (false, nil)
        }
        let old = stream
        candidateStreams.removeValue(forKey: ObjectIdentifier(candidate))
        stream = candidate
        installedFocusGeneration = generation
        priorDHash = nil
        priorDHashGeneration = generation
        priorDHashCaptureOrdinal = 0
        retryOCRGeneration = nil
        if let old, old !== candidate {
            streamFocusGenerations.removeValue(forKey: ObjectIdentifier(old))
            expectedTerminatedStreams.append(old)
        }
        return (true, old)
    }

    private func streamFocusGeneration(_ source: SCStream) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return streamFocusGenerations[ObjectIdentifier(source)]
    }

    private func takeAllStreamsExpectingTermination() -> [SCStream] {
        lock.lock(); defer { lock.unlock() }
        var streams = Array(candidateStreams.values)
        if let stream,
           !streams.contains(where: { $0 === stream })
        {
            streams.append(stream)
        }
        stream = nil
        candidateStreams.removeAll()
        streamFocusGenerations.removeAll()
        installedFocusGeneration = 0
        priorDHash = nil
        priorDHashGeneration = 0
        priorDHashCaptureOrdinal = 0
        retryOCRGeneration = nil
        for s in streams {
            // A stop delegate callback may be delivered asynchronously after
            // `stopCapture()` returns. Retain identity until that callback so
            // an intentional stop is never classified as a runtime failure.
            expectedTerminatedStreams.append(s)
        }
        return streams
    }

    /// Stop a stream already registered as an intentional teardown. A failed
    /// stop can leave pixels flowing after the session claims capture is off,
    /// so it is a terminal owner failure rather than ignorable cleanup noise.
    private func stopExpectedStream(_ stream: SCStream) async -> Bool {
        do {
            try await stream.stopCapture()
            return true
        } catch {
            reportTerminalCaptureFailure()
            return false
        }
    }

    private func reportTerminalCaptureFailure() {
        guard claimUnexpectedStreamTermination(nil) else { return }
        handleClaimedRuntimeFailure()
    }

    private func currentRuntimeFailure() -> CaptureRuntimeFailure? {
        lock.lock(); defer { lock.unlock() }
        return runtimeFailure
    }

    private func isShutdownRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return shutdownRequested
    }

    private func currentPriorDHash(for generation: UInt64) -> DHash? {
        lock.lock(); defer { lock.unlock() }
        guard priorDHashGeneration == generation else { return nil }
        return priorDHash
    }

    private func commitPriorDHash(
        _ next: DHash,
        generation: UInt64,
        captureOrdinal: UInt64
    ) {
        lock.lock(); defer { lock.unlock() }
        guard installedFocusGeneration == generation else { return }
        priorDHash = next
        priorDHashGeneration = generation
        priorDHashCaptureOrdinal = captureOrdinal
        if retryOCRGeneration == generation {
            retryOCRGeneration = nil
        }
    }

    private func revokePriorDHashForRetry(
        generation: UInt64,
        captureOrdinal: UInt64
    ) {
        lock.lock(); defer { lock.unlock() }
        guard CaptureBaselinePolicy.shouldRevokeForRetry(
            currentGeneration: priorDHashGeneration,
            currentCaptureOrdinal: priorDHashCaptureOrdinal,
            retryGeneration: generation,
            retryCaptureOrdinal: captureOrdinal
        ) else {
            return
        }
        priorDHash = nil
        priorDHashCaptureOrdinal = 0
        retryOCRGeneration = generation
    }

    private func isOCRRetryPending(for generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return retryOCRGeneration == generation
    }

    private func allocateCaptureOrdinal() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        captureOrdinal &+= 1
        return captureOrdinal
    }

    /// Read the currently-installed focus generation. Lock-guarded.
    private func currentInstalledFocusGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return installedFocusGeneration
    }

    /// Write the include-list size observed at the most recent
    /// SCStream filter (re)bind. Lock-guarded. Emits one stderr
    /// breadcrumb per bind so the live-Mac smoke test / later
    /// inspection can correlate include-set membership against the
    /// harness fixtures (redesign memo §3.2.3 H8′ / §3.2.4 H9′).
    private func storeIncludeListSize(_ size: UInt32) {
        lock.lock()
        lastIncludeListSize = size
        lock.unlock()
        // Content-free breadcrumb (numeric only — no bundle id, no
        // window id, no title). Steady-state cost = one FileHandle
        // write per SCStream rebind (bounded by focus-change rate;
        // the rebind task runs at 200 ms cadence with no-op-suppress
        // via generation comparison).
        FileHandle.standardError.write(
            ("mci-capture-helper: helper_health: include_list_size=\(size)\n")
                .data(using: .utf8) ?? Data()
        )
    }

    /// Test-only accessor for the last observed include-set size.
    /// `internal` so `@testable import` can prove the (re)bind
    /// bookkeeping without introducing a public API surface.
    internal func lastIncludeListSizeForTest() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return lastIncludeListSize
    }

    /// Increment and return the per-session race-drop count. Guarded
    /// by `lock`. Called by the SCStream callback's race gate before
    /// dispatching the pipeline's `emitFocusRaceDropped(...)`.
    private func bumpFocusRaceDropSeen() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        focusRaceDropSeen &+= 1
        return focusRaceDropSeen
    }

    /// Test-only accessor for the race-drop-seen counter.
    internal func focusRaceDropSeenForTest() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return focusRaceDropSeen
    }

    /// Start the background task that replaces the stream when focus changes.
    /// Lock-guarded; second call while running is a no-op.
    ///
    /// Cadence matches the FocusTracker's default 200 ms identity poll. The
    /// generation gate covers the residual window while replacement starts.
    private func startRebindTaskIfNeeded() {
        guard focusedWindowStore != nil else { return }
        lock.lock()
        guard rebindTask == nil else { lock.unlock(); return }
        let store = focusedWindowStore!
        let task = Task { [weak self] in
            // Poll cadence: 200 ms. The generation gate covers the interval
            // between observation and the replacement stream becoming active.
            while !Task.isCancelled {
                let snap = store.currentSync()
                let installed = self?.currentInstalledFocusGeneration() ?? 0
                if snap.generation != installed,
                   let focused = snap.focused
                {
                    try? await self?.rebindFocusedWindow(
                        focusedWindow: focused,
                        snapshotGeneration: snap.generation
                    )
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        rebindTask = task
        lock.unlock()
    }

    /// Cancel the rebind task (idempotent).
    @discardableResult
    private func cancelRebindTask() -> Task<Void, Never>? {
        lock.lock()
        let t = rebindTask
        rebindTask = nil
        lock.unlock()
        t?.cancel()
        return t
    }

    /// Replace the live stream for a new focused-window generation. A stream's
    /// generation is registered before `startCapture()` can emit its first
    /// callback and never changes afterward. Queued callbacks from the replaced
    /// stream therefore retain their old provenance and fail the generation gate.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`. Stream
    /// replacement requires a live display; the filter-selection decision is
    /// auditable headlessly via the
    /// `SCContentFilterFactory.selectFocusedWindow(...)` helper.
    public func rebindFocusedWindow(
        focusedWindow: FocusedWindow,
        snapshotGeneration: UInt64
    ) async throws {
        guard let lifecycleEpoch = currentActiveCaptureEpoch() else { return }
        // V2-P1 third-lift (Phase 7 PR 13 wiring): the rebind path
        // also uses the multi-window FORK 3 = B API form. Seed-only
        // include-set pending CEO §6.1 co-view heuristic ratification.
        guard let newFilter = try await SCContentFilterFactory.makeMultiWindowFilter(
            focusedWindowId: focusedWindow.windowId,
            coViewWindowIds: [],
            denylist: denylist
        ) else {
            // Focused window was not in `SCShareableContent` (closed /
            // off-screen) OR its owning app is denylisted. Do NOT
            // rebind — the prior filter stays installed and the race
            // gate continues to fire on every frame until the next
            // focus change. This is the safe direction: a denylisted
            // app's window can NEVER become the SCStream's bound
            // window per ADR-0013 §1.
            return
        }
        guard currentActiveCaptureEpoch() == lifecycleEpoch,
              focusedWindowStore?.currentSync().generation == snapshotGeneration
        else {
            return
        }

        let configuration = SCStreamConfigFactory.makeConfiguration(policy: policy)
        let replacement = SCStream(
            filter: newFilter,
            configuration: configuration,
            delegate: self
        )
        try replacement.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        guard registerCandidateStream(
            replacement,
            generation: snapshotGeneration,
            epoch: lifecycleEpoch
        ) else {
            return
        }
        do {
            try await replacement.startCapture()
        } catch {
            discardCandidateStream(replacement, expectingTermination: true)
            _ = await stopExpectedStream(replacement)
            throw error
        }
        guard focusedWindowStore?.currentSync().generation == snapshotGeneration else {
            discardCandidateStream(replacement, expectingTermination: true)
            _ = await stopExpectedStream(replacement)
            return
        }
        let installed = commitCandidateStream(
            replacement,
            generation: snapshotGeneration,
            epoch: lifecycleEpoch
        )
        guard installed.installed else {
            discardCandidateStream(replacement, expectingTermination: true)
            _ = await stopExpectedStream(replacement)
            return
        }
        // Seed-only include-set (redesign-memo §6.1 alt A) ⇒ size 1.
        // Future co-view-heuristic wiring lifts this above 1.
        storeIncludeListSize(1)
        if let replaced = installed.replaced,
           !(await stopExpectedStream(replaced))
        {
            throw CaptureRuntimeFailure.streamStoppedUnexpectedly
        }
    }

    /// Atomically claim the right to emit the one-shot "first sample
    /// received" stderr breadcrumb. Returns `true` exactly once across
    /// the session's lifetime (the first caller wins); every subsequent
    /// call returns `false` so steady-state cost is a single locked
    /// read of a `Bool`. The SCStreamOutput callback fires on
    /// `sampleQueue`; this method is safe to call from any thread.
    ///
    /// `internal` (not `private`) only so the headless lifetime tests
    /// can prove the one-shot contract directly. Not public API.
    internal func claimFirstSampleLogSlot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if firstSampleLogged { return false }
        firstSampleLogged = true
        return true
    }

    // MARK: - ADR-0015 §6 P2.5 — pure context-build helper

    /// Pure, OS-free assembly of the `WorkflowContext` the cascade
    /// consumes. Factored out of the SCStream callback so the
    /// decision matrix (snapshot present / absent / partial; URL
    /// provider present / absent; bundleId empty vs populated) is
    /// unit-testable headlessly. Mirrors the
    /// `CapturedSampleExtractor.computeDHash9x8` / `makeCandidateFrame`
    /// pattern: the OS-touching read is in the live `// UNVERIFIED`
    /// callback; the pure assembly is tested here.
    ///
    /// Behaviour:
    ///   - `snapshot == nil` ⇒ pre-P2.5 fallback (use the bundleId the
    ///     in-callback extractor surfaced, which is currently nil
    ///     by design — see `extractSynchronously`). The cascade
    ///     treats an all-nil context as "unknown app" → fail-closed
    ///     under §7. This branch exists only so legacy / headless
    ///     test constructions can keep building the session without
    ///     wiring a snapshot.
    ///   - `snapshot != nil` ⇒ read `currentSync()` (non-blocking,
    ///     `OSAllocatedUnfairLock`-protected). For a populated
    ///     non-empty bundleId, invoke the URL provider once
    ///     synchronously; the per-browser provider's ≤1 s TTL cache
    ///     (ADR-0015 §3) caps actual AppleScript invocations at ~1/s
    ///     in the steady state.
    ///   - `pageText` is always `nil`; populated by Phase 3 (Vision
    ///     OCR) per DESIGN.md §15 + ADR-0015 §1.4.
    ///
    /// Privacy invariants honoured by construction (ADR-0015 §4):
    ///   - context-as-content — the assembled struct is the cascade's
    ///     *input*; this helper writes nothing to disk / IPC / any
    ///     sink. The caller (`SCStreamPipeline.process(...)`) routes
    ///     it through the cascade BEFORE any storage decision.
    ///   - no auto-grant Apple Events — the URL provider call is a
    ///     pass-through; the per-browser provider's `nil` on denial
    ///     surfaces here as `url == nil`, exactly as if AppleScript
    ///     had never been attempted.
    internal static func buildWorkflowContext(
        snapshot: WorkflowContextSnapshot?,
        urlProvider: URLProvider?,
        fallbackAppBundleId: String?,
        focusedSnapshot: FocusedWindowSnapshot? = nil
    ) -> WorkflowContext {
        // ADR-0031 V2-P1: when a focused-window snapshot is supplied,
        // its `bundleId` is the SOURCE OF TRUTH for OCREvent
        // attribution — the captured pixel surface IS the focused
        // window per Option (a), so the cascade must see the focused
        // window's bundle, not the polled frontmost-app id. In practice
        // they match (the focused window's owning app == the
        // frontmost app), but only the focused-window read composes
        // correctly with the §5.3 race-consistency gate.
        let focusedBundleId: String? = focusedSnapshot?.focused?.bundleId

        guard let snapshotActor = snapshot else {
            // No `WorkflowContextSnapshot` wired (legacy / headless
            // tests). Use the focused-window bundle id when available,
            // fall back to the in-callback extractor's nil-by-design
            // bundle id otherwise.
            return WorkflowContext(
                appBundleId: focusedBundleId ?? fallbackAppBundleId,
                windowTitle: nil,
                url: nil,
                pageText: nil
            )
        }
        let observation = snapshotActor.currentObservationSync()
        let snap = observation.context
        let effectiveBundleId: String? = focusedBundleId ?? snap.appBundleId
        let admittedWindowTitle: String?
        if let focusedSnapshot {
            admittedWindowTitle = FocusedContextPolicy.admittedWindowTitle(
                snapshotBundleId: snap.appBundleId,
                effectiveBundleId: effectiveBundleId,
                snapshotFocusGeneration: observation.focusGeneration,
                effectiveFocusGeneration: focusedSnapshot.generation,
                windowTitle: snap.windowTitle
            )
        } else {
            // Legacy display-scoped construction has no focus provenance to
            // compare. Preserve its existing context behavior; production
            // focused-window capture always takes the generation-bound branch.
            admittedWindowTitle = snap.windowTitle
        }
        let resolvedUrl: String?
        if let id = effectiveBundleId, !id.isEmpty {
            // V2-P2: pass the focused-window CGWindowID so the URL
            // provider's `(bundleId, focusedWindowId)` cache key
            // invalidates on inter-window focus changes (memo
            // `docs/research/tab-attribution-mix-2026-05-29.md` §3).
            let focusedWindowId: UInt32? = focusedSnapshot?.focused.map { UInt32($0.windowId) }
            resolvedUrl = urlProvider?.activeTabURL(
                forFrontmost: id,
                focusedWindowId: focusedWindowId
            )
        } else {
            resolvedUrl = nil
        }
        return WorkflowContext(
            appBundleId: effectiveBundleId,
            windowTitle: admittedWindowTitle,
            url: resolvedUrl,
            pageText: nil
        )
    }

    /// Bring up only the SCStream after a required TCC permission is
    /// restored. The focus tracker and TCC monitor remain active while
    /// capture is paused, so they must not be started a second time.
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    private func bringUpSCStreamOnly(lifecycleEpoch: UInt64) async throws {
        // UNVERIFIED — needs live macOS; do not claim working.
        let filter: SCContentFilter
        let initialFocusGeneration: UInt64
        if let store = focusedWindowStore {
            let initialSnapshot = store.currentSync()
            if let focused = initialSnapshot.focused,
               let focusedFilter = try await SCContentFilterFactory.makeMultiWindowFilter(
                   focusedWindowId: focused.windowId,
                   coViewWindowIds: [],
                   denylist: denylist
               )
            {
                filter = focusedFilter
                initialFocusGeneration = initialSnapshot.generation
            } else {
                filter = try await SCContentFilterFactory.makeDisplayFilter(denylist: denylist)
                initialFocusGeneration = 0
            }
        } else {
            filter = try await SCContentFilterFactory.makeDisplayFilter(denylist: denylist)
            initialFocusGeneration = 0
        }
        let configuration = SCStreamConfigFactory.makeConfiguration(policy: policy)
        let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        guard registerCandidateStream(
            scStream,
            generation: initialFocusGeneration,
            epoch: lifecycleEpoch
        ) else {
            throw CancellationError()
        }
        do {
            try await scStream.startCapture()
        } catch {
            discardCandidateStream(scStream, expectingTermination: true)
            _ = await stopExpectedStream(scStream)
            throw error
        }
        let installed = commitCandidateStream(
            scStream,
            generation: initialFocusGeneration,
            epoch: lifecycleEpoch
        )
        guard installed.installed else {
            discardCandidateStream(scStream, expectingTermination: true)
            _ = await stopExpectedStream(scStream)
            throw CancellationError()
        }
        if let replaced = installed.replaced,
           !(await stopExpectedStream(replaced))
        {
            throw CaptureRuntimeFailure.streamStoppedUnexpectedly
        }
    }

    // MARK: - Cycle 8.45 — TCC pause/resume

    /// Apply the boot-time permission snapshot, then begin transition
    /// monitoring. The monitor itself intentionally does not emit callbacks
    /// while seeding, so startup owns the initial fail-closed state explicitly.
    internal func activateTCCMonitoring() async {
        guard let tccStatusMonitor else { return }
        tccStatusMonitor.seedInitialSnapshot()
        let initialStatuses = tccStatusMonitor.currentStatuses()
        for (surface, status) in initialStatuses where status == .denied {
            await pauseForTCC(surface: surface)
        }
        tccStatusMonitor.start()
    }

    /// Pause the live SCStream because the TCC monitor observed a
    /// mid-run permission revoke. Idempotent per-surface. Emits a
    /// stderr `helper_health tcc_revoked=<surface>` breadcrumb the
    /// parent app tails to drive the menu-bar red pill + user
    /// notification (`TCCRevokedNotifier` in HippocampusKit). Content-
    /// free: only the enum-name of the revoked surface crosses the
    /// process boundary — no file paths, no bundle-ids, no user data.
    ///
    /// The pause drops the SCStream strong ref, so the ingest pipeline
    /// sees a clean capture-off surface (M4 kill-switch pattern) — the
    /// user's expectation "revoke Screen Recording ⇒ MCI stops
    /// recording" is now honoured atomically, not silently violated.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working` for
    /// the OS-touching `stopCapture()`; the state-flag logic is
    /// headless-tested.
    public func pauseForTCC(surface: TCCSurface) async {
        let (alreadyRevoked, wasPaused) = lock.withLock { () -> (Bool, Bool) in
            let alreadyRevoked = revokedSurfaces.contains(surface)
            revokedSurfaces.insert(surface)
            let wasPaused = pausedForTCC
            pausedForTCC = true
            captureEpoch &+= 1
            captureLifecycleActive = false
            installedFocusGeneration = 0
            priorDHash = nil
            priorDHashGeneration = 0
            priorDHashCaptureOrdinal = 0
            retryOCRGeneration = nil
            return (alreadyRevoked, wasPaused)
        }

        if alreadyRevoked { return }

        FileHandle.standardError.write(
            TCCHelperHealth.line(
                for: TCCStatusMonitor.Transition(
                    surface: surface,
                    oldStatus: .granted,
                    newStatus: .denied
                )
            ).data(using: .utf8) ?? Data()
        )

        guard !wasPaused else { return }

        // UNVERIFIED — needs live macOS; do not claim working.
        let streams = takeAllStreamsExpectingTermination()
        for stream in streams {
            _ = await stopExpectedStream(stream)
        }
    }

    /// Resume from a TCC pause. Called by the observer when the
    /// monitor's debounced verdict returns to `.granted` for a
    /// previously-revoked surface. If OTHER surfaces remain revoked,
    /// this is a no-op (bookkeeping only) — the SCStream stays down
    /// until every required TCC surface is back. If the SCStream
    /// rebuild throws (e.g. the OS is still catching up on the grant),
    /// the session stays paused and the next monitor tick can retry
    /// via the same path.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public func resumeFromTCC(surface: TCCSurface) async throws {
        guard !isShutdownRequested() else { return }
        let stillRevoked = lock.withLock { () -> Bool in
            revokedSurfaces.remove(surface)
            return !revokedSurfaces.isEmpty
        }

        FileHandle.standardError.write(
            TCCHelperHealth.line(
                for: TCCStatusMonitor.Transition(
                    surface: surface,
                    oldStatus: .denied,
                    newStatus: .granted
                )
            ).data(using: .utf8) ?? Data()
        )

        if stillRevoked {
            // Another required permission remains revoked. Its restoration
            // will retry once every required TCC surface is available.
            return
        }

        lock.withLock { pausedForTCC = false }

        do {
            guard let lifecycleEpoch = beginCaptureLifecycle() else {
                throw CancellationError()
            }
            try await bringUpSCStreamOnly(lifecycleEpoch: lifecycleEpoch)
            startRebindTaskIfNeeded()
        } catch {
            if isShutdownRequested() { return }
            // The OS hasn't caught up on the grant yet — go back to
            // paused and require two fresh granted samples so the monitor
            // emits another denied-to-granted transition.
            lock.withLock {
                pausedForTCC = true
                revokedSurfaces.insert(surface)
            }
            tccStatusMonitor?.requireFreshGrantForRetry(surface: surface)
            FileHandle.standardError.write(
                "mci-capture-helper: SCStream resume-from-TCC-\(surface.rawValue) failed (staying paused): \(error)\n"
                    .data(using: .utf8) ?? Data()
            )
            throw error
        }
    }

    /// Test-only accessors — prove the pause state without exposing
    /// mutable fields. Not public API.
    internal func isPausedForTCCForTest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pausedForTCC
    }

    internal func revokedSurfacesForTest() -> Set<TCCSurface> {
        lock.lock(); defer { lock.unlock() }
        return revokedSurfaces
    }

    // MARK: - SCStreamOutput

    /// The live frame callback. Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
    ///
    /// Contract enforced here (Amendment 1 §3(c)/(d)): the metadata +
    /// dHash are read SYNCHRONOUSLY into `InCallbackSample` (a
    /// `Sendable` value). PR-2 ALSO retains the pixel buffer
    /// (`CVPixelBufferRetainedSurface`) so PR-3's encoder can outlive
    /// the callback — but nothing encodes/stores it here (no-op
    /// encoder), and the retain is released by the pipeline's
    /// exactly-once `defer` on every exit ⇒ no pool-stall, no stored
    /// frame.
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
        guard outputType == .screen else { return }

        // SCSTREAM-LIVE-001 observability: one-shot stderr breadcrumb
        // proving the callback wired up at least once. Content-free,
        // not a stored frame, not on the wire. The lifetime fix in
        // main.swift is what made this callback reachable; this line
        // gives the human Step-1 re-verify an unambiguous "callback
        // alive" signal without a wire schema bump. Cleared once
        // emitted so steady-state cost is a single locked-read of a
        // `Bool` per frame.
        if claimFirstSampleLogSlot() {
            FileHandle.standardError.write(
                "mci-capture-helper: SCStream callback alive: first sample received.\n"
                    .data(using: .utf8) ?? Data()
            )
        }

        processScreenSample(
            sampleBuffer,
            requiredFocusGeneration: streamFocusGeneration(stream)
        )
    }

    /// Shared ingestion path for focused-window streaming frames. No caller can
    /// reach OCR without passing the generation gate, the pixel-time privacy
    /// snapshot, and `SCStreamPipeline.process(...)`.
    private func processScreenSample(
        _ sampleBuffer: CMSampleBuffer,
        requiredFocusGeneration: UInt64?
    ) {
        guard let sample = Self.extractSynchronously(from: sampleBuffer) else { return }
        let callbackOrdinal = allocateCaptureOrdinal()
        let baselineGeneration = requiredFocusGeneration ?? 0
        let retryPending = isOCRRetryPending(for: baselineGeneration)
        let effectiveDirtyRects = CaptureBaselinePolicy.effectiveDirtyRects(
            reported: sample.dirtyRects,
            frameStatusComplete: sample.frameStatusComplete,
            frameWidth: sample.frameWidth,
            frameHeight: sample.frameHeight,
            retryPending: retryPending
        )

        // ADR-0013 §2: classify this frame's synchronously extracted 9×8
        // luminance grid as a pure value. O(72), well under the hot-path
        // budget; no shared probe state can bleed across queued frames.
        let frameHasBlackedRegion = blackedRegionProbe.map { probe in
            probe.classify(grayscale: sample.grayscale)
        }

        // Close the interval between periodic focus polls only for frames that
        // can reach OCR. Idle/incomplete callbacks remain a lock-only path.
        if sample.frameStatusComplete, !effectiveDirtyRects.isEmpty {
            focusTracker?.refreshBindingOnceSync()
        }

        // ADR-0031 §5.3 — race-consistency gate. When the session is
        // wired with a `focusedWindowStore` (Option (a) is active),
        // compare the generation observed at THIS sample timestamp
        // against the generation the live SCStream filter was bound
        // under. A mismatch means focus changed between filter install
        // and frame delivery — the captured pixels may belong to a
        // different window than the focused-window snapshot reports.
        // Fail closed: emit a `focusRaceDropped` tombstone via the
        // pipeline and skip cascade + encode + OCR for this frame.
        //
        // Read the snapshot once into a local so the focused-window
        // bundle id reaches `buildWorkflowContext(...)` AND the same
        // generation drives the gate — no torn read between the gate
        // decision and the attribution decision.
        //
        // V2-P1 PRODUCTION HARDENING (per
        // `docs/research/v2-p1-production-leak-2026-05-30.md` §5.2):
        // `installedFocusGeneration == 0` is the sentinel for "no
        // focused-window filter is currently bound" — either `start()`'s
        // inner-else fallback to `makeDisplayFilter(...)` ran (the
        // initial focused-window read missed: login window /
        // fast-user-switch / no observable focused window) or rebind
        // has not yet succeeded. In that state the captured pixel
        // surface is the display composite, NOT the focused window;
        // the bundle-keyed attribution gate is structurally unsafe
        // regardless of whether `focusedSnapshot.generation` happens
        // to also be 0. Without this check, the gate trivially passes
        // on the `0 == 0` boot edge and lets display-composite pixels
        // through with `WorkflowContextSnapshot.appBundleId`
        // attribution — exactly the cycle 8.17 misattribution channel.
        // Fail closed.
        //
        // `FocusedWindowStore.store(_:)` only bumps the generation
        // when `focused != nil`, so `generation == 0` ↔ "no focused-
        // window state has ever been observed." The sentinel is
        // unambiguous.
        let focusedSnapshot: FocusedWindowSnapshot? = focusedWindowStore?.currentSync()
        if focusedWindowStore != nil {
            let installedGen = currentInstalledFocusGeneration()
            if !CaptureGenerationPolicy.shouldAdmit(
                streamGeneration: requiredFocusGeneration,
                installedGeneration: installedGen,
                observedGeneration: focusedSnapshot?.generation
            ) {
                let nowUsForRace = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
                let raceBundle = focusedSnapshot?.focused?.bundleId ?? ""
                // The race gate runs before raw-pixel admission. Its
                // tombstone owns no CVPixelBuffer or IOSurface retain.
                let raceLease = SurfaceLease(releaser: BorrowedNoRetainReleaser())
                // V2-P1 third-lift (Phase 7 PR 13 wiring): throttled
                // stderr breadcrumb for `frames_focus_race_dropped`
                // counter increments. Log the first drop + every 100
                // drops thereafter so the CEO's live-Mac smoke can see
                // the race path is being exercised without stderr
                // saturation under a sustained race storm (the cycle
                // 8.27 shape hit 73 % — one line per drop would be
                // untenable). Content-free — count only, no bundle id.
                let seen = bumpFocusRaceDropSeen()
                if seen == 1 || seen.isMultiple(of: 100) {
                    FileHandle.standardError.write(
                        ("mci-capture-helper: helper_health: "
                         + "frames_focus_race_dropped=\(seen) "
                         + "(installedGen=\(installedGen), "
                         + "observedGen=\(focusedSnapshot?.generation.description ?? "nil"))\n")
                            .data(using: .utf8) ?? Data()
                    )
                }
                let pipeline = self.pipeline
                captureDispatcher.submit(
                    captureOrdinal: callbackOrdinal,
                    operation: {
                        try? await pipeline.emitFocusRaceDropped(
                            tsUs: nowUsForRace,
                            appBundle: raceBundle,
                            lease: raceLease
                        )
                    },
                    onDrop: {
                        raceLease.release()
                    }
                )
                return
            }
        }

        // Read without mutating. The baseline is committed only after the
        // pixel-time privacy snapshot permits raw pixels.
        let prior = currentPriorDHash(for: baselineGeneration)
        let frame = CapturedSampleExtractor.makeCandidateFrame(
            userIdle: sample.userIdle,
            frameStatusComplete: sample.frameStatusComplete,
            dirtyRects: effectiveDirtyRects,
            dhash: sample.dhash,
            priorDhash: prior
        )

        // ADR-0015 §6 P2.5 — context join. Delegates to the pure
        // `buildWorkflowContext(...)` helper below so the wiring is
        // exercisable from a headless test (`SCStreamCaptureSession`'s
        // SCStream callback itself is `// UNVERIFIED — needs live
        // macOS`; the *decision* about how the snapshot + URL provider
        // assemble into a `WorkflowContext` is pure and IS tested).
        //
        // ADR-0031 V2-P1: when `focusedSnapshot` is non-nil its
        // `bundleId` is the SOURCE OF TRUTH for OCREvent attribution.
        let context = Self.buildWorkflowContext(
            snapshot: contextSnapshot,
            urlProvider: urlProvider,
            fallbackAppBundleId: sample.appBundleId,
            focusedSnapshot: focusedSnapshot
        )
        let nowUs = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
        let evidenceCandidate = focusedSnapshot?.focused.map { focused in
            KeyframeEvidenceCandidate(
                captureOrdinal: callbackOrdinal,
                focusedWindowId: UInt32(focused.windowId),
                dhash: sample.dhash,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }

        // Freeze every mutable pixel-time privacy signal while this callback
        // still owns the frame. A later secure-input/AX/blacked-region change
        // must never authorize these pixels. Disallowed frames are dispatched
        // without obtaining or retaining their CVPixelBuffer.
        let pipelineSnapshot = self.pipeline
        let privacySnapshot = pipelineSnapshot.snapshotPixelPrivacy(
            context: context,
            hasBlackedRegion: frameHasBlackedRegion
        )
        if !privacySnapshot.permitsRawPixels {
            let lease = SurfaceLease(releaser: BorrowedNoRetainReleaser())
            captureDispatcher.submit(
                captureOrdinal: callbackOrdinal,
                operation: {
                    _ = try? await pipelineSnapshot.process(
                        frame: frame,
                        context: context,
                        nowUs: nowUs,
                        lease: lease,
                        privacySnapshot: privacySnapshot
                    )
                },
                onDrop: {
                    lease.release()
                }
            )
            return
        }

        // PR-2: retain the pixel buffer (⇒ its IOSurface) so a future
        // encoder (PR-3) can read it after the callback returns. The
        // retain is wrapped in a `SurfaceLease`, which the pipeline
        // releases exactly once on EVERY exit path via its single
        // top-level `defer`. If the buffer can't be obtained we fall
        // back to the no-retain releaser (still correct — nothing to
        // free). Either way the §4 pool budget is respected because
        // the hold is bounded by the cascade + no-op encoder.
        //
        // ADR-0016 P3.6: ALSO capture the CVPixelBuffer reference
        // (Swift-side strong ref) so the OCR worker can read it after
        // the lease releases. The pixel-buffer reference is distinct
        // from the IOSurface lease; the worker holds it for the
        // duration of its Vision OCR submission. The §11 live-Mac
        // audit verifies the OS does not recycle the underlying
        // IOSurface storage during that window in practice.
        let releaser: any SurfaceReleasing
        // Build the OCR input in the callback's synchronous frame —
        // `OCREngineInput` is `@unchecked Sendable` (it documents the
        // single-owner-while-in-flight contract), so it crosses the
        // owned dispatcher boundary into the cascade-twice path cleanly.
        // `nil` when the sample carries no pixel buffer; the OCR path
        // is then skipped (no OCREvent ever reaches the wire).
        let ocrInput: OCREngineInput?
        // Preserve the encoder seam for pipeline ordering tests, but
        // production wires the no-op encoder. The post-OCR coordinator
        // is the only visual persistence path.
        let encoderInput: EncoderInput?
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // UNVERIFIED — needs live macOS; do not claim working.
            releaser = PixelSurfaceReleaser(
                surface: CVPixelBufferRetainedSurface(retaining: pb)
            )
            let roi = OCRROIComputer.normalizedBoundingROI(
                widthPx: CVPixelBufferGetWidth(pb),
                heightPx: CVPixelBufferGetHeight(pb),
                dirtyRects: effectiveDirtyRects
            )
            ocrInput = OCREngineInput(pixelBuffer: pb, roi: roi)
            encoderInput = EncoderInput(pixelBuffer: pb)
        } else {
            releaser = BorrowedNoRetainReleaser()
            ocrInput = nil
            encoderInput = nil
        }
        let lease = SurfaceLease(releaser: releaser)

        // Only `Sendable` values are captured — NOT the sample buffer.
        let ocrEmitter = self.ocrPostAllowEmitter
        captureDispatcher.submit(
            captureOrdinal: callbackOrdinal,
            operation: {
                // The single sink for a captured frame is the cascade-gated
                // pipeline. Production always hands `encoderInput` to the
                // no-op encoder; only the twice-cleared OCR branch below can
                // ask the retention coordinator to persist visual evidence.
                // A `.suppress` decision emits a tombstone and never reaches
                // encode — Amendment 1 §3(a)/(c) preserved by construction.
                let outcome = try? await pipelineSnapshot.process(
                    frame: frame,
                    context: context,
                    nowUs: nowUs,
                    lease: lease,
                    encoderInput: encoderInput,
                    privacySnapshot: privacySnapshot
                )
                // Commit only a successfully processed, cascade-allowed frame.
                // The generation check prevents an old queued operation from
                // poisoning a replacement stream's baseline.
                if CaptureBaselinePolicy.shouldCommit(outcome: outcome) {
                    self.commitPriorDHash(
                        sample.dhash,
                        generation: baselineGeneration,
                        captureOrdinal: callbackOrdinal
                    )
                }
                // ADR-0016 P3.6 — cascade-twice. On `.encoded` (pixel-time
                // cascade returned `.allow`), submit to OCR + run §6
                // re-cascade + emit OCREvent or tombstone-6. The emitter
                // owns ALL of that; the callback's only job is to dispatch.
                //
                // Privacy invariant (ADR-0016 §4.2): there is NO call site
                // that emits `OCREvent` other than `ocrEmitter` here, and
                // that call is structurally gated by the pixel-time
                // cascade's `.encoded` outcome.
                if OCRDispatchPolicy.shouldSubmit(
                    outcome: outcome,
                    hasInput: ocrInput != nil
                ),
                   let emitter = ocrEmitter,
                   let input = ocrInput
                {
                    await emitter.processAfterAllow(
                        captureOrdinal: callbackOrdinal,
                        tsUs: nowUs,
                        context: context,
                        input: input,
                        evidenceCandidate: evidenceCandidate,
                        disposition: { [weak self] disposition in
                            guard disposition == .retryableNoContent else { return }
                            self?.revokePriorDHashForRetry(
                                generation: baselineGeneration,
                                captureOrdinal: callbackOrdinal
                            )
                        }
                    )
                }
            },
            onDrop: {
                lease.release()
            }
        )
    }

    // MARK: - SCStreamDelegate

    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public func stream(_ stream: SCStream, didStopWithError _: Error) {
        // UNVERIFIED — needs live macOS; do not claim working.
        guard claimUnexpectedStreamTermination(stream) else { return }
        handleClaimedRuntimeFailure()
    }

    private func handleClaimedRuntimeFailure() {
        // Stop every in-process source of post-failure work before the owner
        // action. The handler's production default exits immediately; the
        // detached drain remains useful for an embedding owner that replaces
        // it with a notification during integration.
        cancelRebindTask()
        focusTracker?.stop()
        tccStatusMonitor?.stop()
        let dispatcher = captureDispatcher
        let emitter = ocrPostAllowEmitter
        Task {
            await dispatcher.cancelAndDrain()
            await emitter?.stopAndDrain()
        }
        runtimeFailureHandler(.streamStoppedUnexpectedly)
    }

    /// Test seam for the shared state transition behind the framework-only
    /// delegate callback. Live ScreenCaptureKit cannot be instantiated in a
    /// headless XCTest process; this executes the exact one-shot owner signal.
    internal func recordUnexpectedStreamTerminationForTest() {
        guard claimUnexpectedStreamTermination(nil) else { return }
        runtimeFailureHandler(.streamStoppedUnexpectedly)
    }

    /// Test-only read of the terminal runtime state. The production behavior
    /// is the default handler's nonzero helper exit, not a polling surface.
    internal func hasRuntimeFailureForTest() -> Bool {
        currentRuntimeFailure() != nil
    }

    /// Returns true only for the first unexpected stop. Expected stops are
    /// consumed by identity, so TCC/share/privacy shutdown cannot accidentally
    /// terminate the helper.
    private func claimUnexpectedStreamTermination(_ stoppedStream: SCStream?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let stoppedStream,
           let expectedIndex = expectedTerminatedStreams.firstIndex(where: { $0 === stoppedStream })
        {
            expectedTerminatedStreams.remove(at: expectedIndex)
            return false
        }
        guard runtimeFailure == nil else { return false }
        runtimeFailure = .streamStoppedUnexpectedly
        captureEpoch &+= 1
        captureLifecycleActive = false
        installedFocusGeneration = 0
        priorDHash = nil
        priorDHashGeneration = 0
        priorDHashCaptureOrdinal = 0
        retryOCRGeneration = nil
        if let stoppedStream {
            let identity = ObjectIdentifier(stoppedStream)
            candidateStreams.removeValue(forKey: identity)
            streamFocusGenerations.removeValue(forKey: identity)
            if stream === stoppedStream {
                stream = nil
            }
        }
        return true
    }

    /// Terminate immediately on a capture loss after readiness. Continuing
    /// would leave the supervisor with a live helper that cannot capture, so
    /// process death is the fail-closed truth signal. The line is deliberately
    /// content-free; it exposes no ScreenCaptureKit error detail.
    @usableFromInline
    static func terminateHelper(for failure: CaptureRuntimeFailure) -> Never {
        FileHandle.standardError.write(
            "mci-capture-helper: helper_health capture_runtime_failed=\(failure)\n"
                .data(using: .utf8) ?? Data()
        )
        exit(81)
    }

    // MARK: - In-callback OS extraction (UNVERIFIED)

    /// Read frame-status, dirty-rects and a 9×8 luminance grid out of
    /// the borrowed buffer SYNCHRONOUSLY, fold the grid to a dHash, and
    /// return a `Sendable` snapshot. THIS function never retains the
    /// buffer (the bounded PR-2 retain is taken separately in the
    /// callback and released by the pipeline lease).
    ///
    /// Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md). Every
    /// `CoreMedia` / `CoreVideo` / `ScreenCaptureKit` call below needs a
    /// real frame. The PURE part (`computeDHash9x8`, the `Sendable`
    /// assembly) is factored into `CapturedSampleExtractor` and IS unit
    /// tested. On any extraction failure this returns `nil` and the
    /// frame is dropped — the safe direction (no capture beats a
    /// half-read capture).
    static func extractSynchronously(from sampleBuffer: CMSampleBuffer) -> InCallbackSample? {
        // Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        let info = attachments?.first

        let statusRaw = info?[.status] as? Int
        let status = statusRaw.flatMap(SCFrameStatus.init(rawValue:))
        let frameStatusComplete = (status == .complete || status == .started)

        var dirtyRects: [DirtyRect] = []
        if let rectDicts = info?[.dirtyRects] as? [[String: Any]] {
            for d in rectDicts {
                guard
                    let cf = d as CFDictionary?,
                    let rect = CGRect(dictionaryRepresentation: cf)
                else { continue }
                dirtyRects.append(DirtyRect(
                    x: UInt32(max(0, rect.origin.x)),
                    y: UInt32(max(0, rect.origin.y)),
                    width: UInt32(max(0, rect.size.width)),
                    height: UInt32(max(0, rect.size.height))
                ))
            }
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        if status == .started, dirtyRects.isEmpty {
            dirtyRects = [DirtyRect(
                x: 0,
                y: 0,
                width: UInt32(clamping: frameWidth),
                height: UInt32(clamping: frameHeight)
            )]
        }
        guard let grid = grayscale9x8(from: pixelBuffer) else { return nil }
        let dhash = CapturedSampleExtractor.computeDHash9x8(grayscale: grid)

        // appBundleId on the InCallbackSample is intentionally nil; the
        // populated WorkflowContext is built at the cascade-feed site
        // in `stream(_:didOutputSampleBuffer:of:)` above (ADR-0015 §6
        // P2.5) from the in-process `WorkflowContextSnapshot` actor.
        // The synchronous extractor runs BEFORE the snapshot is read,
        // so wiring a bundleId here would either duplicate the
        // snapshot read or contradict it — neither is useful.
        //
        // The 9×8 grid is carried through so the ADR-0013 §2 probe
        // can update its verdict in the callback before the cascade
        // runs (single read, no second pixel scan).
        return InCallbackSample(
            userIdle: false,
            frameStatusComplete: frameStatusComplete,
            dirtyRects: dirtyRects,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            dhash: dhash,
            appBundleId: nil,
            grayscale: grid
        )
    }

    /// Nearest-neighbour 9×8 luminance downscale of a borrowed
    /// `CVPixelBuffer`. Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
    /// Assumes 32-BGRA (the `SCStreamConfiguration` default).
    /// Locked read-only; unlocked before returning; the buffer is never
    /// retained.
    private static func grayscale9x8(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        // Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let gw = CapturedSampleExtractor.dhashGridWidth
        let gh = CapturedSampleExtractor.dhashGridHeight
        var grid = [UInt8](repeating: 0, count: CapturedSampleExtractor.dhashGridCount)

        for gy in 0 ..< gh {
            let sy = min(h - 1, (gy * h) / gh)
            for gx in 0 ..< gw {
                let sx = min(w - 1, (gx * w) / gw)
                let off = sy * bytesPerRow + sx * 4 // BGRA
                let b = Int(ptr[off + 0])
                let g = Int(ptr[off + 1])
                let r = Int(ptr[off + 2])
                // Rec.601 luma, integer.
                let luma = (r * 77 + g * 150 + b * 29) >> 8
                grid[gy * gw + gx] = UInt8(min(255, max(0, luma)))
            }
        }
        return grid
    }
}

// MARK: - Cycle 8.45 — TCC monitor observer conformance

extension SCStreamCaptureSession: TCCStatusMonitor.Observer {
    /// Debounced TCC transitions arrive here. A `.denied` verdict
    /// pauses the SCStream immediately for the affected surface; a
    /// `.granted` verdict releases the pause once all previously-
    /// revoked surfaces have restored. Idempotent — the underlying
    /// pause/resume methods no-op on repeated same-state calls per
    /// surface.
    public func tccStatusDidTransition(
        _ transition: TCCStatusMonitor.Transition
    ) async {
        switch transition.newStatus {
        case .denied:
            await pauseForTCC(surface: transition.surface)
        case .granted:
            // Resume best-effort — a throw here leaves the session in
            // the paused state and the next monitor tick can retry
            // once the OS catches up on the grant. Do NOT re-throw:
            // the observer callback is fire-and-forget.
            try? await resumeFromTCC(surface: transition.surface)
        case .unknown:
            // Monitor never emits `.unknown` transitions (probe errors
            // are absorbed as no-op). This branch exists for exhaust-
            // iveness only.
            return
        }
    }
}
