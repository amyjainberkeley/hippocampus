import XCTest
@testable import OnboardingKit

/// Hands Try it one row once memory can be read.
private final class OneRowReads: LastReadProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let row: ReadRow

    init(row: ReadRow) { self.row = row }

    func rows(after tsUs: UInt64) async -> ReadBatch {
        lock.withLock {
            reads += 1
            // Before the first save the agent cannot open memory.
            return reads == 1 ? .notReady : .rows([row], newestTsUs: row.tsUs)
        }
    }

    func stop() async {}
    func resume() async {}
}

/// Setup from first launch to its end, through the view models the
/// screens draw: Welcome, What you get, Permissions, Promise (consent),
/// Try it, and what happens when it is opened again. Nothing here touches the
/// person's files: every store is in memory or in a temporary folder.
@MainActor
final class OnboardingE2ETests: XCTestCase {
    func testAFirstRunFromWelcomeToAsk() async throws {
        let clock = TestClock()
        let sr = StubTCCPermission(kind: .screenRecording)
        let ax = StubTCCPermission(kind: .accessibility)
        let consent = InMemoryOnboardingConsentStore()
        let state = InMemoryOnboardingStateStore()
        let flow = OnboardingFlowViewModel(
            screenRecording: sr, accessibility: ax, stateStore: state, consentStore: consent, now: { clock.now }
        )
        let key = PrepareBrainViewModel(keyGenerator: StubKeyGenerator())

        // Welcome, then what it does.
        XCTAssertEqual(flow.screen, .welcome)
        flow.advance()
        XCTAssertEqual(flow.screen, .whatYouGet)
        flow.advance()

        // Permissions: both rows at once, each asked with macOS's prompt.
        XCTAssertEqual(flow.screen, .permissions)
        XCTAssertEqual(OnboardingCopy.permissionsBody(isReview: flow.isReview), OnboardingCopy.permissionsNothingYet)
        await key.generateKey()
        XCTAssertFalse(flow.canAdvance)
        flow.requestPermission(.screenRecording)
        XCTAssertEqual(flow.rowState(.screenRecording), .waiting)
        sr.simulateGrant()
        await flow.userReturned()
        XCTAssertEqual(flow.rowState(.screenRecording), .granted)
        flow.requestPermission(.accessibility)
        ax.simulateGrant()
        await flow.refreshPermissionsAsync()
        XCTAssertEqual(flow.bothTurnedOnCount, 1, "the window comes forward")
        XCTAssertTrue(flow.canAdvance)
        flow.advance()

        // Promise: only Start Remembering, with the key ready, goes on.
        XCTAssertEqual(flow.screen, .promise)
        XCTAssertEqual(OnboardingCopy.promisePrimary(isReview: false, keyState: key.keyState),
                       OnboardingCopy.startRemembering)
        flow.advance()
        XCTAssertEqual(flow.screen, .promise)
        XCTAssertEqual(consent.writeCount, 0)
        let started = await flow.startRemembering(keyReady: key.canContinue)
        XCTAssertTrue(started)
        XCTAssertEqual(consent.writeCount, 1)
        XCTAssertEqual(consent.openAtLogin, true)
        XCTAssertEqual(flow.screen, .tryIt)
        XCTAssertNil(state.loadRoute(), "after consent there is nothing to resume")

        // Try it: "Turning on…", then the window behind setup is read, then
        // Ask. The app was not remembering when it opened setup; consent
        // started it. The window is the person's note, read whole by
        // whole-screen reading while setup is in front.
        let consentAt = try XCTUnwrap(flow.consentGivenAtUs)
        let reads = OneRowReads(row: ReadRow(
            tsUs: consentAt + 5_000_000, appBundleId: "com.apple.Notes", windowTitle: "Launch plan",
            text: "Launch plan\nBeta ships to forty design partners on October 21.", sourceKind: "screen_context"
        ))
        let note = FrontWindow(bundleId: "com.apple.Notes", appName: "Notes", title: "Launch plan")
        let tryIt = TryItViewModel(
            probe: reads, startedAt: clock.now,
            cursorTsUs: TryItViewModel.cursor(consentGivenAtUs: flow.consentGivenAtUs, now: clock.now),
            remembering: flow.rememberingForTryIt(environment: [RememberingState.environmentKey: "off"]),
            turningOn: flow.consentGivenAtUs != nil, now: { clock.now },
            permissionsOn: { await flow.permissionsStillOn() },
            nameFor: { _ in "Notes" },
            frontWindow: { note }
        )
        let key0 = AskKeyNow(effectiveLabel: "⇧⇧", effectivePhrase: "Press Shift twice", stored: nil)
        XCTAssertEqual(TryItPresentation(card: tryIt.card, keyNow: key0, understanding: nil).heading,
                       OnboardingCopy.tryItStarting)
        for _ in 0..<3 {
            clock.advance(1)
            await tryIt.tick()
        }
        XCTAssertEqual(TryItPresentation(card: tryIt.card, keyNow: key0, understanding: nil).heading, "Reading Notes…")
        for _ in 0..<2 {
            clock.advance(1)
            await tryIt.tick()
        }
        let shown = TryItPresentation(card: tryIt.card, keyNow: key0, understanding: .available)
        XCTAssertEqual(shown.title, "Here’s what I just read from Notes")
        XCTAssertEqual(shown.proof?.appName, "Notes")
        XCTAssertEqual(shown.proof?.lines, ["Beta ships to forty design partners on October 21."])
        XCTAssertEqual(shown.next, "Press Shift twice and ask about it.")
        XCTAssertEqual(shown.stopSharingNote, OnboardingCopy.stopSharingNote)
        tryIt.askDidShow()
        XCTAssertEqual(TryItPresentation(card: tryIt.card, keyNow: key0, understanding: .available).finished,
                       "That’s it. Shift twice works anywhere.")

        // Done: a later run starts fresh.
        flow.clearResumeState()
        XCTAssertNil(state.loadRoute())
    }

