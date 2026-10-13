// SPDX-License-Identifier: TBD-private
//
// Ask's behaviour, against a memory that answers from fixtures: answers are
// kept across a close, "this" is promised only when it is true, at most three
// rows that never move, Return always asks, and a failure is always said.

import Foundation
import XCTest
@testable import HippocampusKit

/// Memory that answers from fixtures. A tool in `held` waits until released.
@MainActor
final class FakeAskMemory: AskMemory {
    struct Call {
        let session: AskSession
        let tool: String
        let arguments: [String: Any]
    }

    private(set) var calls: [Call] = []
    var replies: [String: Result<String, MemorySessionError>] = [:]
    var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Data, any Error>]] = [:]

    func call(_ session: AskSession, _ tool: String, arguments: Data, timeout: Duration) async throws -> Data {
        let object = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        calls.append(Call(session: session, tool: tool, arguments: object))
        if held.contains(tool) {
            return try await withCheckedThrowingContinuation { waiting[tool, default: []].append($0) }
        }
        return try reply(for: tool)
    }

    func release(_ tool: String) {
        held.remove(tool)
        let continuations = waiting.removeValue(forKey: tool) ?? []
        for continuation in continuations {
            continuation.resume(with: Result { try reply(for: tool) })
        }
    }

    func stop() async {}

    func calls(to tool: String) -> [Call] { calls.filter { $0.tool == tool } }

    private func reply(for tool: String) throws -> Data {
        switch replies[tool] {
        case .success(let json): return Data(json.utf8)
        case .failure(let error): throw error
        case nil: throw MemorySessionError.unavailable
        }
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
    func us(minutesAgo: Double) -> UInt64 { UInt64((now.timeIntervalSince1970 - minutesAgo * 60) * 1_000_000) }
}

