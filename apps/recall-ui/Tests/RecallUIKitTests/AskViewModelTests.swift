import Combine
import Foundation
import XCTest
@testable import RecallUIKit

/// Ask's one field: matches as you type, answers on Return, History while it
/// is empty (spec-recall S3, critique-recall-engineering findings 2, 5 and 16,
/// critique-recall-product findings 3 and 9).
@MainActor
final class AskViewModelTests: XCTestCase {
    private static let expected = AskAnswer(answer: "Tuesday, in tax.rs.", unavailable: nil, sources: [])
    private var answer: AskAnswer { Self.expected }

    private func model(_ understanding: ScriptedUnderstanding,
                       deletions: MemoryDeletionSignal = MemoryDeletionSignal()) -> AskViewModel {
        let reader = StubBrainReader()
        let search = SearchViewModel(reader: reader,
                                     persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"],
                                                                   store: MemoryKeyValueStore()),
                                     userDictionaryLoader: { .empty })
        let history = TimelineViewModel(reader: reader, deletions: deletions)
        return AskViewModel(search: search, history: history, understanding: understanding,
                            calendar: SampleDay.calendar, deletions: deletions)
    }

    func testOnlyAWholeFirstWordOrAQuestionMarkMakesAQuestion() {
        for question in ["what did I read about tax rounding", "What\u{2019}s on my screen", "whats the plan",
                         "how?", "invoice 2291?", "Who sent the invoice", "tell me about the tax fix",
                         "is the build green", "  when did I last open Figma  ", "\u{201C}what\u{201D} did Priya say"] {
            XCTAssertTrue(AskIntent.looksLikeQuestion(question), question)
        }
        for search in ["whatsapp invoices", "howard notes", "whole foods receipt", "how", "Who", "",
                       "   ", "invoice 2291", "tax.rs", "whenever we meet", "isolated test"] {
            XCTAssertFalse(AskIntent.looksLikeQuestion(search), search)
        }
    }

    func testReturnAsksAQuestionAndMovesToTheMatchesForWords() async {
        let understanding = ScriptedUnderstanding()
        await understanding.setAnswer(answer, for: "when did I fix the tax bug?")
        let ask = model(understanding)
        ask.query = "privacy"
        await ask.search.runSearch()
        XCTAssertEqual(ask.submit(), .focusFirstMatch)
        ask.query = "invoice 2291"
        await ask.search.runSearch()
        XCTAssertEqual(ask.submit(), .nothing)
        let none = await understanding.questions
        XCTAssertTrue(none.isEmpty, "words are searched, never sent to the model")

        ask.query = "when did I fix the tax bug?"
        XCTAssertEqual(ask.submit(), .asked)
        await assertEventually { await MainActor.run { ask.answerState != .thinking(question: "when did I fix the tax bug?") } }
        XCTAssertEqual(ask.answerState, .answered(question: "when did I fix the tax bug?", answer: answer))
        let asked = await understanding.questions
        XCTAssertEqual(asked, ["when did I fix the tax bug?"])
    }

    func testCommandReturnAsksWhateverIsTyped() async {
        let understanding = ScriptedUnderstanding()
        await understanding.setAnswer(answer, for: "invoice 2291")
        let ask = model(understanding)
        ask.query = "  invoice 2291 "
        XCTAssertEqual(ask.submit(forceAsk: true), .asked)
        XCTAssertEqual(ask.answerState, .thinking(question: "invoice 2291"))
        await assertEventually { await understanding.questions == ["invoice 2291"] }
    }

    func testAnAnswerShowsWhileItsQuestionIsInTheFieldAndComesBackWithIt() async {
        let understanding = ScriptedUnderstanding()
        await understanding.setAnswer(answer, for: "what changed in tax.rs")
        let ask = model(understanding)
        ask.query = "what changed in tax.rs"
        ask.submit()
        await assertEventually { await MainActor.run { ask.answerState == .answered(question: "what changed in tax.rs", answer: AskViewModelTests.expected) } }
        ask.query = "what changed in tax.rs today"
        XCTAssertEqual(ask.answerState, .none, "another question has no answer yet")
        ask.clear()
        XCTAssertEqual(ask.query, "")
        ask.query = "what changed in tax.rs"
        XCTAssertEqual(ask.answerState, .answered(question: "what changed in tax.rs", answer: answer),
                       "kept for the life of the window")
        let asked = await understanding.questions
        XCTAssertEqual(asked.count, 1)
    }

    func testANewQuestionStopsTheOneInFlightAndOnlyTheNewOneIsAnswered() async {
        let understanding = ScriptedUnderstanding()
        await understanding.setAnswer(answer, for: "who reviewed the pricing page")
        await understanding.setAnswer(answer, for: "when is the October sale")
        await understanding.holdNextQuestion()
        let ask = model(understanding)
        ask.query = "who reviewed the pricing page"
        ask.submit()
        await assertEventually { await understanding.waiting }
        ask.query = "when is the October sale"
        ask.submit()
        await assertEventually { await understanding.cancelledQuestions == ["who reviewed the pricing page"] }
        await assertEventually { await MainActor.run { ask.answerState == .answered(question: "when is the October sale", answer: AskViewModelTests.expected) } }
        ask.query = "who reviewed the pricing page"
        XCTAssertEqual(ask.answerState, .none, "a stopped question keeps nothing")
    }

    func testAskingTheQuestionAlreadyInFlightDoesNotAskAgain() async {
        let understanding = ScriptedUnderstanding()
        await understanding.setAnswer(answer, for: "what did I search for")
        await understanding.holdNextQuestion()
        let ask = model(understanding)
        ask.query = "what did I search for"
        ask.submit()
        await assertEventually { await understanding.waiting }
        ask.submit()
        ask.submit(forceAsk: true)
        await understanding.release()
        await assertEventually { await MainActor.run { ask.answerState != .thinking(question: "what did I search for") } }
        let asked = await understanding.questions
        XCTAssertEqual(asked, ["what did I search for"])
    }

    func testAQuestionThatCannotBeAskedSaysSo() async {
        let understanding = ScriptedUnderstanding()
        await understanding.failAnswer(for: "what is due friday")
        let ask = model(understanding)
        ask.query = "what is due friday"
        ask.submit()
        await assertEventually { await MainActor.run { ask.answerState == .failed(question: "what is due friday") } }
        XCTAssertFalse(ask.showsNoMatches)
    }

    func testNoMatchesIsNeverShownForAQuestionNotYetAsked() async {
        let ask = model(ScriptedUnderstanding())
        ask.query = "what did Priya say about the annual plan"
        XCTAssertFalse(ask.showsNoMatches, "still searching")
        await ask.search.runSearch()
        XCTAssertTrue(ask.search.hits.isEmpty)
        XCTAssertFalse(ask.showsNoMatches, "a question waits for Return, not for matches")
        ask.query = "annual plan"
        await ask.search.runSearch()
        XCTAssertTrue(ask.showsNoMatches)
        ask.query = "privacy"
        await ask.search.runSearch()
        XCTAssertFalse(ask.showsNoMatches)
    }

    func testWhenAnswersCannotComeReturnSearchesAndNoMatchesIsTrue() async {
        let understanding = ScriptedUnderstanding()
        let off = AskAnswer(answer: nil, unavailable: "apple_intelligence_off", sources: [])
        await understanding.setAnswer(off, for: "what did I read today")
        let ask = model(understanding)
        XCTAssertNil(ask.answersAvailable)
        ask.query = "what did I read today"
        ask.submit()
        await assertEventually { await MainActor.run { ask.answersAvailable == false } }
        XCTAssertEqual(ask.answerState, .answered(question: "what did I read today", answer: off))

        ask.query = "what did Priya send"
        await ask.search.runSearch()
        XCTAssertEqual(ask.submit(), .nothing, "Return searches while answers cannot come")
        XCTAssertTrue(ask.showsNoMatches)
        let asked = await understanding.questions
        XCTAssertEqual(asked, ["what did I read today"])
    }

    func testTheModelsStatusSaysWhetherAnswersCanComeUntilAReplyDoes() {
        let ask = model(ScriptedUnderstanding())
        ask.note(ModelStatus(state: .unknown, reason: nil, checkedUs: nil))
        XCTAssertNil(ask.answersAvailable)
        ask.note(ModelStatus(state: .unavailable, reason: "model_not_ready", checkedUs: 1))
        XCTAssertNil(ask.answersAvailable, "still getting ready: it may answer")
        ask.note(ModelStatus(state: .unavailable, reason: "device_not_eligible", checkedUs: 1))
        XCTAssertEqual(ask.answersAvailable, false)
        ask.note(ModelStatus(state: .available, reason: nil, checkedUs: 2))
        XCTAssertEqual(ask.answersAvailable, false, "once known, a status does not overrule it")
    }

    func testEscapeClosesTheDetailThenTheSelectionThenStopsTheQuestionThenEmptiesTheField() async {
        let understanding = ScriptedUnderstanding()
        await understanding.holdNextQuestion()
        let ask = model(understanding)
        ask.query = "MCI"
        await ask.search.runSearch()
        XCTAssertFalse(ask.search.hits.isEmpty)
        ask.search.selectedHitId = ask.search.hits.first?.id
        ask.search.focusDetail()
        XCTAssertEqual(ask.submit(forceAsk: true), .asked)
        await assertEventually { await understanding.waiting }

        XCTAssertEqual(ask.escape(), .closedDetail)
        XCTAssertFalse(ask.search.isDetailFocused)
        XCTAssertNotNil(ask.search.selectedHitId)
        XCTAssertEqual(ask.escape(), .clearedSelection)
        XCTAssertNil(ask.search.selectedHitId)
        XCTAssertEqual(ask.escape(), .stoppedQuestion)
        XCTAssertEqual(ask.query, "MCI", "stopping a question keeps what was typed")
        await assertEventually { await understanding.cancelledQuestions == ["MCI"] }
        XCTAssertEqual(ask.escape(), .clearedField)
        XCTAssertEqual(ask.query, "")
        XCTAssertTrue(ask.showsHistory)
        XCTAssertEqual(ask.escape(), .ignored)
    }

    func testEscapeInHistoryClosesItsDetailThenItsSelection() async {
        let ask = model(ScriptedUnderstanding())
        await ask.history.reload()
        ask.history.selectedHitId = ask.history.hits.first?.id
        ask.history.focusDetail()
        XCTAssertTrue(ask.showsHistory)
        XCTAssertEqual(ask.escape(), .closedDetail)
        XCTAssertEqual(ask.escape(), .clearedSelection)
        XCTAssertNil(ask.history.selectedHitId)
        XCTAssertEqual(ask.escape(), .ignored)
    }

    /// A moment opened from outside (`focus=<moment>`, a moment from the Ask
    /// panel) shows in History on its own day, selected, with an empty
    /// field (SPEC 2.16): not alone in the field's results.
    func testAMomentOpenedFromOutsideShowsInHistoryOnItsOwnDay() async {
        let ask = model(ScriptedUnderstanding())
        ask.query = "something typed"
        await ask.open(RecallRoute(environment: ["MCI_INITIAL_FOCUS_EVENT_ID": "102"]))
        XCTAssertEqual(ask.query, "")
        XCTAssertNil(ask.search.focusedEventId, "not one moment alone in the field's results")
        XCTAssertTrue(ask.showsHistory)
        XCTAssertEqual(ask.history.day, MemoryDay(date: Date(timeIntervalSince1970: 1_736_000_120), calendar: SampleDay.calendar))
        XCTAssertEqual(ask.history.range, 1_736_000_120_000_000...1_736_000_120_000_000)
        XCTAssertEqual(ask.history.hits.map(\.id), [102])
        XCTAssertEqual(ask.history.selectedHitId, 102)
        XCTAssertTrue(ask.history.canLoadEarlier, "the rest of its day is under it")
        XCTAssertEqual(ask.escape(), .clearedSelection)
        XCTAssertTrue(ask.showsHistory)
    }

    /// Show in History from Working On, Web Pages and Looked Up sends the
    /// moment alone: it opens exactly as Today's card and the sidebar's Show
    /// in History do (`.history(of:selecting:)` over the moment's time).
    func testShowInHistoryWithAMomentAloneOpensWhatTheSessionsRouteOpens() async {
        let alone = model(ScriptedUnderstanding())
        alone.query = "tax"
        await alone.open(RecallRoute(place: .ask, clearsField: true, focusEventId: 101))
        let session = model(ScriptedUnderstanding())
        let us: Int64 = 1_736_000_000_000_000
        await session.open(.history(of: us...us, selecting: 101))
        for ask in [alone, session] {
            XCTAssertEqual(ask.query, "")
            XCTAssertTrue(ask.showsHistory)
        }
        XCTAssertEqual(alone.history.day, session.history.day)
        XCTAssertEqual(alone.history.range, session.history.range)
        XCTAssertEqual(alone.history.hits.map(\.id), session.history.hits.map(\.id))
        XCTAssertEqual(alone.history.selectedHitId, 101)
        XCTAssertEqual(session.history.selectedHitId, 101)
    }

    /// A moment that can no longer be read (forgotten since) leaves History
    /// where it was, with nothing picked and the field empty.
    func testAMomentThatIsGoneLeavesHistoryWhereItWas() async {
        let ask = model(ScriptedUnderstanding())
        let before = ask.history.day
        await ask.open(RecallRoute(place: .ask, clearsField: true, focusEventId: 999))
        XCTAssertTrue(ask.showsHistory)
        XCTAssertNil(ask.search.focusedEventId)
        XCTAssertEqual(ask.history.day, before)
        XCTAssertNil(ask.history.selectedHitId)
    }

    func testShowInHistoryOpensHistoryOnTheSessionsOwnTime() async {
        let ask = model(ScriptedUnderstanding())
        ask.query = "tax"
        let session: ClosedRange<Int64> = 1_736_000_100_000_000...1_736_000_200_000_000
        await ask.open(.history(of: session, selecting: 102))
        XCTAssertEqual(ask.query, "")
        XCTAssertTrue(ask.showsHistory)
        XCTAssertEqual(ask.history.range, 1_736_000_100_000_000...1_736_000_200_000_000)
        XCTAssertEqual(ask.history.hits.map(\.id), [102])
        XCTAssertEqual(ask.history.selectedHitId, 102)
        XCTAssertEqual(ask.history.day, MemoryDay(date: Date(timeIntervalSince1970: 1_736_000_100), calendar: SampleDay.calendar))
    }

    func testRoutesThatPutTheCursorInTheFieldSaySo() async {
        let ask = model(ScriptedUnderstanding())
        ask.query = "kept"
        await ask.open(.findInAsk)
        XCTAssertEqual(ask.fieldFocusRequest, 1)
        XCTAssertEqual(ask.query, "kept")
        await ask.open(.newQuestion)
        XCTAssertEqual(ask.fieldFocusRequest, 2)
        XCTAssertEqual(ask.query, "")
    }

    func testAskRedrawsWhenTheSearchOrHistoryChanges() async {
        let ask = model(ScriptedUnderstanding())
        var changes = 0
        let watch = ask.objectWillChange.sink { changes += 1 }
        ask.search.query = "privacy"
        XCTAssertGreaterThan(changes, 0)
        let before = changes
        await ask.history.reload()
        XCTAssertGreaterThan(changes, before)
        watch.cancel()
    }

    func testADeleteDropsEveryAnswerAndStopsTheQuestionInFlight() async {
        let signal = MemoryDeletionSignal()
        let understanding = ScriptedUnderstanding()
        await understanding.setAnswer(answer, for: "what changed in tax.rs")
        let ask = model(understanding, deletions: signal)
        ask.query = "what changed in tax.rs"
        ask.submit()
        await assertEventually { await MainActor.run { ask.answerState == .answered(question: "what changed in tax.rs", answer: AskViewModelTests.expected) } }
        await understanding.holdNextQuestion()
        ask.query = "who sent invoice 2291"
        ask.submit()
        await assertEventually { await understanding.waiting }
        signal.post()
        await assertEventually { await understanding.cancelledQuestions == ["who sent invoice 2291"] }
        XCTAssertEqual(ask.answerState, .none)
        ask.query = "what changed in tax.rs"
        XCTAssertEqual(ask.answerState, .none, "an answer may quote what was deleted")
    }

    func testLeavingAskStopsTheQuestionInFlight() async {
        let understanding = ScriptedUnderstanding()
        await understanding.holdNextQuestion()
        let ask = model(understanding)
        ask.query = "what did I do this morning"
        ask.submit()
        await assertEventually { await understanding.waiting }
        ask.disappear()
        XCTAssertEqual(ask.answerState, .none)
        await assertEventually { await understanding.cancelledQuestions == ["what did I do this morning"] }
    }
}
