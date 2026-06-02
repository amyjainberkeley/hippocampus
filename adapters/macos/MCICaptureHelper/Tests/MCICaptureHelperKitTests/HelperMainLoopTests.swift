// SPDX-License-Identifier: TBD-private
//
// HelperMainLoopTests — drives the helper main loop end-to-end via
// mockable inputs. The cascade orchestrator + the FrameSink + the
// heartbeat clock are all driven by tests; no live OS APIs needed.

import Foundation
import XCTest

@testable import MCICaptureHelperKit

// MARK: - Mocks

actor RecordingFrameSink: FrameSink {
    private var frames: [Data] = []
    func write(_ data: Data) async throws {
        frames.append(data)
    }
    func recorded() -> [Data] { frames }
    func count() -> Int { frames.count }
}

private struct AllowEverythingCascade {
    static func make() -> SuppressionCascade {
        struct NoSEI: SecureEventInputProbe {
            func isSecureEventInputEnabled() -> Bool { false }
        }
        struct AXSaysNonSecure: AXSecureSubroleProbe {
            func focusedHasSecureSubrole() -> Bool? { false }
        }
        struct NoDeny: DenylistProbe {
            func appIsDenied(bundleId _: String) -> Bool { false }
            func urlIsDenied(_: String) -> Bool { false }
            func windowTitleIsDenied(_: String) -> Bool { false }
        }
        struct NoBlack: BlackedRegionProbe {
            func hasBlackedRegion() -> Bool { false }
        }
        return SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXSaysNonSecure(),
            denylist: NoDeny(),
            blackedRegion: NoBlack(),
            knownSafeAppBundles: ["com.apple.Safari"]
        )
    }
}

private struct ForceFailsafeCascade {
    static func make() -> SuppressionCascade {
        struct NoSEI: SecureEventInputProbe {
            func isSecureEventInputEnabled() -> Bool { false }
        }
        struct AXSilent: AXSecureSubroleProbe {
            func focusedHasSecureSubrole() -> Bool? { nil }
        }
        struct NoDeny: DenylistProbe {
            func appIsDenied(bundleId _: String) -> Bool { false }
            func urlIsDenied(_: String) -> Bool { false }
            func windowTitleIsDenied(_: String) -> Bool { false }
        }
        struct NoBlack: BlackedRegionProbe {
            func hasBlackedRegion() -> Bool { false }
        }
        return SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXSilent(),
            denylist: NoDeny(),
            blackedRegion: NoBlack(),
            knownSafeAppBundles: []  // empty allowlist → fail-safe
        )
    }
}

// MARK: - Counter actor

final class HelperHealthCountersTests: XCTestCase {
    func testStartsAtZero() async {
        let c = HelperHealthCounters(startedAt: Date(timeIntervalSinceNow: 0))
        let snap = await c.snapshot()
        XCTAssertEqual(snap.framesDelivered, 0)
        XCTAssertEqual(snap.framesSuppressed, 0)
        XCTAssertEqual(snap.framesDroppedBackpressure, 0)
        XCTAssertEqual(snap.framesDroppedLateAck, 0)
    }

    func testRecordedIncrementsAreObservable() async {
        let c = HelperHealthCounters()
        for _ in 0..<3 { await c.recordDelivered() }
        await c.recordSuppressed()
        let snap = await c.snapshot()
        XCTAssertEqual(snap.framesDelivered, 3)
        XCTAssertEqual(snap.framesSuppressed, 1)
    }

    func testUptimeMonotonicallyIncreasing() async {
        let start = Date(timeIntervalSinceNow: -10)
        let c = HelperHealthCounters(startedAt: start)
        let snap1 = await c.snapshot()
        try? await Task.sleep(for: .milliseconds(20))
        let snap2 = await c.snapshot()
        XCTAssertGreaterThanOrEqual(snap1.uptimeMs, 9_500)
        XCTAssertGreaterThan(snap2.uptimeMs, snap1.uptimeMs)
    }
}

// MARK: - FrameSequence actor

final class FrameSequenceTests: XCTestCase {
    func testAllocatesMonotonically() async {
        let s = FrameSequence()
        for expected in 0..<5 {
            let v = await s.allocate()
            XCTAssertEqual(v, UInt64(expected))
        }
    }

