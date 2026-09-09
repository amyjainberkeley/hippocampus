import XCTest
@testable import RecallUIKit

final class ActivityReviewTests: XCTestCase {
    func testForegroundStretchesJoinOnlyAdjacentAttributedIntervals() throws {
        let page = ActivityPage(intervals: [
            interval(1, 5, "input_active", "test.a"),
            interval(5, 8, "input_idle", "test.a"),
            interval(8, 10, "unknown", "private.app"),
            interval(10, 12, "input_active", "test.a"),
            interval(13, 16, "input_active", "test.a"),
            interval(16, 18, "input_active", "test.b"),
            interval(18, 19, "input_active", nil),
            interval(19, 20, "input_active", "test.b"),
        ], truncated: false)
        let summary = try XCTUnwrap(ActivitySummary(page: page, startUs: 0, endUs: 22))
        XCTAssertEqual(summary.foregroundStretches.map(\.startUs), [1, 10, 13, 16, 19])
        XCTAssertEqual(summary.foregroundStretches.map(\.endUs), [8, 12, 16, 18, 20])
        XCTAssertEqual(summary.longestForegroundStretch?.appBundleId, "test.a")
        XCTAssertEqual(summary.longestForegroundStretch?.durationUs, 7)
    }

    func testForegroundStretchesClipAndKeepStableEarliestTieWithoutUnknownAttribution() throws {
        let page = ActivityPage(intervals: [interval(0, 8, "input_active", "test.a"),
                                             interval(8, 10, "input_idle", "test.b")], truncated: false)
        let summary = try XCTUnwrap(ActivitySummary(page: page, startUs: 6, endUs: 12))
        XCTAssertEqual(summary.longestForegroundStretch?.startUs, 6)
        XCTAssertEqual(summary.longestForegroundStretch?.durationUs, 2)
        let unknown = try XCTUnwrap(ActivitySummary(page: .init(intervals: [
            interval(1, 4, "unknown", "private.app")
        ], truncated: false), startUs: 0, endUs: 10))
        XCTAssertTrue(unknown.foregroundStretches.isEmpty)
        XCTAssertNil(unknown.longestForegroundStretch)
    }

    func testForegroundAppTotalsExcludeUnknownAndSeparateRecentInput() throws {
        let page = ActivityPage(intervals: [
            ActivityInterval(startUs: 1, endUs: 5, state: "input_active", appBundleId: "com.example.A"),
            ActivityInterval(startUs: 5, endUs: 8, state: "input_idle", appBundleId: "com.example.A"),
            ActivityInterval(startUs: 8, endUs: 10, state: "unknown", appBundleId: "com.example.Private"),
            ActivityInterval(startUs: 10, endUs: 12, state: "input_active", appBundleId: "com.example.B")
        ], truncated: false)
        let summary = try XCTUnwrap(ActivitySummary(page: page, startUs: 0, endUs: 15))
        XCTAssertEqual(summary.appTotals.map(\.appBundleId), ["com.example.A", "com.example.B"])
        XCTAssertEqual(summary.appTotals.map(\.totalUs), [7, 2])
        XCTAssertEqual(summary.appTotals[0].recentInputUs, 4)
        XCTAssertEqual(summary.totalUs(for: .unknown), 6)
    }
    func testInputLabelsDescribeTheSamplerRatherThanAttention() {
        XCTAssertEqual(MeasuredInputState.inputActive.label, "Recent input")
        XCTAssertEqual(MeasuredInputState.inputIdle.label, "No recent input")
    }

    func testWireUsesSnakeCaseAndUnknownStatesRemainUnknown() throws {
        let data = Data("""
        {"intervals":[{"start_us":10,"end_us":20,"state":"future_state","app_bundle_id":"private.app"}],"truncated":false}
        """.utf8)
        let page = try JSONDecoder().decode(ActivityPage.self, from: data)
        XCTAssertEqual(page.intervals.first?.startUs, 10)
        XCTAssertEqual(try JSONDecoder().decode(ActivityPage.self, from: JSONEncoder().encode(page)), page)
        let summary = try XCTUnwrap(ActivitySummary(page: page, startUs: 0, endUs: 30))
        XCTAssertEqual(summary.totalUs(for: .unknown), 30)
        XCTAssertTrue(summary.intervals.allSatisfy { $0.appBundleId == nil })
    }

    func testMeasuredIntervalsClipToWindowAndFillEveryGapWithoutDoubleCounting() throws {
        let page = ActivityPage(intervals: [
            interval(80, 120, "input_idle", "test.b"),
            interval(0, 30, "input_active", "test.a"),
            interval(40, 50, "unknown", "private.app"),
        ], truncated: false)
        let summary = try XCTUnwrap(ActivitySummary(page: page, startUs: 10, endUs: 100))
        XCTAssertEqual(summary.totalUs(for: .inputActive), 20)
        XCTAssertEqual(summary.totalUs(for: .inputIdle), 20)
        XCTAssertEqual(summary.totalUs(for: .unknown), 50)
        XCTAssertEqual(summary.intervals.first?.startUs, 10)
        XCTAssertEqual(summary.intervals.last?.endUs, 100)
        XCTAssertEqual(summary.intervals.reduce(UInt64(0)) { $0 + $1.endUs - $1.startUs }, 90)
        XCTAssertEqual(summary.intervals.filter { $0.state == "unknown" }.compactMap(\.appBundleId), [])
    }

