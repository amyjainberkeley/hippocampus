// SPDX-License-Identifier: TBD-private
//
// SCStreamPipelineCounterWiringTests — pin the
// pipeline → counters-actor → snapshot → wire path end-to-end.
//
// STEP-2-FINDING-005. The Step-2 v6 live run (post-PR #44 wire 0x03
// merge) surfaced `HelperHealth` wire frames with every counter at zero
// even though the same byte stream carried 228 `PrivacyTombstone`
// records — the cascade demonstrably ran 228 times. Root cause:
// `SCStreamPipeline.init(counters: HelperHealthCounters =
// HelperHealthCounters())` defaulted to a FRESH actor while
// `HelperMainLoop` constructed its OWN fresh actor; the pipeline wrote
// one, `tickHealth()` snapshotted the other. Wire counters at zero by
// design.
//
// The fix in `main.swift` is to share `loop.counters` into the
// pipeline. These tests pin that wiring at the API surface and at the
// wire-byte surface so a future refactor cannot silently re-disconnect
// them.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. OS-FREE: no SCStream,
// SCShareableContent, IOSurface, or VideoToolbox is touched — these
// tests exercise the pure pipeline + counters + wire-encoder surface
// the live callback delegates to.
//
// Cases:
//   (a) pipeline-records-delivered  → snapshot-reports-delivered
//   (b) pipeline-records-suppressed → snapshot-reports-suppressed
//   (c) pipeline-records-cascade-forced     → snapshot-reports-cascade-forced
//   (d) pipeline-records-cascade-from-filter → snapshot-reports-cascade-from-filter
//   (e) the wire encoder reads the snapshot's `cascade_forced_count`
//       and emits matching bytes (round-trip through
//       `encodeHelperHealth` → byte-offset decode)
//   (f) regression: after N pipeline.process() calls the heartbeat-
//       emitted HelperHealth frame carries `frames_delivered == N`

import XCTest

@testable import MCICaptureHelperKit

// MARK: - Local probes / mocks (mirror SCStreamPipelineTests patterns)

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
private struct DenyApp: DenylistProbe {
    let id: String
    func appIsDenied(bundleId: String) -> Bool { bundleId == id }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}
private struct NoBlack: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private actor RecordingSink: FrameSink {
    private(set) var writes: [Data] = []
    func write(_ data: Data) async throws { writes.append(data) }
    func count() -> Int { writes.count }
    func all() -> [Data] { writes }
}

private actor SpyEncoder: FrameEncoder {
    private(set) var calls: [UInt64] = []
    func encodeAllowedFrame(
        input _: EncoderInput?,
        seq: UInt64,
        context _: WorkflowContext
    ) async throws {
        calls.append(seq)
    }
    func callCount() -> Int { calls.count }
}

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

private func buildPipeline(
    ax: any AXSecureSubroleProbe,
    knownSafe: Set<String> = [],
    denylist: any DenylistProbe = NoDeny(),
    encoder: any FrameEncoder,
    counters: HelperHealthCounters,
    sequence: FrameSequence = FrameSequence(),
    sink: any FrameSink,
    floorIntervalMs: UInt64 = 1
) -> SCStreamPipeline {
    let cascade = SuppressionCascade(
        secureEventInput: NoSEI(),
        axSecureSubrole: ax,
        denylist: denylist,
        blackedRegion: NoBlack(),
        knownSafeAppBundles: knownSafe
    )
    return SCStreamPipeline(
        cascade: cascade,
        encoder: encoder,
        counters: counters,
        sequence: sequence,
        sink: sink,
        floorIntervalMs: floorIntervalMs
    )
}

/// Pull a little-endian u64 out of `frame` at `offset` — the wire layout
/// is locked by `WireTests`; replicating it here gives this file a
/// self-contained "decode" of the cascade_forced_count byte path.
private func readU64LE(_ frame: Data, at offset: Int) -> UInt64 {
    precondition(offset + 8 <= frame.count, "u64 read out of bounds")
    var v: UInt64 = 0
    for i in 0..<8 {
        v |= UInt64(frame[frame.startIndex + offset + i]) << (8 * i)
    }
    return v
}

