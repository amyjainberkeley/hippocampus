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

    /// Test-only accessor: proves the OCR emitter wire is connected.
    /// Not public API — `internal` so `@testable import` can read it.
    internal var ocrPostAllowEmitterForTest: (any OCRPostAllowEmitter)? {
        ocrPostAllowEmitter
    }

    private let lock = NSLock()
    private var priorDHash: DHash?
    private var stream: SCStream?

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

    public init(
        pipeline: SCStreamPipeline,
        denylist: Denylist,
        policy: StreamPolicy = .default,
        blackedRegionProbe: PixelGridBlackedRegionProbe? = nil,
        contextSnapshot: WorkflowContextSnapshot? = nil,
        urlProvider: URLProvider? = nil,
        ocrPostAllowEmitter: (any OCRPostAllowEmitter)? = nil
    ) {
        self.pipeline = pipeline
        self.denylist = denylist
        self.policy = policy
        self.blackedRegionProbe = blackedRegionProbe
        self.contextSnapshot = contextSnapshot
        self.urlProvider = urlProvider
        self.ocrPostAllowEmitter = ocrPostAllowEmitter
        self.sampleQueue = DispatchQueue(label: "com.mci.capture.sample", qos: .userInitiated)
        super.init()
    }

    /// Start the live capture stream.
    ///
    /// Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
    /// `SCShareableContent.current` (inside `makeDisplayFilter`),
    /// `SCStream` construction, `startCapture()` all require a real
    /// screen + Screen-Recording TCC grant. Only reachable via the
    /// non-default `--capture` dev flag (Amendment 1 §4).
    public func start() async throws {
        // Verified live on macOS 26 Tahoe, 2026-05-19, Step-1 PASS (PR #31 → a19211b, see docs/audit/2026-05-19-step1-live-scstream.md).
        // Force the §2 probe back to its fail-safe initial state so a
        // stale flag from a prior session cannot bleed into this one.
        blackedRegionProbe?.reset()
        let filter = try await SCContentFilterFactory.makeDisplayFilter(denylist: denylist)
        let configuration = SCStreamConfigFactory.makeConfiguration(policy: policy)
        let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await scStream.startCapture()
        storeStream(scStream)
    }

    /// Stop the live capture stream (idempotent).
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`.
    public func stop() async throws {
        // UNVERIFIED — needs live macOS; do not claim working.
        let s = takeStream()
        try await s?.stopCapture()
        // No frames will arrive after `stopCapture()`; clear the §2
        // verdict so a subsequent `start()` begins from fail-safe.
        blackedRegionProbe?.reset()
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
        fallbackAppBundleId: String?
    ) -> WorkflowContext {
        guard let snapshotActor = snapshot else {
            return WorkflowContext(
                appBundleId: fallbackAppBundleId,
                windowTitle: nil,
                url: nil,
                pageText: nil
            )
        }
        let snap = snapshotActor.currentSync()
        let resolvedUrl: String?
        if let id = snap.appBundleId, !id.isEmpty {
            resolvedUrl = urlProvider?.activeTabURL(forFrontmost: id)
        } else {
            resolvedUrl = nil
        }
        return WorkflowContext(
            appBundleId: snap.appBundleId,
            windowTitle: snap.windowTitle,
            url: resolvedUrl,
            pageText: nil
        )
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
        // ADR-0015 §6 P2.5 — context join. Delegates to the pure
        // `buildWorkflowContext(...)` helper below so the wiring is
        // exercisable from a headless test (`SCStreamCaptureSession`'s
        // SCStream callback itself is `// UNVERIFIED — needs live
        // macOS`; the *decision* about how the snapshot + URL provider
        // assemble into a `WorkflowContext` is pure and IS tested).
        let context = Self.buildWorkflowContext(
            snapshot: contextSnapshot,
            urlProvider: urlProvider,
            fallbackAppBundleId: sample.appBundleId
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
        } else {
            releaser = BorrowedNoRetainReleaser()
            ocrInput = nil
        }
        let lease = SurfaceLease(releaser: releaser)

        // Only `Sendable` values are captured — NOT the sample buffer.
        let pipeline = self.pipeline
        let ocrEmitter = self.ocrPostAllowEmitter
        Task.detached {
            // The single sink for a captured frame is the cascade-gated
            // pipeline. `DeferredVideoToolboxEncoder` (still in place
            // this PR) is a no-op, so an `.allow` decision encodes
            // nothing; a `.suppress` decision emits a tombstone and
            // never reaches encode. Either way: no stored frame.
            let outcome = try? await pipeline.process(
                frame: frame,
                context: context,
                nowUs: nowUs,
                lease: lease
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
