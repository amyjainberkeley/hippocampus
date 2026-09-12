import Foundation
import XCTest
@testable import RecallUIKit

final class StorageAccountingTests: XCTestCase {
    func testUnsupportedReaderDoesNotInventAnExplicitStorageMeasurement() async throws {
        let storage = try await StubBrainReader().storageUsage()
        XCTAssertNil(storage)
    }

    func testSummaryWireDecodesBreakdownInsteadOfTreatingDatabaseAsTotal() throws {
        let json = #"""
        {"total_events":2,"oldest_ts_us":null,"newest_ts_us":null,"disk_bytes":101,
         "storage":{"database":{"logical_bytes":101,"status":"complete"},
         "wal":{"logical_bytes":202,"status":"complete"},
         "shm":{"logical_bytes":303,"status":"complete"},
         "managed_blobs":{"logical_bytes":909,"status":"complete"},
         "reported_total_bytes":1515,"complete":true}}
        """#
        let stats = try JSONDecoder().decode(SummaryStatsWire.self, from: Data(json.utf8)).value
        XCTAssertEqual(stats.diskBytes, 101)
        XCTAssertEqual(stats.storage?.reportedTotalBytes, 1515)
        XCTAssertEqual(stats.storage?.managedBlobs.logicalBytes, 909)
        XCTAssertEqual(stats.storage?.complete, true)
        XCTAssertTrue(PrivacyDashboardSummary.storageTotal(summary: stats).contains("Reported local storage"))
        XCTAssertFalse(PrivacyDashboardSummary.line(summary: stats).contains("encrypted storage"))
    }

    func testLegacySummaryNeverClaimsDatabaseIsTotalStorage() throws {
        let json = #"{"total_events":0,"oldest_ts_us":null,"newest_ts_us":null,"disk_bytes":42}"#
        let stats = try JSONDecoder().decode(SummaryStatsWire.self, from: Data(json.utf8)).value
        XCTAssertNil(stats.storage)
        XCTAssertTrue(PrivacyDashboardSummary.storageTotal(summary: stats).contains("unavailable"))
        XCTAssertFalse(PrivacyDashboardSummary.line(summary: stats).contains("encrypted storage"))
    }

    func testPartialZeroIsNotPresentedAsCompleteOrEmptyStorage() {
        let usage = StorageUsage(
            database: .init(logicalBytes: nil, status: .missing),
            wal: .init(logicalBytes: 0, status: .missing),
            shm: .init(logicalBytes: 0, status: .missing),
            managedBlobs: .init(logicalBytes: 0, status: .limitReached),
            reportedTotalBytes: 0, complete: false
        )
        let stats = summary(usage)
        XCTAssertTrue(PrivacyDashboardSummary.storageTotal(summary: stats).contains("Partial"))
        XCTAssertTrue(PrivacyDashboardSummary.storageValue(usage.database).contains("Unavailable"))
        XCTAssertTrue(PrivacyDashboardSummary.storageValue(usage.managedBlobs).contains("scan limit"))
    }

    func testMissingOptionalFileAndUnreadableFileHaveDifferentPresentation() {
        let missing = StorageMeasurement(logicalBytes: 0, status: .missing)
        let unreadable = StorageMeasurement(logicalBytes: nil, status: .unreadable)
        XCTAssertTrue(PrivacyDashboardSummary.storageValue(missing).contains("absent"))
        XCTAssertTrue(PrivacyDashboardSummary.storageValue(unreadable).contains("Unavailable"))
        XCTAssertTrue(PrivacyDashboardSummary.storageValue(unreadable).contains("unreadable"))
    }

    func testOverflowIsUnavailableAndUInt64ValuesDoNotTrapFormatting() {
        let measured = StorageMeasurement(logicalBytes: UInt64.max, status: .complete)
        let zero = StorageMeasurement(logicalBytes: 0, status: .missing)
        let overflow = StorageUsage(
            database: measured, wal: .init(logicalBytes: 1, status: .complete),
            shm: zero, managedBlobs: zero, reportedTotalBytes: nil, complete: false
        )
        XCTAssertTrue(PrivacyDashboardSummary.storageValue(measured).contains("bytes"))
        XCTAssertTrue(PrivacyDashboardSummary.storageTotal(summary: summary(overflow)).contains("unavailable"))
    }

    func testSummaryCodableRetainsMeasurementQuality() throws {
        let unknown = StorageMeasurement(logicalBytes: nil, status: .symlink)
        let stats = summary(StorageUsage(
            database: unknown, wal: unknown, shm: unknown, managedBlobs: unknown,
            reportedTotalBytes: nil, complete: false
        ))
        let decoded = try JSONDecoder().decode(SummaryStats.self, from: JSONEncoder().encode(stats))
        XCTAssertEqual(decoded, stats)
        XCTAssertFalse(decoded.storage!.complete)
        XCTAssertTrue(PrivacyDashboardSummary.storageValue(unknown).contains("symlink"))
    }

    private func summary(_ storage: StorageUsage) -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0, storage: storage)
    }
}
