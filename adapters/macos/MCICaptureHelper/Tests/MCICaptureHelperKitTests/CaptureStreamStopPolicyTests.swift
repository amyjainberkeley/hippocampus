import Foundation
import ScreenCaptureKit
import XCTest
@testable import MCICaptureHelperKit

final class CaptureStreamStopPolicyTests: XCTestCase {
    func testExplicitMacOSStopCannotUseTheAutomaticRetryExit() {
        let error = NSError(domain: SCStreamErrorDomain, code: -3817)
        let failure = CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: true)
        XCTAssertEqual(failure?.helperExitStatus, 82)
    }

    func testRetiredStreamCallbackCannotTerminateItsReplacement() {
        let error = NSError(domain: SCStreamErrorDomain, code: -3805)
        XCTAssertNil(CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: false))
    }

    func testExplicitUserStopWinsWhenWindowReplacementRacesItsCallback() {
        XCTAssertEqual(CaptureRuntimeFailure.forStreamStop(
            NSError(domain: SCStreamErrorDomain, code: -3817), sourceIsLive: false
        )?.helperExitStatus, 82)
    }

    func testCurrentStreamLossStillRequiresOwnerVisibleFailure() {
        let error = NSError(domain: SCStreamErrorDomain, code: -3805)
        XCTAssertEqual(
            CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: true)?.helperExitStatus,
            81
        )
    }

    func testForeignErrorDomainCannotImpersonateExplicitMacOSStop() {
        let error = NSError(domain: "SyntheticTransportError", code: -3817)
        XCTAssertEqual(
            CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: true)?.helperExitStatus,
            81
        )
    }
}
