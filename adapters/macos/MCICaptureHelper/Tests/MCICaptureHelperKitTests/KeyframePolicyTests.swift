import XCTest

@testable import MCICaptureHelperKit

final class KeyframePolicyTests: XCTestCase {
    private let policy = KeyframePolicy(materialDistance: 12, maxSilenceNanoseconds: 300)

    private func candidate(
        ordinal: UInt64 = 2,
        window: UInt32 = 7,
        bits: UInt64 = 0,
        time: UInt64 = 101
    ) -> KeyframeEvidenceCandidate {
        KeyframeEvidenceCandidate(
            captureOrdinal: ordinal,
            focusedWindowId: window,
            dhash: DHash(bits: bits),
            monotonicNanoseconds: time
        )
    }

    func testFirstEligibleFrameRetains() {
        XCTAssertEqual(policy.decision(previous: nil, current: candidate()), .first)
    }

    func testUnchangedFrameSkips() {
        let previous = candidate(ordinal: 1, time: 100)
        XCTAssertEqual(policy.decision(previous: previous, current: candidate()), .skip)
    }

    func testFocusedWindowChangeRetains() {
        let previous = candidate(ordinal: 1, window: 6, time: 100)
        XCTAssertEqual(policy.decision(previous: previous, current: candidate()), .windowChanged)
    }

    func testMaterialDistanceBoundary() {
        let previous = candidate(ordinal: 1, bits: 0, time: 100)
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(bits: 0b111_111_111_11)),
            .skip
        )
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(bits: 0b111_111_111_111)),
            .materialChange
        )
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(bits: 0b1_111_111_111_111)),
            .materialChange
        )
    }

    func testMaximumMonotonicSilenceBoundary() {
        let previous = candidate(ordinal: 1, time: 100)
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(time: 399)),
            .skip
        )
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(time: 400)),
            .maximumSilence
        )
    }

    func testMonotonicRollbackDoesNotForceRetention() {
        let previous = candidate(ordinal: 1, time: 400)
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(time: 99)),
            .skip
        )
    }

    func testOlderOrDuplicateOrdinalSkips() {
        let previous = candidate(ordinal: 3, time: 100)
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(ordinal: 3, window: 99)),
            .skip
        )
        XCTAssertEqual(
            policy.decision(previous: previous, current: candidate(ordinal: 2, window: 99)),
            .skip
        )
    }
}
