import XCTest
@testable import MCICaptureHelperKit

final class FocusedReadPacingTests: XCTestCase {
    private let second: UInt64 = 1_000_000

    func testAStillWindowIsReadWheneverItChangesTwoSecondsApart() {
        var pacing = FocusedReadPacing()
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 100 * second, textCatchUp: false))
        XCTAssertFalse(pacing.admit(generation: 1, nowUs: 101 * second, textCatchUp: false))
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 105 * second, textCatchUp: false))
    }

    func testAPlayingVideoIsReadEveryFifteenSecondsOnceItKeepsMoving() {
        var pacing = FocusedReadPacing()
        var reads: [UInt64] = []
        // Frames every half second for a minute.
        for tick in 0..<120 {
            let now = 1_000 * second + UInt64(tick) * second / 2
            if pacing.admit(generation: 7, nowUs: now, textCatchUp: false) { reads.append(now) }
        }
        let gapsAfterMotion = zip(reads.dropFirst(), reads).map { $0 - $1 }.filter { $0 > 2 * second }
        XCTAssertLessThanOrEqual(reads.count, 12, "\(reads.count) reads in a minute of video")
        XCTAssertTrue(gapsAfterMotion.allSatisfy { $0 >= FocusedReadPacing.motionIntervalUs })
        XCTAssertTrue(pacing.isInMotion)
    }

    func testANewWindowAndTextCatchUpAreReadAtOnce() {
        var pacing = FocusedReadPacing()
        for tick in 0..<40 { _ = pacing.admit(generation: 1, nowUs: UInt64(tick) * second / 2, textCatchUp: false) }
        XCTAssertTrue(pacing.admit(generation: 2, nowUs: 20 * second + 1, textCatchUp: false), "switching windows reads now")
        XCTAssertTrue(pacing.admit(generation: 2, nowUs: 20 * second + 2, textCatchUp: true), "typing keeps its own floor")
    }

    func testMotionEndsWhenThePictureSettles() {
        var pacing = FocusedReadPacing()
        for tick in 0..<40 { _ = pacing.admit(generation: 1, nowUs: UInt64(tick) * second / 2, textCatchUp: false) }
        XCTAssertTrue(pacing.isInMotion)
        // A pause longer than the continuity window, then one change.
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 60 * second, textCatchUp: false))
        XCTAssertFalse(pacing.isInMotion)
    }
}
