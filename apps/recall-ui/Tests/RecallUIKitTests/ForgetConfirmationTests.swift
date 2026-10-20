import XCTest
@testable import RecallUIKit

/// A larger forget asks first, with the line said the first time anyone
/// forgets, and each forget leaves an audit line Privacy's Activity reads in
/// plain words: counts and ranges, never content (SPEC 3.9, 3.11).
final class ForgetConfirmationTests: XCTestCase {
    /// Monday, October 12, 2026, 2:41 PM in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_791_841_260)

    private func us(_ date: Date) -> UInt64 { UInt64(date.timeIntervalSince1970 * 1_000_000) }

    private func activity(_ audit: ForgetAudit, count: UInt64) -> String? {
        let line = audit.details(count: count, now: now)
        return PrivacyActivity.what(AuditEntry(timestamp: now, action: line.action, details: line.details,
                                               rawLine: "test"))
    }

    func testForgetRecentReadsAsItsChoice() {
        XCTAssertEqual(activity(.recent(.tenMinutes), count: 14), "Forgot the last 10 minutes")
        XCTAssertEqual(activity(.recent(.hour), count: 80), "Forgot the last hour")
        XCTAssertEqual(activity(.recent(.today), count: 900), "Forgot today")
        XCTAssertEqual(ForgetAudit.recent(.tenMinutes).details(count: 14, now: now).details["count"], "14")
    }

    func testTheLast24HoursFromPrivacyReadsAsSuch() {
        let span = ForgetRequest.Span(startUs: us(now.addingTimeInterval(-24 * 3_600)), endUs: us(now))
        XCTAssertEqual(activity(.span(span), count: 300), "Forgot the last 24 hours")
    }

    func testASessionOrPickedMomentsReadAsACount() {
        let session = ForgetRequest.Span(startUs: us(now.addingTimeInterval(-3 * 3_600)),
                                         endUs: us(now.addingTimeInterval(-2 * 3_600)))
        XCTAssertEqual(activity(.span(session), count: 41), LibraryCopy.Privacy.forgotMoments(41))
        XCTAssertEqual(ForgetAudit.moments(3).details(count: 3, now: now).action, .deleteEvent)
        XCTAssertEqual(activity(.moments(3), count: 3), LibraryCopy.Privacy.forgotMoments(3))
    }

    func testTheLineHoldsNoContent() {
        for audit in [ForgetAudit.moments(2), .recent(.today),
                      .span(ForgetRequest.Span(startUs: 1, endUs: 2))] {
            let keys = Set(audit.details(count: 2, now: now).details.keys)
            XCTAssertTrue(keys.isSubset(of: ["count", "range_minutes", "range_hours", "range"]), "\(keys)")
        }
    }

    func testTheFirstForgetSaysWhatStaysWithAnAITool() {
        let request = ForgetRequest(momentIds: [1, 2])
        let first = ForgetConfirmation(title: NavigationCopy.forgetSelectionTitle(36),
                                       body: NavigationCopy.forgetSelectionBody, firstForget: true,
                                       request: request, audit: .moments(36))
        XCTAssertEqual(first.message, NavigationCopy.forgetSelectionBody + "\n\n" + NavigationCopy.firstForget)
        let later = ForgetConfirmation(title: first.title, body: first.body, firstForget: false, request: request,
                                       audit: .moments(36))
        XCTAssertEqual(later.message, NavigationCopy.forgetSelectionBody)
    }

    func testRecordWritesTheLineToTheLogItIsGiven() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("forget-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let at = now
        let log = AuditLog(baseURL: folder, now: { at })
        ForgetAudit.recent(.hour).record(count: 12, now: now, log: log)
        let entries = log.readRecent(count: 5)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.action, .deleteEventsInRange)
        XCTAssertEqual(entries.first?.details["range_minutes"], "60")
        XCTAssertEqual(entries.first.flatMap(PrivacyActivity.what), "Forgot the last hour")
    }
}
