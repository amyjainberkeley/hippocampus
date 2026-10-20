import Foundation
import XCTest
@testable import RecallUIKit

/// A calendar store for tests (SPEC-DELTA 5): macOS's answer is whatever the
/// test says, every read and request is counted, and nothing touches
/// EventKit or the real system's permissions.
final class FakeCalendarStore: CalendarStore, @unchecked Sendable {
    enum Answer {
        /// The person allows or refuses; macOS's answer changes to match.
        case person(allows: Bool)
        /// macOS couldn't ask; its answer stays as it was.
        case fails
    }

    struct Failure: Error {}

    private let lock = NSLock()
    private var current: CalendarPermission
    private let reply: Answer
    private let held: [CalendarEvent]
    private var requests = 0
    private var reads: [DateInterval] = []

    init(_ permission: CalendarPermission, answer: Answer = .person(allows: true), events: [CalendarEvent] = []) {
        current = permission
        reply = answer
        held = events
    }

    var requestCount: Int { lock.withLock { requests } }
    var readIntervals: [DateInterval] { lock.withLock { reads } }

    /// macOS's answer changes, as when the person changes it in System Settings.
    func change(to permission: CalendarPermission) {
        lock.withLock { current = permission }
    }

    func permission() -> CalendarPermission {
        lock.withLock { current }
    }

    func requestFullAccess() async throws -> Bool {
        lock.withLock { requests += 1 }
        switch reply {
        case .person(let allows):
            change(to: allows ? .fullAccess : .denied)
            return allows
        case .fails:
            throw Failure()
        }
    }

    /// Everything it holds, whatever the interval, so the reader's own
    /// filtering is what the tests see.
    func events(in interval: DateInterval) throws -> [CalendarEvent] {
        lock.withLock { reads.append(interval) }
        return permission() == .fullAccess ? held : []
    }
}

/// The window's calendar (SPEC-DELTA 5), over a fake store: the person's
/// choice first, then what macOS allows, and only a click asks.
final class SystemCalendarTests: XCTestCase {
    /// Tuesday, October 13, 2026, midnight to midnight in Los Angeles.
    private let day = DateInterval(start: Date(timeIntervalSince1970: 1_791_874_800), duration: 86_400)

    private func event(_ id: String, hour: Double, minutes: Double = 30, title: String = "Team sync")
        -> CalendarEvent {
        let start = day.start.addingTimeInterval(hour * 3_600)
        return CalendarEvent(id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                             calendarName: "Work")
    }

