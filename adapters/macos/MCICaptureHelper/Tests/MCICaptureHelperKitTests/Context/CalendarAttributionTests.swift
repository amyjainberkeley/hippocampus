// SPDX-License-Identifier: TBD-private
//
// CalendarAttributionTests — Phase 6 PR 5 (SH Fork D1).
//
// Production reads `EKEventStore`; tests inject a stub
// `CalendarEventSource` so the cascade-equivalent contract is
// exercisable without a real EventKit pipeline / TCC prompt.

import XCTest
@testable import MCICaptureHelperKit

/// Stub `CalendarEventSource` for deterministic tests. Records every
/// `eventNow(at:)` call so we can assert the per-tick read happened
/// (or did not).
final class StubCalendarEventSource: CalendarEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _event: CalendarEventRef?
    private var _calls: Int = 0

    init(initial: CalendarEventRef? = nil) {
        self._event = initial
    }

    func set(_ event: CalendarEventRef?) {
        lock.lock(); defer { lock.unlock() }
        _event = event
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func eventNow(at _: Date) -> CalendarEventRef? {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _event
    }
}

final class CalendarAttributionTests: XCTestCase {

    // ------------------------------------------------------------------
    // TCC-granted path — provider returns the EventKit event
    // ------------------------------------------------------------------

    func testStubReturnsConfiguredEvent() async {
        let event = CalendarEventRef(
            subject: "Weekly 1:1",
            startUnixSeconds: 1_716_900_000,
            endUnixSeconds: 1_716_903_600
        )
        let stub = StubCalendarEventSource(initial: event)
        let observed = stub.eventNow(at: Date())
        XCTAssertEqual(observed, event)
        XCTAssertEqual(stub.calls, 1)
    }

    // ------------------------------------------------------------------
    // TCC-denied / no-event path — graceful absence
    // ------------------------------------------------------------------

    func testStubReturnsNilWhenNoEvent() async {
        let stub = StubCalendarEventSource(initial: nil)
        XCTAssertNil(stub.eventNow(at: Date()))
        XCTAssertEqual(stub.calls, 1)
    }

    // ------------------------------------------------------------------
    // Integration with NSWorkspaceContextProvider — the provider's
    // tick consumes the calendar source and writes the event to the
    // snapshot.
    // ------------------------------------------------------------------

