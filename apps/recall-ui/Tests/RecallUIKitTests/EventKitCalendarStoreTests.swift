import EventKit
import Foundation
import XCTest
@testable import RecallUIKit

/// The window's EventKit store (SPEC-DELTA 5). No `EKEventStore` is made
/// here: making one can start the calendar's services, and tests never touch
/// the real calendar. Its reading is held to its source instead.
final class EventKitCalendarStoreTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }

    /// Who is invited, the organizer, notes and links are never read; nothing
    /// is ever written; and one place asks macOS.
    func testItReadsOnlyTitleTimeCalendarAndPlace() throws {
        let store = try source("Sources/RecallUIKit/Calendar/EventKitCalendarStore.swift")
        for banned in [".attendees", ".organizer", ".notes", ".hasNotes", ".hasAttendees", ".url", "EKParticipant",
                       ".structuredLocation", "requestWriteOnlyAccessToEvents", ".save(", ".remove(", ".commit("] {
            XCTAssertFalse(store.contains(banned), "\(banned) is never read or used")
        }
        XCTAssertEqual(store.components(separatedBy: "requestFullAccessToEvents()").count - 1, 1)
        XCTAssertEqual(store.components(separatedBy: "CalendarEvent(").count - 1, 1,
                       "one place makes an event from EventKit")
    }

    /// Only Show Calendar's `turnOn()` asks: no read and no other window code.
    func testOnlyShowCalendarAsksMacOS() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = package.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var askers: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("requestFullAccess()") || text.contains("requestFullAccessToEvents") {
                askers.insert(file.lastPathComponent)
            }
            XCTAssertFalse(text.contains("requestAccess(to: .event"), file.lastPathComponent)
        }
        XCTAssertEqual(askers, ["EventKitCalendarStore.swift", "SystemCalendar.swift"])
        let reader = try source("Sources/RecallUIKit/Calendar/SystemCalendar.swift")
        XCTAssertEqual(reader.components(separatedBy: "store.requestFullAccess()").count - 1, 1)
    }

    func testWhatMacOSAnswersMeansWhatItSays() {
        XCTAssertEqual(EventKitCalendarStore.permission(.notDetermined), .notDetermined)
        XCTAssertEqual(EventKitCalendarStore.permission(.fullAccess), .fullAccess)
        XCTAssertEqual(EventKitCalendarStore.permission(.writeOnly), .addOnly)
        XCTAssertEqual(EventKitCalendarStore.permission(.denied), .denied)
        XCTAssertEqual(EventKitCalendarStore.permission(.restricted), .restricted)
        XCTAssertEqual(EventKitCalendarStore.permission(EKAuthorizationStatus(rawValue: 99)!), .denied,
                       "anything new reads nothing")
    }

    func testAPlaceKeepsOnlyALinksSite() {
        XCTAssertEqual(CalendarText.place("https://us02web.zoom.us/j/81234567890?pwd=SAMPLEpasscode"),
                       "us02web.zoom.us", "a meeting's code and passcode are never kept")
        XCTAssertEqual(CalendarText.place("Zoom (https://northwind.zoom.us/j/555?pwd=abc)"), "Zoom northwind.zoom.us")
        XCTAssertEqual(CalendarText.place("meet.example.com/abc-defg-hij"), "meet.example.com")
        XCTAssertEqual(CalendarText.place("https://www.example.com/rooms/4?token=xyz"), "example.com")
        XCTAssertEqual(CalendarText.place("Room 4.2/4.3"), "Room 4.2/4.3", "not every slash is a link")
        XCTAssertEqual(CalendarText.place("sam@example.com"), "sam@example.com")
    }

    func testAPlaceReadsOnOneLineAndStaysShort() {
        XCTAssertEqual(CalendarText.place("Trailhead HQ\n  12 Harbor Street\nSuite 4"),
                       "Trailhead HQ, 12 Harbor Street, Suite 4")
        XCTAssertNil(CalendarText.place("  \n "))
        XCTAssertNil(CalendarText.place(nil))
        let long = CalendarText.place(String(repeating: "Conference room ", count: 20))
        XCTAssertEqual(long?.count, CalendarText.longestPlace)
        XCTAssertEqual(long?.last, "…")
    }

    func testATitleReadsOnOneLine() {
        XCTAssertEqual(CalendarText.line("  Team\nsync  "), "Team sync")
        XCTAssertEqual(CalendarText.line(nil), "")
        XCTAssertEqual(CalendarText.line(String(repeating: "a", count: 500)).count, CalendarText.longestLine)
    }

    func testEachDayOfARepeatingEventHasItsOwnIdThatSaysNothing() {
        let monday = Date(timeIntervalSince1970: 1_791_820_800)
        let tuesday = monday.addingTimeInterval(86_400)
        let first = CalendarEventID.make("C0FFEE-Standup", start: monday)
        XCTAssertEqual(first, CalendarEventID.make("C0FFEE-Standup", start: monday))
        XCTAssertNotEqual(first, CalendarEventID.make("C0FFEE-Standup", start: tuesday))
        XCTAssertNotEqual(first, CalendarEventID.make("OTHER", start: monday))
        XCTAssertTrue(first.hasPrefix("cal-"))
        XCTAssertEqual(first.count, 20)
        XCTAssertFalse(first.contains("C0FFEE"))
    }
}
