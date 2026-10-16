import XCTest
@testable import MCICaptureHelperKit

/// Pins the reading cadence that PRIVACY.md, the README and ADR-0041 state,
/// so the documents and the code cannot drift apart unnoticed.
final class CapturePowerTests: XCTestCase {
    func testOtherWindowsAreReadEveryThirtySecondsPluggedInSixtyOnBatteryAndNotInLowPowerMode() {
        XCTAssertEqual(CapturePowerMode.pluggedIn.displayReadInterval, 30)
        XCTAssertEqual(CapturePowerMode.battery.displayReadInterval, 60)
        XCTAssertNil(CapturePowerMode.lowPower.displayReadInterval)
    }

    func testTheWindowInFrontWaitsTwiceAsLongOnBatteryAndFourTimesInLowPowerMode() {
        XCTAssertEqual(CapturePowerMode.pluggedIn.intervalScale, 1)
        XCTAssertEqual(CapturePowerMode.battery.intervalScale, 2)
        XCTAssertEqual(CapturePowerMode.lowPower.intervalScale, 4)
        XCTAssertEqual(FocusedReadPacing.minimumIntervalUs, 3_000_000)
        XCTAssertEqual(FocusedReadPacing.motionIntervalUs, 15_000_000)
    }

    func testTheReaderRestsThreeEightOrSixteenTimesAsLongAsARead() {
        XCTAssertEqual(ReadBudget.restFactor(scale: CapturePowerMode.pluggedIn.intervalScale), 3)
        XCTAssertEqual(ReadBudget.restFactor(scale: CapturePowerMode.battery.intervalScale), 8)
        XCTAssertEqual(ReadBudget.restFactor(scale: CapturePowerMode.lowPower.intervalScale), 16)
    }

    func testADisplayIsNeverReadMoreOftenThanEveryFifteenSeconds() {
        XCTAssertEqual(BackgroundCaptureSession.minimumReadInterval, 15)
    }
}
