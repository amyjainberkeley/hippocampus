import XCTest
@testable import OnboardingKit

final class TryItPresentationTests: XCTestCase {
    private let shiftTwice = AskKeyNow(effectiveLabel: "⇧⇧", effectivePhrase: "Press Shift twice", stored: nil)
    private let nothingOpensAsk = AskKeyNow(effectiveLabel: "", effectivePhrase: "", stored: nil)
    private let pricing = FrontWindow(bundleId: "com.apple.Safari", appName: "Safari", title: "Pricing | Stripe")

    private var proof: ReadProof {
        let row = ReadRow(
            tsUs: 1_800_000_000_000_000, appBundleId: "com.apple.Safari", windowTitle: "Pricing | Stripe",
            text: "Per-seat pricing charges for each user on the team.", sourceKind: "screen_context"
        )
        return ReadProof.choose(from: [row], lastActivatedApp: "com.apple.Safari", nameFor: { _ in "Safari" })!
    }

    private func shown(_ card: TryItViewModel.Card) -> TryItPresentation {
        TryItPresentation(card: card, keyNow: shiftTwice, understanding: nil)
    }

    // MARK: - Under a proof

    func testAProofSaysWhereItWasReadAndWhatToTryNow() {
        let shown = TryItPresentation(card: .proof(proof), keyNow: shiftTwice, understanding: .available)
        XCTAssertEqual(shown.title, "Here’s what I read from Safari")
        XCTAssertEqual(shown.proof, proof)
        XCTAssertNil(shown.heading)
        XCTAssertNil(shown.action)
        XCTAssertEqual(shown.next, "Press Shift twice and ask about it.")
        XCTAssertEqual(shown.keycaps, ["⇧", "⇧"])
        XCTAssertTrue(shown.offersOpenItForMe)
        XCTAssertEqual(shown.stopSharingNote,
                       "macOS shows an icon in the menu bar while Hippocampus reads. Stop Sharing there ends it.")
        XCTAssertNil(shown.answersNote, "answers work: nothing to explain")
        XCTAssertEqual(OnboardingCopy.proofHeading(proof), "Pricing | Stripe", "the window; the title names the app")
    }

    func testWithoutAnswersTheFirstTryIsAWordAndOneLineSaysWhy() {
        let cases: [(UnderstandingAvailability, Int, String)] = [
            // Neither Apple Intelligence nor a model on this Mac answers.
            (.noModel, 14, "Answers need Apple Intelligence or a model on this Mac. Search works now."),
            (.noModel, 15, "Answers need Apple Intelligence or a model on this Mac. Search works now."),
            (.noModel, 26, "For answers, turn on Apple Intelligence or install Ollama and a model."),
            (.preparing, 26, "Apple Intelligence is getting ready. Search works now."),
            // Set to use Apple Intelligence alone.
            (.turnedOff, 26, "Answers need Apple Intelligence. Search works without it."),
            (.unsupported, 15, "Search works. Answers need macOS 26 with Apple Intelligence."),
        ]
        for (understanding, macOS, line) in cases {
            let shown = TryItPresentation(
                card: .proof(proof), keyNow: shiftTwice, understanding: understanding, macOSMajorVersion: macOS
            )
            XCTAssertEqual(shown.next, "Press Shift twice and type a word from that window.")
            XCTAssertEqual(shown.answersNote, line)
        }
    }

    func testWhenAModelOnThisMacAnswersNothingExtraIsSaid() {
        // The check says available for Apple Intelligence and for a model
        // Ollama or LM Studio serves, on any macOS.
        for macOS in [14, 15, 26] {
            let shown = TryItPresentation(
                card: .proof(proof), keyNow: shiftTwice, understanding: .available, macOSMajorVersion: macOS
            )
            XCTAssertEqual(shown.next, "Press Shift twice and ask about it.")
            XCTAssertNil(shown.answersNote)
        }
    }

    func testWhileTheCheckRunsTheWordIsOfferedAndNothingIsSaidAboutAnswers() {
        let shown = TryItPresentation(card: .proof(proof), keyNow: shiftTwice, understanding: nil)
        XCTAssertEqual(shown.next, "Press Shift twice and type a word from that window.")
        XCTAssertNil(shown.answersNote)
    }

    func testWhenNoKeyOpensAskTheLinkIsTheWayIn() {
        let shown = TryItPresentation(card: .proof(proof), keyNow: nothingOpensAsk, understanding: .available)
        XCTAssertNil(shown.next)
        XCTAssertEqual(shown.keycaps, [])
        XCTAssertTrue(shown.offersOpenItForMe)
    }

    // MARK: - Before a proof, and after Ask

    func testOnlyAProofCarriesTheLinesUnderItAndChangesTheTitle() {
        let cards: [TryItViewModel.Card] = [
            .starting, .reading(pricing), .noWindow, .nothingToShow(pricing), .skipped(.neverRead, pricing),
            .stalled(.unknown), .notRemembering(.paused), .finished(openedForThem: false),
        ]
        for card in cards {
            let shown = TryItPresentation(card: card, keyNow: shiftTwice, understanding: .turnedOff)
            XCTAssertEqual(shown.title, "Try it", "\(card)")
            XCTAssertNil(shown.proof, "\(card)")
            XCTAssertNil(shown.next, "\(card)")
            XCTAssertEqual(shown.keycaps, [], "\(card)")
            XCTAssertFalse(shown.offersOpenItForMe, "\(card)")
            XCTAssertNil(shown.stopSharingNote, "Stop Sharing is explained once something was read")
            XCTAssertNil(shown.answersNote, "the answers line shows only under a proof")
        }
    }