    func testStartingAtRespectsOffset() async {
        let s = FrameSequence(startingAt: 100)
        let a = await s.allocate()
        let b = await s.allocate()
        XCTAssertEqual(a, 100)
        XCTAssertEqual(b, 101)
    }
}

// MARK: - HelperMainLoop integration

final class HelperMainLoopTests: XCTestCase {
    /// tickHealth emits exactly one HelperHealth frame whose payload
    /// length matches the wire spec. wire 0x09 (Phase 6 PR 6):
    /// header(16) + 9 × u64(72) + u8 entry_count(1) + u32
    /// cpu_pct_micro(4) + u64 rss_bytes(8) + u64 tracker_alive_at_us(8)
    /// = 109 bytes when failsafe_by_app is empty (no FootprintSampler
    /// installed → CPU/RSS default 0; no per-app failsafes recorded).
    /// 0x08 → 0x09 added failsafe_by_app + cpu_pct_micro + rss_bytes
    /// + tracker_alive_at_us — see core/src/ipc/wire.rs FRAME_VERSION
    /// doc.
    func testTickHealthEmitsOneFrameWithCorrectLength() async throws {
        let sink = RecordingFrameSink()
        let loop = HelperMainLoop(
            cascade: AllowEverythingCascade.make(),
            sink: sink
        )
        try await loop.tickHealth()
        let frames = await sink.recorded()
        XCTAssertEqual(frames.count, 1)
        // header(16) + 9×u64(72) + u8(1) + u32(4) + u64(8) + u64(8) = 109
        XCTAssertEqual(frames[0].count, 109)
        // Wire magic + version.
        XCTAssertEqual(frames[0][0], 0x4D)
        XCTAssertEqual(frames[0][1], frameVersion)
        // msg_type 0x0030 = HelperHealth.
        XCTAssertEqual(frames[0][2], 0x30)
        XCTAssertEqual(frames[0][3], 0x00)
    }

    /// processSyntheticTransition on an allow path emits no frame
    /// (cycle-3 work will emit a StateTransitionEvent there; this
    /// iteration intentionally swallows the allow case).
    func testAllowPathEmitsNoFrame() async throws {
        let sink = RecordingFrameSink()
        let loop = HelperMainLoop(
            cascade: AllowEverythingCascade.make(),
            sink: sink
        )
        let ctx = WorkflowContext(
            appBundleId: "com.apple.Safari",
            windowTitle: "Hello",
            url: nil
        )
        let decision = try await loop.processSyntheticTransition(
            nowUs: 1_000,
            context: ctx
        )
        XCTAssertEqual(decision, .allow)
        let emitted = await sink.count()
        XCTAssertEqual(emitted, 0)
        // Delivered counter incremented; suppressed did not.
        let snap = await loop.counters.snapshot()
        XCTAssertEqual(snap.framesDelivered, 1)
        XCTAssertEqual(snap.framesSuppressed, 0)
        XCTAssertEqual(snap.framesRedactedByFailsafe, 0)
    }

    /// Suppress path emits exactly one PrivacyTombstone frame whose
    /// msg_type is 0x0011 and which carries the cascade's reason byte.
    func testFailsafePathEmitsPrivacyTombstone() async throws {
        let sink = RecordingFrameSink()
        let loop = HelperMainLoop(
            cascade: ForceFailsafeCascade.make(),
            sink: sink
        )
        let ctx = WorkflowContext(
            appBundleId: "com.unknown.app",
            windowTitle: "x",
            url: nil
        )
        let decision = try await loop.processSyntheticTransition(
            nowUs: 1_234_567,
            context: ctx
        )
        XCTAssertEqual(decision, .suppress(reason: .failsafeUnknown))

        let frames = await sink.recorded()
        XCTAssertEqual(frames.count, 1)
        // PrivacyTombstone msg_type = 0x0011.
        XCTAssertEqual(frames[0][2], 0x11)
        XCTAssertEqual(frames[0][3], 0x00)
        // Last byte = reason discriminant. FailsafeUnknown = 7.
        XCTAssertEqual(frames[0].last, RedactionReason.failsafeUnknown.rawValue)

        // Delivered + suppressed both incremented — and because the
        // reason was .failsafeUnknown, the §7 sentinel too (a strict
        // subset of framesSuppressed).
        let snap = await loop.counters.snapshot()
        XCTAssertEqual(snap.framesDelivered, 1)
        XCTAssertEqual(snap.framesSuppressed, 1)
        XCTAssertEqual(snap.framesRedactedByFailsafe, 1)
    }

