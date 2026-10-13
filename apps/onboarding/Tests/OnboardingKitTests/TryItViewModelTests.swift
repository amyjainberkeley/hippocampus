import XCTest
@testable import OnboardingKit

/// Hands out scripted batches and records when it was asked.
private final class ScriptedReads: LastReadProbe, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestClock
    private var batches: [ReadBatch]
    private(set) var askedAt: [Date] = []
    private(set) var cursors: [UInt64] = []
    private(set) var stops = 0
    private(set) var resumes = 0
    /// Runs inside `stop()`, while the caller is still waiting on it.
    var onStop: (@Sendable () async -> Void)?

    init(clock: TestClock, batches: [ReadBatch] = []) {
        self.clock = clock
        self.batches = batches
    }

    func push(_ batch: ReadBatch) { lock.withLock { batches.append(batch) } }

    func rows(after tsUs: UInt64) async -> ReadBatch {
        lock.withLock {
            askedAt.append(clock.now)
            cursors.append(tsUs)
            return batches.isEmpty ? .notReady : batches.removeFirst()
        }
    }

    func stop() async {
        lock.withLock { stops += 1 }
        await onStop?()
    }

    func resume() async {
        lock.withLock { resumes += 1 }
    }
}

@MainActor
final class TryItViewModelTests: XCTestCase {
    private func row(_ ts: UInt64, _ app: String = "com.apple.Notes", text: String = "We agreed to ship the pricing page next week.") -> ReadRow {
        ReadRow(tsUs: ts, appBundleId: app, windowTitle: "Launch plan", text: text, sourceKind: "screen_ocr")
    }

    private func makeVM(
        _ reads: ScriptedReads, clock: TestClock, remembering: RememberingState = .on, turningOn: Bool = true,
        permissions: MainBox<(screenRecording: Bool, accessibility: Bool)> = MainBox((true, true))
    ) -> TryItViewModel {
        TryItViewModel(
            probe: reads, startedAt: clock.now, cursorTsUs: 1_000, remembering: remembering, turningOn: turningOn,
            now: { clock.now }, permissionsOn: { permissions.value },
            nameFor: { ["com.apple.Notes": "Notes", "com.apple.Safari": "Safari"][$0] ?? "Other" }
        )
    }

    /// Tick once a second for `seconds`.
    private func run(_ vm: TryItViewModel, _ clock: TestClock, for seconds: Int) async {
        for _ in 0..<seconds {
            clock.advance(1)
            await vm.tick()
        }
    }

    func testTurningOnForThreeSecondsThenWaiting() async {
        let clock = TestClock()
        let vm = makeVM(ScriptedReads(clock: clock), clock: clock)
        await vm.tick()
        XCTAssertEqual(vm.card, .starting)
        await run(vm, clock, for: 2)
        XCTAssertEqual(vm.card, .starting)
        await run(vm, clock, for: 1)
        XCTAssertEqual(vm.card, .waiting(.ordinary))
        XCTAssertEqual(OnboardingCopy.waitingText(.ordinary), "Nothing read yet. Open a document, note or chat, then come back.")
    }