@MainActor
final class AskPanelTests: XCTestCase {
    private let safari = FrontmostContext(bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Pricing")
    private let notes = FrontmostContext(bundleId: "com.apple.Notes", appName: "Notes", windowTitle: "Launch plan")

    private func rig(
        answers: Bool = true,
        status: MenuBarStatus = .recording
    ) -> (CommandBarModel, FakeAskMemory, TestClock) {
        let memory = FakeAskMemory()
        let clock = TestClock()
        memory.replies["mci_events_by_app"] = .success(readOfSafari(clock))
        memory.replies["mci_suggest"] = .success(Self.suggestions)
        memory.replies["mci_recall"] = .success(Self.hits)
        memory.replies["mci_ask"] = .success(answerReply(clock))
        let model = CommandBarModel(
            memory: memory,
            availability: AnswerAvailability(systemSupportsAnswers: answers),
            now: { clock.now }
        )
        model.setStatus(AskPanelStatus(status))
        return (model, memory, clock)
    }

    private func readOfSafari(_ clock: TestClock) -> String {
        #"{"events":[{"event_id":7,"ts_us":\#(clock.us(minutesAgo: 0.5)),"app_bundle_id":"com.apple.Safari","window_title":"Pricing","url":null,"text_snippet":"[app=com.apple.Safari | title=Pricing]\nPer-seat pricing."}]}"#
    }

    private func answerReply(_ clock: TestClock) -> String {
        #"""
        {"answer":"Team is $18 a seat.","sources":[
          {"n":1,"event_id":7,"ts_us":\#(clock.us(minutesAgo: 0.5)),"app":"Safari","title":"Pricing","url":null,"text":"[app=com.apple.Safari | title=Pricing]\nPer-seat pricing."},
          {"n":2,"event_id":11,"ts_us":\#(clock.us(minutesAgo: 26)),"app":"Slack","title":"#pricing","url":null,"text":"Ravi: $18 a seat."}],
         "unavailable":null}
        """#
    }

    private static let suggestions = """
    {"suggestions":[
      {"kind":"screen","title":"What’s on this screen?","why":"Safari — Pricing","action":{"ask":"What is on my screen right now, and what matters in it?"},"score":8},
      {"kind":"resume","title":"Resume: Pricing the Team plan","why":"14:09 · You set Team at $18","action":{"open_session":5},"score":7},
      {"kind":"searched","title":"“stripe per seat”","why":"You searched this at 14:03","action":{"query":"stripe per seat"},"score":6},
      {"kind":"searched","title":"“tiered pricing”","why":"You searched this at 14:01","action":{"query":"tiered pricing"},"score":6},
      {"kind":"related","title":"More about Pricing","why":"Everything you saw on this, across apps","action":{"query":"Pricing"},"score":5},
      {"kind":"day","title":"Your day so far","why":"Time, focus, searches and where you got stuck","action":{"view":"day"},"score":4},
      {"kind":"model","title":"What Hippocampus has learned about you","why":"9 things","action":{"view":"model"},"score":3}]}
    """

    private static let hits = """
    {"hits":[
      {"event_id":11,"ts_us":1,"app_bundle_id":"com.tinyspeck.slackmacgap","window_title":"#pricing","url":null,"text_snippet":"[app=Slack]\\nRavi: $18 a seat."},
      {"event_id":13,"ts_us":2,"app_bundle_id":"com.apple.Safari","window_title":"Stripe","url":"https://stripe.com/docs/billing","text_snippet":"Per-seat pricing."}]}
    """

    /// Let the model's own tasks run until `condition` holds.
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Open over `context` and wait for the window check and the home rows.
    private func open(_ model: CommandBarModel, over context: FrontmostContext?) async {
        let id = model.opened()
        model.contextArrived(context, openID: id)
        await settle()
    }

    // MARK: Never throw an answer away (product critique 1)

    func testAnAnswerComesBackWhenAskReopensWithinTenMinutes() async {
        let (model, memory, clock) = rig()
        await open(model, over: safari)
        model.ask("what did we decide on team pricing?")
        await eventually { model.answer != nil }
        model.closed()
        clock.advance(minutes: 9)
        let suggests = memory.calls(to: "mci_suggest").count
        let selects = model.selectQuestionRequest
        model.opened()
        XCTAssertEqual(model.mode, .answer)
        XCTAssertEqual(model.query, "what did we decide on team pricing?", "the field holds the question")
        XCTAssertEqual(model.selectQuestionRequest, selects + 1, "selected, so typing replaces it")
        XCTAssertEqual(model.answer?.answer, "Team is $18 a seat.")
        XCTAssertEqual(model.answer?.sources.count, 2)
        XCTAssertEqual(model.selection, -1, "Return asks again; ↓ reaches the sources")
        await settle()
        XCTAssertEqual(memory.calls(to: "mci_suggest").count, suggests, "nothing is suggested over a kept answer")
    }

    func testAnAnswerIsGoneWhenAskReopensAfterTenMinutes() async {
        let (model, _, clock) = rig()
        await open(model, over: safari)
        model.ask("what did we decide on team pricing?")
        await eventually { model.answer != nil }
        model.closed()
        clock.advance(minutes: 10.5)
        model.opened()
        XCTAssertEqual(model.mode, .home)
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.answer)
        XCTAssertNil(model.askedQuestion)
    }

    func testTheTenMinutesCountFromTheLastClose() async {
        let (model, _, clock) = rig()
        await open(model, over: safari)
        model.ask("what did we decide?")
        await eventually { model.answer != nil }
        model.closed()
        clock.advance(minutes: 8)
        model.opened()
        clock.advance(minutes: 1)
        model.closed()
        clock.advance(minutes: 8)
        model.opened()
        XCTAssertEqual(model.mode, .answer, "seventeen minutes after asking, eight after the last close")
    }

    func testARequestKeepsRunningWhileAskIsClosed() async {
        let (model, memory, clock) = rig()
        memory.held = ["mci_ask"]
        await open(model, over: safari)
        model.ask("what did we decide?")
        await eventually { memory.calls(to: "mci_ask").count == 1 }
        model.closed()
        memory.release("mci_ask")
        await settle()
        clock.advance(minutes: 2)
        model.opened()
        XCTAssertEqual(model.mode, .answer)
        XCTAssertEqual(model.answer?.answer, "Team is $18 a seat.", "the late reply is kept, not dropped")
        XCTAssertFalse(model.isAsking)
    }

    func testAKeptAnswerKeepsTheWindowItWasAskedOver() async throws {
        let (model, memory, _) = rig()
        await open(model, over: safari)
        model.ask("what is this?")
        await eventually { model.answer != nil }
        model.closed()
        let id = model.opened()
        model.contextArrived(notes, openID: id)
        await settle()
        XCTAssertEqual(model.context, safari, "the chip names the window the answer is about")
        let kept = try XCTUnwrap(model.answer)
        XCTAssertEqual(model.rows.first, .thisWindow(kept.sources[0]))
        // Esc forgets the answer; Ask is then about the window in front.
        XCTAssertTrue(model.back())
        XCTAssertEqual(model.mode, .home)
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.answer)
        XCTAssertEqual(model.context, notes)
        await eventually { memory.calls(to: "mci_suggest").last?.arguments["app"] as? String == "com.apple.Notes" }
        XCTAssertFalse(model.back(), "a second Esc closes")
    }

    func testTypingReplacesAKeptQuestion() async {
        let (model, _, _) = rig()
        await open(model, over: safari)
        model.ask("what did we decide?")
        await eventually { model.answer != nil }
        model.closed()
        model.opened()
        model.query = "launch plan"
        XCTAssertEqual(model.mode, .results)
        XCTAssertNil(model.answer)
        XCTAssertNil(model.askedQuestion)
    }

    func testCommandCCopiesTheAnswerOnlyWhenThereIsOne() async {
        let (model, _, _) = rig()
        await open(model, over: safari)
        XCTAssertNil(model.action(for: .copyAnswer), "with no answer ⌘C copies the field's selection")
        model.ask("what did we decide?")
        await eventually { model.answer != nil }
        XCTAssertEqual(model.action(for: .copyAnswer), .copy("Team is $18 a seat."))
        XCTAssertEqual(model.answerText, "Team is $18 a seat.")
    }

    // MARK: Tell the truth about "this" (product critique 2)

    func testThePlaceholderPromisesThisOnlyForAReadWindowWithAnswers() async {
        let (read, _, _) = rig()
        await open(read, over: safari)
        await eventually { read.savedRead == true }
        XCTAssertEqual(read.placeholder, "Ask about this or anything you’ve seen")
        XCTAssertEqual(read.chipStrength, 1)
        XCTAssertEqual(read.chipTooltip, "Ask about this window")

        // Never read: no saved moment, and so no screen row from the agent.
        let (unread, unreadMemory, _) = rig()
        unreadMemory.replies["mci_suggest"] = .success(#"{"suggestions":[]}"#)
        await open(unread, over: notes)
        await eventually { unread.savedRead == false }
        XCTAssertEqual(unread.placeholder, "Ask about anything you’ve seen")
        XCTAssertEqual(unread.chipStrength, 0.5)
        XCTAssertEqual(unread.chipTooltip, "Hippocampus hasn’t read this window")

        let (noAnswers, _, _) = rig(answers: false)
        await open(noAnswers, over: safari)
        XCTAssertEqual(noAnswers.placeholder, "Search anything you’ve seen")
    }

    func testPausedOffOrStoppedMeansThisWindowIsNotRead() async {
        for status in [MenuBarStatus.paused, .idle, .needsPermission(.screenRecording), .error(reason: "x")] {
            let (model, _, _) = rig(status: status)
            await open(model, over: safari)
            await eventually { model.savedRead == true }
            XCTAssertFalse(model.windowRead, "\(status)")
            XCTAssertEqual(model.placeholder, "Ask about anything you’ve seen", "\(status)")
            XCTAssertEqual(model.chipStrength, 0.5, "\(status)")
        }
    }

    func testTheAgentOfferingTheScreenIsProofOfARead() async {
        let (model, memory, _) = rig()
        memory.replies["mci_events_by_app"] = .success(#"{"events":[]}"#)
        await open(model, over: safari)
        await eventually { !model.homeRows.isEmpty }
        XCTAssertEqual(model.savedRead, true, "the agent offers the screen only when it has read it")
        XCTAssertTrue(model.windowRead)
    }

    func testWhetherTheWindowWasReadIsAskedOfTheReadsSession() async {
        let (model, memory, _) = rig()
        await open(model, over: safari)
        let check = memory.calls(to: "mci_events_by_app")
        XCTAssertEqual(check.count, 1)
        XCTAssertEqual(check.first?.session, .reads, "never queued behind an answer")
        XCTAssertEqual(check.first?.arguments["app_bundle_id"] as? String, "com.apple.Safari")
        XCTAssertTrue(memory.calls(to: "mci_suggest").allSatisfy { $0.arguments["model"] as? Bool == false },
                      "no model suggestions this round")
    }

    func testTheAgentsRuleForTheWindowInFront() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func moment(_ id: UInt64, minutesAgo: Double, title: String?, app: String = "com.apple.Safari", text: String = "Text") -> BarHit {
            let ts = UInt64((now.timeIntervalSince1970 - minutesAgo * 60) * 1_000_000)
            let json = """
            {"event_id":\(id),"ts_us":\(ts),"app_bundle_id":"\(app)","window_title":\(title.map { "\"\($0)\"" } ?? "null"),"url":null,"text_snippet":"\(text)"}
            """
            return try! JSONDecoder().decode(BarHit.self, from: Data(json.utf8))
        }
        let pricing = FrontmostContext(bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Pricing")
        let moments = [
            moment(1, minutesAgo: 1, title: "Other"),
            moment(2, minutesAgo: 9, title: "Pricing"),
            moment(3, minutesAgo: 12, title: "Pricing"),
        ]
        XCTAssertEqual(ThisWindowRead.latest(of: moments, for: pricing, now: now)?.eventId, 2, "same title within 10 minutes")
        XCTAssertNil(ThisWindowRead.latest(of: [moments[2]], for: pricing, now: now), "older than 10 minutes")
        let renamed = FrontmostContext(bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Loading…")
        XCTAssertEqual(ThisWindowRead.latest(of: moments, for: renamed, now: now)?.eventId, 1, "the app within 2 minutes")
        XCTAssertNil(ThisWindowRead.latest(of: [moment(4, minutesAgo: 3, title: "Other")], for: renamed, now: now))
        XCTAssertNil(ThisWindowRead.latest(of: [moment(5, minutesAgo: 1, title: "Pricing", app: "com.apple.Notes")], for: pricing, now: now))
        XCTAssertNil(ThisWindowRead.latest(of: [moment(6, minutesAgo: 1, title: "Pricing", text: "[app=Safari]")], for: pricing, now: now),
                     "a moment with no text is no read")
    }

    func testTheScreenSourceIsLabelledThisWindowWithItsAge() async throws {
        let (model, _, _) = rig()
        await open(model, over: safari)
        model.ask("what is this?")
        await eventually { model.answer != nil }
        guard case .thisWindow(let screen) = model.rows.first else {
            return XCTFail("the window in front comes first, as This window")
        }
        XCTAssertEqual(screen.eventId, 7)
        let answer = try XCTUnwrap(model.answer)
        XCTAssertEqual(model.rows.dropFirst().first, .source(answer.sources[1]))
    }

    func testAFirstSourceFromAnotherWindowIsNotThisWindow() async throws {
        let (model, memory, clock) = rig()
        memory.replies["mci_ask"] = .success("""
        {"answer":"From Slack.","sources":[{"n":1,"event_id":11,"ts_us":\(clock.us(minutesAgo: 1)),"app":"Slack","title":"#pricing","url":null,"text":"x"}],"unavailable":null}
        """)
        await open(model, over: notes)
        model.ask("what did Ravi say?")
        await eventually { model.answer != nil }
        let answer = try XCTUnwrap(model.answer)
        XCTAssertEqual(model.rows, [.source(answer.sources[0])])
    }

    func testAnswersAreLearnedUnavailableFromTheFirstReplyAndForgottenAfterHalfAnHour() async {
        let (model, memory, clock) = rig()
        memory.replies["mci_ask"] = .success("""
        {"answer":null,"sources":[],"unavailable":"apple_intelligence_off"}
        """)
        await open(model, over: safari)
        XCTAssertTrue(model.answersAvailable)
        model.ask("what is this?")
        await eventually { model.answer != nil }
        XCTAssertFalse(model.answersAvailable)
        XCTAssertEqual(model.answerLine, .note("Turn on Apple Intelligence in System Settings to get answers."))
        XCTAssertEqual(model.placeholder, "Search anything you’ve seen")
        XCTAssertEqual(model.footerText, "Answers need Apple Intelligence")
        model.closed()
        clock.advance(minutes: 11)
        await open(model, over: safari)
        model.query = "pricing"
        XCTAssertFalse(model.rows.contains { if case .ask = $0 { true } else { false } }, "no Ask row")
        XCTAssertEqual(model.selection, -1, "Return still asks")
        clock.advance(minutes: 30)
        model.closed()
        model.opened()
        XCTAssertTrue(model.answersAvailable, "the model is asked again after 30 minutes")
    }

    func testATimeoutSaysNothingAboutWhetherAnswersWork() {
        var availability = AnswerAvailability(systemSupportsAnswers: true)
        let now = Date()
        availability.learn(from: BarAnswer(answer: nil, sources: [], unavailable: "timed out after 60s"), at: now)
        XCTAssertTrue(availability.isAvailable(at: now))
        availability.learn(from: BarAnswer(answer: nil, sources: [], unavailable: "model_not_ready"), at: now)
        XCTAssertFalse(availability.isAvailable(at: now))
        availability.learn(from: BarAnswer(answer: "Yes.", sources: [], unavailable: nil), at: now)
        XCTAssertTrue(availability.isAvailable(at: now))
        XCTAssertFalse(AnswerAvailability(systemSupportsAnswers: false).isAvailable(at: now), "before macOS 26 there are none")
    }

    // MARK: One job (product critique 6)

    func testAtMostThreeHomeRowsAndNoneListsAPastSearch() async {
        let (model, _, _) = rig()
        await open(model, over: safari)
        await eventually { !model.homeRows.isEmpty }
        XCTAssertEqual(model.homeRows.map(\.kind), ["screen", "resume", "related"])
        XCTAssertLessThanOrEqual(model.rows.count, CommandBarModel.homeRowLimit)
        XCTAssertEqual(model.selection, 0, "What’s on this screen? is already chosen")
        let many = (0..<6).map { index in
            BarSuggestion.fixture(kind: index % 2 == 0 ? "resume" : "related", title: "Row \(index)")
        }
        XCTAssertEqual(CommandBarModel.homeRows(from: many, readsThisWindow: true).count, 3)
    }

    func testWithoutAnswersNoRowOffersToAsk() async {
        let (model, _, _) = rig(answers: false)
        await open(model, over: safari)
        await eventually { !model.homeRows.isEmpty }
        XCTAssertEqual(model.homeRows.map(\.kind), ["resume", "related"], "What’s on this screen? would promise an answer")
    }

    func testTheWindowInFrontIsOfferedOnlyWhileItIsRead() {
        let rows = [BarSuggestion.fixture(kind: "screen", title: "What’s on this screen?"),
                    BarSuggestion.fixture(kind: "resume", title: "Resume: Plan")]
        XCTAssertEqual(CommandBarModel.homeRows(from: rows, readsThisWindow: false).map(\.kind), ["resume"])
        XCTAssertEqual(CommandBarModel.homeRows(from: rows, readsThisWindow: true).map(\.kind), ["screen", "resume"])
    }

    func testHomeRowsAreAskedForOnceAndNeverMove() async {
        let (model, memory, _) = rig()
        await open(model, over: safari)
        await eventually { !model.homeRows.isEmpty }
        let first = model.homeRows
        model.query = "pricing"
        await settle()
        XCTAssertTrue(model.back())
        XCTAssertEqual(model.mode, .home)
        model.setStatus(AskPanelStatus(.unchanged))
        // A context for an open that is over changes nothing.
        model.contextArrived(notes, openID: -1)
        await settle()
        XCTAssertEqual(model.homeRows, first)
        XCTAssertEqual(memory.calls(to: "mci_suggest").count, 1, "late rows wait for the next open")
    }

    func testReturnAsksWhenTheTextIsNotAQuestion() async {
        let (model, memory, _) = rig()
        await open(model, over: safari)
        model.query = "stripe pricing"
        await eventually { !model.hits.isEmpty }
        XCTAssertEqual(model.rows.first, .ask("stripe pricing"))
        XCTAssertEqual(model.selection, 0)
        XCTAssertNil(model.activate())
        XCTAssertEqual(model.mode, .answer)
        XCTAssertEqual(model.askedQuestion, "stripe pricing")
        await eventually { memory.calls(to: "mci_ask").count == 1 }
        XCTAssertEqual(memory.calls(to: "mci_ask").first?.arguments["question"] as? String, "stripe pricing")
    }

    func testDownThenReturnOpensAMemory() async {
        let (model, _, _) = rig()
        await open(model, over: safari)
        model.query = "pricing"
        await eventually { model.hits.count == 2 }
        model.moveSelection(1)
        XCTAssertEqual(model.activate(), .openEvent(11))
        model.moveSelection(1)
        XCTAssertEqual(model.activate(), .openURL(URL(string: "https://stripe.com/docs/billing")!))
    }

    func testTheResumeRowOpensOverviewAndTheKeysOpenThePlaces() async {
        let (model, _, _) = rig()
        await open(model, over: safari)
        await eventually { !model.homeRows.isEmpty }
        model.moveSelection(1)
        XCTAssertEqual(model.activate(), .openWindow(tab: "overview"))
        XCTAssertEqual(model.action(for: .openOverview), .openWindow(tab: "overview"))
        XCTAssertEqual(model.action(for: .openYou), .openWindow(tab: "you"))
        XCTAssertEqual(model.action(for: .copyForAI), .copyForAI)
    }

    func testCommandKeysAreReadFromTheKeyAndItsModifiers() {
        XCTAssertEqual(AskKeyCommand(key: "c", command: true, shift: false, option: false, control: false), .copyAnswer)
        XCTAssertEqual(AskKeyCommand(key: "C", command: true, shift: true, option: false, control: false), .copyForAI)
        XCTAssertEqual(AskKeyCommand(key: "d", command: true, shift: false, option: false, control: false), .openOverview)
        XCTAssertEqual(AskKeyCommand(key: "u", command: true, shift: false, option: false, control: false), .openYou)
        XCTAssertEqual(AskKeyCommand(key: "q", command: true, shift: false, option: false, control: false), .close)
        XCTAssertNil(AskKeyCommand(key: "c", command: false, shift: false, option: false, control: false))
        XCTAssertNil(AskKeyCommand(key: "c", command: true, shift: false, option: true, control: false))
        XCTAssertNil(AskKeyCommand(key: "x", command: true, shift: false, option: false, control: false))
    }

    // MARK: Things go wrong out loud

    func testAFailedAnswerShowsItsNotice() async {
        let (model, memory, _) = rig()
        memory.replies["mci_ask"] = .failure(.timedOut)
        await open(model, over: safari)
        model.ask("what did we decide?")
        await eventually { !model.isAsking }
        XCTAssertEqual(model.mode, .answer)
        XCTAssertNil(model.answer)
        XCTAssertEqual(model.answerLine, .note("Couldn’t answer that. Try again."), "never an empty card")
    }

    func testAnAnswerWithoutAModelSaysWhyAndShowsTheMatches() {
        let source = BarSource.fixture(n: 1, title: "Plan")
        XCTAssertEqual(
            AnswerLine.make(answer: BarAnswer(answer: nil, sources: [source], unavailable: "device_not_eligible"), asking: false, notice: nil),
            .note("Answers need macOS 26 with Apple Intelligence. Here’s what matched:")
        )
        XCTAssertEqual(AnswerLine.make(answer: nil, asking: true, notice: nil), .thinking)
        XCTAssertEqual(
            AnswerLine.make(answer: BarAnswer(answer: "Yes.", sources: [], unavailable: nil), asking: false, notice: "x"),
            .answer("Yes.")
        )
        XCTAssertNil(AnswerLine.make(answer: nil, asking: false, notice: nil))
    }

    func testAFailedSearchIsSaid() async {
        let (model, memory, _) = rig()
        memory.replies["mci_recall"] = .failure(.timedOut)
        await open(model, over: safari)
        model.query = "pricing"
        await eventually { model.notice != nil }
        XCTAssertEqual(model.notice, "Couldn’t search. Try again.")
        XCTAssertEqual(model.mode, .results)
    }

    func testWithoutTheAgentAskSaysItIsStillStarting() async {
        let (model, memory, _) = rig()
        memory.replies["mci_suggest"] = nil
        await open(model, over: safari)
        await eventually { model.notice != nil }
        XCTAssertEqual(model.notice, "Hippocampus is still starting.")
    }

    // MARK: Order of requests (RULINGS S9)

    func testAQuestionWaitsForTheWindowInFront() async {
        let (model, memory, _) = rig()
        let id = model.opened()
        model.ask("what is this?")
        await settle()
        XCTAssertTrue(memory.calls(to: "mci_ask").isEmpty)
        XCTAssertEqual(model.answerLine, .thinking)
        model.contextArrived(safari, openID: id)
        await eventually { memory.calls(to: "mci_ask").count == 1 }
        XCTAssertEqual(memory.calls(to: "mci_ask").first?.arguments["app"] as? String, "com.apple.Safari")
        XCTAssertEqual(memory.calls(to: "mci_ask").first?.arguments["title"] as? String, "Pricing")
        XCTAssertTrue(memory.calls(to: "mci_suggest").isEmpty, "nothing is suggested under a question")
    }

    func testNothingIsSuggestedWhileAnAnswerIsBeingWritten() async {
        let (model, memory, _) = rig()
        memory.held = ["mci_ask"]
        let id = model.opened()
        model.ask("what is this?")
        model.contextArrived(safari, openID: id)
        await eventually { memory.calls(to: "mci_ask").count == 1 }
        XCTAssertTrue(model.back(), "Esc drops the question")
        await settle()
        XCTAssertTrue(memory.calls(to: "mci_suggest").isEmpty, "the assistant session is busy with the answer")
        memory.release("mci_ask")
        await eventually { memory.calls(to: "mci_suggest").count == 1 }
        await eventually { !model.homeRows.isEmpty }
        XCTAssertNil(model.answer, "the dropped question's reply is not shown")
    }

    // MARK: Footer and mark

    func testTheFooterSaysWhatRememberingIsDoingAndOffersOneFix() {
        let expected: [(MenuBarStatus, String, AskPanelStatus.Action?, HiMark.State)] = [
            (.recording, "On this Mac", nil, .remembering),
            (.unchanged, "On this Mac", nil, .remembering),
            (.starting, "Starting…", nil, .remembering),
            (.noMemory, "Nothing saved yet", nil, .remembering),
            (.paused, "Paused", .resume, .off),
            (.idle, "Off", .turnOn, .off),
            (.needsPermission(.accessibility), "Needs permission", .openSystemSettings(.accessibility), .needsYou),
            (.error(reason: "x"), "Not saving", .tryAgain, .needsYou),
            (.blocked(reason: "x"), "Not saving", .tryAgain, .needsYou),
            (.stale(reason: "x"), "Not saving", .tryAgain, .needsYou),
        ]
        for (status, text, action, mark) in expected {
            let footer = AskPanelStatus(status)
            XCTAssertEqual(footer.text, text, "\(status)")
            XCTAssertEqual(footer.action, action, "\(status)")
            XCTAssertEqual(footer.mark, mark, "\(status)")
            XCTAssertEqual(footer.mark, status.markState, "Ask's mark matches the menu bar")
        }
        XCTAssertEqual(
            [AskPanelStatus.Action.resume, .turnOn, .openSystemSettings(.screenRecording), .tryAgain].map(\.title),
            ["Resume", "Turn On", "Open System Settings…", "Try Again"]
        )
    }

    func testCopiedShowsForAMomentInPlaceOfTheStatus() async {
        let (model, _, _) = rig(status: .paused)
        await open(model, over: safari)
        XCTAssertEqual(model.footerText, "Paused")
        XCTAssertEqual(model.footerAction, .resume)
        model.showFlash("Copied")
        XCTAssertEqual(model.footerText, "Copied")
        XCTAssertNil(model.footerAction)
        model.closed()
        XCTAssertEqual(model.footerText, "Paused")
    }

    // MARK: Onboarding hears that Ask opened (RULINGS X1)

    func testAskAnnouncesItselfOnlyWhileOnboardingRuns() {
        var posted: [Notification.Name] = []
        AskPanelNotice.announceShown(onboardingRunning: false) { posted.append($0) }
        XCTAssertTrue(posted.isEmpty, "a distributed notification reaches every process of the user")
        AskPanelNotice.announceShown(onboardingRunning: true) { posted.append($0) }
        XCTAssertEqual(posted, [Notification.Name("ai.hippocampus.ask.didShow")])
    }

    // MARK: Text of a moment (RULINGS X8)

    func testASourceLosesItsHeaderLineOnlyWhenItHasOne() {
        XCTAssertEqual(BarSource.fixture(n: 1, text: "[app=com.apple.Notes | title=Plan]\nBeta ships Oct 21.\nOwner: Maya").body,
                       "Beta ships Oct 21. Owner: Maya")
        XCTAssertEqual(BarSource.fixture(n: 2, text: "Beta ships Oct 21.\nOwner: Maya").body,
                       "Beta ships Oct 21. Owner: Maya", "a first line that is not a header stays")
    }
}

extension BarSuggestion {
    static func fixture(kind: String, title: String) -> BarSuggestion {
        let json = #"{"kind":"\#(kind)","title":"\#(title)","why":"","action":{},"score":5}"#
        return try! JSONDecoder().decode(BarSuggestion.self, from: Data(json.utf8))
    }
}

extension BarSource {
    static func fixture(n: Int, title: String? = "Plan", text: String = "Text") -> BarSource {
        let object: [String: Any] = ["n": n, "event_id": n, "ts_us": 1, "app": "Notes", "title": title as Any, "text": text]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(BarSource.self, from: data)
    }
}
