#if canImport(AppKit)
import XCTest
@testable import OnboardingKit

@MainActor
final class ScreenRecordingPermissionTests: XCTestCase {
    func testTheQuickCheckNeverTurnsScreenRecordingOff() {
        let fixture = ScreenRecordingFixture(inProcess: true, freshProcessSays: nil)
        XCTAssertEqual(fixture.permission.status, .granted)
        fixture.inProcess = false
        XCTAssertEqual(fixture.permission.checkCurrent(), .granted)
    }

    func testTheAsyncCheckTurnsItOffWhenThisProcessSaysNo() async {
        let fixture = ScreenRecordingFixture(inProcess: true, freshProcessSays: nil)
        fixture.inProcess = false
        let status = await fixture.permission.checkCurrentAsync(outOfProcess: false)
        XCTAssertEqual(status, .denied)
    }

    func testAFreshProcessCanTurnItOnAndThatHoldsForTheSession() async {
        let fixture = ScreenRecordingFixture(inProcess: false, freshProcessSays: true)
        var status = await fixture.permission.checkCurrentAsync(outOfProcess: false)
        XCTAssertEqual(status, .notRequested)
        XCTAssertEqual(fixture.probe.calls, 0, "a fresh process is asked only when allowed")

        status = await fixture.permission.checkCurrentAsync(outOfProcess: true)
        XCTAssertEqual(status, .granted)
        XCTAssertTrue(fixture.permission.grantLatched)
        XCTAssertEqual(fixture.permission.checkCurrent(), .granted)
        status = await fixture.permission.checkCurrentAsync(outOfProcess: false)
        XCTAssertEqual(status, .granted, "only this process's stale no is left; it cannot undo the grant")
        status = await fixture.permission.checkCurrentAsync(outOfProcess: true)
        XCTAssertEqual(fixture.probe.calls, 1, "a latched grant starts no more processes")
    }

    func testAFreshProcessNeverTurnsItOff() async {
        for answer in [false, nil] as [Bool?] {
            let fixture = ScreenRecordingFixture(inProcess: false, freshProcessSays: answer)
            let status = await fixture.permission.checkCurrentAsync(outOfProcess: true)
            XCTAssertEqual(status, .notRequested, "\(String(describing: answer)) keeps the last status")
        }
    }

    func testTheAttemptIsRecordedUnderTheKeySetupAlwaysUsed() {
        XCTAssertEqual(DefaultsScreenRecordingAttempts.key, "MCITCCScreenRecordingAttempted")
        XCTAssertEqual(RealScreenRecordingPermission.tccAttemptedKey, DefaultsScreenRecordingAttempts.key)
    }

    func testAnEarlierAttemptStartsOffAsBefore() {
        let fixture = ScreenRecordingFixture(inProcess: false, freshProcessSays: nil, attempted: true)
        XCTAssertEqual(fixture.permission.status, .denied)
    }

    func testAllowAsksFromAFreshProcessOnceAndOpensThePaneEachTime() {
        let fixture = ScreenRecordingFixture(inProcess: false, freshProcessSays: nil)
        fixture.permission.requestOrOpenSettings()
        fixture.permission.requestOrOpenSettings()
        XCTAssertEqual(fixture.requester.requests, 1)
        XCTAssertEqual(fixture.panesOpened, ["Privacy_ScreenCapture", "Privacy_ScreenCapture"])
        XCTAssertTrue(fixture.attempts.attempted)
    }

    func testAllowWhenAlreadyOnAsksNothing() {
        let fixture = ScreenRecordingFixture(inProcess: true, freshProcessSays: nil)
        fixture.permission.requestOrOpenSettings()
        XCTAssertEqual(fixture.requester.requests, 0)
        XCTAssertTrue(fixture.panesOpened.isEmpty)
    }

    func testAskAgainResetsForgetsTheAttemptAsksAgainAndReturnsAtOnce() async {
        let fixture = ScreenRecordingFixture(inProcess: false, freshProcessSays: true, attempted: true)
        _ = await fixture.permission.checkCurrentAsync(outOfProcess: true)
        XCTAssertTrue(fixture.permission.grantLatched)

        let started = Date()
        await fixture.permission.askAgain()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the row's refresh does the waiting")
        XCTAssertEqual(fixture.resetter.resets, [["reset", "ScreenCapture", "ai.hippocampus"]])
        XCTAssertFalse(fixture.attempts.attempted)
        XCTAssertFalse(fixture.permission.grantLatched)
        XCTAssertEqual(fixture.permission.status, .notRequested)
        XCTAssertEqual(fixture.requester.requests, 1)
    }

    // MARK: - Accessibility

    func testOnlyTheAsyncCheckTurnsAccessibilityOff() async {
        let trusted = MainBox(true)
        let resetter = RecordingResetter()
        let panes = MainBox<[String]>([])
        let permission = RealAccessibilityPermission(
            isTrusted: { trusted.value },
            prompt: { trusted.value },
            resetter: resetter,
            openPane: { panes.value.append($0) }
        )
        XCTAssertEqual(permission.status, .granted)
        trusted.value = false
        XCTAssertEqual(permission.checkCurrent(), .granted)
        let status = await permission.checkCurrentAsync(outOfProcess: true)
        XCTAssertEqual(status, .denied)

        await permission.askAgain()
        XCTAssertEqual(resetter.resets, [["reset", "Accessibility", "ai.hippocampus"]])
        XCTAssertEqual(panes.value, ["Privacy_Accessibility"], "the prompt plus the pane, as Allow does")
    }
}
#endif
