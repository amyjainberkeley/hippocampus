import Foundation
import XCTest
@testable import RecallUIKit

/// The calendar's promises in the window (SPEC-DELTA 5): read only to be
/// shown, never handed to an AI tool on its own, and a day's events are that
/// day's in the person's own time zone.
final class CalendarPrivacyTests: XCTestCase {
    private static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// What builds a message for an AI tool never reads the calendar. Events
    /// reach a tool only when the person picks them: if a change adds that,
    /// keep it behind the person's pick, and change this list with it.
    func testNoAIToolsMessageIsBuiltFromTheCalendar() throws {
        let kit = Self.package.appendingPathComponent("Sources/RecallUIKit")
        var files = ["ContextHandoff.swift", "SessionCopy.swift", "VisualMemoryExport.swift", "WhatIsSent.swift",
                     "HandoffPreview.swift", "ProjectHandoffModel.swift", "HandoffCopy.swift"]
            .map { kit.appendingPathComponent($0) }
        let handoff = kit.appendingPathComponent("Handoff")
        if let more = try? FileManager.default.contentsOfDirectory(at: handoff, includingPropertiesForKeys: nil) {
            files += more.filter { $0.pathExtension == "swift" }
        }
        var read = 0
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            for name in ["CalendarEvent", "CalendarReader", "SystemCalendar", "EventKitCalendarStore", "EventKit"] {
                XCTAssertFalse(text.contains(name), "\(file.lastPathComponent) mentions \(name)")
            }
        }
        XCTAssertGreaterThan(read, 2, "the check reads the handoff's files")
    }

    func testADaysEventsAreThatDaysInThePersonsTimeZone() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Thursday, October 15, 2026, 4:00 PM in Los Angeles.
        let now = Date(timeIntervalSince1970: 1_792_105_200)
        let today = calendar.startOfDay(for: now)
        func event(_ id: String, _ hours: Double) -> CalendarEvent {
            let start = today.addingTimeInterval(hours * 3_600)
            return CalendarEvent(id: id, title: "Team sync", start: start, end: start.addingTimeInterval(1_800),
                                 calendarName: "Work")
        }
        let fixture = FixtureCalendar(access: .allowed, events: [
            event("yesterday", -3), event("morning", 9), event("evening", 20), event("tomorrow", 25),
        ])
        let events = try await fixture.events(onDayOf: now, calendar: calendar)
        XCTAssertEqual(events.map(\.id), ["morning", "evening"])
    }
}
