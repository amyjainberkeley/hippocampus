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
        dhash: DHash,
        appBundleId: String?,
        grayscale: [UInt8]
    ) {
        self.userIdle = userIdle
        self.frameStatusComplete = frameStatusComplete
        self.dirtyRects = dirtyRects
        self.dhash = dhash
        self.appBundleId = appBundleId
        self.grayscale = grayscale
    }
}

/// The live SCStream session. `@unchecked Sendable`: its only mutable
/// state is the prior-dHash, guarded by an `NSLock`; the SCStream is
/// set once on `start()`.
public final class SCStreamCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let pipeline: SCStreamPipeline
    private let denylist: Denylist
    private let policy: StreamPolicy
    private let sampleQueue: DispatchQueue
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

    /// Cycle 8.44 audit risk #1 — screen-share leak detector. When
    /// supplied, `start()` also starts the detector, and the session
    /// registers itself as the detector's observer so it can pause
    /// SCStream when a Zoom/Meet/AirPlay session is active. `nil`
    /// preserves pre-cycle-8.44 behaviour (no screen-share awareness)
    /// — used by tests + any legacy build.
    private let screenShareDetector: ScreenShareDetector?

    /// Test-only accessor: proves the OCR emitter wire is connected.
    /// Not public API — `internal` so `@testable import` can read it.
    internal var ocrPostAllowEmitterForTest: (any OCRPostAllowEmitter)? {
        ocrPostAllowEmitter
    }

    private let lock = NSLock()
    private var priorDHash: DHash?
    private var stream: SCStream?

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

    /// Cycle 8.44 audit risk #1 — set to `true` while the detector
    /// says a Zoom/Meet/AirPlay session is active. Guarded by `lock`.
    /// While `true`, `start()` skips actually starting the SCStream
    /// (the detector's observer callback stops the stream and this
    /// flag prevents an accidental resume from a competing code path)
    /// and `pauseForScreenShare` / `resumeFromScreenShare` toggle it.
    private var pausedForScreenShare: Bool = false

    /// The last SCStream instance that was paused because of screen-
    /// share detection. Not retained across pauses (we call
    /// `stopCapture()`, so the stream is dead after pause) — this
    /// exists only to prove idempotence in tests.
    private var lastPausedActor: String?

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
        screenShareDetector: ScreenShareDetector? = nil
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
        self.screenShareDetector = screenShareDetector
        self.sampleQueue = DispatchQueue(label: "com.mci.capture.sample", qos: .userInitiated)
        super.init()
        // The detector holds a `weak` observer, so this create-then-set
        // pattern is safe: no retain cycle.
        self.screenShareDetector?.setObserver(self)
    }

    /// Start the live capture stream.
    ///
    /// Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
    /// `SCShareableContent.current` (inside `makeDisplayFilter`),
    /// `SCStream` construction, `startCapture()` all require a real
    /// screen + Screen-Recording TCC grant. Only reachable via the
    /// non-default `--capture` dev flag (Amendment 1 §4).
    ///
    /// ADR-0031 V2-P1: when `focusedWindowStore` was supplied, the
    /// FocusTracker is started first, an initial focused-window
    /// snapshot is read, and the SCStream filter is bound to that
    /// window (Option (a) — the captured pixel surface IS the focused
    /// window). When no focused window is observable on the initial
    /// read, the session falls back to the display-scoped filter so
    /// startup is never blocked by a missing focused window; the
    /// background rebind task will swap the filter once focus is
    /// observable. When `focusedWindowStore` is `nil` the session
    /// preserves pre-V2-P1 display-filter behaviour byte-for-byte.
    public func start() async throws {
        // Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
        // Force the §2 probe back to its fail-safe initial state so a
        // stale flag from a prior session cannot bleed into this one.
        blackedRegionProbe?.reset()

        // ADR-0031: start the FocusTracker before reading the initial
        // snapshot. Idempotent on a tracker that's already running.
        focusTracker?.start()

        let filter: SCContentFilter
        let initialFocusGeneration: UInt64
        if let store = focusedWindowStore {
            let initialSnapshot = store.currentSync()
            // The initial focused-window read may miss (no frontmost,
            // login window, fast-user-switch transition). Fall back to
            // the display filter so capture is never blocked; the
            // background rebind task will pick up the first focused
            // window observation and swap to Option (a).
            if let focused = initialSnapshot.focused,
               let focusedFilter = try await SCContentFilterFactory.makeFocusedWindowFilter(
                   windowId: focused.windowId,
                   denylist: denylist
               )
            {
                filter = focusedFilter
                initialFocusGeneration = initialSnapshot.generation
            } else {
                filter = try await SCContentFilterFactory.makeDisplayFilter(denylist: denylist)
                // Sentinel `0` — race gate will fire on every frame
                // until the rebind task installs a real focused filter.
                // The cascade still runs (the legacy display filter is
                // active); the race gate path is only consulted when
                // `focusedWindowStore` is non-nil, which is fail-closed
                // until rebind: frames go to `focusRaceDropped`
                // tombstones rather than mis-attributed OCREvents.
                initialFocusGeneration = 0
            }
        } else {
            filter = try await SCContentFilterFactory.makeDisplayFilter(denylist: denylist)
            initialFocusGeneration = 0
        }
        let configuration = SCStreamConfigFactory.makeConfiguration(policy: policy)
        let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await scStream.startCapture()
        storeStream(scStream)
        storeInstalledFocusGeneration(initialFocusGeneration)
        startRebindTaskIfNeeded()

        // Cycle 8.44 audit risk #1 — start the screen-share detector
        // after the SCStream is live. The detector will pause the
        // stream immediately if a share is already active on start
        // (fail-safe: on start we don't know share state until the
        // first debounced verdict lands).
        screenShareDetector?.start()
    }

    /// Stop the live capture stream (idempotent).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public func stop() async throws {
        // UNVERIFIED — needs live macOS; do not claim working.
        cancelRebindTask()
        focusTracker?.stop()
        screenShareDetector?.stop()
        let s = takeStream()
        try await s?.stopCapture()
        // No frames will arrive after `stopCapture()`; clear the §2
        // verdict so a subsequent `start()` begins from fail-safe.
        blackedRegionProbe?.reset()
        // Clear the paused-for-share flag so a fresh `start()` on the
        // same instance doesn't erroneously refuse to bring up the
        // SCStream (the detector will re-arm on the next `start()`).
        lock.lock(); pausedForScreenShare = false; lastPausedActor = nil; lock.unlock()
    }

    // Locked critical sections live in non-async helpers: `NSLock` is
    // unavailable from async contexts under Swift 6 strict concurrency,
    // and these are the only mutable state.
    private func storeStream(_ s: SCStream) {
        lock.lock(); stream = s; lock.unlock()
    }

    private func takeStream() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        let s = stream
        stream = nil
        return s
    }

    /// Roll the prior-dHash window and return the previous value.
    private func rollPriorDHash(_ next: DHash) -> DHash? {
        lock.lock(); defer { lock.unlock() }
        let prior = priorDHash
        priorDHash = next
        return prior
    }

    /// Read the currently-installed focus generation. Lock-guarded.
    private func currentInstalledFocusGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return installedFocusGeneration
    }

    /// Write the currently-installed focus generation. Lock-guarded.
    private func storeInstalledFocusGeneration(_ gen: UInt64) {
        lock.lock(); installedFocusGeneration = gen; lock.unlock()
    }

    /// Start the background rebind task that observes focus changes
    /// and calls `updateContentFilter` on the live SCStream. Lock-
    /// guarded; second call while running is a no-op.
    ///
    /// Cadence is faster than the FocusTracker's 1 Hz poll so the
    /// SCStream filter follows focus changes promptly (target: ≤200 ms
    /// between FocusTracker observation and SCStream rebind). The race
    /// gate covers the residual window.
    private func startRebindTaskIfNeeded() {
        guard focusedWindowStore != nil else { return }
        lock.lock()
        guard rebindTask == nil else { lock.unlock(); return }
        let store = focusedWindowStore!
        let task = Task { [weak self] in
            // Poll cadence: 200 ms. The FocusTracker writes at 1 Hz;
            // this task picks up the change within one poll interval.
            // The race gate covers the residual window between
            // observation here and SCStream filter applying on the
            // sample queue.
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
    private func cancelRebindTask() {
        lock.lock()
        let t = rebindTask
        rebindTask = nil
        lock.unlock()
        t?.cancel()
    }

    /// ADR-0031 §5.2 — rebind the live SCStream to the supplied focused
    /// window's `SCContentFilter`. Updates the installed-focus generation
    /// AFTER `updateContentFilter` returns so the race gate observes
    /// the new generation only once the filter is actually in force.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`. The
    /// `updateContentFilter` call requires a running `SCStream`; the
    /// rebind decision (when to rebind, what filter to build) is
    /// auditable headlessly via the
    /// `SCContentFilterFactory.selectFocusedWindow(...)` helper.
    public func rebindFocusedWindow(
        focusedWindow: FocusedWindow,
        snapshotGeneration: UInt64
    ) async throws {
        guard let currentStream = currentStream() else { return }
        guard let newFilter = try await SCContentFilterFactory.makeFocusedWindowFilter(
            windowId: focusedWindow.windowId,
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
        try await currentStream.updateContentFilter(newFilter)
        storeInstalledFocusGeneration(snapshotGeneration)
    }

    /// Lock-guarded read of the live SCStream pointer.
    private func currentStream() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        return stream
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
        let snap = snapshotActor.currentSync()
        let effectiveBundleId: String? = focusedBundleId ?? snap.appBundleId
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
            windowTitle: snap.windowTitle,
            url: resolvedUrl,
            pageText: nil
        )
    }

    // MARK: - Cycle 8.44 — screen-share pause/resume

    /// Pause the live SCStream because a screen-share was detected.
    /// Idempotent. Emits a stderr `helper_health screen_share_active=
    /// true actor=<bundleId>` breadcrumb so the parent app (Hippocampus)
    /// can drive the menu-bar red pill until the sibling
    /// `MenuBarStatus.pausedForScreenShare(actor:)` enum lands (mission
    /// brief §7). Content-free: only bundle-id + boolean cross the
    /// process boundary. The pause drops the SCStream strong ref, so
    /// the ingest pipeline sees a clean capture-off surface (M4 kill-
    /// switch pattern).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working` for
    /// the OS-touching `stopCapture()`; state-flag logic is headless-
    /// tested.
    public func pauseForScreenShare(actor: String?) async {
        lock.lock()
        if pausedForScreenShare { lock.unlock(); return }
        pausedForScreenShare = true
        lastPausedActor = actor
        lock.unlock()

        FileHandle.standardError.write(
            "mci-capture-helper: helper_health screen_share_active=true actor=\(actor ?? "unknown")\n"
                .data(using: .utf8) ?? Data()
        )

        // UNVERIFIED — needs live macOS; do not claim working.
        let s = takeStream()
        try? await s?.stopCapture()
    }

    /// Resume from a screen-share pause. Idempotent. If the underlying
    /// SCStream rebuild throws (e.g. TCC revoked during the pause), the
    /// session stays paused and the next detector cycle can retry —
    /// fail-safe = pause more aggressively (mission constraint).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public func resumeFromScreenShare() async throws {
        lock.lock()
        if !pausedForScreenShare { lock.unlock(); return }
        // Clear optimistically so `start()` doesn't recurse; restore on
        // throw so the next detector cycle retries.
        pausedForScreenShare = false
        lock.unlock()

        FileHandle.standardError.write(
            "mci-capture-helper: helper_health screen_share_active=false\n"
                .data(using: .utf8) ?? Data()
        )

        do {
            try await bringUpSCStreamOnly()
        } catch {
            lock.lock(); pausedForScreenShare = true; lock.unlock()
            FileHandle.standardError.write(
                "mci-capture-helper: SCStream resume-from-pause failed (staying paused): \(error)\n"
                    .data(using: .utf8) ?? Data()
            )
            throw error
        }
    }

    /// Bring up ONLY the SCStream (used by `resumeFromScreenShare`),
    /// bypassing `focusTracker.start()` / `screenShareDetector.start()`
    /// — those are already running from the initial `start()`.
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    private func bringUpSCStreamOnly() async throws {
        // UNVERIFIED — needs live macOS; do not claim working.
        let filter: SCContentFilter
        let initialFocusGeneration: UInt64
        if let store = focusedWindowStore {
            let initialSnapshot = store.currentSync()
            if let focused = initialSnapshot.focused,
               let focusedFilter = try await SCContentFilterFactory.makeFocusedWindowFilter(
                   windowId: focused.windowId,
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
        try await scStream.startCapture()
        storeStream(scStream)
        storeInstalledFocusGeneration(initialFocusGeneration)
    }

    /// Test-only accessor — proves the pause state without exposing
    /// the mutable field. Not public API.
    internal func isPausedForScreenShareForTest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pausedForScreenShare
    }

    internal func lastPausedActorForTest() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastPausedActor
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
        _: SCStream,
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

        guard let sample = Self.extractSynchronously(from: sampleBuffer) else { return }

        // ADR-0013 §2 pre-feed: stamp the latest blacked-region
        // verdict from the synchronously-extracted 9×8 luminance grid
        // BEFORE the cascade runs on this frame. O(72), well under
        // the 100 µs/frame hot-path budget. The cascade reads back
        // via `BlackedRegionProbe.hasBlackedRegion()` inside
        // `SCStreamPipeline.process(...)`.
        blackedRegionProbe?.update(grayscale: sample.grayscale)

        // Roll the prior-dHash window — pure bookkeeping, not the
        // surface. The callback is synchronous so the lock is fine
        // here; the helper is shared with the async start/stop path.
        let prior = rollPriorDHash(sample.dhash)

        let frame = CapturedSampleExtractor.makeCandidateFrame(
            userIdle: sample.userIdle,
            frameStatusComplete: sample.frameStatusComplete,
            dirtyRects: sample.dirtyRects,
            dhash: sample.dhash,
            priorDhash: prior
        )

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
            if installedGen == 0 || focusedSnapshot?.generation != installedGen {
                let nowUsForRace = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
                let raceBundle = focusedSnapshot?.focused?.bundleId ?? ""
                // Build the surface lease + release the surface in the
                // pipeline's emit helper. We construct the lease here
                // (same shape as the normal path) so the IOSurface
                // retain lifecycle is identical to a `.suppress` exit.
                let raceReleaser: any SurfaceReleasing
                if CMSampleBufferGetImageBuffer(sampleBuffer) != nil {
                    // `// UNVERIFIED — needs live macOS; do not claim working`.
                    raceReleaser = BorrowedNoRetainReleaser()
                } else {
                    raceReleaser = BorrowedNoRetainReleaser()
                }
                let raceLease = SurfaceLease(releaser: raceReleaser)
                let pipeline = self.pipeline
                Task.detached {
                    try? await pipeline.emitFocusRaceDropped(
                        tsUs: nowUsForRace,
                        appBundle: raceBundle,
                        lease: raceLease
                    )
                }
                return
            }
        }

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
        // `Task.detached` boundary into the cascade-twice path cleanly.
        // `nil` when the sample carries no pixel buffer; the OCR path
        // is then skipped (no OCREvent ever reaches the wire).
        let ocrInput: OCREngineInput?
        // DOGFOOD #3 — wrap the same retained `CVPixelBuffer` in an
        // `EncoderInput` so the cascade's `.allow` branch can hand it
        // to `VideoToolboxHEVCEncoder`. `@unchecked Sendable` for the
        // same reason `OCREngineInput` is — single-owner-while-in-
        // flight; the encoder runs to completion before the pipeline's
        // `defer { lease.release() }` fires, so the `CVPixelBuffer`
        // outlives the encoder call without a second retain. `nil`
        // preserves the pre-DOGFOOD#3 OS-free behaviour (the encoder
        // no-ops and the pipeline still encodes-or-suppresses).
        let encoderInput: EncoderInput?
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // UNVERIFIED — needs live macOS; do not claim working.
            releaser = PixelSurfaceReleaser(
                surface: CVPixelBufferRetainedSurface(retaining: pb)
            )
            let roi = OCRROIComputer.normalizedBoundingROI(
                widthPx: CVPixelBufferGetWidth(pb),
                heightPx: CVPixelBufferGetHeight(pb),
                dirtyRects: sample.dirtyRects
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
        let pipeline = self.pipeline
        let ocrEmitter = self.ocrPostAllowEmitter
        Task.detached {
            // The single sink for a captured frame is the cascade-gated
            // pipeline. On `.allow` the pipeline hands `encoderInput`
            // to whichever `FrameEncoder` is wired:
            //   - default / no `--capture` build: `DeferredVideoToolboxEncoder`
            //     (no-op, stores nothing). Amendment 1 §4 binding.
            //   - `--capture` dev path (DOGFOOD #3): `VideoToolboxHEVCEncoder`
            //     produces an HEVC IDR and hands it to an in-memory
            //     `EncodedSampleSink` (not persisted to disk; the next
            //     PR wires the OCR consumer).
            // A `.suppress` decision emits a tombstone and never reaches
            // encode — Amendment 1 §3(a)/(c) preserved by construction.
            let outcome = try? await pipeline.process(
                frame: frame,
                context: context,
                nowUs: nowUs,
                lease: lease,
                encoderInput: encoderInput
            )
            // ADR-0016 P3.6 — cascade-twice. On `.encoded` (pixel-time
            // cascade returned `.allow`), submit to OCR + run §6
            // re-cascade + emit OCREvent or tombstone-6. The emitter
            // owns ALL of that; the callback's only job is to dispatch.
            //
            // Privacy invariant (ADR-0016 §4.2): there is NO call site
            // that emits `OCREvent` other than `ocrEmitter` here, and
            // that call is structurally gated by the pixel-time
            // cascade's `.encoded` outcome.
            if case .encoded = outcome,
               let emitter = ocrEmitter,
               let input = ocrInput
            {
                await emitter.processAfterAllow(
                    tsUs: nowUs,
                    context: context,
                    input: input
                )
            }
        }
    }

    // MARK: - SCStreamDelegate

    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public func stream(_: SCStream, didStopWithError error: Error) {
        // UNVERIFIED — needs live macOS; do not claim working.
        FileHandle.standardError.write(
            "mci-capture-helper: SCStream stopped with error: \(error)\n"
                .data(using: .utf8) ?? Data()
        )
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
        let frameStatusComplete = (status == .complete)

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

// MARK: - Cycle 8.44 — screen-share detector observer conformance

extension SCStreamCaptureSession: ScreenShareDetector.Observer {
    /// Debounced transitions arrive here. `isSharingActive == true`
    /// pauses; `false` resumes. Idempotent — the underlying
    /// pause/resume methods no-op on repeated same-state calls.
    public func screenShareDetectorDidTransition(
        to sample: ScreenShareSample
    ) async {
        if sample.isSharingActive {
            await pauseForScreenShare(actor: sample.sharingActor)
        } else {
            // Resume best-effort — a throw here leaves the session
            // in the paused state and the next detector cycle can
            // retry. Do NOT re-throw: the observer callback is
            // fire-and-forget from the detector's side.
            try? await resumeFromScreenShare()
        }
    }
}
