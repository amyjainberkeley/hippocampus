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

    public init(
        userIdle: Bool,
        frameStatusComplete: Bool,
        dirtyRects: [DirtyRect],
        dhash: DHash,
        appBundleId: String?
    ) {
        self.userIdle = userIdle
        self.frameStatusComplete = frameStatusComplete
        self.dirtyRects = dirtyRects
        self.dhash = dhash
        self.appBundleId = appBundleId
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

    private let lock = NSLock()
    private var priorDHash: DHash?
    private var stream: SCStream?

    public init(
        pipeline: SCStreamPipeline,
        denylist: Denylist,
        policy: StreamPolicy = .default
    ) {
        self.pipeline = pipeline
        self.denylist = denylist
        self.policy = policy
        self.sampleQueue = DispatchQueue(label: "com.mci.capture.sample", qos: .userInitiated)
        super.init()
    }

    /// Start the live capture stream.
    ///
    /// `// UNVERIFIED — needs live macOS; do not claim working`:
    /// `SCShareableContent.current` (inside `makeDisplayFilter`),
    /// `SCStream` construction, `startCapture()` all require a real
    /// screen + Screen-Recording TCC grant. Only reachable via the
    /// non-default `--capture` dev flag (Amendment 1 §4).
    public func start() async throws {
        // UNVERIFIED — needs live macOS; do not claim working.
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

    // MARK: - SCStreamOutput

    /// The live frame callback. `// UNVERIFIED — needs live macOS; do
    /// not claim working`.
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
        // UNVERIFIED — needs live macOS; do not claim working.
        guard outputType == .screen else { return }
        guard let sample = Self.extractSynchronously(from: sampleBuffer) else { return }

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
        // PR-1 has no Context join (Phase 2). The cascade still runs on
        // whatever bundle id the buffer carried; absent that it is the
        // fail-safe `.suppress` path — which is the safe direction.
        let context = CapturedSampleExtractor.makeWorkflowContext(
            appBundleId: sample.appBundleId,
            windowTitle: nil,
            url: nil,
            pageText: nil
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
        let releaser: any SurfaceReleasing
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // UNVERIFIED — needs live macOS; do not claim working.
            releaser = PixelSurfaceReleaser(
                surface: CVPixelBufferRetainedSurface(retaining: pb)
            )
        } else {
            releaser = BorrowedNoRetainReleaser()
        }
        let lease = SurfaceLease(releaser: releaser)

        // Only `Sendable` values are captured — NOT the sample buffer.
        let pipeline = self.pipeline
        Task.detached {
            // The single sink for a captured frame is the cascade-gated
            // pipeline. `DeferredVideoToolboxEncoder` (still in place
            // this PR) is a no-op, so an `.allow` decision encodes
            // nothing; a `.suppress` decision emits a tombstone and
            // never reaches encode. Either way: no stored frame.
            _ = try? await pipeline.process(
                frame: frame,
                context: context,
                nowUs: nowUs,
                lease: lease
            )
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
    /// `// UNVERIFIED — needs live macOS; do not claim working`: every
    /// `CoreMedia` / `CoreVideo` / `ScreenCaptureKit` call below needs a
    /// real frame. The PURE part (`computeDHash9x8`, the `Sendable`
    /// assembly) is factored into `CapturedSampleExtractor` and IS unit
    /// tested. On any extraction failure this returns `nil` and the
    /// frame is dropped — the safe direction (no capture beats a
    /// half-read capture).
    static func extractSynchronously(from sampleBuffer: CMSampleBuffer) -> InCallbackSample? {
        // UNVERIFIED — needs live macOS; do not claim working.
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

        // PR-1 carries no Context join; bundle id is unknown here and
        // the cascade fail-safe handles that (the safe direction).
        return InCallbackSample(
            userIdle: false,
            frameStatusComplete: frameStatusComplete,
            dirtyRects: dirtyRects,
            dhash: dhash,
            appBundleId: nil
        )
    }

    /// Nearest-neighbour 9×8 luminance downscale of a borrowed
    /// `CVPixelBuffer`. `// UNVERIFIED — needs live macOS; do not claim
    /// working`. Assumes 32-BGRA (the `SCStreamConfiguration` default).
    /// Locked read-only; unlocked before returning; the buffer is never
    /// retained.
    private static func grayscale9x8(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        // UNVERIFIED — needs live macOS; do not claim working.
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
