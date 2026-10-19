import XCTest

@testable import HippocampusKit

@MainActor
final class CapturePreferenceControllerTests: XCTestCase {
    private enum TestError: Error {
        case applyFailed
    }

    private final class FakeApplier: CaptureSettingApplying {
        var captureEnabled: Bool
        var requestedValues: [Bool] = []
        private(set) var turnOnPresses = 0
        var appliedStateBeforeError: Bool?
        var error: Error?

        init(captureEnabled: Bool) {
            self.captureEnabled = captureEnabled
        }

        func turnOn() {
            turnOnPresses += 1
        }

        func applyCaptureEnabled(_ enabled: Bool) async throws {
            requestedValues.append(enabled)
            if let appliedStateBeforeError {
                captureEnabled = appliedStateBeforeError
            }
            if let error {
                throw error
            }
            captureEnabled = enabled
        }
    }

    func test_success_reflects_supervisor_state_after_enforcement() async {
        let applier = FakeApplier(captureEnabled: true)
        let controller = CapturePreferenceController(applier: applier)

        await controller.setCaptureEnabled(false)

        XCTAssertFalse(controller.captureEnabled)
        XCTAssertEqual(applier.requestedValues, [false])
    }

    /// A turn-off that failed leaves the state the supervisor enforced; the
    /// status row says "Couldn’t stop", so the switch adds no words.
    func test_failure_keeps_previous_state_when_supervisor_did_not_apply_change() async {
        let applier = FakeApplier(captureEnabled: true)
        applier.error = TestError.applyFailed
        let controller = CapturePreferenceController(applier: applier)

        await controller.setCaptureEnabled(false)

        XCTAssertTrue(controller.captureEnabled)
        XCTAssertFalse(controller.isApplying)
    }

    /// Switching on is the menu's Turn On: it waits out a change under way
    /// instead of cancelling it, and says why in the status row if it does
    /// not take.
    func test_switching_on_presses_turn_on() async {
        let applier = FakeApplier(captureEnabled: false)
        let controller = CapturePreferenceController(applier: applier)

        await controller.setCaptureEnabled(true)

        XCTAssertEqual(applier.turnOnPresses, 1)
        XCTAssertEqual(applier.requestedValues, [], "never the change that refuses during a start")
        XCTAssertFalse(controller.captureEnabled, "on once it has landed")
        XCTAssertFalse(controller.isApplying)
    }
}
