import Foundation
import XCTest
@testable import RecallUIKit

/// On Demo Memory the window's calendar is the made-up week's (SPEC-DELTA 6):
/// read from the file beside the demo store, never from macOS, and never
/// the made-up one on the person's own memory.
final class DemoCalendarTests: XCTestCase {
    private let monday9 = Date(timeIntervalSince1970: 1_792_486_800)

    func testItReadsTheWeeksMeetingsInOrder() async throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("demo-calendar.json")
        try write(url, events: [
            event("sync", "Team sync", start: monday9.addingTimeInterval(3600), minutes: 30, location: "Zoom"),
            event("investors", "Investor update", start: monday9.addingTimeInterval(7 * 3600), minutes: 45),
            event("standup", "Standup", start: monday9, minutes: 15, location: ""),
            event("next-week", "Board prep", start: monday9.addingTimeInterval(8 * 86_400), minutes: 60),
        ])
        let calendar = DemoCalendar(url: url)
        let access = await calendar.access()
        XCTAssertEqual(access, .allowed)
        let day = DateInterval(start: monday9.addingTimeInterval(-3600), duration: 86_400)
        let events = try await calendar.events(in: day)
        XCTAssertEqual(events.map(\.title), ["Standup", "Team sync", "Investor update"])
        XCTAssertEqual(events[1].location, "Zoom")
        XCTAssertNil(events[0].location, "an empty location is no location")
        XCTAssertEqual(events[1].end.timeIntervalSince(events[1].start), 30 * 60)
        XCTAssertEqual(events[1].calendarName, "Work")
    }

    func testAMissingOrStrangeFileIsNoCalendar() async throws {
        let folder = try makeFolder()
        let missing = DemoCalendar(url: folder.appendingPathComponent("demo-calendar.json"))
        let missingAccess = await missing.access()
        XCTAssertEqual(missingAccess, .notAsked)
        let strange = folder.appendingPathComponent("strange.json")
        try Data("{\"version\":2,\"events\":[]}".utf8).write(to: strange)
        let strangeAccess = await DemoCalendar(url: strange).access()
        XCTAssertEqual(strangeAccess, .notAsked)
        do {
            _ = try await DemoCalendar(url: strange).events(in: DateInterval(start: monday9, duration: 60))
            XCTFail("a file of another version is not read")
        } catch {}
    }

    func testOnlyTheWindowOnDemoMemoryReadsTheMadeUpCalendar() async throws {
        let folder = try makeFolder()
        try write(folder.appendingPathComponent("demo-calendar.json"),
                  events: [event("sync", "Team sync", start: monday9, minutes: 30)])
        let own = FixtureCalendar(access: .denied)
        let demo: [String: String] = [
            "MCI_DEMO_MEMORY": "1", "MCI_DB_PATH": folder.appendingPathComponent("mci.sqlite").path,
        ]
        let onDemo = DemoMemoryMode.calendarReader(environment: demo, fallback: own)
        XCTAssertTrue(onDemo is DemoCalendar)
        let onDemoAccess = await onDemo.access()
        XCTAssertEqual(onDemoAccess, .allowed)
        XCTAssertEqual(DemoMemoryMode.folder(environment: demo)?.standardizedFileURL, folder.standardizedFileURL)

        // The person's own memory: their calendar, even beside a stray file.
        for environment in [
            ["MCI_DB_PATH": folder.appendingPathComponent("mci.sqlite").path],
            ["MCI_DEMO_MEMORY": "0", "MCI_DB_PATH": folder.appendingPathComponent("mci.sqlite").path],
            ["MCI_DEMO_MEMORY": "1"],
        ] {
            let reader = DemoMemoryMode.calendarReader(environment: environment, fallback: own)
            XCTAssertTrue(reader is FixtureCalendar, "\(environment)")
            XCTAssertNil(DemoMemoryMode.folder(environment: environment))
        }
    }

    // MARK: Helpers

    private func event(_ id: String, _ title: String, start: Date, minutes: Int,
                       location: String? = nil) -> [String: Any] {
        let startUs = UInt64(start.timeIntervalSince1970 * 1_000_000)
        var event: [String: Any] = [
            "id": id, "title": title, "start_us": startUs,
            "end_us": startUs + UInt64(minutes) * 60_000_000, "calendar": "Work",
        ]
        event["location"] = location ?? NSNull()
        return event
    }

    private func write(_ url: URL, events: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "events": events])
        try data.write(to: url)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-calendar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
