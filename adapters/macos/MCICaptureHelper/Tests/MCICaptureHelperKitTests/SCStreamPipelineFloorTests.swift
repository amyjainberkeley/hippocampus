// SPDX-License-Identifier: TBD-private
//
// SCStreamPipelineFloorTests — OS-FREE proof that the cascade-floor
// heartbeat (STEP-2-FINDING-004 fix) runs the ADR-0013 cascade at
// least once per `cascadeFloorIntervalMs`, even when the
// `SmartCaptureFilter` would drop every frame.
//
// Why this exists. The four-stage filter (idle / status / dirty-rects
// / dHash) gates the cascade. Static-screen secure surfaces —
// full-screen FairPlay playback, a focused `NSSecureTextField` with
// no surrounding motion, an active `sudo` password prompt — produce
// near-zero dHash variation. Without a floor the filter eats every
// frame and the cascade is starved at the wire: the per-frame
// fail-safe (§7) still catches whatever the cascade DOES see, but the
// specific cascade-layer verdict (`reason=2/3/4`) never emits. The
// floor closes that observability gap without widening any `.allow`
// path (the floor-forced run is the EXACT same cascade decision the
// filter-passed path runs).
//
// PROTECTED-SET per AGENT_PROTOCOL §5. Tests do NOT touch any live
// OS — `nowUs` is driven by the test, the cascade probes are mocks.
//
// Cases (matching the STEP-2-FINDING-004 spec):
//   (a) filter `.drop*` followed by `nowUs` advance ≥ floor → cascade runs
//   (b) filter `.drop*` followed by `nowUs` advance < floor → cascade does NOT run
//   (c) filter `.forward` → cascade runs regardless of the floor
//   (d) a floor-forced cascade can suppress AND can allow
//   (e) `seq` contiguity preserved across forced-cascade frames
//   (f) `lastCascadeRunUs` updates on EVERY cascade call, forced or not, suppress or allow

import XCTest

@testable import MCICaptureHelperKit

// MARK: - Test helpers (mirroring SCStreamPipelineTests.swift)

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
    private(set) var writes: [Data] = []
    func write(_ data: Data) async throws { writes.append(data) }
    func count() -> Int { writes.count }
}

private actor SpyEncoder: FrameEncoder {
    private(set) var calls: [UInt64] = []
    func encodeAllowedFrame(seq: UInt64, context _: WorkflowContext) async throws {
        calls.append(seq)
    }
    func callCount() -> Int { calls.count }
    func sequenceList() -> [UInt64] { calls }
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

/// Same `priorDhash == dhash` so `SmartCaptureFilter` returns
/// `.dropNearDuplicate` — the static-secure-surface signature
/// (FairPlay full-screen playback, sudo password entry).
private func nearDuplicateFrame() -> CandidateFrame {
    let h = DHash(bits: 0xCAFE_BABE_DEAD_BEEF)
    return CandidateFrame(
        userIdle: false,
        frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: h,
        priorDhash: h
    )
}

private func makePipeline(
    ax: any AXSecureSubroleProbe,
    knownSafe: Set<String> = [],
    denylist: any DenylistProbe = NoDeny(),
    encoder: any FrameEncoder,
    sink: any FrameSink,
    counters: HelperHealthCounters = HelperHealthCounters(),
    sequence: FrameSequence = FrameSequence(),
    floorIntervalMs: UInt64 = 1000,
    floorState: CascadeFloorState = CascadeFloorState()
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
        floorIntervalMs: floorIntervalMs,
        floorState: floorState
    )
}

final class SCStreamPipelineFloorTests: XCTestCase {
    // MARK: - (a) filter .drop* + clock past floor → cascade runs

    func test_filter_drop_then_clock_advance_past_floor_runs_cascade() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let counters = HelperHealthCounters()
        // Floor = 1 ms (1_000 us) so the test does not depend on
        // wall-clock; `nowUs` drives the heartbeat purely.
        let pipe = makePipeline(
            ax: AXSilent(),                 // → §7 fail-safe ⇒ .suppress(.failsafeUnknown)
            encoder: encoder, sink: sink,
            counters: counters,
            floorIntervalMs: 1
        )