    func testTheFirstReadIsTwoSecondsInThenEveryTwoSeconds() async {
        let clock = TestClock()
        let start = clock.now
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock)
        await vm.tick()
        await run(vm, clock, for: 8)
        XCTAssertEqual(reads.askedAt.map { $0.timeIntervalSince(start) }, [2, 4, 6, 8])
        XCTAssertEqual(reads.cursors.first, 1_000, "reading starts at consent")
    }

    func testTheWaitingCardSpeaksToTheAppInFront() async {
        let clock = TestClock()
        let vm = makeVM(ScriptedReads(clock: clock), clock: clock)
        await run(vm, clock, for: 4)
        let cases: [(String, String, FrontAppNote)] = [
            ("com.apple.systempreferences", "System Settings", .neverRead(app: "System Settings")),
            ("com.1password.1password", "1Password", .neverRead(app: "1Password")),
            // Browsers are read like every other window (RULINGS G8).
            ("com.apple.Safari", "Safari", .ordinary),
            ("company.thebrowser.Browser", "Arc", .ordinary),
            ("com.google.Chrome", "Google Chrome", .ordinary),
            ("org.mozilla.firefox", "Firefox", .ordinary),
            ("com.apple.TextEdit", "TextEdit", .ordinary),
        ]
        for (bundle, name, note) in cases {
            vm.appActivated(bundleId: bundle, name: name)
            await vm.tick()
            XCTAssertEqual(vm.card, .waiting(note), bundle)
        }
        vm.appActivated(bundleId: "ai.hippocampus", name: "Hippocampus")
        XCTAssertEqual(vm.frontApp?.bundleId, "com.apple.TextEdit", "Hippocampus itself is never the app in front")

        XCTAssertEqual(OnboardingCopy.waitingText(.neverRead(app: "System Settings")),
                       "System Settings is never read. Try a document, note or chat.")
        XCTAssertEqual(OnboardingCopy.waitingText(.ordinary),
                       "Nothing read yet. Open a document, note or chat, then come back.")
    }

    func testAProofReplacesTheCardAndANewerOneReplacesIt() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock, batches: [
            .notReady,
            .rows([row(2_000)], newestTsUs: 2_000),
            .rows([row(3_000, text: "Ask Dana about the annual discount before Friday.")], newestTsUs: 3_000),
        ])
        let vm = makeVM(reads, clock: clock)
        await run(vm, clock, for: 4)
        guard case .proof(let first) = vm.card else { return XCTFail("\(vm.card)") }
        XCTAssertEqual(first.tsUs, 2_000)
        XCTAssertEqual(OnboardingCopy.proofHeading(first), "Notes · Launch plan")
        await run(vm, clock, for: 2)
        guard case .proof(let second) = vm.card else { return XCTFail("\(vm.card)") }
        XCTAssertEqual(second.lines, ["Ask Dana about the annual discount before Friday."])
        XCTAssertEqual(reads.cursors, [1_000, 1_000, 2_000], "each read starts after the newest row seen")
    }

    func testAfterFortyFiveSecondsTheCardNamesWhatItCan() async {
        let clock = TestClock()
        let permissions = MainBox<(screenRecording: Bool, accessibility: Bool)>((true, false))
        let vm = makeVM(ScriptedReads(clock: clock), clock: clock, permissions: permissions)
        await run(vm, clock, for: 44)
        XCTAssertEqual(vm.card, .waiting(.ordinary))
        await run(vm, clock, for: 1)
        XCTAssertEqual(vm.card, .stalled(.permissionOff(.accessibility)))
        XCTAssertEqual(OnboardingCopy.stalledText(.permissionOff(.accessibility)),
                       "Accessibility is off. Turn it on in System Settings.")

        permissions.value = (true, true)
        vm.appActivated(bundleId: "com.apple.systempreferences", name: "System Settings")
        await vm.tick()
        XCTAssertEqual(vm.card, .stalled(.frontApp(.neverRead(app: "System Settings"))))

        // A browser is read like any window, so it names no cause.
        vm.appActivated(bundleId: "com.apple.Safari", name: "Safari")
        await vm.tick()
        XCTAssertEqual(vm.card, .stalled(.unknown))

        vm.appActivated(bundleId: "com.apple.TextEdit", name: "TextEdit")
        await vm.tick()
        XCTAssertEqual(vm.card, .stalled(.unknown))
        XCTAssertEqual(OnboardingCopy.stalledText(.unknown), "Still nothing read.")
    }

    func testAStalledCardChecksThePermissionsThenNotBefore() async {
        let clock = TestClock()
        let checks = MainBox(0)
        let vm = TryItViewModel(
            probe: ScriptedReads(clock: clock), startedAt: clock.now, cursorTsUs: 1_000, now: { clock.now },
            permissionsOn: {
                checks.value += 1
                // Accessibility is turned off after the first check.
                return (true, checks.value < 2)
            }
        )
        await run(vm, clock, for: 44)
        XCTAssertEqual(checks.value, 0, "nothing is checked while the card waits")
        await run(vm, clock, for: 1)
        XCTAssertEqual(vm.card, .stalled(.unknown))
        await run(vm, clock, for: 1)
        XCTAssertEqual(vm.card, .stalled(.permissionOff(.accessibility)), "each look checks again")
    }

    func testAPermissionTurnedOffSinceConsentIsNamed() async throws {
        // Setup saw both on at consent, and nothing has looked since.
        let clock = TestClock()
        let ax = LivePermission(kind: .accessibility, isOn: true)
        let flow = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: ax,
            now: { clock.now },
            initialScreen: .promise
        )
        let started = await flow.startRemembering(keyReady: true)
        XCTAssertTrue(started)
        let vm = TryItViewModel(
            probe: ScriptedReads(clock: clock), startedAt: clock.now,
            cursorTsUs: try XCTUnwrap(flow.consentGivenAtUs), now: { clock.now },
            permissionsOn: { await flow.permissionsStillOn() }
        )
        ax.isOn = false
        XCTAssertEqual(flow.accessibilityPermission.status, .granted, "what setup last saw")
        await run(vm, clock, for: 45)
        XCTAssertEqual(vm.card, .stalled(.permissionOff(.accessibility)))
        XCTAssertEqual(TryItPresentation(card: vm.card, keyNow: AskKeyNow(effectiveLabel: nil, effectivePhrase: nil, stored: nil),
                                         understanding: nil).action,
                       .openSettings(.accessibility))
    }

    func testTryAgainWhileTheStallIsCheckedIsNotUndone() async {
        let clock = TestClock()
        let gate = Gate()
        let vm = TryItViewModel(
            probe: ScriptedReads(clock: clock), startedAt: clock.now, cursorTsUs: 1_000, now: { clock.now },
            permissionsOn: {
                await gate.wait()
                return (true, true)
            }
        )
        await run(vm, clock, for: 44)
        clock.advance(1)
        let step = Task { await vm.tick() }
        while !gate.isHeld { await Task.yield() }
        await vm.tryAgain()
        XCTAssertEqual(vm.card, .starting)
        gate.open()
        await step.value
        XCTAssertEqual(vm.card, .starting, "the stall found before Try Again is not drawn over it")
    }

    func testReadingStopsThirtySecondsAfterTheFirstProof() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock, batches: [.rows([row(2_000)], newestTsUs: 2_000)])
        let vm = makeVM(reads, clock: clock)
        await run(vm, clock, for: 2)
        XCTAssertEqual(reads.askedAt.count, 1)
        await run(vm, clock, for: 29)
        XCTAssertTrue(vm.isReading)
        XCTAssertEqual(reads.stops, 0)
        await run(vm, clock, for: 1)
        XCTAssertFalse(vm.isReading)
        XCTAssertEqual(reads.stops, 1)
        let asked = reads.askedAt.count
        await run(vm, clock, for: 20)
        XCTAssertEqual(reads.askedAt.count, asked, "no reads after it stops")
        guard case .proof = vm.card else { return XCTFail("\(vm.card)") }
    }

    func testReadingStopsAfterThreeMinutesWithoutAProof() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock)
        await run(vm, clock, for: 179)
        XCTAssertTrue(vm.isReading)
        await run(vm, clock, for: 1)
        XCTAssertFalse(vm.isReading)
        XCTAssertEqual(reads.stops, 1)
        XCTAssertEqual(vm.card, .stalled(.unknown))
    }

    func testAskOpeningEndsTheScreen() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock)
        await run(vm, clock, for: 5)
        vm.askDidShow()
        XCTAssertEqual(vm.card, .finished(openedForThem: false))
        await run(vm, clock, for: 3)
        XCTAssertEqual(vm.card, .finished(openedForThem: false))
        XCTAssertEqual(TryItViewModel.askDidShowNotification.rawValue, "ai.hippocampus.ask.didShow")
    }

    func testTheClosingLineNamesOnlyAKeyThatWorksNow() {
        let shiftTwice = AskKeyNow(effectiveLabel: "⇧⇧", effectivePhrase: "Press Shift twice", stored: "shiftTwice")
        XCTAssertEqual(OnboardingCopy.tryItFinished(shiftTwice, openedForThem: false), "That’s it. Shift twice works anywhere.")
        let rightCommand = AskKeyNow(effectiveLabel: "right ⌘", effectivePhrase: "Tap right ⌘", stored: "rightCommand")
        XCTAssertEqual(OnboardingCopy.tryItFinished(rightCommand, openedForThem: false), "That’s it. Right ⌘ works anywhere.")
        // Accessibility is not on yet, so only the chord works.
        let chordOnly = AskKeyNow(effectiveLabel: "⌃⇧Space", effectivePhrase: "Press ⌃⇧Space", stored: "shiftTwice")
        XCTAssertEqual(OnboardingCopy.tryItFinished(chordOnly, openedForThem: false), "That’s it. ⌃⇧Space works anywhere.")
        // Nothing opens Ask right now.
        let none = AskKeyNow(effectiveLabel: "", effectivePhrase: "", stored: "shiftTwice")
        XCTAssertEqual(OnboardingCopy.tryItFinished(none, openedForThem: false), "That’s Ask. Open it from the menu bar.")
        // The app published nothing: the chosen key stands in.
        let unpublished = AskKeyNow(effectiveLabel: nil, effectivePhrase: nil, stored: "rightShift")
        XCTAssertEqual(OnboardingCopy.tryItFinished(unpublished, openedForThem: false), "That’s it. Right Shift works anywhere.")
        XCTAssertEqual(OnboardingCopy.tryItFinished(AskKeyNow(effectiveLabel: nil, effectivePhrase: nil, stored: "off"),
                                                    openedForThem: false),
                       "That’s it. Control-Shift-Space works anywhere.")
    }

    func testOpenItForMeEndsOnAskNotOnTheKey() async {
        let clock = TestClock()
        let vm = makeVM(ScriptedReads(clock: clock), clock: clock)
        await run(vm, clock, for: 5)
        vm.willOpenAskForThem()
        clock.advance(2)
        vm.askDidShow()
        XCTAssertEqual(vm.card, .finished(openedForThem: true), "the link proves nothing about the key")
        let key = AskKeyNow(effectiveLabel: "⇧⇧", effectivePhrase: "Press Shift twice", stored: nil)
        XCTAssertEqual(OnboardingCopy.tryItFinished(key, openedForThem: true), "That’s Ask. Press Shift twice to open it anywhere.")

        // Later the person presses the key, and Ask shows again.
        clock.advance(30)
        vm.askDidShow()
        XCTAssertEqual(vm.card, .finished(openedForThem: false))
        vm.askDidShow()
        XCTAssertEqual(vm.card, .finished(openedForThem: false), "a key that worked stays the ending")
    }

    func testAskShowingLongAfterTheLinkIsTheKey() async {
        let clock = TestClock()
        let vm = makeVM(ScriptedReads(clock: clock), clock: clock)
        vm.willOpenAskForThem()
        clock.advance(TryItViewModel.openedForThemWithin + 1)
        vm.askDidShow()
        XCTAssertEqual(vm.card, .finished(openedForThem: false))
    }

    func testAskOpeningWhileReadingStopsStillEndsTheScreen() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock, batches: [.rows([row(2_000)], newestTsUs: 2_000)])
        let vm = makeVM(reads, clock: clock)
        reads.onStop = { await MainActor.run { vm.askDidShow() } }
        await run(vm, clock, for: 32)
        XCTAssertFalse(vm.isReading)
        XCTAssertEqual(vm.card, .finished(openedForThem: false))
    }

    func testRunStopsTheReaderWhenAskOpens() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock)
        vm.askDidShow()
        await vm.run(sleep: { _ in clock.advance(1) })
        XCTAssertGreaterThanOrEqual(reads.stops, 1)
    }

    func testInReviewWithRememberingOnThereIsNoTurningOn() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock, turningOn: false)
        XCTAssertEqual(vm.card, .waiting(.ordinary), "remembering was already on")
        await vm.tick()
        XCTAssertEqual(vm.card, .waiting(.ordinary))
        await run(vm, clock, for: 2)
        XCTAssertEqual(vm.card, .waiting(.ordinary))
        XCTAssertEqual(reads.askedAt.count, 1, "it still reads")
    }

    func testTryAgainStartsTheScreenOverAndReadsAgainAfterThreeMinutes() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock)
        await run(vm, clock, for: 180)
        XCTAssertFalse(vm.isReading)
        XCTAssertEqual(vm.card, .stalled(.unknown))
        XCTAssertEqual(OnboardingCopy.tryAgain, "Try Again")

        // The app restarts remembering; this screen starts over with it.
        await vm.tryAgain()
        XCTAssertEqual(vm.card, .starting)
        XCTAssertTrue(vm.isReading)
        XCTAssertEqual(reads.resumes, 1)
        let asked = reads.askedAt.count
        reads.push(.rows([row(9_000)], newestTsUs: 9_000))
        await run(vm, clock, for: 2)
        XCTAssertEqual(reads.askedAt.count, asked + 1, "reading starts again")
        guard case .proof(let proof) = vm.card else { return XCTFail("\(vm.card)") }
        XCTAssertEqual(proof.tsUs, 9_000)
    }

    func testTryAgainBeforeReadingStopsKeepsTheReaderAndRestartsTheClock() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock)
        await run(vm, clock, for: 60)
        XCTAssertEqual(vm.card, .stalled(.unknown))
        await vm.tryAgain()
        XCTAssertEqual(reads.resumes, 0, "the reader never stopped")
        await run(vm, clock, for: 44)
        XCTAssertEqual(vm.card, .waiting(.ordinary), "45 s more before it stalls again")
        await run(vm, clock, for: 1)
        XCTAssertEqual(vm.card, .stalled(.unknown))
        await run(vm, clock, for: 135)
        XCTAssertFalse(vm.isReading, "three minutes after Try Again")
    }

    func testReviewModeSaysRememberingIsPausedOrOffAndReadsNothing() async {
        for state in [RememberingState.paused, .off] {
            let clock = TestClock()
            let reads = ScriptedReads(clock: clock)
            let vm = makeVM(reads, clock: clock, remembering: state)
            await run(vm, clock, for: 10)
            XCTAssertEqual(vm.card, .notRemembering(state))
            XCTAssertTrue(reads.askedAt.isEmpty)
        }
        XCTAssertEqual(RememberingState(environment: ["MCI_ONBOARDING_REMEMBERING": "paused"]), .paused)
        XCTAssertEqual(RememberingState(environment: ["MCI_ONBOARDING_REMEMBERING": "off"]), .off)
        XCTAssertEqual(RememberingState(environment: [:]), .on)
        XCTAssertEqual(RememberingState(environment: ["MCI_ONBOARDING_REMEMBERING": "maybe"]), .on)
    }

    func testReadingStartsAtConsentOrThirtySecondsBackInReview() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(TryItViewModel.cursor(consentGivenAtUs: 42, now: now), 42)
        XCTAssertEqual(TryItViewModel.cursor(consentGivenAtUs: nil, now: now), 1_799_999_970_000_000)
    }

    func testWhatToTryNextFollowsTheKeyThatWorksNowAndWhetherAnswersWork() {
        let shiftTwice = AskKeyNow(effectiveLabel: "⇧⇧", effectivePhrase: "Press Shift twice", stored: "shiftTwice")
        XCTAssertEqual(OnboardingCopy.tryItNext(shiftTwice, answersAvailable: true), "Now press Shift twice and ask about it.")
        XCTAssertEqual(OnboardingCopy.tryItNext(shiftTwice, answersAvailable: false),
                       "Now press Shift twice and type a word from that window.")
        // Shift twice is chosen, but only the chord works yet.
        let chordOnly = AskKeyNow(effectiveLabel: "⌃⇧Space", effectivePhrase: "Press ⌃⇧Space", stored: "shiftTwice")
        XCTAssertEqual(OnboardingCopy.tryItNext(chordOnly, answersAvailable: false),
                       "Now press ⌃⇧Space and type a word from that window.")
        // Nothing works: no key sentence, only "Open it for me".
        XCTAssertNil(OnboardingCopy.tryItNext(AskKeyNow(effectiveLabel: "", effectivePhrase: nil, stored: "shiftTwice"),
                                              answersAvailable: true))
        // The app published nothing: the chosen key stands in.
        let unpublished = AskKeyNow(effectiveLabel: nil, effectivePhrase: nil, stored: "rightCommand")
        XCTAssertEqual(OnboardingCopy.tryItNext(unpublished, answersAvailable: true), "Now tap right Command and ask about it.")
    }

    func testReadAgoUsesWholeSecondsInThePersonsLanguage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(OnboardingCopy.readAgo(now.addingTimeInterval(-12), now: now, locale: english), "Read 12 seconds ago")
        XCTAssertEqual(OnboardingCopy.readAgo(now, now: now, locale: english), "Read 1 second ago")
    }
}
