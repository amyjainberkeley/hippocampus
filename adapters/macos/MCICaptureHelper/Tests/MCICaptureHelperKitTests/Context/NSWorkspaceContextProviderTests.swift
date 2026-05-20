// SPDX-License-Identifier: TBD-private
//
// NSWorkspaceContextProviderTests — exercises the polling + snapshot
// push without a real NSWorkspace. Uses a `StubFrontmostAppSource`
// the same way PRs #36/#38 stub `SecureEventInputProbe` /
// `AXSecureSubroleProbe` in their headless tests.
//
// We test:
//   1. `tickOnce(...)` (synchronous test hook) — push reaches the
//      snapshot end-to-end.
//   2. `start()` then poll for ≤ 2 s — at least one timer tick fires
//      and the snapshot leaves all-nil. Uses a stub source so no AX
//      / NSWorkspace / TCC permission is involved.
//   3. `stop()` halts further ticks — counter does not advance after.
//   4. `start()` is idempotent — calling twice does not double-fire.
//   5. Only `appBundleId` is populated in P2.1; `windowTitle` / `url`
//      / `pageText` stay nil. Pins ADR-0015 §6 P2.1 scope —
//      regression-guards future PRs from accidentally writing the
//      P2.2/P2.3/P2.4 fields out of order.

import XCTest
@testable import MCICaptureHelperKit

/// Stub `FrontmostAppSource` that returns whatever the test sets, with
/// a thread-safe call counter. Mirrors the
/// `MockSecureEventInputProbe` shape from SuppressionCascadeTests.
final class StubFrontmostAppSource: FrontmostAppSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _bundleId: String?
    private var _callCount: Int = 0

    init(initial: String? = nil) {
        self._bundleId = initial
    }

    func set(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        _bundleId = id
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func currentBundleId() -> String? {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
        return _bundleId
    }
}

final class NSWorkspaceContextProviderTests: XCTestCase {
    func testTickOncePushesObservedBundleIdToSnapshot() async {
        let stub = StubFrontmostAppSource(initial: "com.apple.Safari")
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(source: stub, store: store)
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertEqual(stub.callCount, 1)
    }

    func testTickOncePushesNilWhenSourceReturnsNil() async {
        let stub = StubFrontmostAppSource(initial: nil)
        let store = WorkflowContextSnapshot()
        // Pre-load a non-nil so we can prove the tick actually
        // overwrites with nil rather than no-oping.
        await store.store(WorkflowContext(appBundleId: "com.previous.app"))
        await NSWorkspaceContextProvider.tickOnce(source: stub, store: store)
        XCTAssertNil(store.currentSync().appBundleId)
    }

    func testOnlyAppBundleIdIsPopulatedInP21() async {
        // ADR-0015 §6 P2.1 scope guard: this PR ships `appBundleId`
        // only. `windowTitle` (P2.2), `url` (P2.3/P2.4), `pageText`
        // (Phase 3) all stay nil. A future PR that accidentally
        // writes them through this provider trips this test.
        let stub = StubFrontmostAppSource(initial: "com.apple.Safari")
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(source: stub, store: store)
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertNil(ctx.windowTitle, "P2.2 owns windowTitle, not P2.1")
        XCTAssertNil(ctx.url, "P2.3/P2.4 own url, not P2.1")
        XCTAssertNil(ctx.pageText, "Phase 3 (Vision OCR) owns pageText")
    }

