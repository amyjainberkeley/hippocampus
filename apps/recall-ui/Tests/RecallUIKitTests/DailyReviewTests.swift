import XCTest
@testable import RecallUIKit

final class DailyReviewTests: XCTestCase {
    private var day: MemoryDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return MemoryDay(date: Date(timeIntervalSince1970: 1_788_739_200), calendar: calendar)
    }

    func testEmptyDayDoesNotInventObservations() {
        let review = DailyReview(day: day, events: [])
        XCTAssertTrue(review.observations.isEmpty)
        XCTAssertEqual(review.textCount, 0)
        XCTAssertEqual(review.imageCount, 0)
    }

    func testCountsDeduplicateAndExcludeOtherDatesWithoutTreatingImagesAsText() {
        let first = event(1, minute: 1, text: " ", image: true)
        let review = DailyReview(day: day, events: [
            first, first, event(2, minute: 2, image: false),
            TimelineEvent(eventId: 9, tsUs: day.endUs + 1, appBundleId: nil, snippet: "Other day"),
        ])
        XCTAssertEqual(review.events.map(\.id), [1, 2])
        XCTAssertEqual(review.textCount, 1)
        XCTAssertEqual(review.imageCount, 1)
        XCTAssertEqual(review.observations.first?.evidence.map(\.id), [2])
    }

    func testReturnAndCaptureGapCarryTheirActualSupportingEvents() {
        let rows = [event(1, minute: 1), event(2, minute: 2, app: "com.apple.Terminal"),
                    event(3, minute: 3), event(4, minute: 30)]
        let review = DailyReview(day: day, events: rows.reversed())
        XCTAssertEqual(review.observations.map(\.kind), [.lastContext, .returnedToApp, .captureGap])
        XCTAssertEqual(review.observations.map { $0.evidence.map(\.id) }, [[4], [1, 2, 3], [3, 4]])
        XCTAssertEqual(review, DailyReview(day: day, events: rows))
        XCTAssertTrue(review.observations.last!.detail.contains("capture samples"))
    }

    func testImportsAndUnknownSourcesCannotImplyScreenReturnsOrCaptureGaps() {
        let review = DailyReview(day: day, events: [
            event(1, minute: 1),
            event(2, minute: 20, app: "com.apple.Terminal", kind: "transcript_import"),
            event(3, minute: 30, kind: nil),
        ])
        XCTAssertEqual(review.observations.map(\.kind), [.lastContext])
        XCTAssertNil(review.observations.first?.evidence.first?.sourceKind)
    }

    func testCompactEvidenceIsBoundedAndIncludesFirstAndLastImages() {
        let review = DailyReview(day: day, events: (1...40).map { event(UInt64($0), minute: $0) })
        XCTAssertEqual(review.visualEvidence.count, 6)
        XCTAssertEqual(review.visualEvidence.first?.id, 1)
        XCTAssertEqual(review.visualEvidence.last?.id, 40)
        XCTAssertEqual(Set(review.visualEvidence.map(\.id)).count, 6)
    }

    private func event(_ id: UInt64, minute: Int, app: String = "com.apple.Safari",
                       text: String = "Saved text", image: Bool = true,
                       kind: String? = "screen_ocr") -> TimelineEvent {
        TimelineEvent(eventId: id, tsUs: day.startUs + UInt64(minute) * 60_000_000,
                      appBundleId: app, snippet: text, thumbnailPath: image ? "/tmp/synthetic-\(id)" : nil,
                      sourceKind: kind)
    }
}
