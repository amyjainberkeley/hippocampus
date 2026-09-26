import XCTest
@testable import MCICaptureHelperKit

final class CaptureActivityScheduleTests: XCTestCase {
    func testQuietInputStillSamplesEveryTenSeconds() {
        let schedule = CaptureActivitySchedule()
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: true, focusGeneration: 1, now: 1))
        XCTAssertFalse(schedule.shouldProcess(inputQuiet: true, focusGeneration: 1, now: 10_000_000_000))
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: true, focusGeneration: 1, now: 10_000_000_001))
    }

    func testNewWindowAndResumedInputNeverWaitForQuietCadence() {
        let schedule = CaptureActivitySchedule()
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: true, focusGeneration: 1, now: 1))
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: true, focusGeneration: 2, now: 2))
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: false, focusGeneration: 2, now: 3))
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: false, focusGeneration: 2, now: 4))
    }

    func testBackwardClockCannotUnderflowOrFreezeSampling() {
        let schedule = CaptureActivitySchedule()
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: true, focusGeneration: nil, now: 100))
        XCTAssertTrue(schedule.shouldProcess(inputQuiet: true, focusGeneration: nil, now: 1))
        XCTAssertFalse(schedule.shouldProcess(inputQuiet: true, focusGeneration: nil, now: 2))
    }
}
