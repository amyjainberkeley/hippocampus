import XCTest
@testable import RecallUIKit

final class SessionEvidenceTests: XCTestCase {
    func testSessionIncludesTextAndImagesOnlyWithinItsAppAndTimeRange() {
        let session = Episode(episodeId: 7, appBundleId: "test.app", tsStartUs: 10, tsEndUs: 30, eventCount: 2)
        let text = TimelineEvent(eventId: 1, tsUs: 10, appBundleId: "test.app", snippet: "Imported text", sourceKind: "transcript_import")
        let image = TimelineEvent(eventId: 2, tsUs: 30, appBundleId: "test.app", snippet: "", thumbnailPath: "/tmp/synthetic", sourceKind: "screen_ocr")
        let rows = [image, text, text,
            TimelineEvent(eventId: 3, tsUs: 31, appBundleId: "test.app", snippet: "Outside"),
            TimelineEvent(eventId: 4, tsUs: 20, appBundleId: "other.app", snippet: "Different app")]
        XCTAssertEqual(session.evidence(from: rows), [text, image])
    }
}
