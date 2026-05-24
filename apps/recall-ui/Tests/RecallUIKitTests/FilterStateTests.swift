// FilterStateTests.swift — exercises the dynamic per-app filter + the
// structured DateRangePreset model. v1's hardcoded `appSafari` /
// `today` / `lastHour` pills were replaced by `appBundleIds` +
// `dateRange` (Director-Brain audit, dogfood-v1 gaps #1 + #2).

import XCTest
@testable import RecallUIKit

final class FilterStateTests: XCTestCase {
    func testInitialStateIsEmpty() {
        let state = FilterState()
        XCTAssertTrue(state.appBundleIds.isEmpty)
        XCTAssertEqual(state.dateRange, .none)
        XCTAssertFalse(state.hasUrl)
        XCTAssertFalse(state.anyActive)
    }

    func testToggleAppAddsAndRemovesBundleId() {
        var state = FilterState()
        state.toggleApp("com.apple.Safari")
        XCTAssertTrue(state.appBundleIds.contains("com.apple.Safari"))
        XCTAssertTrue(state.anyActive)
        state.toggleApp("com.apple.Safari")
        XCTAssertFalse(state.appBundleIds.contains("com.apple.Safari"))
        XCTAssertFalse(state.anyActive)
    }

    func testToggleAppSupportsMultiSelect() {
        var state = FilterState()
        state.toggleApp("com.apple.Safari")
        state.toggleApp("com.microsoft.VSCode")
        XCTAssertEqual(state.appBundleIds.count, 2)
        XCTAssertTrue(state.requiresClientSideAppFilter)
    }

    func testAppFilterPassesThroughWhenSingle() {
        var state = FilterState()
        state.toggleApp("com.apple.Safari")
        XCTAssertEqual(state.appFilter, "com.apple.Safari")
        XCTAssertFalse(state.requiresClientSideAppFilter)
    }

    func testAppFilterNilWhenMultipleSelected() {
        var state = FilterState()
        state.toggleApp("com.apple.Safari")
        state.toggleApp("com.microsoft.VSCode")
        XCTAssertNil(state.appFilter, "FFI can only filter on one app; multi-select uses client-side post-filter")
        XCTAssertTrue(state.requiresClientSideAppFilter)
    }

    func testMatchesAppWithEmptySetAcceptsAll() {
        let state = FilterState()
        XCTAssertTrue(state.matchesApp("com.apple.Safari"))
        XCTAssertTrue(state.matchesApp(nil))
    }

    func testMatchesAppWithSetExcludesOthers() {
        var state = FilterState()
        state.toggleApp("com.apple.Safari")
        XCTAssertTrue(state.matchesApp("com.apple.Safari"))
        XCTAssertFalse(state.matchesApp("com.microsoft.VSCode"))
        XCTAssertFalse(state.matchesApp(nil))
    }

    func testHasUrlToggle() {
        var state = FilterState()
        state.toggleHasUrl()
        XCTAssertTrue(state.hasUrl)
        XCTAssertTrue(state.anyActive)
        state.toggleHasUrl()
        XCTAssertFalse(state.hasUrl)
    }

    func testDateRangeNoneProducesNoWindow() {
        let state = FilterState()
        let window = state.timeWindowUs()
        XCTAssertNil(window.fromUs)
        XCTAssertNil(window.toUs)
        XCTAssertNil(state.timeFromUs())
    }

    func testDateRangeTodayStartsAtMidnight() {
        var state = FilterState()
        state.setDateRange(.today)
        let now = Date()
        let window = state.timeWindowUs(now: now)
        XCTAssertNotNil(window.fromUs)
        XCTAssertNil(window.toUs, "today has an open upper bound")
        let startOfDay = Calendar.current.startOfDay(for: now)
        let expected = UInt64(startOfDay.timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(window.fromUs, expected)
    }

    func testDateRangeYesterdayClosedInterval() {
        var state = FilterState()
        state.setDateRange(.yesterday)
        let now = Date()
        let window = state.timeWindowUs(now: now)
        XCTAssertNotNil(window.fromUs)
        XCTAssertNotNil(window.toUs)
        let startToday = Calendar.current.startOfDay(for: now)
        let startYesterday = Calendar.current.date(byAdding: .day, value: -1, to: startToday)!
        XCTAssertEqual(window.fromUs, UInt64(startYesterday.timeIntervalSince1970 * 1_000_000))
        XCTAssertEqual(window.toUs, UInt64(startToday.timeIntervalSince1970 * 1_000_000))
    }

    func testDateRangeLast7DaysIsApproximatelySevenDays() {
        var state = FilterState()
        state.setDateRange(.last7Days)
        let now = Date(timeIntervalSince1970: 1_700_000_000) // pinned epoch
        let window = state.timeWindowUs(now: now)
        XCTAssertNotNil(window.fromUs)
        XCTAssertNil(window.toUs)
        let expected = UInt64(
            (now.addingTimeInterval(-7 * 86_400)).timeIntervalSince1970 * 1_000_000
        )
        // Allow ±1s of slop from Calendar arithmetic.
        if let from = window.fromUs {
            XCTAssertEqual(Double(from), Double(expected), accuracy: 1_000_000)
        }
    }

    func testDateRangeCustomProducesInclusiveFromExclusiveTo() {
        var state = FilterState()
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_086_400)  // +1 day
        state.setDateRange(.custom(from: from, to: to))
        let window = state.timeWindowUs()
        XCTAssertNotNil(window.fromUs)
        XCTAssertNotNil(window.toUs)
        let fromStart = Calendar.current.startOfDay(for: from)
        let toEnd = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)
        )!
        XCTAssertEqual(window.fromUs, UInt64(fromStart.timeIntervalSince1970 * 1_000_000))
        XCTAssertEqual(window.toUs, UInt64(toEnd.timeIntervalSince1970 * 1_000_000))
    }

    func testSetDateRangeReplaces() {
        var state = FilterState()
        state.setDateRange(.today)
        state.setDateRange(.last7Days)
        XCTAssertEqual(state.dateRange, .last7Days)
        state.setDateRange(.none)
        XCTAssertFalse(state.dateRange.isActive)
    }

    func testDateRangePresetLabelsAreNonEmpty() {
        for preset in [
            DateRangePreset.none, .today, .yesterday, .last7Days,
            .custom(from: Date(), to: Date()),
        ] {
            XCTAssertFalse(preset.label.isEmpty)
        }
    }

    func testFilterPillRawValuesStable() {
        // The single remaining boolean pill — `Has URL`.
        XCTAssertEqual(FilterPill.allCases, [.hasUrl])
        XCTAssertEqual(FilterPill.hasUrl.label, "Has URL")
    }
}
