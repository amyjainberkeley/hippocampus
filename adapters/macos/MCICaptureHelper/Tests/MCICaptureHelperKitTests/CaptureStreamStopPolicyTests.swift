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

final class FocusRebindPolicyTests: XCTestCase {
    func testAClosedWindowIsNotAFailure() {
        let closed = NSError(domain: SCStreamErrorDomain, code: -3815)
        XCTAssertTrue(ClosedWindowBudget.isClosedWindow(closed))
        var budget = ClosedWindowBudget()
        XCTAssertTrue(budget.absorb(nowUs: 1_000_000))
    }

    func testOtherStopsAreNotMistakenForAClosedWindow() {
        for code in [-3805, -3811, -3817, -3821] {
            XCTAssertFalse(ClosedWindowBudget.isClosedWindow(NSError(domain: SCStreamErrorDomain, code: code)))
        }
        XCTAssertFalse(ClosedWindowBudget.isClosedWindow(NSError(domain: "SyntheticTransportError", code: -3815)))
    }

    func testClosedWindowStopsBackToBackAreStillAFailure() {
        var budget = ClosedWindowBudget()
        let absorbed = (0..<ClosedWindowBudget.limit).map { budget.absorb(nowUs: 1_000_000 + UInt64($0) * 300_000) }
        XCTAssertEqual(absorbed, Array(repeating: true, count: ClosedWindowBudget.limit - 1) + [false])
    }

    func testWindowsClosedMinutesApartNeverUseUpTheBudget() {
        var budget = ClosedWindowBudget()
        for close in 0..<50 {
            XCTAssertTrue(budget.absorb(nowUs: UInt64(close) * 60_000_000))
        }
    }

    func testStoppingAStreamThatAlreadyEndedIsNotAFailure() {
        XCTAssertTrue(ClosedWindowBudget.isAlreadyStopped(NSError(domain: SCStreamErrorDomain, code: -3808)))
        XCTAssertFalse(ClosedWindowBudget.isAlreadyStopped(NSError(domain: SCStreamErrorDomain, code: -3816)))
        XCTAssertFalse(ClosedWindowBudget.isAlreadyStopped(NSError(domain: "SyntheticTransportError", code: -3808)))
    }

    func testAWindowThatCannotBeBoundIsRetriedEveryTwoSecondsNotFiveTimesASecond() {
        var pacing = RebindRetryPacing()
        XCTAssertTrue(pacing.admit(generation: 7, nowUs: 0))
        pacing.record(generation: 7, installed: false, nowUs: 0)
        let polls = stride(from: UInt64(200_000), through: 10_000_000, by: 200_000)
        var attempts = 0
        for now in polls where pacing.admit(generation: 7, nowUs: now) {
            attempts += 1
            pacing.record(generation: 7, installed: false, nowUs: now)
        }
        XCTAssertEqual(attempts, 5)
    }

    func testANewFocusedWindowIsTriedAtOnce() {
        var pacing = RebindRetryPacing()
        pacing.record(generation: 7, installed: false, nowUs: 1_000_000)
        XCTAssertFalse(pacing.admit(generation: 7, nowUs: 1_200_000))
        XCTAssertTrue(pacing.admit(generation: 8, nowUs: 1_200_000))
    }

    func testABoundWindowClearsTheWait() {
        var pacing = RebindRetryPacing()
        pacing.record(generation: 7, installed: false, nowUs: 1_000_000)
        pacing.record(generation: 7, installed: true, nowUs: 1_100_000)
        XCTAssertTrue(pacing.admit(generation: 7, nowUs: 1_200_000))
    }
}
