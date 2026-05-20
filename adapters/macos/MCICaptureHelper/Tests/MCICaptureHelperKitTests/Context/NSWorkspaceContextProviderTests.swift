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
//   5. With NO `windowTitleProvider` injected (the default) only
//      `appBundleId` is populated; `windowTitle` / `url` / `pageText`
//      stay nil. Pins the P2.1 byte-for-byte shape so this PR
//      (P2.2) does not silently regress P2.1's no-injection path.
//   6. With a `windowTitleProvider` injected, `windowTitle`
//      propagates into the snapshot — the provider is consulted
//      with the polled bundle id, and a polled-bundle-id of `nil`
//      short-circuits to `windowTitle: nil` without consulting the
//      provider. ADR-0015 §6 P2.2 wiring.

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

/// Programmable `WindowTitleProvider` for headless tests. Records
/// every `forFrontmost` bundle id passed in and returns whichever
/// title the test loaded into `titles` (missing → nil, matching
/// the production "no permission / no focused window / unsupported
/// bundle" leg).
final class StubWindowTitleProvider: WindowTitleProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String: String?]
    private var _lookups: [String] = []

    init(titles: [String: String?]) {
        self.titles = titles
    }

    var lookups: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lookups
    }

    func title(forFrontmost bundleId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        _lookups.append(bundleId)
        return titles[bundleId] ?? nil
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

    func testOnlyAppBundleIdIsPopulatedWithoutTitleProviderInjected() async {
        // ADR-0015 §6 P2.1 byte-for-byte shape: with NO
        // `windowTitleProvider` injected (the default), the provider
        // writes `appBundleId` only. `windowTitle` (needs the P2.2
        // provider), `url` (P2.3/P2.4 — wired at P2.5 composite),
        // `pageText` (Phase 3) all stay nil. Pins the P2.2 default-
        // off contract so this PR does not silently regress P2.1.
        let stub = StubFrontmostAppSource(initial: "com.apple.Safari")
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(source: stub, store: store)
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertNil(
            ctx.windowTitle,
            "Without a WindowTitleProvider injected, windowTitle stays nil"
        )
        XCTAssertNil(ctx.url, "P2.3/P2.4 own url, wired at P2.5 composite")
        XCTAssertNil(ctx.pageText, "Phase 3 (Vision OCR) owns pageText")
    }

    // MARK: – P2.2 windowTitle propagation

    /// With a `windowTitleProvider` injected, `tickOnce` reads the
    /// title for the polled bundle id and stores it in the
    /// snapshot. Pins the P2.2 wiring end-to-end at the provider
    /// boundary.
    func testTickOncePropagatesWindowTitleWhenProviderInjected() async {
        let stub = StubFrontmostAppSource(initial: "com.apple.Safari")
        let titleStub = StubWindowTitleProvider(
            titles: ["com.apple.Safari": "Apple — Official Site"]
        )
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: stub,
            titleProvider: titleStub,
            store: store
        )
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertEqual(ctx.windowTitle, "Apple — Official Site")
        XCTAssertEqual(
            titleStub.lookups.count, 1,
            "Title provider must be consulted exactly once per tick"
        )
        XCTAssertEqual(
            titleStub.lookups.first, "com.apple.Safari",
            "Title provider must be called with the polled bundle id"
        )
    }

    /// Polled bundle id is `nil` → provider is NOT consulted, and
    /// `windowTitle` stays nil. Pins the "no frontmost app → no
    /// title read" short-circuit in `buildContext`. The cascade is
    /// fail-closed on `appBundleId == nil` anyway; we don't want to
    /// waste an AX read for a tick that will redact regardless.
    func testNilBundleIdShortCircuitsTitleProvider() async {
        let stub = StubFrontmostAppSource(initial: nil)
        let titleStub = StubWindowTitleProvider(
            titles: ["com.apple.Safari": "should-not-be-read"]
        )
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: stub,
            titleProvider: titleStub,
            store: store
        )
        let ctx = store.currentSync()
        XCTAssertNil(ctx.appBundleId)
        XCTAssertNil(ctx.windowTitle)
        XCTAssertEqual(
            titleStub.lookups.count, 0,
            "Title provider MUST NOT be called when bundle id is nil"
        )
    }

    /// Provider returns `nil` (no permission / no focused window /
    /// timeout / unsupported bundle) → `windowTitle: nil`,
    /// `appBundleId` still flows through. Pins per-field
    /// independence (ADR-0015 §2 alternatives-rejected reasoning).
    func testTitleProviderNilDoesNotZeroOutBundleId() async {
        let stub = StubFrontmostAppSource(initial: "com.apple.Safari")
        let titleStub = StubWindowTitleProvider(titles: [:])  // every bundle → nil
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: stub,
            titleProvider: titleStub,
            store: store
        )
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertNil(ctx.windowTitle)
        XCTAssertEqual(titleStub.lookups.count, 1)
    }

    /// Live timer path: a `windowTitleProvider` injected into the
    /// `init` propagates through to the snapshot on each tick.
    /// Pins that the optional dep flows through `start()` /
    /// `setEventHandler` capture (regression-guard against a future
    /// refactor that drops the capture).
    func testInitInjectedTitleProviderPropagatesAcrossLiveTicks() async {
        let stub = StubFrontmostAppSource(initial: "com.test.live")
        let titleStub = StubWindowTitleProvider(
            titles: ["com.test.live": "Live Title"]
        )
        let store = WorkflowContextSnapshot()
        let provider = NSWorkspaceContextProvider(
            snapshotStore: store,
            source: stub,
            windowTitleProvider: titleStub,
            intervalMs: 100
        )
        provider.start()
        defer { provider.stop() }

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let ctx = store.currentSync()
            if ctx.appBundleId == "com.test.live"
                && ctx.windowTitle == "Live Title"
            {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(
            "windowTitle did not propagate within 1 s — final="
            + "\(String(describing: store.currentSync().windowTitle))"
        )
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
