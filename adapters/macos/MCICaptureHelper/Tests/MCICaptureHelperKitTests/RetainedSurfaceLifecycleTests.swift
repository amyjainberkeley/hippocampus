// SPDX-License-Identifier: TBD-private
//
// RetainedSurfaceLifecycleTests — DOGFOOD_V1 #2 / ADR-0013 Amendment 1
// §3 (a)–(d) coverage extension. Pins the IOSurface retain →
// surface-lease release lifecycle under the paths the existing
// `RetainedSurfaceTests` did NOT exercise:
//
//   1. floor-forced cascade (STEP-2-FINDING-004 path) → lease released
//      on suppress AND on allow AND when the encoder throws AND when
//      the sink throws.
//   2. rapid-frame loop (sequential) — N back-to-back `process(...)`
//      calls with a FRESH lease per frame must produce exactly N
//      relinquishes, never N+1 (no double release).
//   3. concurrent-frame loop — many `process(...)` calls in flight at
//      once over the SAME pipeline + counters must still produce
//      exactly N relinquishes; the actor-guarded counters + the
//      `SurfaceLease`'s exactly-once guard must hold under contention.
//   4. 10K-frame stress at a simulated 60 Hz cadence — proves the
//      retain/lease discipline scales without leak and without ever
//      incrementing the wire-observable backpressure / late-ack
//      counters (which the production hot path does not increment;
//      this test is the standing regression guard for that).
//
// PROTECTED-SET per AGENT_PROTOCOL §5. OS-FREE: no live SCStream, no
// real IOSurface pool, no VideoToolbox. The `SpyRetainable` /
// `SpyReleaser` doubles stand in for the live OS retain (whose
// `// UNVERIFIED — needs live macOS` annotation in
// `CVPixelBufferRetainedSurface` is intentional and out of scope for
// this PR; live verification owed by the §7 corpus runner).
//
// Wire-level expectations exercised here (do NOT change the wire schema):
//   - `frames_delivered` increments on EVERY `process(...)` call.
//   - `frames_suppressed` increments when the cascade short-circuits.
//   - `frames_dropped_backpressure` stays 0 under steady-state (the
//     production hot path never increments it; this is the regression
//     guard against a future refactor accidentally wiring it).
//   - `frames_dropped_late_ack` stays 0 under steady-state (same).
//   - `cascade_forced_count` continues to increment from the floor
//     heartbeat on `.drop*` frames past the floor interval.

import CoreVideo
import VideoToolbox
import XCTest

@testable import MCICaptureHelperKit

// MARK: - Local probes / mocks (mirror SCStreamPipelineFloorTests patterns)

private struct NoSEI: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct AXNonSecure: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct AXSilent: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { nil }
}

private struct AXSecure: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { true }
}

private struct NoDeny: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlack: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private actor RecordingSink: FrameSink {
    private(set) var writes: Int = 0
    func write(_: Data) async throws { writes += 1 }
    func count() -> Int { writes }
}

private actor SpyEncoder: FrameEncoder {
    private(set) var calls: Int = 0
    func encodeAllowedFrame(
        input _: EncoderInput?,
        seq _: UInt64,
        context _: WorkflowContext
    ) async throws {
        calls += 1
    }
    func callCount() -> Int { calls }
}

private struct EncodeBoom: Error {}
private struct SinkBoom: Error {}

private struct ThrowingEncoder: FrameEncoder {
    func encodeAllowedFrame(
        input _: EncoderInput?,
        seq _: UInt64,
        context _: WorkflowContext
    ) async throws {
        throw EncodeBoom()
    }
}

private struct ThrowingSink: FrameSink {
    func write(_: Data) async throws { throw SinkBoom() }
}

