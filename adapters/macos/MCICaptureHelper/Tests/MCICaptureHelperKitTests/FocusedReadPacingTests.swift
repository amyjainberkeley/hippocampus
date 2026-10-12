import CoreGraphics
import XCTest
@testable import MCICaptureHelperKit

final class FocusedReadPacingTests: XCTestCase {
    private let second: UInt64 = 1_000_000

    func testAStillWindowIsReadWheneverItChangesThreeSecondsApart() {
        var pacing = FocusedReadPacing()
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 100 * second, textCatchUp: false))
        XCTAssertFalse(pacing.admit(generation: 1, nowUs: 101 * second, textCatchUp: false))
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 110 * second, textCatchUp: false))
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 130 * second, textCatchUp: false))
        XCTAssertFalse(pacing.isInMotion)
    }

    func testAPlayingVideoIsReadEveryFifteenSecondsOnceItKeepsMoving() {
        for frameGap: UInt64 in [second / 2, 2 * second] {
            var pacing = FocusedReadPacing()
            var reads: [UInt64] = []
            for tick in 0..<(120 * second / frameGap) {
                let now = 1_000 * second + tick * frameGap
                if pacing.admit(generation: 7, nowUs: now, textCatchUp: false) { reads.append(now) }
            }
            XCTAssertTrue(pacing.isInMotion, "frames every \(frameGap) us")
            XCTAssertLessThanOrEqual(reads.count, 14, "\(reads.count) reads in two minutes of video")
        }
    }

    func testANewWindowIsReadAtOnceAndTypingKeepsItsOwnFloor() {
        var pacing = FocusedReadPacing()
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 0, textCatchUp: false))
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 1, textCatchUp: true), "typing catch-up has its own 3 s floor upstream")
        XCTAssertTrue(pacing.admit(generation: 2, nowUs: 2, textCatchUp: false), "switching windows reads now")
    }

    func testChangeInsideTheFocusedWindowDoesNotWakeTheDisplayRead() {
        let width = 10, height = 10
        let before = TextChangeThumbnail(width: width, height: height, luma: [UInt8](repeating: 0, count: 100))
        var luma = [UInt8](repeating: 0, count: 100)
        for y in 2..<6 { for x in 2..<6 { luma[y * width + x] = 200 } }
        let after = TextChangeThumbnail(width: width, height: height, luma: luma)
        XCTAssertEqual(after.changedPixels(since: before), 16)
        XCTAssertEqual(after.changedPixels(since: before, excluding: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)), 0)
        XCTAssertEqual(after.changedPixels(since: before, excluding: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.4)), 8)
    }
}