    func testTickFoldsCalendarEventIntoSnapshot() async {
        let event = CalendarEventRef(
            subject: "Standup",
            startUnixSeconds: 1_716_900_000,
            endUnixSeconds: 1_716_903_600
        )
        let frontmost = StubFrontmostAppSource(initial: "com.apple.Safari")
        let calendar = StubCalendarEventSource(initial: event)
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: frontmost,
            titleProvider: nil,
            calendarSource: calendar,
            nowPlayingSource: nil,
            contactsSource: nil,
            store: store
        )
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertEqual(ctx.currentCalendarEvent, event)
        XCTAssertNil(ctx.currentListeningTrack)
        XCTAssertNil(ctx.currentContact)
    }

    func testTickWithNoCalendarSourceKeepsFieldNil() async {
        let frontmost = StubFrontmostAppSource(initial: "com.apple.Safari")
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: frontmost,
            titleProvider: nil,
            calendarSource: nil,
            nowPlayingSource: nil,
            contactsSource: nil,
            store: store
        )
        XCTAssertNil(store.currentSync().currentCalendarEvent)
    }

    func testTccDeniedSourceReturnsNilGracefully() async {
        // Production `CalendarAttribution` returns nil when auth is
        // not granted. Stub mirrors that contract by returning nil
        // without throwing — the per-tick path must NOT crash.
        let frontmost = StubFrontmostAppSource(initial: "com.apple.Safari")
        let calendar = StubCalendarEventSource(initial: nil)
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: frontmost,
            titleProvider: nil,
            calendarSource: calendar,
            nowPlayingSource: nil,
            contactsSource: nil,
            store: store
        )
        // No event observed — calendar field stays nil. Event capture
        // itself is not affected (appBundleId still populated).
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Safari")
        XCTAssertNil(ctx.currentCalendarEvent)
    }

    // ------------------------------------------------------------------
    // Lazy construction and authorization, using no EventKit store
    // ------------------------------------------------------------------

    func testConstructionAndUnauthorizedReadsNeverCreateStore() {
        let factory = CalendarStoreFactorySpy()
        let attribution = CalendarAttribution(storeFactory: factory.makeStore)
        XCTAssertEqual(factory.calls, 0)
        XCTAssertNil(attribution.eventNow(at: Date(timeIntervalSince1970: 100)))
        XCTAssertNil(attribution.eventNow(at: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(factory.calls, 0)
        XCTAssertEqual(factory.store.requests, 0)
        XCTAssertTrue(factory.store.readDates.isEmpty)
    }

    func testExplicitStartRequestsAccessAndPendingOrDeniedAccessCannotRead() {
        let factory = CalendarStoreFactorySpy()
        let attribution = CalendarAttribution(storeFactory: factory.makeStore)
        attribution.start()
        XCTAssertEqual(factory.calls, 1)
        XCTAssertEqual(factory.store.requests, 1)
        XCTAssertNil(attribution.eventNow(at: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(factory.store.readDates.isEmpty)
        factory.store.completeAccess(granted: false)
        XCTAssertNil(attribution.eventNow(at: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(factory.store.readDates.isEmpty)
        XCTAssertEqual(factory.calls, 1)
    }

    func testGrantedAccessReadsExactDateAndPreservesCacheTTL() {
        let factory = CalendarStoreFactorySpy()
        let attribution = CalendarAttribution(cacheTtl: 30, storeFactory: factory.makeStore)
        attribution.start()
        factory.store.completeAccess(granted: true)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(attribution.eventNow(at: now), factory.store.event)
        XCTAssertEqual(attribution.eventNow(at: now.addingTimeInterval(1)), factory.store.event)
        XCTAssertEqual(factory.store.readDates, [now])
        XCTAssertEqual(attribution.eventNow(at: now.addingTimeInterval(31)), factory.store.event)
        XCTAssertEqual(factory.store.readDates, [now, now.addingTimeInterval(31)])
        XCTAssertEqual(factory.calls, 1)
    }

    func testRepeatedExplicitStartsReuseOneStoreAndPreserveAccessRequests() {
        let factory = CalendarStoreFactorySpy()
        let attribution = CalendarAttribution(storeFactory: factory.makeStore)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in attribution.start() }
        XCTAssertEqual(factory.calls, 1)
        XCTAssertEqual(factory.store.requests, 8)
        XCTAssertTrue(factory.store.readDates.isEmpty)
    }
}

private final class CalendarStoreFactorySpy: @unchecked Sendable {
    let store = FakeCalendarStore()
    private let lock = NSLock()
    private var creations = 0
    var calls: Int { lock.withLock { creations } }

    func makeStore() -> any CalendarAttributionStore {
        lock.withLock { creations += 1 }
        return store
    }
}

private final class FakeCalendarStore: CalendarAttributionStore, @unchecked Sendable {
    let event = CalendarEventRef(subject: "Synthetic meeting", startUnixSeconds: 90, endUnixSeconds: 200)
    private let lock = NSLock()
    private var callbacks: [@Sendable (Bool) -> Void] = []
    private var observedDates: [Date] = []
    var requests: Int { lock.withLock { callbacks.count } }
    var readDates: [Date] { lock.withLock { observedDates } }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { callbacks.append(completion) }
    }

    func completeAccess(granted: Bool) {
        let callback = lock.withLock { callbacks.last }
        callback?(granted)
    }

    func eventNow(at now: Date) -> CalendarEventRef? {
        lock.withLock { observedDates.append(now) }
        return event
    }
}