final class SCStreamPipelineCounterWiringTests: XCTestCase {

    // MARK: - (a) pipeline-records-delivered → snapshot-reports-delivered

    /// Every `process(...)` call increments `framesDelivered` on the
    /// SHARED counters actor, regardless of the cascade outcome —
    /// filter-dropped, suppressed, OR encoded. The snapshot the
    /// heartbeat reads picks the increment up.
    func test_a_pipeline_records_delivered_visible_in_snapshot() async throws {
        let counters = HelperHealthCounters()
        let pipe = buildPipeline(
            ax: AXSilent(),                  // → fail-safe ⇒ .suppress
            encoder: SpyEncoder(),
            counters: counters,
            sink: RecordingSink()
        )

        // 1) filter-passed frame → cascade runs (.suppress in this regime)
        _ = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.x"),
            nowUs: 1_000,
            lease: SurfaceLease(releaser: SpyReleaser())
        )
        // 2) filter-dropped, below floor → cascade does NOT run, but
        //    delivered still counts (the frame WAS delivered into the
        //    pipeline; the counter tracks deliveries, not cascade runs).
        _ = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.x"),
            nowUs: 1_001,                    // 1 µs past frame 1 — below 1 ms floor
            lease: SurfaceLease(releaser: SpyReleaser())
        )

        let snap = await counters.snapshot()
        XCTAssertEqual(
            snap.framesDelivered, 2,
            "pipeline must increment framesDelivered on the SHARED counters actor on EVERY process() — including filter-dropped frames"
        )
    }

    // MARK: - (b) pipeline-records-suppressed → snapshot-reports-suppressed

    /// `.suppress` outcomes increment `framesSuppressed` AND — when the
    /// reason is `.failsafeUnknown` — the §7 fail-safe subcount on the
    /// SHARED actor. STEP-2-FINDING-005's PRIMARY symptom: live
    /// captures dominated by `reason=7` tombstones must produce wire
    /// frames with a non-zero `frames_redacted_by_failsafe`.
    func test_b_pipeline_records_suppressed_and_failsafe_subcount() async throws {
        let counters = HelperHealthCounters()

        // 1) Denylist suppression → suppressed++, failsafe stays 0.
        let pipeDeny = buildPipeline(
            ax: AXNonSecure(),
            denylist: DenyApp(id: "com.secret.app"),
            encoder: SpyEncoder(),
            counters: counters,
            sink: RecordingSink()
        )
        _ = try await pipeDeny.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.secret.app"),
            nowUs: 1,
            lease: SurfaceLease(releaser: SpyReleaser())
        )

        // 2) Fail-safe suppression → suppressed++ AND failsafe++.
        //    Same shared counters actor, different pipeline instance —
        //    the wiring lives on the actor, not the pipeline.
        let pipeFailsafe = buildPipeline(
            ax: AXSilent(),
            encoder: SpyEncoder(),
            counters: counters,
            sink: RecordingSink()
        )
        _ = try await pipeFailsafe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.unknown.app"),
            nowUs: 2,
            lease: SurfaceLease(releaser: SpyReleaser())
        )

        let snap = await counters.snapshot()
        XCTAssertEqual(snap.framesSuppressed, 2, "both .suppress outcomes count")
        XCTAssertEqual(
            snap.framesRedactedByFailsafe, 1,
            "ONLY the .failsafeUnknown suppression increments the §7 subcount — denylistSource must not"
        )
    }

    // MARK: - (c) pipeline-records-cascade-forced → snapshot-reports-cascade-forced

    /// A filter-`.drop*` frame past the floor interval forces the
    /// cascade and increments `cascadeForced` (wire 0x03's
    /// `cascade_forced_count`).
    func test_c_pipeline_records_cascade_forced() async throws {
        let counters = HelperHealthCounters()
        let pipe = buildPipeline(
            ax: AXSecure(),                  // .suppress(.axSecureSubrole)
            encoder: SpyEncoder(),
            counters: counters,
            sink: RecordingSink(),
            floorIntervalMs: 1
        )

        // Idle frame past 1 ms floor → floor-forced cascade fires.
        let outcome = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.static.surface"),
            nowUs: 10_000,
            lease: SurfaceLease(releaser: SpyReleaser())
        )

        guard case .suppressed(_, let forced) = outcome else {
            XCTFail("expected .suppressed from floor-forced cascade, got \(outcome)")
            return
        }
        XCTAssertTrue(forced)

        let snap = await counters.snapshot()
        XCTAssertEqual(
            snap.cascadeForced, 1,
            "floor-forced cascade must increment cascadeForced on the SHARED counters actor"
        )
        XCTAssertEqual(snap.cascadeFromFilter, 0)
    }

    // MARK: - (d) pipeline-records-cascade-from-filter → snapshot

    /// A `.forward` frame increments `cascadeFromFilter` (in-process
    /// observability — not on the wire; see HelperHealthCounters docs).
    func test_d_pipeline_records_cascade_from_filter() async throws {
        let counters = HelperHealthCounters()
        let pipe = buildPipeline(
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],     // .allow path
            encoder: SpyEncoder(),
            counters: counters,
            sink: RecordingSink(),
            floorIntervalMs: 1_000_000       // effectively no floor
        )

        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 1,
            lease: SurfaceLease(releaser: SpyReleaser())
        )
        guard case .encoded(_, let forced) = outcome else {
            XCTFail("expected .encoded, got \(outcome)")
            return
        }
        XCTAssertFalse(forced)

        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeFromFilter, 1, "filter-passed cascade counted")
        XCTAssertEqual(snap.cascadeForced, 0)
    }

    // MARK: - (e) wire encoder reads snapshot.cascadeForced → matching bytes

    /// The wire-byte path: drive N floor-forced cascades on the SHARED
    /// counters actor, then assert `encodeHelperHealth(... snapshot ...)`
    /// emits a frame whose `cascade_forced_count` u64 (offset 48 LE,
    /// per Wire.swift v0x03 layout, locked by WireTests) equals N.
    /// Round-trip: pipeline writes → snapshot reads → encoder writes →
    /// byte read matches.
    func test_e_cascade_forced_round_trips_through_wire_encoder() async throws {
        let counters = HelperHealthCounters()
        let pipe = buildPipeline(
            ax: AXSecure(),
            encoder: SpyEncoder(),
            counters: counters,
            sink: RecordingSink(),
            floorIntervalMs: 1
        )

        let n: UInt64 = 5
        var t: UInt64 = 10_000
        for _ in 0..<n {
            _ = try await pipe.process(
                frame: idleFrame(),
                context: WorkflowContext(appBundleId: "com.static.surface"),
                nowUs: t,
                lease: SurfaceLease(releaser: SpyReleaser())
            )
            t &+= 10_000      // stay past the 1 ms floor
        }

        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, n)

        let frame = encodeHelperHealth(
            seq: 0,
            uptimeMs: snap.uptimeMs,
            framesDelivered: snap.framesDelivered,
            framesSuppressed: snap.framesSuppressed,
            framesRedactedByFailsafe: snap.framesRedactedByFailsafe,
            cascadeForcedCount: snap.cascadeForced,
            framesDroppedBackpressure: snap.framesDroppedBackpressure,
            framesDroppedLateAck: snap.framesDroppedLateAck
        )

        // Layout (locked by WireTests v0x03): header(16) + 7 × u64.
        // cascade_forced_count is the 5th u64 → offset 16 + 4×8 = 48.
        let cfcOffset = minFrameHeaderBytes + 4 * 8
        let onWire = readU64LE(frame, at: cfcOffset)
        XCTAssertEqual(
            onWire, n,
            "the wire's cascade_forced_count u64 must equal the snapshot value the pipeline wrote — this is the byte the Telemetry-Gap analyst reads"
        )

        // Sanity: frames_suppressed (3rd u64) also round-trips.
        let suppressedOffset = minFrameHeaderBytes + 2 * 8
        XCTAssertEqual(readU64LE(frame, at: suppressedOffset), snap.framesSuppressed)
    }

    // MARK: - (f) regression: heartbeat carries frames_delivered == N

    /// The full main.swift wiring shape. Build a `HelperMainLoop`, share
    /// its `counters` actor with the pipeline (the exact contract
    /// `main.swift` now upholds), drive N `process(...)` calls, then
    /// call `loop.tickHealth()` and read frames_delivered off the
    /// emitted bytes. Before STEP-2-FINDING-005's fix this was 0 by
    /// construction — the pipeline wrote one actor, the loop read
    /// another. After the fix this is N.
    func test_f_regression_helper_health_carries_delivered_equals_n() async throws {
        let loop = HelperMainLoop(
            cascade: SuppressionCascade(
                secureEventInput: NoSEI(),
                axSecureSubrole: AXSilent(),
                denylist: NoDeny(),
                blackedRegion: NoBlack()
            ),
            sink: RecordingFrameSink()
        )

        // The pipeline shares the loop's counters actor — this is the
        // post-fix wiring. (Pre-fix: pipeline defaulted to its OWN
        // fresh `HelperHealthCounters`; the heartbeat snapshotted the
        // loop's separate actor; wire reported 0 forever.)
        let pipeSink = RecordingSink()
        let pipe = SCStreamPipeline(
            cascade: SuppressionCascade(
                secureEventInput: NoSEI(),
                axSecureSubrole: AXSilent(),
                denylist: NoDeny(),
                blackedRegion: NoBlack()
            ),
            encoder: SpyEncoder(),
            counters: loop.counters,
            sink: pipeSink,
            floorIntervalMs: 1
        )

        let n: UInt64 = 7
        var t: UInt64 = 10_000
        for _ in 0..<n {
            _ = try await pipe.process(
                frame: forwardingFrame(),
                context: WorkflowContext(appBundleId: "com.x"),
                nowUs: t,
                lease: SurfaceLease(releaser: SpyReleaser())
            )
            t &+= 10_000
        }

        // Now have the loop snapshot + emit a heartbeat frame.
        guard let heartbeatSink = loop.sink as? RecordingFrameSink else {
            XCTFail("unexpected sink type")
            return
        }
        try await loop.tickHealth()
        let frames = await heartbeatSink.recorded()
        XCTAssertEqual(frames.count, 1, "exactly one HelperHealth frame from tickHealth()")
        let hh = frames[0]

        // frames_delivered = 2nd u64 in the payload → offset 16 + 8 = 24.
        let deliveredOffset = minFrameHeaderBytes + 1 * 8
        let delivered = readU64LE(hh, at: deliveredOffset)
        XCTAssertEqual(
            delivered, n,
            "regression: after N process() calls the HelperHealth wire frame MUST carry frames_delivered == N (STEP-2-FINDING-005 — pre-fix this was 0 because pipeline + loop held disjoint counter actors)"
        )

        // And the §7 subcount is N as well (every process() in this
        // regime hits .failsafeUnknown — proves the new
        // recordRedactedByFailsafe call site in SCStreamPipeline.
        let failsafeOffset = minFrameHeaderBytes + 3 * 8
        let failsafe = readU64LE(hh, at: failsafeOffset)
        XCTAssertEqual(
            failsafe, n,
            "regression: live-pipeline .failsafeUnknown suppressions must increment frames_redacted_by_failsafe (STEP-2-FINDING-005 — pre-fix the pipeline never called recordRedactedByFailsafe)"
        )
    }
}
