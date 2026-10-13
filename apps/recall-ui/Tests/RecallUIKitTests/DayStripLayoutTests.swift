import Foundation
import XCTest
@testable import RecallUIKit

/// Where sessions, hours and empty time sit on Overview's day strip
/// (contract overview.md section 6, RULINGS W6).
final class DayStripLayoutTests: XCTestCase {
    private let hour: Int64 = 3_600_000_000
    private let minute: Int64 = 60_000_000
    /// Midnight starting Monday 2026-10-12 in UTC−7, the samples' day.
    private let midnight: Int64 = 1_791_788_400_000_000

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -25_200)!
        return calendar
    }

    private func overview(
        strip: (Int64, Int64)?,
        blocks: [(start: Int64, end: Int64, touches: Bool)],
        isToday: Bool = false,
        nowUs: Int64? = nil,
        truncated: Bool = false
    ) throws -> DayOverview {
        let json: [String: Any] = [
            "version": 1, "date": "2026-10-12", "is_today": isToday,
            "now_us": nowUs ?? midnight + 23 * hour, "tz_offset_secs": -25_200,
            "day_start_us": midnight, "day_end_us": midnight + 24 * hour,
            "basis": "measured", "truncated": truncated,
            "model_status": ["state": "available", "reason": NSNull(), "checked_us": NSNull()],
            "now": ["state": "none"],
            "strip": strip.map { ["start_us": $0.0, "end_us": $0.1] as Any } ?? NSNull(),
            "blocks": blocks.enumerated().map { index, block in
                [
                    "id": block.start, "provisional": false, "start_us": block.start, "end_us": block.end,
                    "in_progress": false, "touches_previous": block.touches, "title": "Session \(index)",
                    "written_by": "measured", "kind": index % 2 == 0 ? "code" : "writing",
                    "kind_label": index % 2 == 0 ? "Code" : "Writing", "mixed": false, "kinds": [], "apps": [],
                    "windows": [], "sentences": [], "searches": [], "screenshot_event_id": NSNull(),
                    "open_event_id": 1, "reopen": NSNull(), "noticed": NSNull(),
                ] as [String: Any]
            },
            "gaps": [], "kinds": [], "facts": [], "searches": [], "account": NSNull(),
            "ai_knows": ["recent_work": [], "about_you": [], "hook_installed": false],
        ]
        return try JSONDecoder().decode(DayOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testTheSamplesDayHasAnHourlyTickFromNineToThree() throws {
        let layout = try XCTUnwrap(DayStripLayout(overview: UnderstandingFixture.overview(), calendar: calendar))
        XCTAssertEqual(layout.ticks.map(\.atUs), (9...15).map { midnight + Int64($0) * hour })
        XCTAssertEqual(layout.ticks.first?.x, 0)
        XCTAssertEqual(layout.ticks.last?.x, 1)
        XCTAssertEqual(layout.blocks.count, 8)
        // Oldest first, inside the strip, never overlapping the next.
        for (block, next) in zip(layout.blocks, layout.blocks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(block.x, 0)
            XCTAssertLessThanOrEqual(block.x + block.width, next.x + 1e-9)
        }
    }

    func testABlockSitsAtItsTimeAsAFractionOfTheStrip() throws {
        let start = midnight + 9 * hour
        let layout = try XCTUnwrap(DayStripLayout(
            overview: overview(strip: (start, start + 4 * hour),
                               blocks: [(start + hour, start + 2 * hour, false)]),
            calendar: calendar))
        XCTAssertEqual(layout.blocks[0].x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(layout.blocks[0].width, 0.25, accuracy: 1e-9)
    }

    func testAShortSessionIsDrawnAtTheMinimumWidthAndStaysInside() throws {
        let start = midnight + 9 * hour
        let end = start + 4 * hour
        let layout = try XCTUnwrap(DayStripLayout(
            overview: overview(strip: (start, end),
                               blocks: [(start + hour, start + hour + minute, false), (end - minute, end, false)]),
            minimumWidth: 0.02, calendar: calendar))
        XCTAssertEqual(layout.blocks[0].width, 0.02, accuracy: 1e-9)
        XCTAssertEqual(layout.blocks[1].width, 0.02, accuracy: 1e-9)
        XCTAssertEqual(layout.blocks[1].x + layout.blocks[1].width, 1, accuracy: 1e-9)
    }

    func testTicksThinOutOnLongerDays() throws {
        let ten = try XCTUnwrap(DayStripLayout(
            overview: overview(strip: (midnight + 8 * hour, midnight + 18 * hour),
                               blocks: [(midnight + 9 * hour, midnight + 10 * hour, false)]),
            calendar: calendar))
        XCTAssertEqual(ten.ticks.map(\.atUs), [8, 10, 12, 14, 16, 18].map { midnight + Int64($0) * hour })
        let twenty = try XCTUnwrap(DayStripLayout(
            overview: overview(strip: (midnight + 2 * hour, midnight + 22 * hour),
                               blocks: [(midnight + 9 * hour, midnight + 10 * hour, false)]),
            calendar: calendar))
        XCTAssertEqual(twenty.ticks.map(\.atUs), [3, 6, 9, 12, 15, 18, 21].map { midnight + Int64($0) * hour })
    }

    func testEmptyTimeIsEveryUncoveredStretchButNotTheFutureNorAMissingMorning() throws {
        let start = midnight + 9 * hour
        let blocks: [(start: Int64, end: Int64, touches: Bool)] = [
            (start + hour, start + hour + 30 * minute, false),
            (start + hour + 31 * minute, start + 2 * hour, true),
            (start + 3 * hour, start + 3 * hour + 20 * minute, false),
        ]
        let past = try XCTUnwrap(DayStripLayout(overview: overview(strip: (start, start + 5 * hour), blocks: blocks),
                                                calendar: calendar))
        XCTAssertEqual(past.nothingSaved.map(\.startUs), [start, start + hour + 30 * minute, start + 2 * hour,
                                                           start + 3 * hour + 20 * minute])
        XCTAssertEqual(past.nothingSaved.last?.endUs, start + 5 * hour)
        XCTAssertEqual(past.blocks.map(\.touchesPrevious), [false, true, false])

        // Today stops at now; a day whose start is missing has no empty time
        // before its first session.
        let now = start + 3 * hour + 40 * minute
        let today = try XCTUnwrap(DayStripLayout(
            overview: overview(strip: (start, start + 5 * hour), blocks: blocks, isToday: true, nowUs: now,
                               truncated: true),
            calendar: calendar))
        XCTAssertEqual(today.nothingSaved.first?.startUs, start + hour + 30 * minute)
        XCTAssertEqual(today.nothingSaved.last?.endUs, now)
    }

    func testADayWithNoSessionsHasNoStrip() throws {
        XCTAssertNil(DayStripLayout(overview: try overview(strip: nil, blocks: []), calendar: calendar))
    }
}
