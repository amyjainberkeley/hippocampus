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
}

@MainActor
final class TryItViewModelTests: XCTestCase {
    private func row(_ ts: UInt64, _ app: String = "com.apple.Notes", text: String = "We agreed to ship the pricing page next week.") -> ReadRow {
        ReadRow(tsUs: ts, appBundleId: app, windowTitle: "Launch plan", text: text, sourceKind: "screen_ocr")
    }

    private func makeVM(
        _ reads: ScriptedReads, clock: TestClock, remembering: RememberingState = .on,
        permissions: MainBox<(screenRecording: Bool, accessibility: Bool)> = MainBox((true, true))
    ) -> TryItViewModel {
        TryItViewModel(
            probe: reads, startedAt: clock.now, cursorTsUs: 1_000, remembering: remembering,
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
            ("com.apple.Safari", "Safari", .needsExtension(browser: "Safari")),
            ("company.thebrowser.Browser", "Arc", .needsExtension(browser: "Arc")),
            ("com.google.Chrome", "Google Chrome", .browserWillAsk(browser: "Google Chrome")),
            ("org.mozilla.firefox", "Firefox", .unreadBrowser(browser: "Firefox")),
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
        XCTAssertEqual(OnboardingCopy.waitingText(.needsExtension(browser: "Safari")),
                       "Safari isn’t read until you add the extension.")
        XCTAssertEqual(OnboardingCopy.waitingText(.browserWillAsk(browser: "Google Chrome")),
                       "macOS will ask about Google Chrome. Choose Allow so Hippocampus can skip private windows.")
        XCTAssertEqual(OnboardingCopy.waitingText(.unreadBrowser(browser: "Firefox")),
                       "Firefox isn’t read. Try a document, note or chat.")
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
        vm.appActivated(bundleId: "com.apple.Safari", name: "Safari")
        await vm.tick()
        XCTAssertEqual(vm.card, .stalled(.frontApp(.needsExtension(browser: "Safari"))))

        vm.appActivated(bundleId: "com.apple.TextEdit", name: "TextEdit")
        await vm.tick()
        XCTAssertEqual(vm.card, .stalled(.unknown))
        XCTAssertEqual(OnboardingCopy.stalledText(.unknown), "Still nothing read.")
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
        XCTAssertEqual(vm.card, .finished)
        await run(vm, clock, for: 3)
        XCTAssertEqual(vm.card, .finished)
        XCTAssertEqual(OnboardingCopy.tryItFinished(.shiftTwice), "That’s it. Shift twice works anywhere.")
        XCTAssertEqual(OnboardingCopy.tryItFinished(.rightShift), "That’s it. Right Shift works anywhere.")
        XCTAssertEqual(OnboardingCopy.tryItFinished(.chord), "That’s it. Control-Shift-Space works anywhere.")
        XCTAssertEqual(TryItViewModel.askDidShowNotification.rawValue, "ai.hippocampus.ask.didShow")
    }

    func testAskOpeningWhileReadingStopsStillEndsTheScreen() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock, batches: [.rows([row(2_000)], newestTsUs: 2_000)])
        let vm = makeVM(reads, clock: clock)
        reads.onStop = { await MainActor.run { vm.askDidShow() } }
        await run(vm, clock, for: 32)
        XCTAssertFalse(vm.isReading)
        XCTAssertEqual(vm.card, .finished)
    }

    func testRunStopsTheReaderWhenAskOpens() async {
        let clock = TestClock()
        let reads = ScriptedReads(clock: clock)
        let vm = makeVM(reads, clock: clock)
        vm.askDidShow()
        await vm.run(sleep: { _ in clock.advance(1) })
        XCTAssertGreaterThanOrEqual(reads.stops, 1)
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

    func testWhatToTryNextFollowsTheKeyAndWhetherAnswersWork() {
        XCTAssertEqual(OnboardingCopy.tryItNext(.shiftTwice, answersAvailable: true), "Now press Shift twice and ask about it.")
        XCTAssertEqual(OnboardingCopy.tryItNext(.shiftTwice, answersAvailable: false),
                       "Now press Shift twice and type a word from that window.")
        XCTAssertEqual(OnboardingCopy.tryItNext(.rightCommand, answersAvailable: true), "Now tap right Command and ask about it.")
        XCTAssertEqual(OnboardingCopy.tryItNext(.chord, answersAvailable: false),
                       "Now press Control-Shift-Space and type a word from that window.")
    }

    func testReadAgoUsesWholeSecondsInThePersonsLanguage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(OnboardingCopy.readAgo(now.addingTimeInterval(-12), now: now, locale: english), "Read 12 seconds ago")
        XCTAssertEqual(OnboardingCopy.readAgo(now, now: now, locale: english), "Read 1 second ago")
    }
}
