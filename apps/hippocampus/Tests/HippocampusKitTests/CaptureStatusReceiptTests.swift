import XCTest
@testable import HippocampusKit

final class CaptureStatusReceiptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_609_600)

    private func receipt(
        count: Int = 12, savedAgo: TimeInterval? = 5,
        updatedAgo: TimeInterval = 0, suppression: String? = nil,
        blocked: String? = nil
    ) throws -> CaptureStatusReceipt {
        let formatter = ISO8601DateFormatter()
        var json: [String: Any] = [
            "schema_version": 1,
            "updated_at": formatter.string(from: now.addingTimeInterval(-updatedAgo)),
            "stored_frame_count": count,
            "stored_screenshot_count": count,
            "last_stored_frame_at": NSNull(),
        ]
        if let savedAgo {
            json["last_stored_frame_at"] = formatter.string(from: now.addingTimeInterval(-savedAgo))
        }
        json["suppression_reason"] = suppression
        json["blocked_reason"] = blocked
        return try CaptureStatusReceipt.decode(JSONSerialization.data(withJSONObject: json))
    }

    private var helper: HealthSnapshot {
        HealthSnapshot(framesDelivered: 5125, framesSuppressed: 5125,
                       lastCaptureTs: nil, lastUpdated: now)
    }

    /// A run that started a minute ago. `skipHeld` is how long the receipt's
    /// skip has been seen with no newer save.
    private func status(
        _ receipt: CaptureStatusReceipt?, helper: HealthSnapshot? = nil, skipHeld: TimeInterval? = nil
    ) -> MenuBarStatus {
        MenuBarStatus.derive(from: .running, receipt: receipt, helperHealth: helper,
                             captureStartedAt: now.addingTimeInterval(-60),
                             skipSeenSince: skipHeld.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testOnlyRecentCommittedFrameFromCurrentRunCanShowSaving() throws {
        XCTAssertEqual(status(try receipt()), .recording)
        XCTAssertNotEqual(status(nil, helper: helper), .recording)
        XCTAssertNotEqual(status(try receipt(savedAgo: 120)), .recording)
        XCTAssertNotEqual(status(try receipt(savedAgo: 125, updatedAgo: 120)), .recording)
    }

    func testZeroMemoryIsPlainEvenWithThousandsOfHelperFrames() throws {
        let result = status(try receipt(count: 0, savedAgo: nil), helper: helper)
        XCTAssertEqual(result.displayText, "Nothing saved yet")
        XCTAssertFalse(result.shouldPulse)
        XCTAssertEqual(result.action, .pause)
        XCTAssertEqual(status(try receipt(count: 0, savedAgo: 120)), .noMemory)
    }

    func testStaticScreenIsNeutralWhenHelperAndReceiptAreFresh() throws {
        let result = status(try receipt(savedAgo: 86_400), helper: helper)
        XCTAssertEqual(result, .unchanged)
        XCTAssertFalse(result.shouldPulse)
        XCTAssertNotEqual(status(try receipt(savedAgo: 86_400)), .unchanged)
    }

    func testStaleReceiptCannotBeRescuedByFreshHelper() throws {
        let result = status(try receipt(savedAgo: 605, updatedAgo: 600), helper: helper)
        guard case .stale = result else { return XCTFail("Expected stale: \(result)") }
    }

    func testBlockedPermissionAndUnknownBrowserModeHaveActions() throws {
        let permission = status(try receipt(blocked: "screen_recording_permission"))
        XCTAssertEqual(permission, .needsPermission(.screenRecording))
        XCTAssertEqual(permission.action, .openSystemSettings(.screenRecording))
        let browser = status(try receipt(suppression: "browser_window_unknown"), skipHeld: 11)
        XCTAssertEqual(browser.displayText, "Skipping this window")
        XCTAssertEqual(browser.detailText, "It can’t tell if this browser window is private.")
        XCTAssertEqual(browser.action, .pause)
    }

    func testPauseAndOffOverrideOldCaptureEvidence() throws {
        let saved = try receipt()
        XCTAssertEqual(MenuBarStatus.derive(from: .paused, receipt: saved), .paused)
        XCTAssertEqual(MenuBarStatus.derive(from: .running, captureEnabled: false, receipt: saved), .idle)
    }

    func testMissingRunIdentityCannotClaimSaving() throws {
        XCTAssertNotEqual(MenuBarStatus.derive(from: .running, receipt: try receipt(), now: now), .recording)
    }

    func testOldHelperFromPreviousRunCannotExplainStaticScreen() throws {
        let oldHelper = HealthSnapshot(framesDelivered: 5125, framesSuppressed: 5125,
                                       lastCaptureTs: nil, lastUpdated: now.addingTimeInterval(-90))
        let result = status(try receipt(savedAgo: 86_400), helper: oldHelper)
        guard case .stale = result else { return XCTFail("Expected stale: \(result)") }
    }

    func testRejectMalformedUnsupportedAndInconsistentReceipts() throws {
        for raw in [
            "{}",
            #"{"schema_version":2,"updated_at":"2026-09-05T00:00:00Z","stored_frame_count":0,"stored_screenshot_count":0}"#,
            #"{"schema_version":1,"updated_at":"invalid","stored_frame_count":0,"stored_screenshot_count":0}"#,
            #"{"schema_version":1,"updated_at":"2026-09-05T00:00:00Z","stored_frame_count":-1,"stored_screenshot_count":0}"#,
            #"{"schema_version":1,"updated_at":"2026-09-05T00:00:00Z","stored_frame_count":1,"stored_screenshot_count":0}"#,
        ] {
            XCTAssertThrowsError(try CaptureStatusReceipt.decode(Data(raw.utf8)))
        }
    }

    func testFutureTimestampDoesNotShowSaving() throws {
        XCTAssertNotEqual(status(try receipt(savedAgo: -600, updatedAgo: -600)), .recording)
    }

    /// Every reason the agent writes: a privacy skip is "Skipping this
    /// window" once it has held, a failure "Not saving" at once (spec-shell
    /// S9), and a fast window switch nothing at all.
    func testEveryCurrentAgentReasonSaysSkippingOrNotSaving() throws {
        let skips = ["denylist-source", "os-blacked-region", "secure-event-input", "ax-secure-subrole",
                     "denylist-postcapture", "ocr-time-secret", "failsafe-unknown"]
        for code in skips {
            let result = status(try receipt(suppression: code), helper: helper, skipHeld: 11)
            XCTAssertEqual(result.displayText, "Skipping this window", code)
            XCTAssertFalse(result.shouldPulse, code)
            XCTAssertEqual(result.action, .pause, code)
        }
        let failures = ["capture_disabled", "store_unavailable", "ingest_failed", "helper_disconnected", "capture_failed"]
        for code in failures {
            let result = status(try receipt(blocked: code), helper: helper)
            XCTAssertEqual(result.displayText, "Not saving", code)
            XCTAssertFalse(result.shouldPulse, code)
            XCTAssertEqual(result.action, .tryAgain, code)
        }
        XCTAssertEqual(status(try receipt(suppression: "focus-race-dropped"), skipHeld: 11).displayText, "Remembering")
        let unknown = status(try receipt(suppression: "future-code"), skipHeld: 11)
        XCTAssertEqual(unknown.detailText, "It stopped and can’t say why.")
    }

    func testMissingPartialAndRemovedFileDiscardEvidence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(CaptureStatusReceipt.read(at: file))
        try Data("{".utf8).write(to: file)
        XCTAssertNil(CaptureStatusReceipt.read(at: file))
    }
}
