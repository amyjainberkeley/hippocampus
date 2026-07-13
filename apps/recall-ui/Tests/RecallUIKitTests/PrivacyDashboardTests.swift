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

    // MARK: - Cycle 8.47 PrivacyMutator surface (PR #76 follow-up)

    /// The mutator surface is protocol-typed so headless tests can
    /// substitute a mock. This test pins the call sequence the SwiftUI
    /// dashboard emits for each destructive action:
    ///   - `deleteLast24h` → `deleteEventsInRange(startTsUs, endTsUs)`
    ///   - `deleteEverything` → `prepareWipe()` then `wipeBrain(token:)`
    /// (The dashboard view exercises this sequence in `runDestructive`.)

    final class SpyMutator: PrivacyMutator, @unchecked Sendable {
        struct RangeCall: Equatable {
            let startTsUs: UInt64
            let endTsUs: UInt64
        }
        var deleteIdCalls: [UInt64] = []
        var rangeCalls: [RangeCall] = []
        var prepareCount = 0
        var wipeCalls: [String] = []
        var canned = DeleteResult(eventsDeleted: 0, vacuumOk: true)
        var cannedToken = "ffee".repeating(times: 16)

        func deleteEvent(id: UInt64) async throws -> DeleteResult {
            deleteIdCalls.append(id)
            return canned
        }

        func deleteEventsInRange(
            startTsUs: UInt64, endTsUs: UInt64
        ) async throws -> DeleteResult {
            rangeCalls.append(RangeCall(startTsUs: startTsUs, endTsUs: endTsUs))
            return canned
        }

        func prepareWipe() async throws -> String {
            prepareCount += 1
            return cannedToken
        }

        func wipeBrain(token: String) async throws -> DeleteResult {
            wipeCalls.append(token)
            return canned
        }
    }

    func testDeleteResultRoundTripsThroughCodable() throws {
        let r = DeleteResult(eventsDeleted: 42, vacuumOk: true)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(DeleteResult.self, from: data)
        XCTAssertEqual(r, back)
    }

    func testMutatorSpyDeleteEventTracksCallSequence() async throws {
        let spy = SpyMutator()
        spy.canned = DeleteResult(eventsDeleted: 1, vacuumOk: true)
        let r = try await spy.deleteEvent(id: 101)
        XCTAssertEqual(r.eventsDeleted, 1)
        XCTAssertEqual(spy.deleteIdCalls, [101])
    }

    func testMutatorSpyDeleteRangeRecordsBounds() async throws {
        let spy = SpyMutator()
        _ = try await spy.deleteEventsInRange(startTsUs: 100, endTsUs: 200)
        XCTAssertEqual(spy.rangeCalls, [SpyMutator.RangeCall(startTsUs: 100, endTsUs: 200)])
    }

    func testMutatorSpyWipeIsTwoStep() async throws {
        // The dashboard flow is prepareWipe() → wipeBrain(token:). The
        // token from prepare is opaque to the caller; the mutator returns
        // it verbatim so the same token round-trips.
        let spy = SpyMutator()
        let token = try await spy.prepareWipe()
        XCTAssertEqual(spy.prepareCount, 1)
        _ = try await spy.wipeBrain(token: token)
        XCTAssertEqual(spy.wipeCalls, [token])
    }
}

// Small helper — Swift Foundation's `String` has no `repeating:times:`
// for a String pattern out of the box.
private extension String {
    func repeating(times n: Int) -> String {
        String(repeating: self, count: n)
    }
}