        // Frame 1: filter would drop (idle), nowUs = 2_000 µs.
        // delta = 2_000 - 0 = 2_000 ≥ 1_000 ⇒ floor fires.
        let lease1 = SurfaceLease(releaser: SpyReleaser())
        let outcome = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.static.surface"),
            nowUs: 2_000,
            lease: lease1
        )

        guard case .suppressed(let reason, let forced) = outcome else {
            XCTFail("expected .suppressed from floor-forced cascade, got \(outcome)")
            return
        }
        XCTAssertEqual(reason, .failsafeUnknown)
        XCTAssertTrue(forced, "this run was forced by the floor — the filter would have dropped it")

        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, 1, "cascadeForced counter must increment on a floor-forced run")
        XCTAssertEqual(snap.cascadeFromFilter, 0, "filter dropped — no filter-passed cascade should be counted")
        XCTAssertEqual(snap.framesSuppressed, 1, "tombstone path ran ⇒ framesSuppressed increments")
        let sinkCount = await sink.count()
        XCTAssertEqual(sinkCount, 1, "exactly one tombstone written from the floor probe")
    }

    // MARK: - (b) filter .drop* + clock within floor → cascade does NOT run

    func test_filter_drop_within_floor_does_not_run_cascade() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let counters = HelperHealthCounters()
        // Floor = 1_000 ms. nowUs = 500 µs (way below 1_000_000 µs).
        let pipe = makePipeline(
            ax: AXSilent(),
            encoder: encoder, sink: sink,
            counters: counters,
            floorIntervalMs: 1_000
        )

        let lease = SurfaceLease(releaser: SpyReleaser())
        let outcome = try await pipe.process(
            frame: nearDuplicateFrame(),
            context: WorkflowContext(appBundleId: "com.static.surface"),
            nowUs: 500,
            lease: lease
        )

        XCTAssertEqual(outcome, .filteredOut, "below-floor drop preserves pre-floor dedup behavior")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, 0, "below-floor drop must NOT count as a floor-forced run")
        XCTAssertEqual(snap.cascadeFromFilter, 0, "filter dropped — no filter-passed run either")
        XCTAssertEqual(snap.framesSuppressed, 0, "no cascade, no tombstone")
        let sinkCount = await sink.count()
        let encCount = await encoder.callCount()
        XCTAssertEqual(sinkCount, 0)
        XCTAssertEqual(encCount, 0)
    }

    // MARK: - (c) filter .forward → cascade runs regardless of floor

    func test_filter_forward_runs_cascade_regardless_of_floor() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],
            encoder: encoder, sink: sink,
            counters: counters,
            floorIntervalMs: 1_000_000  // effectively never (10^6 ms = 17 min)
        )

        let lease = SurfaceLease(releaser: SpyReleaser())
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 1,
            lease: lease
        )

        guard case .encoded(_, let forced) = outcome else {
            XCTFail("expected .encoded, got \(outcome)")
            return
        }
        XCTAssertFalse(forced, "the filter forwarded — this is NOT a floor-forced run")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeFromFilter, 1, "filter-passed cascade ran ⇒ cascadeFromFilter increments")
        XCTAssertEqual(snap.cascadeForced, 0, "no floor-forced run")
        let encCount = await encoder.callCount()
        XCTAssertEqual(encCount, 1)
    }

    // MARK: - (d) the floor-forced cascade can suppress AND can allow

    func test_floor_forced_cascade_can_allow() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],   // the only `.allow` path in the cascade
            encoder: encoder, sink: sink,
            counters: counters,
            floorIntervalMs: 1
        )

        let lease = SurfaceLease(releaser: SpyReleaser())
        let outcome = try await pipe.process(
            frame: idleFrame(),            // filter would drop
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 100_000,                // past 1 ms floor
            lease: lease
        )

        guard case .encoded(let seq, let forced) = outcome else {
            XCTFail("expected .encoded from floor-forced .allow, got \(outcome)")
            return
        }
        XCTAssertTrue(forced)
        XCTAssertEqual(seq, 0)
        let encCount = await encoder.callCount()
        let sinkCount = await sink.count()
        XCTAssertEqual(encCount, 1, "floor probe took the `.allow` path → encoder ran")
        XCTAssertEqual(sinkCount, 0, "no tombstone on a floor `.allow`")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, 1)
        XCTAssertEqual(snap.framesSuppressed, 0)
    }

    func test_floor_forced_cascade_can_suppress() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let counters = HelperHealthCounters()
        // AXSecure makes the cascade fire `.suppress(.axSecureSubrole)`
        // → the §4 layer specifically — i.e., what STEP-2-FINDING-001
        // needed and what STEP-2-FINDING-004 is about: getting that
        // verdict on the wire even when the filter drops the frame.
        let pipe = makePipeline(
            ax: AXSecure(),
            encoder: encoder, sink: sink,
            counters: counters,
            floorIntervalMs: 1
        )

        let lease = SurfaceLease(releaser: SpyReleaser())
        let outcome = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.system.settings"),
            nowUs: 100_000,
            lease: lease
        )

        guard case .suppressed(let reason, let forced) = outcome else {
            XCTFail("expected .suppressed from floor-forced .suppress, got \(outcome)")
            return
        }
        XCTAssertEqual(reason, .axSecureSubrole)
        XCTAssertTrue(forced)
        let sinkCount = await sink.count()
        let encCount = await encoder.callCount()
        XCTAssertEqual(sinkCount, 1)
        XCTAssertEqual(encCount, 0)
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, 1)
        XCTAssertEqual(snap.framesSuppressed, 1)
    }

    // MARK: - (e) seq contiguity preserved across floor-forced frames

    func test_seq_contiguous_across_mixed_forward_and_floor_frames() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        // Cascade is in the fail-safe regime (AXSilent, no knownSafe) so
        // every cascade evaluation `.suppress`es with `failsafeUnknown`.
        // The point of this test is to prove that BOTH filter-passed
        // and floor-forced cascade runs draw monotonically increasing
        // seq numbers from the SAME `FrameSequence` actor — no gaps,
        // no duplicates.
        let sequence = FrameSequence()
        let pipe = makePipeline(
            ax: AXSilent(),
            encoder: encoder, sink: sink,
            sequence: sequence,
            floorIntervalMs: 1
        )

        // Drive a deterministic mix:
        //   t=2_000  : .forward       ⇒ cascade .suppress → seq 0
        //   t=4_000  : .dropIdle past floor ⇒ floor .suppress → seq 1
        //   t=6_000  : .forward       ⇒ cascade .suppress → seq 2
        //   t=8_000  : .dropNearDup past floor ⇒ floor .suppress → seq 3
        let frames: [(CandidateFrame, UInt64)] = [
            (forwardingFrame(),      2_000),
            (idleFrame(),            4_000),
            (forwardingFrame(),      6_000),
            (nearDuplicateFrame(),   8_000),
        ]

        var outcomes: [SCStreamPipeline.Outcome] = []
        for (f, t) in frames {
            let lease = SurfaceLease(releaser: SpyReleaser())
            let o = try await pipe.process(
                frame: f,
                context: WorkflowContext(appBundleId: "com.static.surface"),
                nowUs: t,
                lease: lease
            )
            outcomes.append(o)
        }

        // Extract the seqs that the suppress path wrote into the sink.
        let sinkWrites = await sink.count()
        XCTAssertEqual(sinkWrites, 4, "every cascade evaluation in this fail-safe regime emits one tombstone")

        // Pull all seq fields off the outcomes (every outcome is a
        // `.suppressed` here so the FrameSequence allocated for each).
        // The `FrameSequence.current()` afterward must equal 4 — exactly
        // four allocations, no gap.
        let next = await sequence.current()
        XCTAssertEqual(next, 4, "exactly 4 seq allocations across mixed forward + floor frames; no gaps, no duplicates")

        // Verify alternation of forcedByFloor flags matches the mix.
        if case .suppressed(_, let f0) = outcomes[0] { XCTAssertFalse(f0) } else { XCTFail("outcome 0") }
        if case .suppressed(_, let f1) = outcomes[1] { XCTAssertTrue(f1) }  else { XCTFail("outcome 1") }
        if case .suppressed(_, let f2) = outcomes[2] { XCTAssertFalse(f2) } else { XCTFail("outcome 2") }
        if case .suppressed(_, let f3) = outcomes[3] { XCTAssertTrue(f3) }  else { XCTFail("outcome 3") }
    }

    // MARK: - (f) lastCascadeRunUs updates on EVERY cascade call

    func test_last_cascade_us_updates_on_every_cascade_call() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let floorState = CascadeFloorState()
        let pipe = makePipeline(
            ax: AXSilent(),                // fail-safe → .suppress on every run
            encoder: encoder, sink: sink,
            floorIntervalMs: 1,
            floorState: floorState
        )

        // Drive four cascade-firing frames at strictly increasing
        // timestamps, alternating filter-passed and floor-forced. After
        // each, the floor state's `lastCascadeRunUs` must equal the
        // nowUs we just fed in.

        let stamps: [UInt64] = [10_000, 20_000, 30_000, 40_000]
        let frames: [CandidateFrame] = [
            forwardingFrame(),     // filter-passed
            idleFrame(),           // floor-forced (delta = 10_000 >= 1_000)
            forwardingFrame(),     // filter-passed
            nearDuplicateFrame(),  // floor-forced
        ]

        for (t, f) in zip(stamps, frames) {
            let lease = SurfaceLease(releaser: SpyReleaser())
            let outcome = try await pipe.process(
                frame: f,
                context: WorkflowContext(appBundleId: "com.static.surface"),
                nowUs: t,
                lease: lease
            )
            // Every iteration must hit the cascade — either via filter-pass
            // or via the floor. Outcome must be .suppressed in this regime.
            guard case .suppressed = outcome else {
                XCTFail("expected .suppressed on iteration t=\(t), got \(outcome)")
                return
            }
            let observed = await floorState.currentLastCascadeRunUs()
            XCTAssertEqual(observed, t,
                "lastCascadeRunUs must equal the nowUs of the cascade call that just ran (t=\(t))")
        }
    }

    // Same invariant on the .allow path: stamping must happen there too.
    func test_last_cascade_us_updates_on_allow_path() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let floorState = CascadeFloorState()
        let pipe = makePipeline(
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],
            encoder: encoder, sink: sink,
            floorIntervalMs: 1,
            floorState: floorState
        )

        let lease = SurfaceLease(releaser: SpyReleaser())
        _ = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 12_345,
            lease: lease
        )
        let observed = await floorState.currentLastCascadeRunUs()
        XCTAssertEqual(observed, 12_345,
            ".allow outcomes must ALSO stamp the cascade-floor wall-clock")
    }

    // The cascade floor must not re-fire on the very next frame after a
    // floor probe. Stamp-on-every-cascade is what guarantees that —
    // this test pins the regression class.
    func test_floor_does_not_refire_immediately_after_a_floor_run() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXSilent(),
            encoder: encoder, sink: sink,
            counters: counters,
            floorIntervalMs: 100   // 100 ms = 100_000 µs
        )

        // Frame 1: t=200_000 µs → past floor (delta = 200_000 ≥ 100_000)
        // ⇒ floor-forced cascade fires.
        let l1 = SurfaceLease(releaser: SpyReleaser())
        _ = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.static.surface"),
            nowUs: 200_000,
            lease: l1
        )

        // Frame 2: t=250_000 µs (only 50 ms after Frame 1) → BELOW floor.
        // Floor must NOT fire again.
        let l2 = SurfaceLease(releaser: SpyReleaser())
        let outcome2 = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.static.surface"),
            nowUs: 250_000,
            lease: l2
        )

        XCTAssertEqual(outcome2, .filteredOut,
            "the stamp from frame 1 must keep the floor from re-firing on frame 2")
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, 1,
            "exactly one floor-forced cascade across the two frames")
    }

    // Floor = 0 means "disabled" — pre-floor legacy behavior. This is the
    // safety knob for anyone who wants to reproduce the pre-fix shape.
    func test_floor_interval_zero_disables_floor() async throws {
        let counters = HelperHealthCounters()
        let pipe = makePipeline(
            ax: AXSilent(),
            encoder: SpyEncoder(), sink: RecordingSink(),
            counters: counters,
            floorIntervalMs: 0
        )

        // Even a huge nowUs must not force a cascade when the floor is 0.
        let lease = SurfaceLease(releaser: SpyReleaser())
        let outcome = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.static.surface"),
            nowUs: 999_999_999_999,
            lease: lease
        )
        XCTAssertEqual(outcome, .filteredOut)
        let snap = await counters.snapshot()
        XCTAssertEqual(snap.cascadeForced, 0)
        XCTAssertEqual(snap.cascadeFromFilter, 0)
    }

    // The `StreamPolicy.cascadeFloorIntervalMs` default value is the
    // contract surface; a refactor that flips it silently would change
    // the wire-observable behavior on every static-secure-surface frame
    // across the fleet. Lock it.
    func test_stream_policy_default_floor_interval_is_one_second() {
        XCTAssertEqual(StreamPolicy.default.cascadeFloorIntervalMs, 1000,
            "default floor is 1 Hz (STEP-2-FINDING-004 design); flipping this is a CSO-gated review item")
    }
}