    func testReadingNamesTheWindowInFront() {
        let reading = shown(.reading(pricing))
        XCTAssertEqual(reading.heading, "Reading Safari…")
        XCTAssertEqual(reading.detail, "Pricing | Stripe")
        XCTAssertEqual(reading.icon, .app(bundleId: "com.apple.Safari", skipped: false))
        XCTAssertTrue(reading.isWorking)
        XCTAssertNil(reading.action)
        XCTAssertEqual(reading.spoken, "Reading Safari… Pricing | Stripe")

        let untitled = shown(.reading(FrontWindow(bundleId: "com.apple.TextEdit", appName: "TextEdit", title: nil)))
        XCTAssertEqual(untitled.heading, "Reading TextEdit…")
        XCTAssertNil(untitled.detail)

        XCTAssertEqual(shown(.starting).heading, "Turning on…")
        XCTAssertTrue(shown(.starting).isWorking)
        XCTAssertNil(shown(.starting).icon)
    }

    func testASkippedWindowSaysWhyAndSuggestsAnother() {
        let passwords = FrontWindow(bundleId: "com.apple.Passwords", appName: "Passwords", title: nil)
        let cases: [(SkipReason, FrontWindow, String)] = [
            (.neverRead, passwords, "Passwords is never read."),
            (.excluded, FrontWindow(bundleId: "com.apple.MobileSMS", appName: "Messages", title: nil),
             "Messages is skipped, as you asked."),
            (.privateWindow, FrontWindow(bundleId: "com.google.Chrome", appName: "Google Chrome", title: "New Incognito Tab"),
             "This private window is skipped."),
        ]
        for (reason, window, heading) in cases {
            let skipped = shown(.skipped(reason, window))
            XCTAssertEqual(skipped.heading, heading)
            XCTAssertEqual(skipped.detail, "Switch to another window to try it.")
            XCTAssertEqual(skipped.icon, .app(bundleId: window.bundleId, skipped: true))
            XCTAssertNil(skipped.action, "nothing to press: another window is the way on")
            XCTAssertFalse(skipped.isWorking)
        }
        let field = shown(.skipped(.passwordField, pricing))
        XCTAssertEqual(field.heading, "Nothing is read while a password field is in use.")
        XCTAssertEqual(field.detail, "Switch to another window to try it.")
        XCTAssertEqual(field.icon, .symbol("lock"))
    }

    func testNothingToReadSaysWhatToOpen() {
        let finder = FrontWindow(bundleId: "com.apple.finder", appName: "Finder", title: "Applications")
        let nothing = shown(.nothingToShow(finder))
        XCTAssertEqual(nothing.heading, "Nothing to read in Finder yet.")
        XCTAssertEqual(nothing.detail, "Open a page, a document or a chat.")
        XCTAssertEqual(nothing.icon, .app(bundleId: "com.apple.finder", skipped: false))
        let none = shown(.noWindow)
        XCTAssertEqual(none.heading, "No window to read yet.")
        XCTAssertEqual(none.detail, "Open a page, a document or a chat.")
        XCTAssertEqual(none.icon, .symbol("macwindow"))
    }

    func testEachOtherCardSaysItsLineWithItsOneButton() {
        XCTAssertEqual(shown(.stalled(.unknown)).heading, "Still nothing read.")
        XCTAssertNil(shown(.stalled(.unknown)).detail)
        XCTAssertEqual(shown(.stalled(.unknown)).action, .tryAgain)
        let off = shown(.stalled(.permissionOff(.accessibility)))
        XCTAssertEqual(off.heading, "Accessibility is off.")
        XCTAssertEqual(off.detail, "Turn it on in System Settings.", "nothing is dropped")
        XCTAssertEqual(off.action, .openSettings(.accessibility))
        XCTAssertEqual(shown(.notRemembering(.paused)).heading, "Remembering is paused.")
        XCTAssertEqual(shown(.notRemembering(.paused)).detail, "Resume it from the menu bar.")
        XCTAssertEqual(shown(.notRemembering(.off)).heading, "Remembering is off.")
        XCTAssertEqual(shown(.notRemembering(.off)).detail, "Turn it on from the menu bar.")
        XCTAssertNil(shown(.notRemembering(.off)).action)
        XCTAssertEqual(shown(.finished(openedForThem: false)).finished, "That’s it. Shift twice works anywhere.")
        XCTAssertEqual(shown(.finished(openedForThem: true)).finished, "That’s Ask. Press Shift twice to open it anywhere.")
    }

    func testTheLinksAreTheAppsRoutes() {
        // Contract section 3b.
        XCTAssertEqual(AppLink.ask.absoluteString, "hippocampus://ask")
        XCTAssertEqual(AppLink.restart.absoluteString, "hippocampus://restart")
        // The app's own name for the fresh read setup asks for.
        XCTAssertEqual(SetupReadRequest.notification.rawValue, "ai.hippocampus.setup.readFrontWindow")
    }
}
