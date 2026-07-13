// PrivacyDashboardTests.swift — pin the pure-function surface of the
// cycle-8.46 in-app Privacy Dashboard: summary-line formatter, filter
// compose/apply, destructive-action typed-word gate.

import XCTest
@testable import RecallUIKit

final class PrivacyDashboardTests: XCTestCase {

    // MARK: - SummaryStats.daysCovered

    func testDaysCoveredCeilForPartialDay() {
        let oldest: UInt64 = 1_000_000_000_000_000
        let newest = oldest + 25 * 3600 * 1_000_000  // 25h → 2 days (ceil)
        let stats = SummaryStats(
            totalEvents: 100, oldestTsUs: oldest, newestTsUs: newest, diskBytes: 0
        )
        XCTAssertEqual(stats.daysCovered, 2)
    }

    func testDaysCoveredExactlyOneDay() {
        let oldest: UInt64 = 1_000_000_000_000_000
        let newest = oldest + 24 * 3600 * 1_000_000
        let stats = SummaryStats(
            totalEvents: 100, oldestTsUs: oldest, newestTsUs: newest, diskBytes: 0
        )
        XCTAssertEqual(stats.daysCovered, 1)
    }

    func testDaysCoveredEmptyStore() {
        let stats = SummaryStats(
            totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0
        )
        XCTAssertEqual(stats.daysCovered, 0)
    }

    // MARK: - Summary card snapshot (pure formatter)

    func testSummaryLineRealisticData() {
        // 3 events, 4 minutes span (1 day), 12 MiB.
        let stats = SummaryStats(
            totalEvents: 3,
            oldestTsUs: 1_736_000_000_000_000,
            newestTsUs: 1_736_000_240_000_000,
            diskBytes: 12_582_912
        )
        let line = PrivacyDashboardSummary.line(summary: stats)
        // ByteCountFormatter is locale-dependent; assert the structure.
        XCTAssertTrue(line.contains("MCI has captured 3 events"))
        XCTAssertTrue(line.contains("across 1 day"))
        XCTAssertTrue(line.contains("of encrypted storage"))
    }

    func testSummaryLinePluralDays() {
        let oldest: UInt64 = 1_736_000_000_000_000
        let newest = oldest + 3 * 86_400 * 1_000_000
        let stats = SummaryStats(
            totalEvents: 42, oldestTsUs: oldest, newestTsUs: newest, diskBytes: 1024
        )
        XCTAssertTrue(
            PrivacyDashboardSummary.line(summary: stats).contains("across 3 days")
        )
    }

    func testSummaryLineNil() {
        XCTAssertEqual(
            PrivacyDashboardSummary.line(summary: nil, isLoading: true), "Loading…"
        )
        XCTAssertEqual(
            PrivacyDashboardSummary.line(summary: nil, isLoading: false),
            "No brain data yet."
        )
    }

    // MARK: - Filter compose JSON (pinned test surface)

    func testFilterComposeJSONEmpty() {
        XCTAssertEqual(PrivacyDashboardFilter.empty.composeJSON(), [:])
    }

    func testFilterComposeJSONAppOnly() {
        let f = PrivacyDashboardFilter(appBundleId: "com.apple.Safari", sinceHours: nil)
        XCTAssertEqual(f.composeJSON(), ["app_bundle_id": "com.apple.Safari"])
    }

    func testFilterComposeJSONSinceHours() {
        let ref = Date(timeIntervalSince1970: 1_800_000_000)
        let f = PrivacyDashboardFilter(appBundleId: nil, sinceHours: 24)
        let out = f.composeJSON(now: ref)
        XCTAssertNil(out["app_bundle_id"])
        // 24h before ref = 1_799_913_600 s = 1_799_913_600_000_000 us
        XCTAssertEqual(out["time_from_us"], "1799913600000000")
    }

    func testFilterComposeJSONDropsEmptyAppAndZeroHours() {
        XCTAssertEqual(
            PrivacyDashboardFilter(appBundleId: "", sinceHours: 0).composeJSON(),
            [:]
        )
    }

    // MARK: - Filter apply

    func testFilterApplyByApp() {
        let out = PrivacyDashboardFilter(
            appBundleId: "com.microsoft.VSCode", sinceHours: nil
        ).apply(to: StubBrainReader.demoHits)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.appBundleId, "com.microsoft.VSCode")
    }

    func testFilterApplyEmpty() {
        let hits = StubBrainReader.demoHits
        XCTAssertEqual(
            PrivacyDashboardFilter.empty.apply(to: hits).count, hits.count
        )
    }

    // MARK: - DestructivePrivacyAction typed-word gate

    func testDeleteLast24hRequiresExactDELETE() {
        let a = DestructivePrivacyAction.deleteLast24h
        XCTAssertTrue(a.matches("DELETE"))
        XCTAssertTrue(a.matches("  DELETE  "))  // whitespace-trimmed
        XCTAssertFalse(a.matches("delete"))     // case-sensitive
        XCTAssertFalse(a.matches("DELETE!"))
        XCTAssertFalse(a.matches(""))
    }

    func testDeleteEverythingRequiresLongerPhrase() {
        let a = DestructivePrivacyAction.deleteEverything
        XCTAssertEqual(a.requiredPhrase, "DELETE EVERYTHING")
        XCTAssertTrue(a.matches("DELETE EVERYTHING"))
        XCTAssertFalse(a.matches("DELETE"))
        XCTAssertFalse(a.matches("delete everything"))
        XCTAssertFalse(a.matches("DELETE  EVERYTHING"))  // double-space fails
    }

    // MARK: - Stub reader smoke

    func testStubReaderSummaryStatsShape() async throws {
        let stats = try await StubBrainReader().summaryStats()
        XCTAssertEqual(stats.totalEvents, 3)
        XCTAssertGreaterThan(stats.diskBytes, 0)
    }
}
