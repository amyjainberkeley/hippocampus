// SPDX-License-Identifier: Apache-2.0
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
    // The helper reads no calendar and makes no store
    // ------------------------------------------------------------------

    /// Nothing reads `WorkflowContext.currentCalendarEvent` or sends it, so
    /// the helper's own source reads nothing: starting it, and every tick
    /// with it, give no event, with the calendar on or off.
    func testTheHelpersCalendarSourceReadsNothing() async {
        let attribution = CalendarAttribution()
        attribution.start()
        attribution.start()
        for seconds in [0.0, 100, 1_716_900_000] {
            XCTAssertNil(attribution.eventNow(at: Date(timeIntervalSince1970: seconds)))
        }
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: StubFrontmostAppSource(initial: "com.apple.Safari"),
            titleProvider: nil,
            calendarSource: attribution,
            nowPlayingSource: nil,
            contactsSource: nil,
            store: store
        )
        XCTAssertEqual(store.currentSync().appBundleId, "com.apple.Safari")
        XCTAssertNil(store.currentSync().currentCalendarEvent)
    }

    /// No `EKEventStore` is made anywhere in the capture helper, at launch
    /// or later, while the calendar is off or on: making one can start the
    /// calendar's services, and the helper has nothing to read with it. The
    /// calendar is the window's, read only while the person has it on.
    func testTheCaptureHelperNeverMakesACalendarStore() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50, "the package's sources were found")
        for file in files {
            // The code without comments, so prose that names an API is not a call.
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").map { line in
                line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
            }.joined(separator: "\n")
            for call in ["EKEventStore", "import EventKit", "requestFullAccessToEvents", "predicateForEvents",
                         "authorizationStatus(for: .event"] {
                XCTAssertFalse(code.contains(call), "\(file.lastPathComponent) reads the calendar: \(call)")
            }
        }
    }
}