/// Concurrency-safe counter that sums every `relinquish()` across every
/// `SurfaceLease` the test constructed. Each lease is a one-shot — the
/// pipeline's top-level `defer { lease.release() }` releases it exactly
/// once — but every test below shares ONE counter across N leases so
/// the assertion is "total relinquishes == frames in".
private final class SpyReleaser: SurfaceReleasing, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func releaseSurface() {
        lock.lock(); n += 1; lock.unlock()
    }
    var releaseCount: Int {
        lock.lock(); defer { lock.unlock() }; return n
    }
}

private func forwardingFrame() -> CandidateFrame {
    CandidateFrame(
        userIdle: false,
        frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: DHash(bits: 0),
        priorDhash: nil
    )
}

private func idleFrame() -> CandidateFrame {
    CandidateFrame(
        userIdle: true,
        frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: DHash(bits: 0),
        priorDhash: nil
    )
}

/// dHash matches priorDHash so `SmartCaptureFilter` returns
/// `.dropNearDuplicate` — the static-secure-surface signature.
private func nearDuplicateFrame() -> CandidateFrame {
    let h = DHash(bits: 0xDEAD_BEEF_CAFE_BABE)
    return CandidateFrame(
        userIdle: false,
        frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: h,
        priorDhash: h
    )
}

private func makePipeline(
    ax: any AXSecureSubroleProbe = AXNonSecure(),
    knownSafe: Set<String> = [],
    encoder: any FrameEncoder,
    sink: any FrameSink,
    counters: HelperHealthCounters = HelperHealthCounters(),
    sequence: FrameSequence = FrameSequence(),
    floorIntervalMs: UInt64 = 1
) -> SCStreamPipeline {
    SCStreamPipeline(
        cascade: SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: ax,
            denylist: NoDeny(),
            blackedRegion: NoBlack(),
            knownSafeAppBundles: knownSafe
        ),
        encoder: encoder,
        counters: counters,
        sequence: sequence,
        sink: sink,
        floorIntervalMs: floorIntervalMs
    )
}

final class RetainedSurfaceLifecycleTests: XCTestCase {

    // MARK: - (a) lease released on every floor-forced exit

    /// Floor-forced `.suppress` path: filter would drop the frame, the
    /// heartbeat fires the cascade, the cascade suppresses, the
    /// tombstone goes out, and the top-level `defer` releases the lease
    /// exactly once. The lease must NOT be leaked just because the
    /// cascade ran on the heartbeat rather than via the filter.
    func test_lease_released_once_on_floor_forced_suppress() async throws {
        let spy = SpyReleaser()
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXSecure(),                  // .suppress(.axSecureSubrole)
            encoder: SpyEncoder(),
            sink: RecordingSink(),
            counters: counters,
            floorIntervalMs: 1
        )

        let lease = SurfaceLease(releaser: spy)
        let outcome = try await pipe.process(
            frame: idleFrame(),              // filter would drop
            context: WorkflowContext(appBundleId: "com.static.surface"),
            nowUs: 10_000,                   // past the 1 ms floor
            lease: lease
        )

