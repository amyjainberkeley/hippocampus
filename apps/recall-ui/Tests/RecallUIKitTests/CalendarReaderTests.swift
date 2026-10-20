import Foundation
import XCTest
@testable import RecallUIKit

/// The calendar, read-only and on this Mac only (SPEC-DELTA 5). Tests and
/// renders read a fake: nothing here asks the real system for access.
final class CalendarReaderTests: XCTestCase {
    private func event(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> CalendarEvent {
        CalendarEvent(id: id, title: "Team sync", start: Date(timeIntervalSince1970: start),
                      end: Date(timeIntervalSince1970: end), calendarName: "Work")
    }

    func testTheFakeIsEmptyAndNotAskedByDefault() async throws {
        let calendar = FixtureCalendar()
        let access = await calendar.access()
        XCTAssertEqual(access, .notAsked)
        let events = try await calendar.events(in: DateInterval(start: .distantPast, end: .distantFuture))
        XCTAssertEqual(events, [])
    }

    func testNothingIsReadUnlessAccessIsAllowed() async throws {
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        for access in [CalendarAccess.notAsked, .denied] {
            let events = try await FixtureCalendar(access: access, events: [event("a", 0, 60)]).events(in: all)
            XCTAssertEqual(events, [], "\(access)")
        }
    }

    func testEventsOverlappingTheIntervalComeEarliestFirst() async throws {
        let calendar = FixtureCalendar(access: .allowed, events: [
            event("late", 7_200, 9_000), event("early", 0, 1_800), event("outside", 20_000, 21_000),
        ])
        let events = try await calendar.events(in: DateInterval(start: Date(timeIntervalSince1970: 900),
                                                                 end: Date(timeIntervalSince1970: 8_000)))
        XCTAssertEqual(events.map(\.id), ["early", "late"])
    }

    func testAnEventKeepsOnlyItsTitleTimeCalendarAndLocation() {
        let labels = Set(Mirror(reflecting: event("a", 0, 60)).children.compactMap { $0.label })
        let allowed: Set<String> = ["id", "title", "start", "end", "isAllDay", "calendarName", "location"]
        XCTAssertTrue(labels.isSubset(of: allowed), "attendee lists are never read or stored: \(labels)")
        XCTAssertTrue(labels.isSuperset(of: ["title", "start", "end", "calendarName"]))
    }
}
