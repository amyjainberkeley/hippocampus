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
        var appliedStateBeforeError: Bool?
        var error: Error?

        init(captureEnabled: Bool) {
            self.captureEnabled = captureEnabled
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
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(applier.requestedValues, [false])
    }

    func test_failure_keeps_previous_state_when_supervisor_did_not_apply_change() async {
        let applier = FakeApplier(captureEnabled: true)
        applier.error = TestError.applyFailed
        let controller = CapturePreferenceController(applier: applier)

        await controller.setCaptureEnabled(false)

        XCTAssertTrue(controller.captureEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }

    func test_restart_failure_reflects_fail_closed_state_instead_of_requested_state() async {
        let applier = FakeApplier(captureEnabled: false)
        applier.appliedStateBeforeError = false
        applier.error = TestError.applyFailed
        let controller = CapturePreferenceController(applier: applier)

        await controller.setCaptureEnabled(true)

        XCTAssertFalse(controller.captureEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }
}