    func testATurnedDownPermissionGetsHelpAndAskAgainRecovers() async {
        let sr = StubTCCPermission(kind: .screenRecording)
        let flow = OnboardingFlowViewModel(
            screenRecording: sr,
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            initialScreen: .permissions
        )
        flow.requestPermission(.screenRecording)
        await flow.userReturned()
        XCTAssertEqual(flow.rowState(.screenRecording), .needsHelp)
        XCTAssertFalse(flow.offersAskAgain(.screenRecording))
        flow.openSettings(.screenRecording)
        await flow.userReturned()
        XCTAssertTrue(flow.offersAskAgain(.screenRecording), "after the second return that finds it off")
        await flow.askAgain(.screenRecording)
        XCTAssertEqual(sr.askAgainCallCount, 1)
        sr.simulateGrant()
        await flow.userReturned()
        XCTAssertTrue(flow.canAdvance)
        flow.advance()
        XCTAssertEqual(flow.screen, .promise)
    }

    func testOpeningSetupAgainAfterConsentChangesNothing() async {
        let consent = InMemoryOnboardingConsentStore(given: true)
        let flow = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            consentStore: consent
        )
        XCTAssertTrue(flow.isReview)
        XCTAssertNil(OnboardingCopy.permissionsBody(isReview: true), "it may already be reading")
        XCTAssertNil(OnboardingCopy.promiseBody(isReview: true))
        flow.advance()
        flow.advance()
        flow.advance()
        XCTAssertEqual(flow.screen, .promise)
        XCTAssertEqual(OnboardingCopy.promisePrimary(isReview: true, keyState: .checking), OnboardingCopy.continueLabel)
        flow.advance()
        XCTAssertEqual(flow.screen, .tryIt)
        XCTAssertEqual(consent.writeCount, 0, "consent is never written again")

        let tryIt = TryItViewModel(
            probe: OneRowReads(row: ReadRow(tsUs: 1, appBundleId: nil, windowTitle: nil, text: "", sourceKind: "x")),
            startedAt: Date(), cursorTsUs: 0, remembering: .paused, turningOn: flow.consentGivenAtUs != nil
        )
        XCTAssertEqual(tryIt.card, .notRemembering(.paused), "no Turning on… when it was already set up")
    }

    func testQuittingMidSetupResumesWhereItLeftOff() throws {
        let file = try temporaryDirectory().appendingPathComponent(".onboarding-state")
        let store = FileOnboardingStateStore(path: file)
        let sr = StubTCCPermission(kind: .screenRecording, status: .granted)
        let ax = StubTCCPermission(kind: .accessibility, status: .granted)
        let first = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store)
        first.advance()
        first.advance()
        first.advance()
        XCTAssertEqual(first.screen, .promise)

        let reopened = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store)
        XCTAssertEqual(reopened.screen, .promise)

        // A file from the thirteen-step flow names a step that is gone.
        try "3\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, stateStore: store).screen,
                       .welcome)
    }

    func testRoutesTheAppPassesOpenTheFlowOrAPanelThatKeepsNoPlace() {
        let panel = OnboardingLaunch.parse("app-access").resolved(consentGiven: true)
        XCTAssertEqual(panel, .panel(.appAccess))
        XCTAssertFalse(panel.usesResumeFile)
        XCTAssertEqual(OnboardingLaunch.parse("app-access").resolved(consentGiven: false), .flow(nil),
                       "before consent there is only setup")
        XCTAssertTrue(OnboardingLaunch.parse("permissions").usesResumeFile)
        XCTAssertTrue(OnboardingLaunch.parse(nil).usesResumeFile)
    }
}