        guard case .suppressed(_, let forced) = outcome else {
            XCTFail("expected .suppressed from floor-forced cascade, got \(outcome)")
            return
        }
        XCTAssertTrue(forced, "this run was forced by the floor")
        XCTAssertEqual(spy.releaseCount, 1, "floor-forced suppress must release the lease exactly once")
        XCTAssertTrue(lease.isReleased)
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, 1, "wire's cascade_forced_count still increments on the floor path")
    }

    /// Floor-forced `.allow` path: filter would drop, heartbeat fires
    /// the cascade, the cascade allows, the (no-op) encoder runs, and
    /// the lease must still release exactly once. This is the path the
    /// future VideoToolbox encoder (DOGFOOD_V1 #3) will plug into.
    func test_lease_released_once_on_floor_forced_allow() async throws {
        let spy = SpyReleaser()
        let pipe = makePipeline(
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],
            encoder: SpyEncoder(),
            sink: RecordingSink(),
            floorIntervalMs: 1
        )

        let lease = SurfaceLease(releaser: spy)
        let outcome = try await pipe.process(
            frame: idleFrame(),              // filter would drop
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 100_000,
            lease: lease
        )

        guard case .encoded(_, let forced) = outcome else {
            XCTFail("expected .encoded from floor-forced .allow, got \(outcome)")
            return
        }
        XCTAssertTrue(forced)
        XCTAssertEqual(spy.releaseCount, 1, "floor-forced allow must release the lease exactly once")
    }

    /// Floor-forced `.allow` with a throwing encoder: the encoder
    /// throws, the error propagates, the top-level `defer` still runs,
    /// and the lease releases exactly once. No pool-stall under failure
    /// on the heartbeat path.
    func test_lease_released_once_on_floor_forced_allow_when_encoder_throws() async throws {
        let spy = SpyReleaser()
        let pipe = makePipeline(
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],
            encoder: ThrowingEncoder(),
            sink: RecordingSink(),
            floorIntervalMs: 1
        )

        let lease = SurfaceLease(releaser: spy)
        do {
            _ = try await pipe.process(
                frame: idleFrame(),
                context: WorkflowContext(appBundleId: "com.good.app"),
                nowUs: 100_000,
                lease: lease
            )
            XCTFail("encoder threw — must propagate")
        } catch is EncodeBoom {
            // expected
        }
        XCTAssertEqual(spy.releaseCount, 1, "throwing encoder on floor path must not leak the retain")
    }

    /// Floor-forced `.suppress` with a throwing sink: the tombstone
    /// write throws, the error propagates, the lease still releases
    /// exactly once. Mirrors the suppress-path leak the existing
    /// `RetainedSurfaceTests` covered for the filter-passed path; this
    /// pins the equivalent guarantee on the heartbeat path.
    func test_lease_released_once_on_floor_forced_suppress_when_sink_throws() async throws {
        let spy = SpyReleaser()
        let pipe = makePipeline(
            ax: AXSecure(),
            encoder: SpyEncoder(),
            sink: ThrowingSink(),
            floorIntervalMs: 1
        )

        let lease = SurfaceLease(releaser: spy)
        do {
            _ = try await pipe.process(
                frame: idleFrame(),
                context: WorkflowContext(appBundleId: "com.static.surface"),
                nowUs: 10_000,
                lease: lease
            )
            XCTFail("sink threw — must propagate")
        } catch is SinkBoom {
            // expected
        }
        XCTAssertEqual(spy.releaseCount, 1, "throwing sink on floor-forced suppress must not leak the retain")
    }

    // MARK: - (b) no double release under a rapid sequential frame loop

    /// 1 024 back-to-back `process(...)` calls, each with a FRESH
    /// `SurfaceLease` backed by the SAME `SpyReleaser`. After the loop
    /// the spy must show exactly 1 024 relinquishes — no skipped
    /// release (would leak the OS pool) and no doubled release (would
    /// trip `SurfaceLease`'s exactly-once `assertionFailure` in debug
    /// builds, which is what `swift test` runs under).
    func test_no_double_release_under_rapid_sequential_loop() async throws {
        let spy = SpyReleaser()
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXSilent(),                  // .suppress(.failsafeUnknown)
            encoder: SpyEncoder(),
            sink: RecordingSink(),
            counters: counters,
            floorIntervalMs: 1
        )

        let n = 1_024
        var t: UInt64 = 1
        for _ in 0..<n {
            // Mix the frame shape so we exercise filter-passed AND
            // floor-forced cascade paths in the same loop.
            let frame: CandidateFrame = (t & 1 == 0) ? forwardingFrame() : idleFrame()
            let lease = SurfaceLease(releaser: spy)
            _ = try await pipe.process(
                frame: frame,
                context: WorkflowContext(appBundleId: "com.x"),
                nowUs: t,
                lease: lease
            )
            t &+= 10_000                     // 10 ms steps — past 1 ms floor
        }

        XCTAssertEqual(spy.releaseCount, n,
            "exactly one relinquish per delivered frame — no skip (leak) and no double (panic)")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.framesDelivered, UInt64(n), "wire's frames_delivered tracks every process() call")
        XCTAssertEqual(snap.framesDroppedBackpressure, 0, "no backpressure drops on the production hot path")
        XCTAssertEqual(snap.framesDroppedLateAck, 0, "no late-ack drops on the production hot path")
    }

    // MARK: - (c) no double release under a concurrent frame loop

    /// 256 `process(...)` calls in flight concurrently against the SAME
    /// pipeline + the SAME counters actor + the SAME spy. Proves the
    /// `SurfaceLease` exactly-once guard holds under contention and the
    /// actor-guarded counters do not under- or over-count.
    func test_no_double_release_under_concurrent_frame_loop() async throws {
        let spy = SpyReleaser()
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXSilent(),
            encoder: SpyEncoder(),
            sink: RecordingSink(),
            counters: counters,
            floorIntervalMs: 1
        )

        let n = 256
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                let lease = SurfaceLease(releaser: spy)
                let t = UInt64(i + 1) &* 1_000
                group.addTask {
                    _ = try? await pipe.process(
                        frame: forwardingFrame(),
                        context: WorkflowContext(appBundleId: "com.x"),
                        nowUs: t,
                        lease: lease
                    )
                }
            }
        }

        XCTAssertEqual(spy.releaseCount, n,
            "exactly N relinquishes across N concurrent process() calls — no double-release under contention")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.framesDelivered, UInt64(n))
        XCTAssertEqual(snap.framesDroppedBackpressure, 0)
        XCTAssertEqual(snap.framesDroppedLateAck, 0)
    }

    // MARK: - (d) 10 000 synthetic frames @ 60 Hz simulated rate

    /// The §4 IOSurface-pool-stall regression guard. 10 000
    /// `process(...)` calls at a 60 Hz simulated cadence (16 667 µs
    /// between frames) over a SHARED counters actor + SHARED spy
    /// releaser. After the loop:
    ///   - exactly 10 000 relinquishes (no leak, no double-release)
    ///   - `frames_delivered == 10 000` on the wire snapshot
    ///   - `frames_dropped_backpressure == 0`
    ///   - `frames_dropped_late_ack == 0`
    ///   - `cascade_forced_count` strictly increments on every
    ///     `.drop*` frame past the floor (proves the heartbeat keeps
    ///     firing under sustained load)
    ///
    /// This test does NOT simulate the real OS pool depth. What it
    /// does prove is the structural property the §4 budget rests on:
    /// every captured surface is released back to the (whatever its
    /// real shape) pool exactly once per inbound frame, under
    /// sustained throughput, on every exit path the pipeline takes.
    func test_stress_10k_synthetic_frames_no_leak_no_backpressure() async throws {
        let spy = SpyReleaser()
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXSilent(),                  // .suppress(.failsafeUnknown)
            encoder: SpyEncoder(),
            sink: RecordingSink(),
            counters: counters,
            floorIntervalMs: 1                // small floor → most idle frames force the cascade
        )

        let n: UInt64 = 10_000
        // 60 Hz cadence: 1_000_000 / 60 ≈ 16 667 µs between frames.
        let step: UInt64 = 16_667
        var t: UInt64 = step
        var forwardCount: UInt64 = 0
        var idleCount: UInt64 = 0
        for i in 0..<n {
            // Even iterations: forwarding (filter passes; cascade runs
            // and suppresses). Odd iterations: idle (filter drops; floor
            // forces cascade past the 1 ms floor; cascade suppresses).
            // Both increment `framesDelivered` and `framesSuppressed`.
            let isForward = (i & 1 == 0)
            let frame: CandidateFrame = isForward ? forwardingFrame() : idleFrame()
            if isForward { forwardCount &+= 1 } else { idleCount &+= 1 }
            let lease = SurfaceLease(releaser: spy)
            _ = try await pipe.process(
                frame: frame,
                context: WorkflowContext(appBundleId: "com.stress"),
                nowUs: t,
                lease: lease
            )
            t &+= step
        }

        XCTAssertEqual(spy.releaseCount, Int(n),
            "10 000 process() calls ⇒ 10 000 relinquishes; no IOSurface leak detectable in the lifecycle")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.framesDelivered, n,
            "wire's frames_delivered tracks every delivery (cascade-floor-fed path included)")
        XCTAssertEqual(snap.framesSuppressed, n,
            "in this fail-safe regime every cascade ⇒ .suppress; framesSuppressed == framesDelivered")
        XCTAssertEqual(snap.framesRedactedByFailsafe, n,
            "§7 fail-safe subcount tracks every .failsafeUnknown suppression on the live pipeline")
        XCTAssertEqual(snap.framesDroppedBackpressure, 0,
            "§4 regression guard: the production hot path must NEVER increment frames_dropped_backpressure under steady-state")
        XCTAssertEqual(snap.framesDroppedLateAck, 0,
            "§4 regression guard: the production hot path must NEVER increment frames_dropped_late_ack under steady-state")
        XCTAssertEqual(snap.cascadeFromFilter, forwardCount,
            "every forwarding frame produces one filter-passed cascade evaluation")
        XCTAssertEqual(snap.cascadeForced, idleCount,
            "every idle frame past the 1 ms floor produces one floor-forced cascade evaluation")
        XCTAssertEqual(snap.cascadeFromFilter &+ snap.cascadeForced, n,
            "every delivered frame produced exactly one cascade evaluation (filter-passed XOR floor-forced)")
    }

    // MARK: - (e) DOGFOOD #3 — real VideoToolboxHEVCEncoder on .allow

    /// The DOGFOOD #3 encoder lease-discipline pin. Drives a REAL
    /// `VideoToolboxHEVCEncoder` (no spy) on a `.allow` decision with a
    /// synthetic `CVPixelBufferCreate` buffer, and asserts:
    ///   - the encoder produced exactly one `CMSampleBuffer` into the
    ///     sink (proves the `.allow` → encode → sink path works);
    ///   - the surface lease released exactly once (proves Amendment 1
    ///     §3(d) holds with the real encoder, not just a spy).
    ///
    /// Skipped when the host cannot construct an HEVC compression
    /// session (older / headless macOS). The spy-encoder equivalents
    /// above remain the always-on lease-discipline guards.
    func test_lease_released_once_with_real_hevc_encoder_on_allow() async throws {
        var probe: VTCompressionSession?
        let probeStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: 32, height: 32,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &probe
        )
        if let probe { VTCompressionSessionInvalidate(probe) }
        try XCTSkipIf(probeStatus != noErr, "HEVC VTCompressionSession unavailable on this host")

        let spy = SpyReleaser()
        let sink = InMemoryEncodedSampleQueue()
        let encoder = VideoToolboxHEVCEncoder(sink: sink)
        let pipe = makePipeline(
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],
            encoder: encoder,
            sink: RecordingSink()
        )

        var pb: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &pb
        )
        try XCTSkipIf(createStatus != kCVReturnSuccess, "CVPixelBufferCreate failed")
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * 64)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let lease = SurfaceLease(releaser: spy)
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 1_000,
            lease: lease,
            encoderInput: EncoderInput(pixelBuffer: buffer)
        )

        if case .encoded = outcome {} else {
            XCTFail("expected .encoded from real encoder, got \(outcome)")
        }
        XCTAssertEqual(encoder.emittedSampleCount(), 1,
            "real VideoToolboxHEVCEncoder must emit one CMSampleBuffer on a .allow")
        let sinkCount = await sink.count()
        XCTAssertEqual(sinkCount, 1, "encoded sample handed to the in-memory sink")
        XCTAssertEqual(spy.releaseCount, 1,
            "Amendment 1 §3(d): lease released exactly once with the real encoder on the .allow path")
        XCTAssertTrue(lease.isReleased)
    }
}