    func testNothingIsReadOrAskedBeforeThePersonChooses() async throws {
        let store = FakeCalendarStore(.fullAccess, events: [event("a", hour: 9)])
        let calendar = SystemCalendar(store: store, setting: .inMemory())
        let access = await calendar.access()
        XCTAssertEqual(access, .notAsked)
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events, [])
        XCTAssertEqual(store.readIntervals, [], "not even a read that macOS would allow")
        XCTAssertEqual(store.requestCount, 0)
    }

    func testTurnedOffReadsNothingEvenWhileMacOSAllowsIt() async throws {
        let store = FakeCalendarStore(.fullAccess, events: [event("a", hour: 9)])
        let calendar = SystemCalendar(store: store, setting: .inMemory(false))
        let access = await calendar.access()
        XCTAssertEqual(access, .notAsked)
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events, [])
        XCTAssertEqual(store.readIntervals, [])
    }

    func testOnAndAllowedReadsTheDayEarliestFirst() async throws {
        let store = FakeCalendarStore(.fullAccess, events: [
            event("late", hour: 16), event("early", hour: 9), event("b-same", hour: 13), event("a-same", hour: 13),
        ])
        let calendar = SystemCalendar(store: store, setting: .inMemory(true))
        let access = await calendar.access()
        XCTAssertEqual(access, .allowed)
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events.map(\.id), ["early", "a-same", "b-same", "late"])
        XCTAssertEqual(store.readIntervals, [day])
    }

    func testWhatMacOSAllowsDecidesWhenThePersonHasItOn() {
        let rows: [(Bool?, CalendarPermission, CalendarAccess)] = [
            (true, .fullAccess, .allowed), (true, .notDetermined, .notAsked), (true, .denied, .denied),
            (true, .addOnly, .denied), (true, .restricted, .denied),
            (nil, .fullAccess, .notAsked), (false, .fullAccess, .notAsked), (nil, .denied, .notAsked),
            (nil, .notDetermined, .notAsked),
            // A Mac that doesn't let apps read calendars: never offered, whatever was chosen.
            (nil, .restricted, .denied), (false, .restricted, .denied),
        ]
        for (choice, permission, access) in rows {
            XCTAssertEqual(SystemCalendar.access(choice: choice, permission: permission), access,
                           "\(String(describing: choice)), \(permission)")
        }
    }

    func testDeniedRestrictedOrAddOnlyReadNothing() async throws {
        for permission in [CalendarPermission.denied, .restricted, .addOnly, .notDetermined] {
            let store = FakeCalendarStore(permission, events: [event("a", hour: 9)])
            let calendar = SystemCalendar(store: store, setting: .inMemory(true))
            let events = try await calendar.events(in: day)
            XCTAssertEqual(events, [], "\(permission)")
            XCTAssertEqual(store.readIntervals, [], "\(permission)")
        }
    }

    func testAccessTakenBackLaterStopsTheNextReadAndNothingBreaks() async throws {
        let store = FakeCalendarStore(.fullAccess, events: [event("a", hour: 9)])
        let calendar = SystemCalendar(store: store, setting: .inMemory(true))
        let before = try await calendar.events(in: day)
        XCTAssertEqual(before.count, 1)
        store.change(to: .denied)
        let access = await calendar.access()
        XCTAssertEqual(access, .denied)
        let after = try await calendar.events(in: day)
        XCTAssertEqual(after, [], "Today drops its bars")
        XCTAssertEqual(store.readIntervals.count, 1)
        store.change(to: .fullAccess)
        let again = try await calendar.events(in: day)
        XCTAssertEqual(again.count, 1, "allowed again in System Settings: it shows without another click")
        XCTAssertEqual(store.requestCount, 0)
    }

    func testReadsNeverAskMacOS() async throws {
        let store = FakeCalendarStore(.notDetermined)
        let calendar = SystemCalendar(store: store, setting: .inMemory(true))
        for _ in 0..<3 {
            _ = await calendar.access()
            _ = try await calendar.events(in: day)
        }
        XCTAssertEqual(store.requestCount, 0)
    }

    func testShowCalendarAsksMacOSOnlyWhenItNeverHas() async throws {
        let store = FakeCalendarStore(.notDetermined, answer: .person(allows: true), events: [event("a", hour: 9)])
        let setting = CalendarSetting.inMemory()
        let calendar = SystemCalendar(store: store, setting: setting)
        let access = await calendar.turnOn()
        XCTAssertEqual(access, .allowed)
        XCTAssertEqual(setting.choice, true)
        XCTAssertEqual(store.requestCount, 1)
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events.map(\.id), ["a"])
        _ = await calendar.turnOn()
        XCTAssertEqual(store.requestCount, 1, "already allowed: no second question")
    }

    func testShowCalendarWhenThePersonSaysNo() async {
        let store = FakeCalendarStore(.notDetermined, answer: .person(allows: false))
        let calendar = SystemCalendar(store: store, setting: .inMemory())
        let access = await calendar.turnOn()
        XCTAssertEqual(access, .denied)
        XCTAssertEqual(CalendarCopy.note(after: access), CalendarCopy.notAllowed)
    }

    func testShowCalendarAfterAnEarlierNoDoesNotAskAgain() async {
        let store = FakeCalendarStore(.denied)
        let calendar = SystemCalendar(store: store, setting: .inMemory(false))
        let access = await calendar.turnOn()
        XCTAssertEqual(access, .denied)
        XCTAssertEqual(store.requestCount, 0, "macOS won't ask twice: System Settings is where it changes")
        XCTAssertTrue(calendar.canAllowInSystemSettings)
        store.change(to: .addOnly)
        XCTAssertTrue(calendar.canAllowInSystemSettings, "add-only access is changed there too")
    }

    func testOnAMacThatDoesNotAllowItNothingIsOfferedOrKept() async throws {
        let store = FakeCalendarStore(.restricted, events: [event("a", hour: 9)])
        let setting = CalendarSetting.inMemory()
        let calendar = SystemCalendar(store: store, setting: setting)
        let before = await calendar.access()
        XCTAssertEqual(before, .denied, "Today offers only what can work")
        let access = await calendar.turnOn()
        XCTAssertEqual(access, .denied)
        XCTAssertNil(setting.choice, "no choice is kept that the Mac won't allow")
        XCTAssertEqual(store.requestCount, 0)
        XCTAssertFalse(calendar.canAllowInSystemSettings, "the person can't change it in System Settings")
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events, [])
        XCTAssertEqual(store.readIntervals, [])
    }

    func testShowCalendarWhenMacOSCantBeAsked() async {
        let store = FakeCalendarStore(.notDetermined, answer: .fails)
        let setting = CalendarSetting.inMemory()
        let calendar = SystemCalendar(store: store, setting: setting)
        let access = await calendar.turnOn()
        XCTAssertEqual(access, .notAsked)
        XCTAssertEqual(setting.choice, false, "nothing was decided: the window and Preferences agree it is off")
        XCTAssertEqual(CalendarCopy.note(after: access), CalendarCopy.couldNotAsk)
        XCTAssertNil(CalendarCopy.note(after: .allowed))
    }

    func testTurningOffStopsReading() async throws {
        let store = FakeCalendarStore(.fullAccess, events: [event("a", hour: 9)])
        let setting = CalendarSetting.inMemory(true)
        let calendar = SystemCalendar(store: store, setting: setting)
        calendar.turnOff()
        XCTAssertEqual(setting.choice, false)
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events, [])
        XCTAssertEqual(store.readIntervals, [])
    }

    func testALongRangeKeepsItsLatestYear() async throws {
        let store = FakeCalendarStore(.fullAccess)
        let calendar = SystemCalendar(store: store, setting: .inMemory(true))
        let threeYears = DateInterval(start: day.end.addingTimeInterval(-3 * 365 * 86_400), end: day.end)
        _ = try await calendar.events(in: threeYears)
        XCTAssertEqual(store.readIntervals.first?.end, day.end)
        XCTAssertEqual(store.readIntervals.first?.duration, SystemCalendar.longestRead)
        _ = try await calendar.events(in: day)
        XCTAssertEqual(store.readIntervals.last, day, "a day is read as it is")
    }

    func testOnlyEventsInsideTheRangeWithALengthComeBackUpToTheMost() async throws {
        let empty = CalendarEvent(id: "empty", title: "Hold", start: day.start.addingTimeInterval(3_600),
                                  end: day.start.addingTimeInterval(3_600), calendarName: "Work")
        let outside = CalendarEvent(id: "tomorrow", title: "Planning", start: day.end.addingTimeInterval(3_600),
                                    end: day.end.addingTimeInterval(7_200), calendarName: "Work")
        let crossing = CalendarEvent(id: "late", title: "Launch", start: day.end.addingTimeInterval(-1_800),
                                     end: day.end.addingTimeInterval(1_800), calendarName: "Work")
        let many = (0..<(SystemCalendar.mostEvents + 50)).map { index in
            event(String(format: "e%05d", index), hour: 8 + Double(index % 600) / 60, minutes: 1)
        }
        let store = FakeCalendarStore(.fullAccess, events: [empty, outside, crossing] + many)
        let calendar = SystemCalendar(store: store, setting: .inMemory(true))
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events.count, SystemCalendar.mostEvents)
        XCTAssertFalse(events.contains { $0.id == "empty" || $0.id == "tomorrow" })
        let few = SystemCalendar(store: FakeCalendarStore(.fullAccess, events: [empty, outside, crossing]),
                                 setting: .inMemory(true))
        let shown = try await few.events(in: day)
        XCTAssertEqual(shown.map(\.id), ["late"], "an event running past midnight still shows on its day")
    }

    func testTheChoiceIsSharedWithTheApp() throws {
        let suite = "ai.hippocampus.tests.window-calendar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = CalendarSetting(defaults: defaults)
        XCTAssertNil(setting.choice)
        setting.set(true)
        XCTAssertEqual(defaults.object(forKey: "ai.hippocampus.calendar.show") as? Bool, true)
        XCTAssertTrue(CalendarSetting(defaults: defaults).isOn, "the app's Preferences and the window read one key")

        // The app keeps the same key (HippocampusKit's CalendarSetting).
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: repository.appendingPathComponent(
            "apps/hippocampus/Sources/HippocampusKit/Calendar/CalendarAccess.swift"
        ), encoding: .utf8)
        XCTAssertTrue(app.contains("public static let key = \"\(CalendarSetting.key)\""))
    }

    func testSystemSettingsOpensOnCalendarsPrivacy() {
        XCTAssertEqual(SystemCalendar.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }
}
