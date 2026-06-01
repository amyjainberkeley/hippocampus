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
    // Production-shape construction smoke test
    // ------------------------------------------------------------------

    func testProductionConstructorBindsCleanly() {
        // The production `CalendarAttribution` must construct
        // without exceptions even in headless CI (no EventKit
        // access prompt is triggered until start() is called, and
        // the `#if canImport(EventKit)` guard collapses to a no-op
        // when the framework is unavailable).
        let attribution = CalendarAttribution()
        // Until start() is called and the auth callback resolves,
        // every read returns nil — the safe direction. Test the
        // initial state ONLY (start() triggers an async callback we
        // do NOT want to wait on in unit tests).
        XCTAssertNil(attribution.eventNow(at: Date()))
    }
}
