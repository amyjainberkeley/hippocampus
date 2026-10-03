import XCTest
@testable import MCICaptureHelperKit

final class OCRReviewedTranscriptTests: XCTestCase {
    func testUncertainAndInvalidConfidenceDoesNotMasqueradeAsTranscription() {
        let lines = [line("Review notes", 0.99), line("garbled", 0.2), line("invalid", .nan)]
        XCTAssertEqual(OCRReviewedTranscript.review(result(lines)), .text("Review notes", omittedLines: 2))
        XCTAssertEqual(OCRReviewedTranscript.review(result([line("garbled", 0.2)])), .unreadable)
    }

    func testSecretsInRawAndCleanedTranscriptBlockPreview() {
        XCTAssertEqual(OCRReviewedTranscript.review(result([line("password: synthetic-example", 0.1)])), .blocked)
        let lines = [line("password", 1), line("garbled", 0.2), line(": synthetic-example", 1)]
        XCTAssertEqual(OCRReviewedTranscript.review(result(lines)), .blocked)
    }

    func testTimedOutAndOversizeResultsAreNeverPartialSuccess() {
        XCTAssertEqual(OCRReviewedTranscript.review(OCRResult(recognizedLines: [line("partial", 1)], durationMs: 30_000, timedOut: true)), .timedOut)
        XCTAssertEqual(OCRReviewedTranscript.review(result([line(String(repeating: "x", count: maxOCRTextBytes + 1), 1)])), .unreadable)
        XCTAssertEqual(OCRReviewedTranscript.review(.empty), .unreadable)
    }

    private func line(_ text: String, _ confidence: Float) -> OCRLine {
        OCRLine(text: text, boundingBox: .zero, confidence: confidence)
    }
    private func result(_ lines: [OCRLine]) -> OCRResult {
        OCRResult(recognizedLines: lines, durationMs: 1, timedOut: false)
    }
}
