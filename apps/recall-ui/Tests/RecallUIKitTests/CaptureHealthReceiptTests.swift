import XCTest
@testable import RecallUIKit

final class CaptureHealthReceiptTests: XCTestCase {
    func testSuppressionDetailsNameTheReportedCause() throws {
        let cases = [
            ("app_denied", "The source is excluded by a privacy rule."),
            ("denylist-source", "The source is excluded by a privacy rule."),
            ("denylist-postcapture", "Privacy exclusions changed during capture."),
            ("os-blacked-region", "macOS protected this screen content."),
            ("secure-event-input", "Secure keyboard input is active."),
            ("secure_input", "Secure keyboard input is active."),
            ("ax-secure-subrole", "A password field is focused."),
            ("ocr-time-secret", "Sensitive text was detected before saving."),
            ("failsafe-unknown", "The window could not be verified as safe to capture."),
            ("focus-race-dropped", "The focused window changed during capture."),
            ("private_browsing", "Private browsing is excluded from capture."),
            ("browser_window_unknown", "The browser window's privacy mode could not be verified."),
            ("app_identity_unknown", "The current app could not be identified."),
        ]
        for (code, expected) in cases {
            let receipt = try receipt(suppression: code)
            XCTAssertEqual(receipt.detailText(now: receipt.updatedAt), expected, code)
        }
    }

    func testBlockerTakesPrecedenceOverEarlierSuppression() throws {
        let cases = [
            ("capture_disabled", "Screen capture is turned off."),
            ("screen_recording_permission", "Screen Recording permission is required."),
            ("accessibility_permission", "Accessibility permission is required to check screen content safely."),
            ("store_unavailable", "Saved memory is unavailable."),
            ("storage_error", "The captured screen could not be saved."),
            ("ingest_failed", "The captured screen could not be saved."),
            ("helper_disconnected", "The screen capture helper disconnected."),
            ("capture_failed", "Screen capture failed."),
        ]
        for (code, expected) in cases {
            let receipt = try receipt(suppression: "secure-event-input", blocked: code)
            XCTAssertEqual(receipt.stateLabel, "Capture blocked")
            XCTAssertEqual(receipt.detailText(now: receipt.updatedAt), expected, code)
        }
    }

    func testStaleDetailsAreClearlyHistorical() throws {
        let receipt = try receipt(suppression: "ax-secure-subrole")
        for offset in [91.0, -31.0] {
            XCTAssertEqual(
                receipt.detailText(now: receipt.updatedAt.addingTimeInterval(offset)),
                "Last report: A password field is focused."
            )
        }
        XCTAssertEqual(receipt.detailText(now: receipt.updatedAt.addingTimeInterval(90)),
                       "A password field is focused.")
    }

    func testUnknownReasonsDoNotEchoUntrustedReceiptContentOrGuessACause() throws {
        let unrecognized = "future_reason /private/content https://example.com/secret"
        for receipt in [try receipt(suppression: unrecognized), try receipt(blocked: unrecognized)] {
            XCTAssertEqual(receipt.detailText(now: receipt.updatedAt),
                           "The capture service reported an unrecognized reason.")
        }
    }

    func testReceiptWithoutReasonsDoesNotInventSuppression() throws {
        let receipt = try receipt()
        XCTAssertEqual(receipt.stateLabel, "Screen memory saved")
        XCTAssertNil(receipt.detailText(now: receipt.updatedAt))
        XCTAssertNil(receipt.detailText(now: receipt.updatedAt.addingTimeInterval(120)))
    }

    func testUnchangedScreenIsNotPresentedAsAPrivacyFailure() throws {
        for reason in ["unchanged_screen", "deduplicated"] {
            let receipt = try receipt(suppression: reason)
            XCTAssertEqual(receipt.stateLabel, "Screen unchanged")
            XCTAssertEqual(receipt.detailText(now: receipt.updatedAt), "No new screen content was saved.")
        }
        let blocked = try receipt(suppression: "unchanged_screen", blocked: "store_unavailable")
        XCTAssertEqual(blocked.stateLabel, "Capture blocked")
        XCTAssertEqual(blocked.detailText(now: blocked.updatedAt), "Saved memory is unavailable.")
    }

    private func receipt(suppression: String? = nil, blocked: String? = nil) throws -> CaptureHealthReceipt {
        var json: [String: Any] = [
            "schema_version": 1,
            "updated_at": "2026-09-05T12:00:00Z",
            "last_stored_frame_at": "2026-09-05T11:59:00Z",
            "stored_frame_count": 8,
            "stored_screenshot_count": 3,
        ]
        json["suppression_reason"] = suppression
        json["blocked_reason"] = blocked
        return try CaptureHealthReceipt.decode(JSONSerialization.data(withJSONObject: json))
    }
}
