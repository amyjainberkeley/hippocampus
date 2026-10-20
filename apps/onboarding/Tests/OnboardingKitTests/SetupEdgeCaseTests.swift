import XCTest
@testable import OnboardingKit

/// SPEC 7.2 and 7.7: Quit & Reopen, two copies of the app, what VoiceOver
/// hears when a permission turns on, and Low Power Mode on Try it.
@MainActor
final class SetupEdgeCaseTests: XCTestCase {
    // MARK: - Quit & Reopen

    func testAfterQuitAndReopenTheRowThatCameOnShowsItsCheckmarkOnce() throws {
        let file = try temporaryDirectory().appendingPathComponent(".onboarding-state")
        let store = FileOnboardingStateStore(path: file)
        let sr = StubTCCPermission(kind: .screenRecording)
        let ax = StubTCCPermission(kind: .accessibility)
        let first = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store)
        first.advance()
        first.advance()
        XCTAssertEqual(first.screen, .permissions)
        first.requestPermission(.screenRecording)
        XCTAssertEqual(first.rowState(.screenRecording), .waiting)
        XCTAssertEqual(store.loadAsked(), [.screenRecording], "kept beside the resume point")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "permissions\n", "the resume file keeps one line")

        // macOS's Quit & Reopen: Screen Recording came on while setup was closed.
        sr.simulateGrant()
        let reopened = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store)
        XCTAssertEqual(reopened.screen, .permissions, "it resumes where it was")
        XCTAssertEqual(reopened.turnedOnWhileAway, [.screenRecording])
        XCTAssertEqual(reopened.rowState(.screenRecording), .granted)
        XCTAssertEqual(reopened.rowState(.accessibility), .idle, "nothing else moved")
        reopened.didShowTurnedOn(.screenRecording)
        XCTAssertTrue(reopened.turnedOnWhileAway.isEmpty)

        // Once: opening setup again shows no checkmark appearing.
        let again = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store)
        XCTAssertTrue(again.turnedOnWhileAway.isEmpty)
    }

    func testARowStillOffAfterReopeningIsNotShownAsTurningOn() throws {
        let store = FileOnboardingStateStore(path: try temporaryDirectory().appendingPathComponent(".onboarding-state"))
        let sr = StubTCCPermission(kind: .screenRecording)
        let ax = StubTCCPermission(kind: .accessibility)
        let first = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store)
        first.advance()
        first.advance()
        first.requestPermission(.accessibility)
        let reopened = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store)
        XCTAssertTrue(reopened.turnedOnWhileAway.isEmpty)
        XCTAssertEqual(store.loadAsked(), [.accessibility], "still waited on")
    }

    func testNothingIsKeptForReopeningOnceConsentIsGiven() throws {
        let store = InMemoryOnboardingStateStore(route: "permissions", asked: [.screenRecording])
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility),
            stateStore: store, consentStore: InMemoryOnboardingConsentStore(given: true)
        )
        XCTAssertTrue(vm.turnedOnWhileAway.isEmpty, "review mode resumes nothing")
        XCTAssertTrue(store.loadAsked().isEmpty, "a left-over list is removed with the resume point")
        vm.openSettings(.accessibility)
        XCTAssertTrue(store.loadAsked().isEmpty, "after consent nothing is written")
    }

    func testTheAskedFileHoldsNamesOnlyAndClearsWithSetup() throws {
        let directory = try temporaryDirectory()
        let store = FileOnboardingStateStore(path: directory.appendingPathComponent(".onboarding-state"))
        store.saveAsked([.accessibility, .screenRecording])
        let asked = directory.appendingPathComponent(".onboarding-asked")
        XCTAssertEqual(try String(contentsOf: asked, encoding: .utf8), "screenRecording\naccessibility\n")
        try "screenRecording\nsomething-else\n\n".write(to: asked, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.loadAsked(), [.screenRecording], "unknown lines are ignored")
        store.saveAsked([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: asked.path))
        store.saveAsked([.screenRecording])
        store.save(.permissions)
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: asked.path), "Done clears it with the resume point")
        XCTAssertNil(store.loadRoute())
    }

    // MARK: - Two copies

    func testTwoCopiesOfTheAppAddTheLineAboutWhichToTurnOn() {
        func vm(copies: Int) -> OnboardingFlowViewModel {
            OnboardingFlowViewModel(
                screenRecording: StubTCCPermission(kind: .screenRecording, status: .denied),
                accessibility: StubTCCPermission(kind: .accessibility),
                initialScreen: .permissions, copiesOfTheApp: { copies }
            )
        }
        XCTAssertFalse(vm(copies: 1).twoCopiesInstalled)
        XCTAssertFalse(vm(copies: 0).twoCopiesInstalled)
        XCTAssertTrue(vm(copies: 2).twoCopiesInstalled)
        XCTAssertEqual(OnboardingCopy.needsHelpLines(twoCopies: vm(copies: 2).twoCopiesInstalled).last,
                       "If you see two, turn on the one in Applications.")
    }

    func testCopiesAreCountedByPlaceAndTheTrashDoesNotCount() {
        let urls = [
            URL(fileURLWithPath: "/Applications/Hippocampus.app"),
            URL(fileURLWithPath: "/Applications/Hippocampus.app/"),
            URL(fileURLWithPath: "/Users/sam/Downloads/Hippocampus.app"),
            URL(fileURLWithPath: "/Users/sam/.Trash/Hippocampus.app"),
        ]
        XCTAssertEqual(AppCopies.count(urls), 2)
        XCTAssertEqual(AppCopies.count([]), 0)
        XCTAssertEqual(AppCopies.bundleIdentifier, "ai.hippocampus")
    }

    // MARK: - What VoiceOver hears

    func testVoiceOverHearsWhatTurnedOnAndThatBothAreOnInOneAnnouncement() {
        let idle: [PermissionSurface: PermissionRowState] = [.screenRecording: .idle, .accessibility: .idle]
        XCTAssertNil(PermissionAnnouncement.after(idle, idle))
        XCTAssertEqual(PermissionAnnouncement.after(idle, [.screenRecording: .granted, .accessibility: .idle]),
                       "Screen Recording is on.")
        XCTAssertEqual(
            PermissionAnnouncement.after([.screenRecording: .granted, .accessibility: .waiting],
                                         [.screenRecording: .granted, .accessibility: .granted]),
            "Accessibility is on. Both are on. You can continue."
        )
        XCTAssertEqual(PermissionAnnouncement.after(idle, [.screenRecording: .granted, .accessibility: .granted]),
                       "Screen Recording is on. Accessibility is on. Both are on. You can continue.")
        // A row that was already on says nothing again.
        let both: [PermissionSurface: PermissionRowState] = [.screenRecording: .granted, .accessibility: .granted]
        XCTAssertNil(PermissionAnnouncement.after(both, both))
    }

    func testTheFlowGivesEveryRowsState() {
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility),
            initialScreen: .permissions
        )
        XCTAssertEqual(vm.rowStates, [.screenRecording: .granted, .accessibility: .idle])
    }

    // MARK: - Low Power Mode

    func testInLowPowerModeTryItWaitsNinetySecondsAndSaysWhy() async {
        let clock = TestClock()
        let lowPower = MainBox(true)
        let vm = TryItViewModel(
            probe: NothingRead(), startedAt: clock.now, cursorTsUs: 1, now: { clock.now },
            frontWindow: { FrontWindow(bundleId: "com.apple.Notes", appName: "Notes", title: "Launch plan") },
            lowPowerMode: { lowPower.value }
        )
        XCTAssertTrue(vm.lowPowerMode)
        for _ in 0..<60 {
            clock.advance(1)
            await vm.tick()
        }
        guard case .reading = vm.card else { return XCTFail("still reading at 60 s, not \(vm.card)") }
        XCTAssertEqual(TryItPresentation(card: vm.card, keyNow: AskKeyNow(phrase: nil, keycaps: []), understanding: nil,
                                         lowPowerMode: vm.lowPowerMode).lowPowerNote,
                       "Low Power Mode is on, so reading takes a little longer.")
        for _ in 0..<31 {
            clock.advance(1)
            await vm.tick()
        }
        XCTAssertEqual(vm.card, .stalled(.unknown), "after 90 seconds")
        XCTAssertNil(TryItPresentation(card: vm.card, keyNow: AskKeyNow(phrase: nil, keycaps: []), understanding: nil,
                                       lowPowerMode: true).lowPowerNote, "the stalled card says what to do instead")

        // Plugged in again: the usual 45 seconds, and no note.
        lowPower.value = false
        let usual = TryItViewModel(
            probe: NothingRead(), startedAt: clock.now, cursorTsUs: 1, now: { clock.now },
            frontWindow: { FrontWindow(bundleId: "com.apple.Notes", appName: "Notes", title: "Launch plan") },
            lowPowerMode: { lowPower.value }
        )
        for _ in 0..<46 {
            clock.advance(1)
            await usual.tick()
        }
        XCTAssertEqual(usual.card, .stalled(.unknown))
        XCTAssertFalse(usual.lowPowerMode)
    }

    func testTheLowPowerNoteShowsOnlyWhileTryItWaitsForARead() {
        let key = AskKeyNow(phrase: "Press Shift twice", keycaps: ["⇧", "⇧"])
        let notes = FrontWindow(bundleId: "com.apple.Notes", appName: "Notes", title: "Launch plan")
        for card: TryItViewModel.Card in [.starting, .reading(notes)] {
            XCTAssertEqual(TryItPresentation(card: card, keyNow: key, understanding: nil, lowPowerMode: true).lowPowerNote,
                           OnboardingCopy.tryItLowPower, "\(card)")
            XCTAssertNil(TryItPresentation(card: card, keyNow: key, understanding: nil, lowPowerMode: false).lowPowerNote)
        }
        for card: TryItViewModel.Card in [.noWindow, .stalled(.unknown), .finished(openedForThem: false),
                                          .notRemembering(.paused), .skipped(.privateWindow, notes)] {
            XCTAssertNil(TryItPresentation(card: card, keyNow: key, understanding: nil, lowPowerMode: true).lowPowerNote,
                         "\(card)")
        }
        XCTAssertEqual(TryItViewModel.stalledAfter(lowPowerMode: false), 45)
        XCTAssertEqual(TryItViewModel.stalledAfter(lowPowerMode: true), 90)
    }
}

/// A reader with nothing to show.
private final class NothingRead: LastReadProbe, @unchecked Sendable {
    func rows(after tsUs: UInt64) async -> ReadBatch { .notReady }
    func stop() async {}
    func resume() async {}
}
