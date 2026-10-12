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

    func testTextThatKeepsStreamingSlowsToTheMotionIntervalAndRecoversWhenItSettles() {
        // (interval scale, seconds between catch-up candidates, reads allowed in two minutes)
        for (scale, gap, limit) in [(UInt64(1), UInt64(3), 12), (2, 6, 8)] {
            var pacing = FocusedReadPacing()
            var reads: [UInt64] = []
            for now in stride(from: UInt64(0), through: 120, by: Int(gap)) {
                if pacing.admit(generation: 3, nowUs: (1_000 + now) * second, textCatchUp: true, scale: scale) {
                    reads.append(now)
                }
            }
            XCTAssertTrue(pacing.isInMotion, "scale \(scale)")
            XCTAssertEqual(reads.count, limit, "scale \(scale): read at \(reads)")
            XCTAssertEqual(Array(reads.prefix(5)), [0, gap, 2 * gap, 3 * gap, 4 * gap], "the first reads are not delayed")
            // The answer finished. The next edit, minutes later, is read at once.
            XCTAssertTrue(pacing.admit(generation: 3, nowUs: (1_000 + 400) * second, textCatchUp: true, scale: scale))
            XCTAssertFalse(pacing.isInMotion)
        }
    }

    func testOccasionalTypingNeverCountsAsStreaming() {
        var pacing = FocusedReadPacing()
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 0, textCatchUp: false))
        for burst in 1...20 {
            XCTAssertTrue(pacing.admit(generation: 1, nowUs: UInt64(burst) * 10 * second, textCatchUp: true))
            XCTAssertFalse(pacing.isInMotion)
        }
    }

    func testOnBatteryTheReaderRestsEightTimesAsLongAsARead() {
        var budget = ReadBudget()
        XCTAssertTrue(budget.admits(nowUs: 0, scale: 2))
        // A four-second read that ended at t = 10 s.
        budget.record(endedUs: 10 * second, tookUs: 4 * second, scale: 2)
        XCTAssertFalse(budget.admits(nowUs: 20 * second, scale: 2))
        XCTAssertFalse(budget.admits(nowUs: 41 * second, scale: 2))
        XCTAssertTrue(budget.admits(nowUs: 42 * second, scale: 2))
        // A quick re-read barely rests at all.
        budget.record(endedUs: 50 * second, tookUs: second / 2, scale: 2)
        XCTAssertTrue(budget.admits(nowUs: 54 * second, scale: 2))
    }

    func testTheReaderIsBusyAtMostANinthOfTheTimeOnBattery() {
        var budget = ReadBudget()
        var now: UInt64 = 0, busy: UInt64 = 0
        let horizon = 600 * second
        while now < horizon {
            if budget.admits(nowUs: now, scale: 2) {
                let took = 3 * second
                now += took; busy += took
                budget.record(endedUs: now, tookUs: took, scale: 2)
            } else {
                now += second / 4
            }
        }
        XCTAssertLessThanOrEqual(Double(busy) / Double(now), 1.0 / 9.0 + 0.01)
    }

    func testPluggedInThereIsNoRestAndPluggingInEndsOne() {
        var budget = ReadBudget()
        budget.record(endedUs: 10 * second, tookUs: 5 * second, scale: 1)
        XCTAssertTrue(budget.admits(nowUs: 10 * second, scale: 1))
        budget.record(endedUs: 20 * second, tookUs: 5 * second, scale: 2)
        XCTAssertFalse(budget.admits(nowUs: 30 * second, scale: 2))
        XCTAssertTrue(budget.admits(nowUs: 30 * second, scale: 1), "plugged in mid-rest")
    }

    func testLowPowerModeRestsLongerAndATimedOutReadCannotSilenceTheReaderForLong() {
        var budget = ReadBudget()
        budget.record(endedUs: 0, tookUs: 2 * second, scale: 4)
        XCTAssertFalse(budget.admits(nowUs: 31 * second, scale: 4))
        XCTAssertTrue(budget.admits(nowUs: 32 * second, scale: 4))
        budget.record(endedUs: 100 * second, tookUs: 30 * second, scale: 2)
        XCTAssertTrue(budget.admits(nowUs: 220 * second, scale: 2))
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

    func testOnBatteryReadsAreSpacedTwiceAsFar() {
        var pacing = FocusedReadPacing()
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 0, textCatchUp: false, scale: 2))
        XCTAssertFalse(pacing.admit(generation: 1, nowUs: 4 * second, textCatchUp: false, scale: 2))
        XCTAssertFalse(pacing.admit(generation: 1, nowUs: 4 * second + 1, textCatchUp: true, scale: 2), "typing waits too")
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 7 * second, textCatchUp: true, scale: 2))
    }

    func testTheChangedAreaIsFoundOutsideTheFocusedWindow() {
        let before = TextChangeThumbnail(width: 10, height: 10, luma: [UInt8](repeating: 0, count: 100))
        var luma = [UInt8](repeating: 0, count: 100)
        luma[2 * 10 + 2] = 200; luma[8 * 10 + 7] = 200
        let after = TextChangeThumbnail(width: 10, height: 10, luma: luma)
        let bounds = after.changedBounds(since: before, excluding: nil)
        XCTAssertEqual(bounds, CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.7))
        XCTAssertEqual(after.changedBounds(since: before, excluding: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                       CGRect(x: 0.7, y: 0.8, width: 0.1, height: 0.1))
        XCTAssertNil(before.changedBounds(since: before, excluding: nil))
    }
}