    func testEmptyTruncatedMalformedAndOverlappingPagesCannotBecomeAChart() {
        for page in [
            ActivityPage(intervals: [], truncated: false),
            ActivityPage(intervals: [interval(10, 20)], truncated: true),
            ActivityPage(intervals: [interval(20, 10)], truncated: false),
            ActivityPage(intervals: [interval(20, 20)], truncated: false),
            ActivityPage(intervals: [interval(10, 30), interval(20, 40)], truncated: false),
            ActivityPage(intervals: [interval(110, 120)], truncated: false),
        ] {
            XCTAssertNil(ActivitySummary(page: page, startUs: 0, endUs: 100))
        }
        XCTAssertNil(ActivitySummary(page: .init(intervals: [interval(10, 20)], truncated: false), startUs: 20, endUs: 20))
    }

    private func interval(_ start: UInt64, _ end: UInt64, _ state: String = "input_active", _ app: String? = nil) -> ActivityInterval {
        ActivityInterval(startUs: start, endUs: end, state: state, appBundleId: app)
    }
}

@MainActor
final class DailyActivityTests: XCTestCase {
    func testSameDayRefreshPreservesChartWhileLoadingAndOldDayCannotReplaceNewDay() async {
        let now = Date(timeIntervalSince1970: 1_788_955_200)
        let reader = ActivityTestReader()
        let model = DailyMemoryViewModel(reader: reader, selectedDate: now,
                                        healthLoader: { nil }, now: { now })
        await model.reload()
        let original = model.activitySummary
        await reader.delayNextRead()
        let refresh = Task { await model.reload() }
        await reader.waitForPendingRead()
        XCTAssertEqual(model.activitySummary, original)
        model.moveDay(-1)
        await model.reload()
        let current = model.activitySummary
        XCTAssertEqual(current?.startUs, model.day.startUs)
        XCTAssertEqual(current?.endUs, model.day.endUs + 1)
        await reader.finishPendingRead()
        await refresh.value
        XCTAssertEqual(model.activitySummary, current)
    }

    func testRealReaderWindowUsesExclusiveEndAndStopsAtNow() async throws {
        let now = Date(timeIntervalSince1970: 1_788_955_200)
        let reader = ActivityTestReader()
        let model = DailyMemoryViewModel(reader: reader, selectedDate: now,
                                        healthLoader: { nil }, now: { now })
        await model.reload()
        let recorded = await reader.request
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.0, model.day.startUs)
        XCTAssertEqual(request.1, UInt64(now.timeIntervalSince1970 * 1_000_000))
        XCTAssertEqual(request.2, 50_000)
        XCTAssertNotNil(model.activitySummary)
        XCTAssertTrue(model.events.isEmpty, "Measured input must be independent of screenshot evidence")
        await reader.setUnavailable()
        await model.reload()
        XCTAssertNil(model.activitySummary)
        XCTAssertEqual(model.activityStatus, "Measured input unavailable")
    }

    func testLegacyReaderAbstainsAndNavigationClearsPreviousMeasurement() async {
        let reader = ActivityTestReader()
        let now = Date(timeIntervalSince1970: 1_788_955_200)
        let model = DailyMemoryViewModel(reader: reader, selectedDate: now,
                                        healthLoader: { nil }, now: { now })
        await model.reload()
        XCTAssertNotNil(model.activitySummary)
        model.moveDay(-1)
        XCTAssertNil(model.activitySummary)
        let oldReader = DailyMemoryViewModel(reader: StubBrainReader(), healthLoader: { nil })
        await oldReader.reload()
        XCTAssertNil(oldReader.activitySummary)
        XCTAssertEqual(oldReader.activityStatus, "Measured input unavailable")
    }
}

private actor ActivityTestReader: BrainReader {
    var request: (UInt64, UInt64, UInt32)?
    var unavailable = false
    var shouldDelay = false
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    func delayNextRead() { shouldDelay = true }
    func waitForPendingRead() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishPendingRead() { pending?.resume(); pending = nil }
    func setUnavailable() { unavailable = true }
    func activityIntervals(startUs: UInt64, endUs: UInt64, limit: UInt32) async throws -> ActivityPage {
        request = (startUs, endUs, limit)
        if shouldDelay {
            shouldDelay = false
            await withCheckedContinuation {
                pending = $0
                started?.resume()
                started = nil
            }
        }
        if unavailable { throw BrainReaderError.queryFailed("synthetic") }
        return ActivityPage(intervals: [.init(startUs: startUs, endUs: endUs,
            state: "input_active", appBundleId: "test.app")], truncated: false)
    }
    func search(_ options: SearchOptions) async throws -> [Hit] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}
