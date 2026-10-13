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
    ) -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
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

        let started = await vm.startRemembering(keyReady: true)
        XCTAssertTrue(started)
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertEqual(consent.writeCount, 1)
        XCTAssertEqual(consent.openAtLogin, true)
        XCTAssertEqual(vm.consentGivenAtUs, UInt64(clock.now.timeIntervalSince1970 * 1_000_000))
        XCTAssertFalse(vm.canGoBack, "Try it has no Back")
    }

    func testOpenAtLoginIsOnUntilTurnedOffAndIsRecordedWithConsent() async {
        let on = InMemoryOnboardingConsentStore()
        let first = makeVM(consent: on)
        XCTAssertTrue(first.openAtLogin, "the checkbox starts on")
        await first.startRemembering(keyReady: true)
        XCTAssertEqual(on.openAtLogin, true)

        let off = InMemoryOnboardingConsentStore()
        let second = makeVM(consent: off)
        second.openAtLogin = false
        await second.startRemembering(keyReady: true)
        XCTAssertEqual(off.openAtLogin, false)
    }

    func testAClickWhileTheLastIsStillCheckedDoesNothing() async {
        let consent = InMemoryOnboardingConsentStore()
        let screenRecording = HeldPermission(kind: .screenRecording, status: .granted)
        let vm = OnboardingFlowViewModel(
            screenRecording: screenRecording,
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            consentStore: consent,
            initialScreen: .promise
        )
        XCTAssertEqual(vm.screen, .promise)

        screenRecording.holdNextAsyncCheck()
        let first = Task { await vm.startRemembering(keyReady: true) }
        while !screenRecording.isHeld { await Task.yield() }
        XCTAssertTrue(vm.isStartingRemembering, "the button is off while the click is checked")
        // A second click that went ahead would wait for the first one's
        // check; the deadline lets that failure show instead of hanging.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            screenRecording.release()
        }
        let second = await vm.startRemembering(keyReady: true)
        XCTAssertFalse(second)
        XCTAssertTrue(screenRecording.isHeld, "refused at once, without waiting for the first click's check")
        deadline.cancel()
        screenRecording.release()
        let started = await first.value
        XCTAssertTrue(started)
        XCTAssertFalse(vm.isStartingRemembering)
        XCTAssertEqual(consent.writeCount, 1)
    }

    func testStartRememberingRefusesWithoutBothPermissions() async {
        for (sr, ax) in [(TCCStatus.notRequested, TCCStatus.granted), (.granted, .denied)] {
            let consent = InMemoryOnboardingConsentStore()
            let vm = makeVM(screenRecording: sr, accessibility: ax, consent: consent)
            XCTAssertEqual(vm.screen, .permissions, "Promise needs both permissions")
            let started = await vm.startRemembering(keyReady: true)
            XCTAssertFalse(started)
            XCTAssertEqual(consent.writeCount, 0)
            XCTAssertNotEqual(vm.screen, .tryIt)
        }
    }

    func testAPermissionTurnedOffBeforeTheClickGoesBackToPermissions() async {
        let consent = InMemoryOnboardingConsentStore()
        let ax = LivePermission(kind: .accessibility, isOn: true)
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: ax,
            consentStore: consent,
            initialScreen: .promise
        )
        XCTAssertEqual(vm.screen, .promise)
        // Turned off in System Settings while Promise showed. Nothing on
        // Promise looks, so the button still looked ready.
        ax.isOn = false
        XCTAssertEqual(vm.accessibilityPermission.status, .granted)

        let started = await vm.startRemembering(keyReady: true)
        XCTAssertFalse(started)
        XCTAssertEqual(consent.writeCount, 0)
        XCTAssertEqual(vm.screen, .permissions, "back where the row says what to do")
        XCTAssertEqual(vm.rowState(.accessibility), .needsHelp)
        XCTAssertNil(vm.consentFailure, "nothing failed to save")
    }

    func testScreenRecordingTurnedOffBeforeTheClickGoesBackToPermissions() async {
        // The real Screen Recording permission: this process and a fresh
        // one both say no now.
        let sr = ScreenRecordingFixture(inProcess: true, freshProcessSays: true)
        let vm = OnboardingFlowViewModel(
            screenRecording: sr.permission,
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            initialScreen: .promise
        )
        XCTAssertEqual(vm.screen, .promise)
        sr.inProcess = false
        sr.probe.answer = false

        let started = await vm.startRemembering(keyReady: true)
        XCTAssertFalse(started)
        XCTAssertEqual(vm.screen, .permissions)
        XCTAssertEqual(vm.rowState(.screenRecording), .needsHelp)
    }

    func testStartRememberingRefusesUntilTheKeyIsReady() async {
        let consent = InMemoryOnboardingConsentStore()
        let vm = makeVM(consent: consent)
        let started = await vm.startRemembering(keyReady: false)
        XCTAssertFalse(started)
        XCTAssertEqual(vm.screen, .promise)
        XCTAssertEqual(consent.writeCount, 0)
    }

    func testStartRememberingRefusesAwayFromPromise() async {
        let consent = InMemoryOnboardingConsentStore()
        let vm = makeVM(consent: consent, at: .welcome)
        let started = await vm.startRemembering(keyReady: true)
        XCTAssertFalse(started)
        XCTAssertEqual(vm.screen, .welcome)
        XCTAssertEqual(consent.writeCount, 0)
    }

    func testAFailedWriteStaysOnPromiseAndSaysSo() async {
        let consent = InMemoryOnboardingConsentStore()
        consent.failWrites(with: DiskFull())
        let vm = makeVM(consent: consent)
        let started = await vm.startRemembering(keyReady: true)
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

        let old = InMemoryOnboardingStateStore(route: "retention")
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

    // MARK: - After consent

    func testConsentClearsTheResumePointSoSetupShownAgainStartsAtWelcome() async {
        let consent = InMemoryOnboardingConsentStore()
        let state = InMemoryOnboardingStateStore()
        let vm = makeVM(consent: consent, stateStore: state)
        vm.back()
        vm.advance()
        XCTAssertEqual(state.loadRoute(), "promise", "before consent a quit resumes here")

        await vm.startRemembering(keyReady: true)
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertNil(state.loadRoute(), "closing Try it leaves nothing to come back to")

        // Show Setup Again, over a file an older build left on Try it,
        // which has no Back.
        let leftOver = InMemoryOnboardingStateStore(route: "try-it")
        let again = makeVM(consent: consent, stateStore: leftOver, at: nil)
        XCTAssertTrue(again.isReview)
        XCTAssertEqual(again.screen, .welcome)
        XCTAssertNil(leftOver.loadRoute())
        again.advance()
        again.advance()
        XCTAssertEqual(again.screen, .promise)
        XCTAssertNil(leftOver.loadRoute(), "a review keeps no place")

        // A route the app names still opens that screen.
        XCTAssertEqual(makeVM(consent: consent, stateStore: leftOver, at: .permissions).screen, .permissions)
    }

    func testAFirstRunTryItIsRememberingWhateverTheAppSaidAtSpawn() async {
        let off = [RememberingState.environmentKey: "off"]
        let paused = [RememberingState.environmentKey: "paused"]
        // The app opened setup before consent, when it was not remembering.
        let vm = makeVM()
        await vm.startRemembering(keyReady: true)
        XCTAssertEqual(vm.screen, .tryIt)
        XCTAssertEqual(vm.rememberingForTryIt(environment: off), .on, "the consent click started it")
        XCTAssertEqual(vm.rememberingForTryIt(environment: paused), .on)

        // In review, the app's state when it opened setup is what counts.
        let review = makeVM(consent: InMemoryOnboardingConsentStore(given: true), at: .tryIt)
        XCTAssertEqual(review.rememberingForTryIt(environment: off), .off)
        XCTAssertEqual(review.rememberingForTryIt(environment: paused), .paused)
        XCTAssertEqual(review.rememberingForTryIt(environment: [:]), .on)
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

    // MARK: - One writer, one click

    /// Source lines, without comments, of every Swift file in `Sources`.
    private func sourceCode() throws -> [(path: String, lines: [String])] {
        let root = onboardingPackageRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                let lines = try String(contentsOf: url, encoding: .utf8)
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                return (String(url.path.dropFirst(root.path.count + 1)), lines)
            }
    }

    func testTheSentinelIsWrittenOnlyByTheConsentClick() throws {
        let code = try sourceCode()
        func files(containing needle: String) -> [String] {
            code.filter { $0.lines.contains { $0.contains(needle) } }.map(\.path).sorted()
        }
        // The file itself: only the consent store names it and writes it.
        XCTAssertEqual(files(containing: ".onboarding-complete"), ["OnboardingKit/OnboardingConsentStore.swift"])
        // Recording consent: only the view model's Start Remembering calls the store.
        XCTAssertEqual(files(containing: ".give(openAtLogin:"), ["OnboardingKit/OnboardingFlowViewModel.swift"])
        let model = try XCTUnwrap(code.first { $0.path == "OnboardingKit/OnboardingFlowViewModel.swift" })
        let gives = model.lines.filter { $0.contains(".give(openAtLogin:") }
        XCTAssertEqual(gives.map { $0.trimmingCharacters(in: .whitespaces) },
                       ["try consentStore.give(openAtLogin: openAtLogin)"])
        let start = try XCTUnwrap(model.lines.firstIndex { $0.contains("func startRemembering(keyReady: Bool)") })
        let give = try XCTUnwrap(model.lines.firstIndex { $0.contains(".give(openAtLogin:") })
        let next = model.lines[(start + 1)...].firstIndex { $0.contains(" func ") } ?? model.lines.count
        XCTAssertTrue(start < give && give < next, "the write is inside startRemembering")
        // And Start Remembering is one click: the Promise's button in the bar.
        XCTAssertEqual(files(containing: "startRemembering("),
                       ["Onboarding/OnboardingFlowView.swift", "OnboardingKit/OnboardingFlowViewModel.swift"])
        let flow = try XCTUnwrap(code.first { $0.path == "Onboarding/OnboardingFlowView.swift" })
        XCTAssertEqual(flow.lines.filter { $0.contains("startRemembering(") }.count, 1)
    }
}
