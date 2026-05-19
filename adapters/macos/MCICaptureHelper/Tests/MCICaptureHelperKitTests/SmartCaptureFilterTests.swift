// SPDX-License-Identifier: TBD-private
//
// SmartCaptureFilterTests — DESIGN.md §5.2 four-stage filter chain
// + the RESEARCH_DIGEST Stream A dual-threshold dHash.

import XCTest
@testable import MCICaptureHelperKit

final class DHashDistanceTests: XCTestCase {
    func testZeroDistanceForIdenticalHashes() {
        let a = DHash(bits: 0xDEAD_BEEF_CAFE_F00D)
        XCTAssertEqual(a.distance(to: a), 0)
    }

    func testAllBitsDifferIs64() {
        let a = DHash(bits: 0)
        let b = DHash(bits: UInt64.max)
        XCTAssertEqual(a.distance(to: b), 64)
    }

    func testSingleBitDifferIs1() {
        let a = DHash(bits: 0b0)
        let b = DHash(bits: 0b1)
        XCTAssertEqual(a.distance(to: b), 1)
    }
}

final class DHashThresholdsTests: XCTestCase {
    func testBelowLowDrops() {
        let t = DHashThresholds(low: 4, high: 12)
        XCTAssertEqual(t.decide(distance: 0), .drop)
        XCTAssertEqual(t.decide(distance: 4), .drop)
    }

    func testAboveHighStores() {
        let t = DHashThresholds(low: 4, high: 12)
        XCTAssertEqual(t.decide(distance: 12), .store)
        XCTAssertEqual(t.decide(distance: 64), .store)
    }

    func testBetweenTieBreaks() {
        let t = DHashThresholds(low: 4, high: 12)
        XCTAssertEqual(t.decide(distance: 5), .tieBreak)
        XCTAssertEqual(t.decide(distance: 11), .tieBreak)
    }
}

final class SmartCaptureFilterTests: XCTestCase {
    private let dummyRect = DirtyRect(x: 0, y: 0, width: 100, height: 100)

    func testIdleGateDropsFirst() {
        let f = SmartCaptureFilter()
        let decision = f.decide(frame: CandidateFrame(
            userIdle: true,
            frameStatusComplete: true,
            dirtyRects: [dummyRect],
            dhash: DHash(bits: 0),
            priorDhash: DHash(bits: UInt64.max)  // would otherwise force store
        ))
        XCTAssertEqual(decision, .dropIdle)
    }

    func testFrameStatusIncompleteDrops() {
        let f = SmartCaptureFilter()
        let decision = f.decide(frame: CandidateFrame(
            userIdle: false,
            frameStatusComplete: false,
            dirtyRects: [dummyRect],
            dhash: DHash(bits: 0),
            priorDhash: nil
        ))
        XCTAssertEqual(decision, .dropStatus)
    }

    func testEmptyDirtyRectsDrops() {
        let f = SmartCaptureFilter()
        let decision = f.decide(frame: CandidateFrame(
            userIdle: false,
            frameStatusComplete: true,
            dirtyRects: [],
            dhash: DHash(bits: 0),
            priorDhash: nil
        ))
        XCTAssertEqual(decision, .dropNoDirtyRects)
    }

    func testFirstFrameForwards() {
        // No prior dHash → cannot compute distance → forward.
        let f = SmartCaptureFilter()
        let decision = f.decide(frame: CandidateFrame(
            userIdle: false,
            frameStatusComplete: true,
            dirtyRects: [dummyRect],
            dhash: DHash(bits: 42),
            priorDhash: nil
        ))
        XCTAssertEqual(decision, .forward)
    }

    func testNearDuplicateDropsViaDualThreshold() {
        let f = SmartCaptureFilter(thresholds: .default)
        // Distance 1 ≤ low=4 ⇒ drop.
        let decision = f.decide(frame: CandidateFrame(
            userIdle: false,
            frameStatusComplete: true,
            dirtyRects: [dummyRect],
            dhash: DHash(bits: 0b1),
            priorDhash: DHash(bits: 0)
        ))
        XCTAssertEqual(decision, .dropNearDuplicate)
    }

    func testGenuineChangeForwards() {
        let f = SmartCaptureFilter(thresholds: .default)
        // Distance 64 ≥ high=12 ⇒ store.
        let decision = f.decide(frame: CandidateFrame(
            userIdle: false,
            frameStatusComplete: true,
            dirtyRects: [dummyRect],
            dhash: DHash(bits: UInt64.max),
            priorDhash: DHash(bits: 0)
        ))
        XCTAssertEqual(decision, .forward)
    }

    func testTieBreakBandReturnsForwardTieBreak() {
        let f = SmartCaptureFilter(thresholds: .default)
        // Distance 8 ∈ (4, 12) ⇒ tie-break.
        let decision = f.decide(frame: CandidateFrame(
            userIdle: false,
            frameStatusComplete: true,
            dirtyRects: [dummyRect],
            dhash: DHash(bits: 0b1111_1111),
            priorDhash: DHash(bits: 0)
        ))
        XCTAssertEqual(decision, .forwardTieBreak)
    }
}

final class StreamPolicyTests: XCTestCase {
    /// The single most load-bearing line in the entire helper.
    /// Per RESEARCH_DIGEST Stream A: leaving the cursor on the
    /// capture stream busts the §4 footprint SLO.
    func testDefaultPolicyHidesCursor() {
        XCTAssertFalse(StreamPolicy.default.showsCursor)
    }

    func testDefaultPolicyMatchesAppleRecommendations() {
        XCTAssertEqual(StreamPolicy.default.queueDepth, 3)
        XCTAssertEqual(StreamPolicy.default.minimumFrameIntervalMs, 200)
    }
}
