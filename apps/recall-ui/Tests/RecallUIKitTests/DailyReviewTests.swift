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
        XCTAssertTrue(review.resumePoints.isEmpty)
    }

    func testResumeGroupsKeepSourceKindsSeparateAndUseLatestLiteralEvidence() {
        let rows = [event(1, minute: 1), event(2, minute: 2, app: "com.apple.Terminal"),
                    event(3, minute: 3, text: "Question: ship the draft?"),
                    event(4, minute: 4, text: "Imported claim: complete", kind: "transcript_import")]
        let review = DailyReview(day: day, events: rows + [rows[0]])
        XCTAssertEqual(review.resumePoints.map(\.id), [4, 3, 2])
        XCTAssertEqual(review.resumePoints.map(\.sampleCount), [1, 2, 1])
        XCTAssertEqual(review.resumePoints.map(\.sampleLabel), ["1 saved sample", "2 saved samples", "1 saved sample"])
        XCTAssertEqual(review.resumePoints.map { $0.evidence.map(\.id) }, [[4], [3, 1], [2]])
        XCTAssertEqual(review.resumePoints.map(\.detail),
                       ["Imported claim: complete", "Question: ship the draft?", "Saved text"])
        XCTAssertEqual(review.resumePoints.first?.sourceLabel, "Imported transcript")
        XCTAssertTrue(review.resumePoints.allSatisfy { !$0.title.contains("complete") })
    }

    func testResumeIsBoundedAndDoesNotCombineUnattributedSources() {
        let rows = (1...12).map { id in
            TimelineEvent(eventId: UInt64(id), tsUs: day.startUs + UInt64(id),
                          appBundleId: nil, snippet: "Source \(id)")
        }
        let review = DailyReview(day: day, events: rows)
        XCTAssertEqual(review.resumePoints.map(\.id), [12, 11, 10, 9])
        XCTAssertTrue(review.resumePoints.allSatisfy { $0.sampleCount == 1 && $0.sourceLabel == "Unknown source" })
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

    func testHydrationChangesOnlyLatestDetailAndPreservesEvidenceCountsAndOtherObservations() throws {
        let rows = [event(1, minute: 1), event(2, minute: 2, app: "com.apple.Terminal"),
                    event(3, minute: 3), event(4, minute: 30)]
        let original = DailyReview(day: day, events: rows)
        let text = try EventText(eventId: 4, tsUs: day.startUs + 1_800_000_000,
            appBundleId: "com.apple.Safari",
            text: "[app=Safari | title=" + String(repeating: "metadata", count: 100)
                + " | url=? | ts=now]\nActual work **literal markdown**", isTruncated: false)
        let review = DailyReview(day: day, events: rows, latestContextText: text)

        XCTAssertEqual(review.observations.first?.detail, "Actual work **literal markdown**")
        XCTAssertEqual(review.observations.first?.evidence, [rows[3]])
        XCTAssertEqual(review.events, original.events)
        XCTAssertEqual(review.countLabel, original.countLabel)
        XCTAssertEqual(review.visualEvidence, original.visualEvidence)
        XCTAssertEqual(review.observations.dropFirst(), original.observations.dropFirst())
    }

    func testHydrationMustMatchLatestInDayIDTimestampAndApp() throws {
        let rows = [event(1, minute: 1), event(2, minute: 2)]
        let identities: [(UInt64, UInt64, String?)] = [
            (1, day.startUs + 60_000_000, "com.apple.Safari"),
            (99, day.startUs + 120_000_000, "com.apple.Safari"),
            (2, day.startUs + 120_000_001, "com.apple.Safari"),
            (2, day.startUs + 120_000_000, "com.apple.Terminal"),
            (2, day.startUs + 120_000_000, nil),
            (2, day.endUs + 1, "com.apple.Safari"),
        ]
        for (id, timestamp, app) in identities {
            let text = try EventText(eventId: id, tsUs: timestamp, appBundleId: app,
                text: "Unrelated full text", isTruncated: false)
            XCTAssertEqual(DailyReview(day: day, events: rows, latestContextText: text),
                           DailyReview(day: day, events: rows))
            XCTAssertTrue(DailyReview(day: day, events: [], latestContextText: text).observations.isEmpty)
        }
    }

    func testHydratedTextUsesOnlyLeadingRecognizedHeaderStripping() throws {
        let row = event(1, minute: 1)
        let bodies = [
            "# Captured heading\n![image](https://example.invalid/tracker)",
            "Ordinary text\n[app=Safari | title=Title | url=? | ts=now]\nMore text",
            "",
        ]
        for body in bodies {
            let text = try EventText(eventId: row.id, tsUs: row.tsUs, appBundleId: row.appBundleId,
                text: "[app=Safari | title=Title | url=? | ts=now]\n" + body, isTruncated: false)
            XCTAssertEqual(DailyReview(day: day, events: [row], latestContextText: text)
                .observations.first?.detail, body)
        }
    }

    private func event(_ id: UInt64, minute: Int, app: String = "com.apple.Safari",
                       text: String = "Saved text", image: Bool = true,
                       kind: String? = "screen_ocr") -> TimelineEvent {
        TimelineEvent(eventId: id, tsUs: day.startUs + UInt64(minute) * 60_000_000,
                      appBundleId: app, snippet: text, thumbnailPath: image ? "/tmp/synthetic-\(id)" : nil,
                      sourceKind: kind)
    }
}
