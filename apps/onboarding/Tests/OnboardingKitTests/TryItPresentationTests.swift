import XCTest
@testable import OnboardingKit

final class TryItPresentationTests: XCTestCase {
    private let shiftTwice = AskKeyNow(effectiveLabel: "⇧⇧", effectivePhrase: "Press Shift twice", stored: nil)
    private let nothingOpensAsk = AskKeyNow(effectiveLabel: "", effectivePhrase: "", stored: nil)

    private var proof: ReadProof {
        let row = ReadRow(
            tsUs: 1_800_000_000_000_000, appBundleId: "com.apple.Notes", windowTitle: "Launch plan",
            text: "Beta ships to forty design partners on October 21.", sourceKind: "screen_ocr"
        )
        return ReadProof.choose(from: [row], lastActivatedApp: nil, nameFor: { _ in "Notes" })!
    }

    // MARK: - Under a proof

    func testAProofCarriesWhatToTryAndWhatToKnow() {
        let shown = TryItPresentation(card: .proof(proof), keyNow: shiftTwice, understanding: .available)
        XCTAssertEqual(shown.proof, proof)
        XCTAssertNil(shown.message)
        XCTAssertNil(shown.action)
        XCTAssertEqual(shown.next, "Now press Shift twice and ask about it.")
        XCTAssertEqual(shown.keycaps, ["⇧", "⇧"])
        XCTAssertTrue(shown.offersOpenItForMe)
        XCTAssertEqual(shown.stopSharingNote,
                       "macOS shows an icon in the menu bar while Hippocampus reads. Stop Sharing there ends it.")
        XCTAssertNil(shown.answersNote, "answers work: nothing to explain")
    }

    func testWithoutAnswersTheFirstTryIsAWordAndOneLineSaysWhy() {
        let cases: [(UnderstandingAvailability, String)] = [
            (.turnedOff, "Answers need Apple Intelligence. Search works without it."),
            (.preparing, "Apple Intelligence is getting ready. Search works now."),
            (.unsupported, "Search works. Answers need macOS 26 with Apple Intelligence."),
        ]
        for (understanding, line) in cases {
            let shown = TryItPresentation(card: .proof(proof), keyNow: shiftTwice, understanding: understanding)
            XCTAssertEqual(shown.next, "Now press Shift twice and type a word from that window.")
            XCTAssertEqual(shown.answersNote, line)
        }
    }

    func testWhileTheCheckRunsTheWordIsOfferedAndNothingIsSaidAboutAnswers() {
        let shown = TryItPresentation(card: .proof(proof), keyNow: shiftTwice, understanding: nil)
        XCTAssertEqual(shown.next, "Now press Shift twice and type a word from that window.")
        XCTAssertNil(shown.answersNote)
    }

    func testWhenNoKeyOpensAskTheLinkIsTheWayIn() {
        let shown = TryItPresentation(card: .proof(proof), keyNow: nothingOpensAsk, understanding: .available)
        XCTAssertNil(shown.next)
        XCTAssertEqual(shown.keycaps, [])
        XCTAssertTrue(shown.offersOpenItForMe)
    }

    // MARK: - Before a proof, and after Ask

    func testOnlyAProofCarriesTheLinesUnderIt() {
        let cards: [TryItViewModel.Card] = [
            .starting, .waiting(.ordinary), .stalled(.unknown), .notRemembering(.paused), .finished(openedForThem: false),
        ]
        for card in cards {
            let shown = TryItPresentation(card: card, keyNow: shiftTwice, understanding: .turnedOff)
            XCTAssertNil(shown.proof, "\(card)")
            XCTAssertNil(shown.next, "\(card)")
            XCTAssertEqual(shown.keycaps, [], "\(card)")
            XCTAssertFalse(shown.offersOpenItForMe, "\(card)")
            XCTAssertNil(shown.stopSharingNote, "Stop Sharing is explained once something was read")
            XCTAssertNil(shown.answersNote, "the Apple Intelligence line shows only under a proof")
        }
    }

    func testEachCardSaysItsLineWithItsOneButton() {
        func shown(_ card: TryItViewModel.Card) -> TryItPresentation {
            TryItPresentation(card: card, keyNow: shiftTwice, understanding: nil)
        }
        XCTAssertEqual(shown(.starting).message, "Turning on…")
        XCTAssertTrue(shown(.starting).isWorking)
        XCTAssertFalse(shown(.waiting(.ordinary)).isWorking)
        XCTAssertNil(shown(.waiting(.ordinary)).action)
        XCTAssertEqual(shown(.waiting(.needsExtension(browser: "Safari"))).action, .addExtension)
        XCTAssertNil(shown(.waiting(.browserWillAsk(browser: "Google Chrome"))).action)
        XCTAssertEqual(shown(.stalled(.unknown)).message, "Still nothing read.")
        XCTAssertEqual(shown(.stalled(.unknown)).action, .tryAgain)
        XCTAssertEqual(shown(.stalled(.permissionOff(.accessibility))).action, .openSettings(.accessibility))
        XCTAssertEqual(shown(.stalled(.frontApp(.needsExtension(browser: "Arc")))).action, .addExtension)
        XCTAssertEqual(shown(.notRemembering(.paused)).message, "Remembering is paused. Resume it from the menu bar.")
        XCTAssertEqual(shown(.notRemembering(.off)).message, "Remembering is off. Turn it on from the menu bar.")
        XCTAssertNil(shown(.notRemembering(.off)).action)
        XCTAssertEqual(shown(.finished(openedForThem: false)).finished, "That’s it. Shift twice works anywhere.")
        XCTAssertEqual(shown(.finished(openedForThem: true)).finished, "That’s Ask. Press Shift twice to open it anywhere.")
    }

    func testAMessageIsDrawnAsItsFirstSentenceAndTheRestWithNothingDropped() {
        let two = TryItPresentation(card: .waiting(.ordinary), keyNow: shiftTwice, understanding: nil)
        let parts = two.messageParts
        XCTAssertEqual(parts?.heading, "Nothing read yet.")
        XCTAssertEqual(parts?.detail, "Open a document, note or chat, then come back.")
        XCTAssertEqual(parts.map { "\($0.heading) \($0.detail ?? "")" }, two.message)

        let one = TryItPresentation(card: .stalled(.unknown), keyNow: shiftTwice, understanding: nil)
        XCTAssertEqual(one.messageParts?.heading, "Still nothing read.")
        XCTAssertNil(one.messageParts?.detail)
        XCTAssertNil(TryItPresentation(card: .proof(proof), keyNow: shiftTwice, understanding: nil).messageParts)
    }

    func testTheLinksAreTheAppsRoutes() {
        // Contract section 3b.
        XCTAssertEqual(AppLink.ask.absoluteString, "hippocampus://ask")
        XCTAssertEqual(AppLink.restart.absoluteString, "hippocampus://restart")
    }
}
