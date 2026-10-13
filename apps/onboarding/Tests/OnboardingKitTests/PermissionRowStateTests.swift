import XCTest
@testable import OnboardingKit

@MainActor
final class PermissionRowStateTests: XCTestCase {
    private func makeVM(
        screenRecording: any TCCPermission,
        accessibility: any TCCPermission,
        clock: TestClock = TestClock(),
        consent: InMemoryOnboardingConsentStore = InMemoryOnboardingConsentStore()
    ) -> FourScreenFlowViewModel {
        FourScreenFlowViewModel(
            screenRecording: screenRecording,
            accessibility: accessibility,
            stateStore: InMemoryOnboardingStateStore(),
            consentStore: consent,
            now: { clock.now },
            initialScreen: .permissions
        )
    }

    func testRowsStartIdleOrOnAndAPermissionOffBeforeThisRunNeedsHelp() {
        let vm = makeVM(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .denied),
            accessibility: StubTCCPermission(kind: .accessibility, status: .notRequested)
        )
        XCTAssertEqual(vm.rowState(.screenRecording), .needsHelp)
        XCTAssertEqual(vm.rowState(.accessibility), .idle)

        let on = makeVM(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted)
        )
        XCTAssertEqual(on.rowState(.screenRecording), .granted)
        XCTAssertEqual(on.rowState(.accessibility), .granted)
        XCTAssertFalse(on.canRequest(.screenRecording))
    }

    func testAllowWaitsAndNoTimerEverMovesTheRow() async {
        let sr = StubTCCPermission(kind: .screenRecording)
        let clock = TestClock()
        let vm = makeVM(screenRecording: sr, accessibility: StubTCCPermission(kind: .accessibility), clock: clock)
        vm.requestPermission(.screenRecording)
        XCTAssertEqual(sr.openSettingsCallCount, 1, "Allow runs today's request")
        XCTAssertEqual(vm.rowState(.screenRecording), .waiting)
        for _ in 0..<10 {
            clock.advance(30)
            vm.refreshPermissions()
            await vm.refreshPermissionsAsync()
        }
        XCTAssertEqual(vm.rowState(.screenRecording), .waiting, "the person is in System Settings")
    }

    func testOnlyOneRowCanBeAskedAtATime() async {
        let vm = makeVM(
            screenRecording: StubTCCPermission(kind: .screenRecording),
            accessibility: StubTCCPermission(kind: .accessibility)
        )
        vm.requestPermission(.accessibility)
        XCTAssertFalse(vm.canRequest(.screenRecording))
        vm.requestPermission(.screenRecording)
        XCTAssertEqual(vm.rowState(.screenRecording), .idle, "its Allow is off while the other row waits")
        await vm.userReturned()
        XCTAssertTrue(vm.canRequest(.screenRecording))
    }

    func testOnReturnOneRefreshRunsBeforeTheRowDecides() async {
        let sr = HeldPermission(kind: .screenRecording)
        let vm = makeVM(screenRecording: sr, accessibility: StubTCCPermission(kind: .accessibility, status: .granted))
        vm.requestPermission(.screenRecording)
        sr.grantedOnNextAsyncCheck = true
        sr.holdNextAsyncCheck()

        let returning = Task { await vm.userReturned() }
        while !sr.isHeld { await Task.yield() }
        XCTAssertEqual(vm.rowState(.screenRecording), .waiting,
                       "no \"Not on yet.\" before the refresh has answered")
        sr.release()
        await returning.value

        XCTAssertEqual(vm.rowState(.screenRecording), .granted)
        XCTAssertFalse(vm.offersAskAgain(.screenRecording))
    }

    func testComingBackWithoutTheGrantNeedsHelpAndAskAgainFollowsTheSecondTry() async {
        let sr = StubTCCPermission(kind: .screenRecording)
        let vm = makeVM(screenRecording: sr, accessibility: StubTCCPermission(kind: .accessibility))
        vm.requestPermission(.screenRecording)
        await vm.userReturned()
        XCTAssertEqual(vm.rowState(.screenRecording), .needsHelp)
        XCTAssertFalse(vm.offersAskAgain(.screenRecording))

        vm.openSettings(.screenRecording)
        XCTAssertEqual(vm.rowState(.screenRecording), .waiting)
        await vm.userReturned()
        XCTAssertEqual(vm.rowState(.screenRecording), .needsHelp)
        XCTAssertTrue(vm.offersAskAgain(.screenRecording))

        await vm.askAgain(.screenRecording)
        XCTAssertEqual(sr.askAgainCallCount, 1)
        XCTAssertEqual(vm.rowState(.screenRecording), .waiting)
        sr.simulateGrant()
        await vm.userReturned()
        XCTAssertEqual(vm.rowState(.screenRecording), .granted)
        XCTAssertTrue(vm.bothGranted == false, "Accessibility is still off")
    }

    func testABothOnPermissionsScreenCanContinue() async {
        let sr = StubTCCPermission(kind: .screenRecording)
        let ax = StubTCCPermission(kind: .accessibility)
        let vm = makeVM(screenRecording: sr, accessibility: ax)
        XCTAssertFalse(vm.canAdvance)
        sr.simulateGrant()
        ax.simulateGrant()
        vm.refreshPermissions()
        XCTAssertTrue(vm.canAdvance)
        vm.advance()
        XCTAssertEqual(vm.screen, .promise)
    }

    // MARK: - Screen Recording seen by a fresh process (engineering finding 1)

    func testAGrantSeenByAFreshProcessSurvivesTheQuickRefreshAndConsent() async {
        let fixture = ScreenRecordingFixture(inProcess: false, freshProcessSays: true)
        defer { fixture.tearDown() }
        let consent = InMemoryOnboardingConsentStore()
        let vm = makeVM(
            screenRecording: fixture.permission,
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            consent: consent
        )
        vm.requestPermission(.screenRecording)
        await vm.userReturned()
        XCTAssertEqual(vm.rowState(.screenRecording), .granted, "the fresh process saw the grant")

        // This process still says no, as it does on the stale path.
        vm.refreshPermissions()
        XCTAssertEqual(vm.rowState(.screenRecording), .granted)
        vm.advance()
        XCTAssertEqual(vm.screen, .promise)

        let started = await vm.startRemembering(keyReady: true, openAtLogin: true)
        XCTAssertTrue(started)
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertEqual(fixture.permission.status, .granted)
        XCTAssertEqual(consent.writeCount, 1)
    }

    func testTheFreshProcessIsAskedOnlyWhileTheRowWaitsAndAtMostEveryTwoAndAHalfSeconds() async {
        let fixture = ScreenRecordingFixture(inProcess: false, freshProcessSays: false)
        defer { fixture.tearDown() }
        let clock = TestClock()
        let vm = makeVM(
            screenRecording: fixture.permission,
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            clock: clock
        )
        await vm.refreshPermissionsAsync()
        XCTAssertEqual(fixture.probe.calls, 0, "nothing was asked yet")

        vm.requestPermission(.screenRecording)
        await vm.refreshPermissionsAsync()
        XCTAssertEqual(fixture.probe.calls, 1)
        clock.advance(1)
        await vm.refreshPermissionsAsync()
        clock.advance(1)
        await vm.refreshPermissionsAsync()
        XCTAssertEqual(fixture.probe.calls, 1, "not again within 2.5 s")
        clock.advance(0.6)
        await vm.refreshPermissionsAsync()
        XCTAssertEqual(fixture.probe.calls, 2)

        // Back in this window: one more check decides the row.
        await vm.userReturned()
        XCTAssertEqual(fixture.probe.calls, 3)
        XCTAssertEqual(vm.rowState(.screenRecording), .needsHelp)
        clock.advance(10)
        await vm.refreshPermissionsAsync()
        XCTAssertEqual(fixture.probe.calls, 3, "no polling of a fresh process while nothing waits")

        // Once a fresh process says yes, no process is started again.
        fixture.probe.answer = true
        vm.openSettings(.screenRecording)
        clock.advance(3)
        await vm.refreshPermissionsAsync()
        XCTAssertEqual(fixture.probe.calls, 4)
        XCTAssertEqual(vm.rowState(.screenRecording), .granted)
        clock.advance(3)
        await vm.refreshPermissionsAsync()
        _ = await vm.startRemembering(keyReady: true, openAtLogin: true)
        XCTAssertEqual(fixture.probe.calls, 4)
    }
}