    /// A NON-fail-safe suppression (denylist §1) increments
    /// framesSuppressed but NOT the §7 fail-safe sentinel — proving
    /// the sentinel is reason-specific, not "any suppression."
    func testNonFailsafeSuppressionDoesNotIncrementSentinel() async throws {
        struct NoSEI: SecureEventInputProbe {
            func isSecureEventInputEnabled() -> Bool { false }
        }
        struct AXSilent: AXSecureSubroleProbe {
            func focusedHasSecureSubrole() -> Bool? { nil }
        }
        struct DenyApp: DenylistProbe {
            func appIsDenied(bundleId: String) -> Bool { bundleId == "com.denied.app" }
            func urlIsDenied(_: String) -> Bool { false }
            func windowTitleIsDenied(_: String) -> Bool { false }
        }
        struct NoBlack: BlackedRegionProbe {
            func hasBlackedRegion() -> Bool { false }
        }
        let loop = HelperMainLoop(
            cascade: SuppressionCascade(
                secureEventInput: NoSEI(),
                axSecureSubrole: AXSilent(),
                denylist: DenyApp(),
                blackedRegion: NoBlack()
            ),
            sink: RecordingFrameSink()
        )
        let decision = try await loop.processSyntheticTransition(
            nowUs: 1,
            context: WorkflowContext(appBundleId: "com.denied.app")
        )
        XCTAssertEqual(decision, .suppress(reason: .denylistSource))
        let snap = await loop.counters.snapshot()
        XCTAssertEqual(snap.framesSuppressed, 1)
        XCTAssertEqual(snap.framesRedactedByFailsafe, 0)
    }

    /// Sequence numbers monotonically increase across emitted frames.
    func testSequenceMonotonicAcrossEmissions() async throws {
        let sink = RecordingFrameSink()
        let loop = HelperMainLoop(
            cascade: ForceFailsafeCascade.make(),
            sink: sink
        )
        // emit: HelperHealth (seq 0), tombstone (seq 1),
        // HelperHealth (seq 2), tombstone (seq 3).
        try await loop.tickHealth()
        let ctx = WorkflowContext(appBundleId: "com.x")
        _ = try await loop.processSyntheticTransition(nowUs: 1, context: ctx)
        try await loop.tickHealth()
        _ = try await loop.processSyntheticTransition(nowUs: 2, context: ctx)

        let frames = await sink.recorded()
        XCTAssertEqual(frames.count, 4)

        // Read seq u64 LE at bytes 4..12.
        for (i, f) in frames.enumerated() {
            let seqBytes = f[4..<12]
            let seq = seqBytes.enumerated().reduce(UInt64(0)) { acc, item in
                acc | (UInt64(item.element) << (8 * item.offset))
            }
            XCTAssertEqual(seq, UInt64(i), "frame \(i) seq")
        }
    }

    /// run() emits an immediate tick + then ticks every heartbeat.
    /// Use a 50 ms heartbeat + cancel after ~120 ms — we should see
    /// 3 frames (t=0, t=50, t=100). Allow ±1 for clock variance.
    func testRunHeartbeatsAtConfiguredInterval() async throws {
        let sink = RecordingFrameSink()
        let loop = HelperMainLoop(
            cascade: AllowEverythingCascade.make(),
            sink: sink,
            heartbeatInterval: .milliseconds(50)
        )
        let runTask = Task {
            try await loop.run()
        }
        try await Task.sleep(for: .milliseconds(120))
        runTask.cancel()
        // Wait for the task to actually finish.
        _ = try? await runTask.value

        let count = await sink.count()
        XCTAssertGreaterThanOrEqual(
            count, 2,
            "expected ≥2 ticks in 120 ms with 50 ms interval; got \(count)"
        )
        XCTAssertLessThanOrEqual(
            count, 4,
            "expected ≤4 ticks in 120 ms with 50 ms interval; got \(count)"
        )
    }
}
