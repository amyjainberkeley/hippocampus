import Foundation
import XCTest
@testable import RecallUIKit

/// The Privacy page (SPEC 3.9): what is kept, how long, what the side
/// pictures use, and what was forgotten or exported, in plain words.
final class PrivacyPageTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    private func storage(blobs: UInt64?, text: UInt64?, complete: Bool = true) -> StorageUsage {
        let status: StorageMeasurementStatus = complete ? .complete : .partial
        return StorageUsage(database: StorageMeasurement(logicalBytes: text, status: status),
                            wal: StorageMeasurement(logicalBytes: 0, status: .missing),
                            shm: StorageMeasurement(logicalBytes: 0, status: .missing),
                            managedBlobs: StorageMeasurement(logicalBytes: blobs, status: status),
                            reportedTotalBytes: nil, complete: complete)
    }

    func testTheKeptLineSaysMomentsDaysAndSizesOnceMeasured() {
        let day: UInt64 = 86_400_000_000
        let start: UInt64 = 1_788_000_000_000_000
        let counts = SummaryStats(totalEvents: 41_208, oldestTsUs: start, newestTsUs: start + 37 * day + 1,
                                  diskBytes: 0)
        let line = PrivacyKept.line(counts, locale: locale)
        XCTAssertTrue(line?.hasPrefix("41,208 moments from ") == true, line ?? "")
        XCTAssertFalse(line?.contains("Screenshots") == true, "sizes wait for the measurement")

        let measured = SummaryStats(totalEvents: 41_208, oldestTsUs: start, newestTsUs: start + 37 * day + 1,
                                    diskBytes: 0, storage: storage(blobs: 1_400_000_000, text: 610_000_000))
        let full = PrivacyKept.line(measured, locale: locale) ?? ""
        XCTAssertTrue(full.contains(" \u{00B7} Screenshots 1.4 GB \u{00B7} Text and search 610 MB"), full)

        let partial = SummaryStats(totalEvents: 3, oldestTsUs: start, newestTsUs: start, diskBytes: 0,
                                   storage: storage(blobs: 1_000, text: 1_000, complete: false))
        XCTAssertEqual(PrivacyKept.line(partial, locale: locale), "3 moments from 1 day",
                       "a size measured in part is not said")
        XCTAssertNil(PrivacyKept.line(SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)))
    }

    func testHowLongMomentsAreKept() {
        XCTAssertEqual(LibraryCopy.Privacy.keptFor(days: 90), "Kept for 90 days.")
        XCTAssertEqual(LibraryCopy.Privacy.keptFor(days: 1), "Kept for 1 day.")
        XCTAssertEqual(LibraryCopy.Privacy.keptUntilForgotten, "Kept until you forget it.")
    }

    func testSidePicturesUseIsReadFromTheContentFreeFile() {
        let usage = PicturesUsage.decode(Data("""
            {"schema_version": 1, "updated_at": "2026-10-12T14:00:00Z", "side_enabled": true,
             "front_bytes": 1400000000, "side_bytes": 640000000, "side_pictures": 2300,
             "side_budget_bytes": 2000000000}
            """.utf8))
        XCTAssertEqual(usage?.line, "Pictures of windows beside the one you\u{2019}re using: 640 MB of 2 GB.")
        let noBudget = PicturesUsage(sideBytes: 640_000_000, budgetBytes: nil, enabled: false)
        XCTAssertEqual(noBudget.line, "Pictures of windows beside the one you\u{2019}re using: 640 MB.",
                       "pictures kept while off still show")
        XCTAssertNil(PicturesUsage(sideBytes: 0, budgetBytes: 2_000_000_000, enabled: false).line,
                     "never on and nothing kept: no line")
        XCTAssertNil(PicturesUsage.decode(Data("{}".utf8)))
        XCTAssertNil(PicturesUsage.read(environment: ["MCI_DB_PATH": "/nonexistent-\(UUID().uuidString)/brain.db"]))
    }

    func testActivityListsForgetsAndExportsOnlyInPlainWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_791_841_025) // Mon Oct 12, 2026, 2:37 PM
        func entry(_ action: AuditAction, _ secondsAgo: TimeInterval, _ details: [String: String] = [:]) -> AuditEntry {
            AuditEntry(timestamp: now.addingTimeInterval(-secondsAgo), action: action, details: details,
                       rawLine: "\(action.rawValue)-\(secondsAgo)")
        }
        let rows = PrivacyActivity.rows([
            entry(.deleteEventsInRange, 600, ["range_minutes": "10", "count": "12"]),
            entry(.appLaunched, 700),
            entry(.deleteEvent, 86_400 * 3, ["count": "1"]),
            entry(.deleteEventsInRange, 86_400 * 4, ["range_hours": "24", "count": "300"]),
            entry(.settingsChange, 86_400 * 5),
            entry(.exportJson, 86_400 * 10, ["events": "200"]),
            entry(.wipeBrain, 86_400 * 11),
        ], now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(rows.map(\.what), ["Forgot the last 10 minutes", "Forgot 1 moment",
                                         "Forgot the last 24 hours", "Exported everything", "Deleted everything"])
        XCTAssertEqual(rows[0].when, "Today 2:27\u{202F}PM")
        XCTAssertEqual(rows[1].when, "Fri 2:37\u{202F}PM")
        XCTAssertEqual(rows[3].when, "Oct 2 2:37\u{202F}PM")
    }

    func testEveryPrivacyWordFollowsTheStyle() {
        typealias Words = LibraryCopy.Privacy
        let words = [
            Words.lead, Words.kept(moments: 41_208, days: 38), Words.screenshots("1.4 GB"),
            Words.textAndSearch("610 MB"), Words.keptFor(days: 90), Words.keptUntilForgotten,
            Words.sidePictures("640 MB", of: "2 GB"), Words.forgetRecent, Words.forgetLast24Hours,
            Words.exportEverything, Words.deleteEverything, Words.exportHelp, Words.forgetLast24Title,
            Words.forgetLast24Body, Words.typeToConfirm("FORGET"), Words.forget, Words.cancel, Words.working,
            Words.activity, Words.activityEmpty, Words.forgotMoments(3), Words.forgotLastMinutes(10),
            Words.forgotLastHour, Words.forgotLastHours(24), Words.forgotToday, Words.deletedEverything,
            Words.exportedEverything,
        ]
        for word in words {
            XCTAssertFalse(CopyStyleValidator.containsRawErrorCode(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            for mark in ["\u{2014}", ";", "%", "!", "'", "\"", " / ", "..."] {
                XCTAssertFalse(word.contains(mark), "\(word) has \(mark)")
            }
            // The side pictures' line is SPEC 3.9's, word for word.
            for sentence in word.components(separatedBy: ". ") where word != Words.sidePictures("640 MB", of: "2 GB") {
                XCTAssertLessThanOrEqual(sentence.split(separator: " ").count, 12, sentence)
            }
            XCTAssertFalse(word.lowercased().contains("delete") && word != Words.deleteEverything
                           && word != Words.deletedEverything && word != Words.forgetLast24Body,
                           "one verb, Forget: \(word)")
        }
    }
}
