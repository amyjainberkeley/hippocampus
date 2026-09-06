// SPDX-License-Identifier: TBD-private

import Foundation
import XCTest
#if os(macOS)
import CoreGraphics
#endif

@testable import MCICaptureHelperKit

final class UserActivityReaderTests: XCTestCase {
    func testZeroAndJustBelowDefaultThresholdAreActive() {
        for seconds in [0, TimeInterval(60).nextDown] {
            XCTAssertEqual(
                UserActivityState.classify(secondsSinceLastInput: seconds),
                .active
            )
        }
    }

    func testAtAndAboveDefaultThresholdAreIdle() {
        for seconds in [60, TimeInterval(60).nextUp, 86_400, .greatestFiniteMagnitude] {
            XCTAssertEqual(
                UserActivityState.classify(secondsSinceLastInput: seconds),
                .idle
            )
        }
    }

    func testCustomThresholdUsesInclusiveIdleBoundary() {
        XCTAssertEqual(
            UserActivityState.classify(secondsSinceLastInput: TimeInterval(5).nextDown, idleThreshold: 5),
            .active
        )
        XCTAssertEqual(
            UserActivityState.classify(secondsSinceLastInput: 5, idleThreshold: 5),
            .idle
        )
    }

    func testZeroThresholdIsValidAndImmediatelyIdle() {
        for seconds in [TimeInterval(0), 1] {
            XCTAssertEqual(
                UserActivityState.classify(secondsSinceLastInput: seconds, idleThreshold: 0),
                .idle
            )
        }
    }

    func testMissingNegativeAndNonfiniteReadingsAreUnknown() {
        let readings: [TimeInterval?] = [nil, -1, -.leastNonzeroMagnitude, .nan, .infinity, -.infinity]
        for seconds in readings {
            XCTAssertEqual(
                UserActivityState.classify(secondsSinceLastInput: seconds),
                .unknown
            )
            XCTAssertEqual(
                UserActivityState.classify(secondsSinceLastInput: seconds, idleThreshold: 0),
                .unknown
            )
        }
    }

    func testNegativeAndNonfiniteThresholdsAreUnknown() {
        let thresholds: [TimeInterval] = [-1, -.leastNonzeroMagnitude, .nan, .infinity, -.infinity]
        for threshold in thresholds {
            for seconds in [TimeInterval(0), 120] {
                XCTAssertEqual(
                    UserActivityState.classify(
                        secondsSinceLastInput: seconds,
                        idleThreshold: threshold
                    ),
                    .unknown
                )
            }
        }
    }

    #if os(macOS)
    func testSystemReaderQueriesAnyInputInCombinedSession() {
        let reader: any UserActivityReading = SystemUserActivityReader { state, eventType in
            XCTAssertEqual(state, .combinedSessionState)
            XCTAssertEqual(eventType.rawValue, 0xFFFF_FFFF)
            return 12.5
        }

        XCTAssertEqual(reader.secondsSinceLastInput(), 12.5)
    }

    func testSystemReaderPreservesFiniteNonnegativeReadings() {
        let readings: [TimeInterval] = [0, TimeInterval(60).nextDown, 60, 86_400, .greatestFiniteMagnitude]
        for seconds in readings {
            let reader = SystemUserActivityReader { _, _ in seconds }
            XCTAssertEqual(reader.secondsSinceLastInput(), seconds)
        }
    }

    func testSystemReaderRejectsNegativeAndNonfiniteReadings() {
        let readings: [TimeInterval] = [-1, -.leastNonzeroMagnitude, .nan, .infinity, -.infinity]
        for seconds in readings {
            let reader = SystemUserActivityReader { _, _ in seconds }
            XCTAssertNil(reader.secondsSinceLastInput())
            XCTAssertEqual(
                UserActivityState.classify(secondsSinceLastInput: reader.secondsSinceLastInput()),
                .unknown
            )
        }
    }

    func testEachReadQueriesOnceWithoutReusingPreviousActivity() {
        let query = SequenceActivityQuery(readings: [120, 0, -1, 60, .nan, 0])
        let reader = SystemUserActivityReader { _, _ in query.next() }
        let expected: [UserActivityState] = [.idle, .active, .unknown, .idle, .unknown, .active]

        for (index, state) in expected.enumerated() {
            XCTAssertEqual(
                UserActivityState.classify(secondsSinceLastInput: reader.secondsSinceLastInput()),
                state
            )
            XCTAssertEqual(query.invocationCount, index + 1)
        }
    }
    #else
    func testSystemReaderIsUnavailableOffMacOS() {
        let reader: any UserActivityReading = SystemUserActivityReader()
        XCTAssertNil(reader.secondsSinceLastInput())
    }
    #endif
}

#if os(macOS)
private final class SequenceActivityQuery: @unchecked Sendable {
    private let lock = NSLock()
    private let readings: [TimeInterval]
    private var count = 0

    init(readings: [TimeInterval]) {
        self.readings = readings
    }

    var invocationCount: Int {
        lock.withLock { count }
    }

    func next() -> TimeInterval {
        lock.withLock {
            defer { count += 1 }
            return count < readings.count ? readings[count] : .nan
        }
    }
}
#endif
