import XCTest
@testable import OnboardingKit

@MainActor
final class ConsentGateTests: XCTestCase {
    private func makeVM(
        screenRecording: TCCStatus = .granted,
        accessibility: TCCStatus = .granted,
        consent: InMemoryOnboardingConsentStore = InMemoryOnboardingConsentStore(),
        stateStore: InMemoryOnboardingStateStore = InMemoryOnboardingStateStore(),
        clock: TestClock = TestClock(),
        at screen: OnboardingScreen? = .promise
    ) -> FourScreenFlowViewModel {
        FourScreenFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: screenRecording),
            accessibility: StubTCCPermission(kind: .accessibility, status: accessibility),
            stateStore: stateStore,
            consentStore: consent,
            now: { clock.now },
            initialScreen: screen
        )
    }

    func testOnlyStartRememberingRecordsConsentAndOpensTryIt() async {
        let consent = InMemoryOnboardingConsentStore()
        let clock = TestClock()
        let vm = makeVM(consent: consent, clock: clock)
        XCTAssertEqual(vm.screen, .promise)
        XCTAssertFalse(vm.isReview)

        XCTAssertFalse(vm.canAdvance)
        vm.advance()
        vm.goTo(.tryIt)
        XCTAssertEqual(vm.screen, .promise, "nothing but Start Remembering passes Promise on a first run")
        XCTAssertEqual(consent.writeCount, 0)

        let started = await vm.startRemembering(keyReady: true, openAtLogin: true)
        XCTAssertTrue(started)
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertEqual(consent.writeCount, 1)
        XCTAssertEqual(consent.openAtLogin, true)
        XCTAssertEqual(vm.consentGivenAtUs, UInt64(clock.now.timeIntervalSince1970 * 1_000_000))
        XCTAssertFalse(vm.canGoBack, "Try it has no Back")
    }

    func testTheOpenAtLoginChoiceIsRecordedWithConsent() async {
        let consent = InMemoryOnboardingConsentStore()
        let vm = makeVM(consent: consent)
        await vm.startRemembering(keyReady: true, openAtLogin: false)
        XCTAssertEqual(consent.openAtLogin, false)
    }

    func testStartRememberingRefusesWithoutBothPermissions() async {
        for (sr, ax) in [(TCCStatus.notRequested, TCCStatus.granted), (.granted, .denied)] {
            let consent = InMemoryOnboardingConsentStore()
            let vm = makeVM(screenRecording: sr, accessibility: ax, consent: consent)
            XCTAssertEqual(vm.screen, .permissions, "Promise needs both permissions")
            let started = await vm.startRemembering(keyReady: true, openAtLogin: true)
            XCTAssertFalse(started)
            XCTAssertEqual(consent.writeCount, 0)
            XCTAssertNotEqual(vm.screen, .tryIt)
        }
    }

    func testStartRememberingRefusesUntilTheKeyIsReady() async {
        let consent = InMemoryOnboardingConsentStore()
        let vm = makeVM(consent: consent)
        let started = await vm.startRemembering(keyReady: false, openAtLogin: true)
        XCTAssertFalse(started)
        XCTAssertEqual(vm.screen, .promise)
        XCTAssertEqual(consent.writeCount, 0)
    }

    func testStartRememberingRefusesAwayFromPromise() async {
        let consent = InMemoryOnboardingConsentStore()
        let vm = makeVM(consent: consent, at: .welcome)
        let started = await vm.startRemembering(keyReady: true, openAtLogin: true)
        XCTAssertFalse(started)
        XCTAssertEqual(vm.screen, .welcome)
        XCTAssertEqual(consent.writeCount, 0)
    }

    func testAFailedWriteStaysOnPromiseAndSaysSo() async {
        let consent = InMemoryOnboardingConsentStore()
        consent.failWrites(with: DiskFull())
        let vm = makeVM(consent: consent)
        let started = await vm.startRemembering(keyReady: true, openAtLogin: true)
        XCTAssertFalse(started)
        XCTAssertEqual(vm.screen, .promise)
        XCTAssertEqual(vm.consentFailure, .notSaved)
        XCTAssertNil(vm.consentGivenAtUs)
        vm.dismissConsentFailure()
        XCTAssertNil(vm.consentFailure)
    }

    func testTryItNeedsConsentAndPromiseNeedsBothPermissions() {
        XCTAssertEqual(makeVM(at: .tryIt).screen, .promise)
        XCTAssertEqual(makeVM(screenRecording: .denied, at: .tryIt).screen, .permissions)
        XCTAssertEqual(makeVM(accessibility: .notRequested, at: .promise).screen, .permissions)
        XCTAssertEqual(
            makeVM(consent: InMemoryOnboardingConsentStore(given: true), at: .tryIt).screen, .tryIt
        )
        XCTAssertEqual(makeVM(screenRecording: .denied, at: .welcome).screen, .welcome)
    }

    func testTheResumeFileIsClampedTheSameWay() {
        let state = InMemoryOnboardingStateStore(route: "try-it")
        let vm = makeVM(stateStore: state, at: nil)
        XCTAssertEqual(vm.screen, .promise)

        let old = InMemoryOnboardingStateStore(initial: .retention)
        XCTAssertEqual(makeVM(stateStore: old, at: nil).screen, .welcome, "a retired step starts at Welcome")
    }

    func testJumpsAreClampedAndSaved() {
        let state = InMemoryOnboardingStateStore()
        let vm = makeVM(screenRecording: .notRequested, stateStore: state, at: .welcome)
        vm.goTo(.tryIt)
        XCTAssertEqual(vm.screen, .permissions)
        XCTAssertEqual(state.loadRoute(), "permissions")
        XCTAssertFalse(vm.canAdvance, "Permissions needs both permissions")
        vm.back()
        XCTAssertEqual(vm.screen, .welcome)
        XCTAssertFalse(vm.canGoBack)
    }

    func testReviewModeContinuesPastPromiseWithoutWritingAgain() {
        let consent = InMemoryOnboardingConsentStore(given: true)
        let vm = makeVM(consent: consent)
        XCTAssertTrue(vm.isReview)
        XCTAssertTrue(vm.canAdvance)
        vm.advance()
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertEqual(consent.writeCount, 0)
    }

    // MARK: - The consent file

    func testTheConsentFileCarriesTheOpenAtLoginChoiceAndIsWrittenOnce() throws {
        let url = try temporaryDirectory().appendingPathComponent("MCI/.onboarding-complete")
        let store = FileOnboardingConsentStore(url: url, now: { Date(timeIntervalSince1970: 1_791_234_567) })
        XCTAssertFalse(store.isGiven)
        try store.give(openAtLogin: true)
        XCTAssertTrue(store.isGiven)
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(body, "onboarding-completed-at 2026-10-05T21:09:27Z\nopen-at-login yes\n")

        try store.give(openAtLogin: false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), body, "a second run keeps the first answer")
    }

    func testTheConsentFileIsTheAppsSentinel() {
        XCTAssertTrue(FileOnboardingConsentStore.defaultURL.path
            .hasSuffix("Library/Application Support/MCI/.onboarding-complete"))
        XCTAssertEqual(
            FileOnboardingConsentStore.body(at: Date(timeIntervalSince1970: 0), openAtLogin: false),
            "onboarding-completed-at 1970-01-01T00:00:00Z\nopen-at-login no\n"
        )
    }

    func testTheOldFlowWritesConsentThroughTheStore() throws {
        let flow = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/OnboardingFlowView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(flow.contains("try FileOnboardingConsentStore().give(openAtLogin: false)"))
        XCTAssertTrue(flow.contains("await flowVM.refreshPermissionsAsync()"))
        XCTAssertFalse(flow.contains(".onboarding-complete"), "one writer of the consent file")
    }
}
