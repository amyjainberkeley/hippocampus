import XCTest
@testable import RecallUIKit

final class EventTextTests: XCTestCase {
    private func payload(id: UInt64 = 42, text: String, truncated: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "event_id": id, "ts_us": 100, "app_bundle_id": NSNull(),
            "text": text, "truncated": truncated,
        ])
    }

    func testDecodesExactStoredTextBeyondListSnippetIncludingUnicodeAndNul() throws {
        let text = String(repeating: "a", count: 350) + "\n\u{4e2d}\u{6587} e\u{301}\0\"\\tail"
        let result = try XCTUnwrap(FFIBrainReader.decodeEventText(payload(text: text), eventId: 42))
        XCTAssertEqual(result.eventId, 42)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.isTruncated)
    }

    func testCapIsUTF8BytesAndPreservesTruncationFlag() throws {
        let text = String(repeating: "\u{e9}", count: EventText.maxUTF8Bytes / 2)
        for truncated in [false, true] {
            let result = try XCTUnwrap(FFIBrainReader.decodeEventText(
                payload(text: text, truncated: truncated), eventId: 42))
            XCTAssertEqual(result.text.utf8.count, 128 * 1024)
            XCTAssertEqual(result.isTruncated, truncated)
        }
        XCTAssertThrowsError(try EventText(eventId: 42, tsUs: 100, appBundleId: nil, text: text + "x", isTruncated: false))
        XCTAssertThrowsError(try FFIBrainReader.decodeEventText(payload(text: text + "x"), eventId: 42))
    }

    func testEmptyStoredTextIsDifferentFromMissingEvent() throws {
        XCTAssertNil(try FFIBrainReader.decodeEventText(Data("null".utf8), eventId: 42))
        let result = try XCTUnwrap(FFIBrainReader.decodeEventText(payload(text: ""), eventId: 42))
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.isTruncated)
    }

    func testRejectsMismatchedOrInvalidEventIds() throws {
        XCTAssertThrowsError(try FFIBrainReader.decodeEventText(payload(id: 41, text: "other"), eventId: 42))
        for id in [UInt64(0), UInt64.max] {
            XCTAssertThrowsError(try EventText(eventId: id, tsUs: 100, appBundleId: nil, text: "", isTruncated: false))
            XCTAssertThrowsError(try FFIBrainReader.decodeEventText(payload(id: id, text: ""), eventId: id))
        }
    }

    func testMalformedOrOversizedPayloadFailsWithoutEchoingContent() throws {
        let marker = "private-fixture-marker"
        let inputs = [
            Data("{\"text\":\"\(marker)\"}".utf8),
            Data("{\"event_id\":42,\"text\":\"\(marker)\",\"truncated\":\"wrong\"}".utf8),
            Data(repeating: 32, count: EventText.maxJSONBytes + 1),
        ]
        for input in inputs {
            XCTAssertThrowsError(try FFIBrainReader.decodeEventText(input, eventId: 42)) { error in
                XCTAssertFalse(String(describing: error).contains(marker))
            }
        }
    }

    func testMaximumEscapedControlTextDecodes() throws {
        let text = String(repeating: "\u{1}", count: EventText.maxUTF8Bytes)
        let result = try XCTUnwrap(FFIBrainReader.decodeEventText(
            payload(text: text, truncated: true), eventId: 42))
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.isTruncated)
    }

    func testExistingStubDefaultsToUnavailableRatherThanInventingFullText() async throws {
        let result = try await StubBrainReader().eventText(eventId: 101)
        XCTAssertNil(result)
    }

    func testMissingIdentityFailsClosedAndNilIsNotAnEmptyApp() throws {
        for identity in [[:], ["ts_us": 100], ["app_bundle_id": NSNull()]] as [[String: Any]] {
            var json: [String: Any] = ["event_id": 42, "text": "replacement", "truncated": false]
            json.merge(identity) { _, new in new }
            XCTAssertThrowsError(try FFIBrainReader.decodeEventText(
                JSONSerialization.data(withJSONObject: json), eventId: 42))
        }
        let text = try XCTUnwrap(FFIBrainReader.decodeEventText(payload(text: "exact"), eventId: 42))
        let nilApp = Hit(eventId: 42, tsUs: 100, appBundleId: nil, windowTitle: nil,
                         url: nil, ocrTextSnippet: "preview", source: "timeline", score: nil)
        let emptyApp = Hit(eventId: 42, tsUs: 100, appBundleId: "", windowTitle: nil,
                           url: nil, ocrTextSnippet: "preview", source: "timeline", score: nil)
        XCTAssertTrue(text.matches(nilApp))
        XCTAssertFalse(text.matches(emptyApp))
    }

    func testIdentityByteAndTimestampBoundsAreEnforced() throws {
        XCTAssertThrowsError(try EventText(eventId: 42, tsUs: UInt64.max, appBundleId: nil,
                                           text: "", isTruncated: false))
        let maximum = String(repeating: "\u{e9}", count: EventText.maxAppUTF8Bytes / 2)
        XCTAssertNoThrow(try EventText(eventId: 42, tsUs: 100, appBundleId: maximum,
                                       text: "", isTruncated: false))
        XCTAssertThrowsError(try EventText(eventId: 42, tsUs: 100, appBundleId: maximum + "x",
                                           text: "", isTruncated: false))
    }
}