    func testStartFiresAtLeastOneTickWithinPollInterval() async {
        // 100 ms interval to keep the test snappy; production default
        // is 1000 ms (ADR-0015 §3). The test asserts only that a tick
        // fires — the cadence itself is verified by inspection of the
        // `DispatchSourceTimer.schedule(...)` interval argument.
        let stub = StubFrontmostAppSource(initial: "com.test.alpha")
        let store = WorkflowContextSnapshot()
        let provider = NSWorkspaceContextProvider(
            snapshotStore: store,
            source: stub,
            intervalMs: 100
        )
        provider.start()
        defer { provider.stop() }

        // Poll for ≤ 1 s for the first tick to land in the snapshot.
        // Most ticks fire well under 50 ms (timer schedules at .now()).
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if store.currentSync().appBundleId == "com.test.alpha" {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
        XCTFail(
            "timer did not push a snapshot within 1 s — callCount=\(stub.callCount), final=\(String(describing: store.currentSync().appBundleId))"
        )
    }

    func testStartIsIdempotent() async {
        let stub = StubFrontmostAppSource(initial: "com.test.idem")
        let store = WorkflowContextSnapshot()
        let provider = NSWorkspaceContextProvider(
            snapshotStore: store,
            source: stub,
            intervalMs: 100
        )
        provider.start()
        provider.start()  // second call must NOT double-schedule
        defer { provider.stop() }

        // Wait for the snapshot to settle to the stub value.
        let landed = await waitForBundleId(
            "com.test.idem",
            in: store,
            timeout: 1.0
        )
        XCTAssertTrue(landed)

        // Sleep a window in which a doubled timer would fire ~6 times
        // (two timers @ 100 ms × 300 ms). Then check the call count
        // is within the single-timer bound. We allow some slack for
        // scheduling jitter; what we're proving is "not 2×".
        let before = stub.callCount
        try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
        let after = stub.callCount
        let delta = after - before
        // Single 100 ms timer @ 300 ms ≈ 3 ticks. Two timers would
        // produce ≈ 6. The upper bound here gives 50% headroom for
        // jitter while still failing on a doubled schedule.
        XCTAssertLessThanOrEqual(
            delta, 5,
            "second start() doubled the timer cadence (delta=\(delta) over 300ms @ 100ms interval)"
        )
    }

    func testStopHaltsFurtherTicks() async {
        let stub = StubFrontmostAppSource(initial: "com.test.stop")
        let store = WorkflowContextSnapshot()
        let provider = NSWorkspaceContextProvider(
            snapshotStore: store,
            source: stub,
            intervalMs: 100
        )
        provider.start()
        let landed = await waitForBundleId(
            "com.test.stop",
            in: store,
            timeout: 1.0
        )
        XCTAssertTrue(landed)

        provider.stop()
        let afterStop = stub.callCount

        // Wait beyond the interval; counter should not advance once
        // the timer is cancelled. Allow one tick of slack for a tick
        // already in flight at cancel time.
        try? await Task.sleep(nanoseconds: 400_000_000) // 400 ms
        let later = stub.callCount
        XCTAssertLessThanOrEqual(
            later - afterStop, 1,
            "stop() did not halt the timer (\(later - afterStop) ticks after stop in 400ms)"
        )
    }

    func testStopBeforeStartIsNoOp() {
        let stub = StubFrontmostAppSource(initial: "com.test.noop")
        let store = WorkflowContextSnapshot()
        let provider = NSWorkspaceContextProvider(
            snapshotStore: store,
            source: stub,
            intervalMs: 100
        )
        provider.stop()  // must not crash or leak
        XCTAssertEqual(stub.callCount, 0)
        XCTAssertNil(store.currentSync().appBundleId)
    }

    func testSnapshotReturnsSnapshotStoreCurrent() async {
        // Pins the `ContextProvider.snapshot()` contract: it MUST
        // delegate to the snapshot store's non-blocking accessor —
        // the SCStream callback at P2.5 will call this synchronously.
        let stub = StubFrontmostAppSource(initial: "com.test.snap")
        let store = WorkflowContextSnapshot()
        await store.store(WorkflowContext(appBundleId: "com.test.snap"))
        let provider = NSWorkspaceContextProvider(
            snapshotStore: store,
            source: stub
        )
        XCTAssertEqual(provider.snapshot().appBundleId, "com.test.snap")
    }

    // MARK: - Helpers

    private func waitForBundleId(
        _ id: String,
        in store: WorkflowContextSnapshot,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.currentSync().appBundleId == id { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
