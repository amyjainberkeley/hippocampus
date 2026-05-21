import XCTest
@testable import RecallUIKit

final class FilterStateTests: XCTestCase {
    func testInitialStateHasNoActivePills() {
        let state = FilterState()
        XCTAssertFalse(state.anyActive)
        for pill in FilterPill.allCases {
            XCTAssertFalse(state.isActive(pill))
        }
    }

    func testToggleActivatesPill() {
        var state = FilterState()
        state.toggle(.appSafari)
        XCTAssertTrue(state.isActive(.appSafari))
        XCTAssertTrue(state.anyActive)
    }

    func testToggleTwiceDeactivatesPill() {
        var state = FilterState()
        state.toggle(.hasUrl)
        state.toggle(.hasUrl)
        XCTAssertFalse(state.isActive(.hasUrl))
        XCTAssertFalse(state.anyActive)
    }

    func testTodayAndLastHourAreMutuallyExclusive() {
        var state = FilterState()
        state.toggle(.today)
        XCTAssertTrue(state.isActive(.today))

        state.toggle(.lastHour)
        XCTAssertTrue(state.isActive(.lastHour))
        XCTAssertFalse(state.isActive(.today), "today should be deactivated when lastHour activated")
    }

    func testLastHourDeactivatedByToday() {
        var state = FilterState()
        state.toggle(.lastHour)
        state.toggle(.today)
        XCTAssertTrue(state.isActive(.today))
        XCTAssertFalse(state.isActive(.lastHour), "lastHour should be deactivated when today activated")
    }

    func testAppFilterReturnsSafariBundleId() {
        var state = FilterState()
        XCTAssertNil(state.appFilter)
        state.toggle(.appSafari)
        XCTAssertEqual(state.appFilter, "com.apple.Safari")
    }

    func testTimeFromUsForLastHour() {
        var state = FilterState()
        let now = Date()
        state.toggle(.lastHour)
        let from = state.timeFromUs(now: now)
        XCTAssertNotNil(from)
        let expected = UInt64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(from, expected)
    }

    func testTimeFromUsForToday() {
        var state = FilterState()
        let now = Date()
        state.toggle(.today)
        let from = state.timeFromUs(now: now)
        XCTAssertNotNil(from)
        let startOfDay = Calendar.current.startOfDay(for: now)
        let expected = UInt64(startOfDay.timeIntervalSince1970 * 1_000_000)
        XCTAssertEqual(from, expected)
    }

    func testTimeFromUsNilWhenNoTimePillActive() {
        let state = FilterState()
        XCTAssertNil(state.timeFromUs())
    }

    func testHasUrlFilter() {
        var state = FilterState()
        XCTAssertFalse(state.hasUrl)
        state.toggle(.hasUrl)
        XCTAssertTrue(state.hasUrl)
    }

    func testMultiplePillsCanBeActiveSimultaneously() {
        var state = FilterState()
        state.toggle(.appSafari)
        state.toggle(.today)
        state.toggle(.hasUrl)
        XCTAssertTrue(state.isActive(.appSafari))
        XCTAssertTrue(state.isActive(.today))
        XCTAssertTrue(state.isActive(.hasUrl))
        XCTAssertFalse(state.isActive(.lastHour))
    }

    func testPillLabelsAreNonEmpty() {
        for pill in FilterPill.allCases {
            XCTAssertFalse(pill.label.isEmpty)
        }
    }
}
