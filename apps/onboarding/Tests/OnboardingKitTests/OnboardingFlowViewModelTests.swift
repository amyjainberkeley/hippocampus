import XCTest
@testable import OnboardingKit

/// The four screens: their order, the moves between them, and what the
/// resume file keeps. Consent itself is `ConsentGateTests`; the permission
/// rows are `PermissionRowStateTests`.
@MainActor
final class OnboardingFlowViewModelTests: XCTestCase {
    private func makeVM(
        screenRecording: TCCStatus = .granted,
        accessibility: TCCStatus = .granted,
        consent: InMemoryOnboardingConsentStore = InMemoryOnboardingConsentStore(),
        stateStore: InMemoryOnboardingStateStore = InMemoryOnboardingStateStore(),
        at screen: OnboardingScreen? = nil
    ) -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: screenRecording),
            accessibility: StubTCCPermission(kind: .accessibility, status: accessibility),
            stateStore: stateStore,
            consentStore: consent,
            initialScreen: screen
        )
    }

    func testThereAreFourScreensInThisOrder() {
        XCTAssertEqual(OnboardingScreen.allCases, [.welcome, .permissions, .promise, .tryIt])
        XCTAssertEqual(OnboardingScreen.allCases.count, 4)
        XCTAssertEqual(OnboardingScreen.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    func testAFreshRunStartsAtWelcome() {
        XCTAssertEqual(makeVM().screen, .welcome)
    }

    func testAFirstRunTakesThreeStepsAndTheThirdIsConsent() async {
        let consent = InMemoryOnboardingConsentStore()
        let vm = makeVM(consent: consent)
        vm.advance()
        XCTAssertEqual(vm.screen, .permissions)
        vm.advance()
        XCTAssertEqual(vm.screen, .promise)
        vm.advance()
        XCTAssertEqual(vm.screen, .promise, "Continue does not pass Promise on a first run")
        await vm.startRemembering(keyReady: true)
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertEqual(consent.writeCount, 1)
    }

    func testWelcomeAlwaysContinuesAndPermissionsOnlyWithBoth() {
        XCTAssertTrue(makeVM(screenRecording: .notRequested, accessibility: .denied).canAdvance)
        for (sr, ax) in [(TCCStatus.notRequested, TCCStatus.granted), (.granted, .denied), (.denied, .notRequested)] {
            let vm = makeVM(screenRecording: sr, accessibility: ax, at: .permissions)
            XCTAssertFalse(vm.canAdvance)
            vm.advance()
            XCTAssertEqual(vm.screen, .permissions)
        }
        XCTAssertTrue(makeVM(at: .permissions).canAdvance)
    }

    func testTryItIsTheEnd() {
        let vm = makeVM(consent: InMemoryOnboardingConsentStore(given: true), at: .tryIt)
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertFalse(vm.canAdvance)
        vm.advance()
        XCTAssertEqual(vm.screen, .tryIt)
    }

    func testBackIsOnPermissionsAndPromiseOnly() {
        let consent = InMemoryOnboardingConsentStore(given: true)
        XCTAssertFalse(makeVM(at: .welcome).canGoBack)
        XCTAssertFalse(makeVM(consent: consent, at: .tryIt).canGoBack)

        let vm = makeVM(at: .promise)
        XCTAssertTrue(vm.canGoBack)
        vm.back()
        XCTAssertEqual(vm.screen, .permissions)
        XCTAssertTrue(vm.canGoBack)
        vm.back()
        XCTAssertEqual(vm.screen, .welcome)
        vm.back()
        XCTAssertEqual(vm.screen, .welcome)

        let done = makeVM(consent: consent, at: .tryIt)
        done.back()
        XCTAssertEqual(done.screen, .tryIt, "Try it has no Back")
    }

    func testEveryMoveIsSavedByRouteName() {
        let store = InMemoryOnboardingStateStore()
        let vm = makeVM(stateStore: store)
        vm.advance()
        XCTAssertEqual(store.loadRoute(), "permissions")
        vm.advance()
        XCTAssertEqual(store.loadRoute(), "promise")
        vm.back()
        XCTAssertEqual(store.loadRoute(), "permissions")
        vm.clearResumeState()
        XCTAssertNil(store.loadRoute())
    }

    func testSetupResumesAtTheSavedScreenWithinTheClamp() {
        for screen in [OnboardingScreen.welcome, .permissions, .promise] {
            let vm = makeVM(stateStore: InMemoryOnboardingStateStore(route: screen.routeName))
            XCTAssertEqual(vm.screen, screen, screen.routeName)
        }
        XCTAssertEqual(makeVM(stateStore: InMemoryOnboardingStateStore(route: "try-it")).screen, .promise,
                       "Try it needs consent")
        let firstRun = makeVM(screenRecording: .denied, stateStore: InMemoryOnboardingStateStore(route: "try-it"))
        XCTAssertEqual(firstRun.screen, .permissions, "Try it needs consent, Promise both permissions")
    }

    func testAfterConsentNoResumePointIsReadOrWritten() {
        // Only a file left over from before consent, or by an older build,
        // could be there; setup shown again starts at Welcome.
        for screen in OnboardingScreen.allCases {
            let store = InMemoryOnboardingStateStore(route: screen.routeName)
            let vm = makeVM(consent: InMemoryOnboardingConsentStore(given: true), stateStore: store)
            XCTAssertEqual(vm.screen, .welcome, screen.routeName)
            XCTAssertNil(store.loadRoute(), "the left-over point is removed")
            vm.advance()
            XCTAssertNil(store.loadRoute())
        }
    }

    func testALaunchScreenWinsOverTheResumeFileAndIsClampedTheSameWay() {
        let store = InMemoryOnboardingStateStore(route: "promise")
        XCTAssertEqual(makeVM(stateStore: store, at: .welcome).screen, .welcome)
        XCTAssertEqual(makeVM(stateStore: store, at: .tryIt).screen, .promise)
    }

    func testReviewIsKnownFromTheConsentFileAtStart() {
        XCTAssertFalse(makeVM().isReview)
        XCTAssertTrue(makeVM(consent: InMemoryOnboardingConsentStore(given: true)).isReview)
    }

    func testAllowAsksMacOSAndNothingElse() {
        let sr = StubTCCPermission(kind: .screenRecording)
        let ax = StubTCCPermission(kind: .accessibility)
        let vm = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, initialScreen: .permissions)
        vm.requestPermission(.accessibility)
        XCTAssertEqual(ax.promptCallCount, 1)
        XCTAssertEqual(ax.openSettingsCallCount, 0)
        XCTAssertEqual(sr.promptCallCount, 0)
    }
}
