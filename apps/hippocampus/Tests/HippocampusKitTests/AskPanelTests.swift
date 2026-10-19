// SPDX-License-Identifier: Apache-2.0
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
      {"kind":"screen","title":"What’s on this screen?","why":"Safari · Pricing","action":{"ask":"What is on my screen right now, and what matters in it?"},"score":8},
      {"kind":"resume","title":"Resume: Pricing the Team plan","why":"You set Team at $18.","action":{"open_session":5},"score":7,"ts_us":5},
      {"kind":"searched","title":"“stripe per seat”","why":"You searched for this","action":{"query":"stripe per seat"},"score":6,"ts_us":3},
      {"kind":"searched","title":"“tiered pricing”","why":"You searched for this","action":{"query":"tiered pricing"},"score":6,"ts_us":1},
      {"kind":"related","title":"More about Pricing","why":"Everything else you saw about this","action":{"query":"Pricing"},"score":5},
      {"kind":"day","title":"Your day so far","why":"What you worked on and looked up","action":{"view":"day"},"score":4},
      {"kind":"model","title":"What Hippocampus understands about you","why":"9 things, from your own work. Fix anything wrong.","action":{"view":"model"},"score":3}]}
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
            XCTAssertEqual(model.chipTooltip, "Hippocampus isn’t reading this window",
                           "it was read before; it is not being read now (\(status))")
        }
    }

    func testTheChipSaysNothingAboutAReadItHasNotCheckedYet() async {
        let (model, memory, _) = rig()
        memory.held = ["mci_events_by_app", "mci_suggest"]
        await open(model, over: safari)
        XCTAssertNil(model.savedRead)
        XCTAssertNil(model.chipTooltip)
        XCTAssertEqual(model.chipStrength, 0.5)
        memory.release("mci_events_by_app")
        await eventually { model.savedRead == true }
        XCTAssertEqual(model.chipTooltip, "Ask about this window")
        memory.release("mci_suggest")
        await settle()
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

    /// The same file open in two editors: a title is no proof of the window.
    func testASourceWithThisWindowsTitleFromAnotherAppIsNotThisWindow() async throws {
        let xcode = FrontmostContext(bundleId: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "Package.swift")
        let otherEditor = { (clock: TestClock) in
            """
            {"answer":"It adds the kit.","sources":[{"n":1,"event_id":21,"ts_us":\(clock.us(minutesAgo: 3)),"app":"Visual Studio Code","title":"Package.swift","url":null,"text":"x"}],"unavailable":null}
            """
        }

        // Never read: the chip says so, and no source may say "This window".
        let (unread, unreadMemory, unreadClock) = rig()
        unreadMemory.replies["mci_events_by_app"] = .success(#"{"events":[]}"#)
        unreadMemory.replies["mci_suggest"] = .success(#"{"suggestions":[]}"#)
        unreadMemory.replies["mci_ask"] = .success(otherEditor(unreadClock))
        await open(unread, over: xcode)
        await eventually { unread.savedRead == false }
        unread.ask("what does this change?")
        await eventually { unread.answer != nil }
        XCTAssertEqual(unread.rows, [.source(try XCTUnwrap(unread.answer).sources[0])])

        // Read, but the source is the other editor's.
        let (read, readMemory, readClock) = rig()
        readMemory.replies["mci_events_by_app"] = .success("""
        {"events":[{"event_id":20,"ts_us":\(readClock.us(minutesAgo: 1)),"app_bundle_id":"com.apple.dt.Xcode","window_title":"Package.swift","url":null,"text_snippet":"let package = Package("}]}
        """)
        readMemory.replies["mci_ask"] = .success(otherEditor(readClock))
        await open(read, over: xcode)
        await eventually { read.savedRead == true }
        read.ask("what does this change?")
        await eventually { read.answer != nil }
        XCTAssertEqual(read.rows, [.source(try XCTUnwrap(read.answer).sources[0])])
    }

    /// The window was read again between opening Ask and asking: the newer
    /// read of the same window is still "This window".
    func testANewerReadOfTheSameWindowIsThisWindow() async throws {
        let (model, memory, clock) = rig()
        memory.replies["mci_ask"] = .success("""
        {"answer":"Team is $18 a seat.","sources":[{"n":1,"event_id":8,"ts_us":\(clock.us(minutesAgo: 0.1)),"app":"Safari","title":"Pricing","url":null,"text":"Per-seat pricing."}],"unavailable":null}
        """)
        await open(model, over: safari)
        await eventually { model.savedRead == true }
        model.ask("what is this?")
        await eventually { model.answer != nil }
        XCTAssertEqual(model.rows, [.thisWindow(try XCTUnwrap(model.answer).sources[0])])
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

    func testTheFooterSaysWhyNoAnswerCanBeWritten() async {
        // A Mac with neither Apple Intelligence nor a model server of its own.
        let (older, _, _) = rig(answers: false)
        await open(older, over: safari)
        XCTAssertEqual(older.footerText, "Answers need Apple Intelligence or your own model")

        let reasons = [
            ("apple_intelligence_off", "Answers need Apple Intelligence"),
            ("device_not_eligible", "Answers need Apple Intelligence"),
            ("model_not_ready", "Apple Intelligence is getting ready"),
            ("needs_macos_26", "Answers need macOS 26"),
            ("needs_apple_intelligence_or_local_model", "Answers need Apple Intelligence or your own model"),
            ("local_server_unreachable", "Your model server isn’t answering"),
            ("local_model_missing", "Your model server doesn’t have that model"),
            ("local_model_unset", "Your model server has no model to answer with"),
            ("local_model_not_local", "Pick a model that runs on this Mac"),
            ("local_server_not_local", "Hippocampus only talks to model servers on this Mac"),
            ("not_installed", "Answers aren’t available"),
        ]
        for (reason, footer) in reasons {
            let (model, memory, _) = rig()
            memory.replies["mci_ask"] = .success(#"{"answer":null,"sources":[],"unavailable":"\#(reason)"}"#)
            await open(model, over: safari)
            XCTAssertEqual(model.footerText, "On this Mac", reason)
            model.ask("what is this?")
            await eventually { model.answer != nil }
            XCTAssertEqual(model.footerText, footer, reason)
        }

        // Paused or off, the footer says that first.
        let (paused, _, _) = rig(answers: false, status: .paused)
        await open(paused, over: safari)
        XCTAssertEqual(paused.footerText, "Paused")
    }

    /// The agent sends a row's time as `ts_us` and writes none into `why`;
    /// the row formats it in the person's locale (RULINGS I14).
    func testARowsTimeComesAsANumberNotInItsWords() throws {
        let rows = try JSONDecoder().decode([BarSuggestion].self, from: Data(#"""
        [{"kind":"searched","title":"“q”","why":"You searched for this","action":{"query":"q"},"score":6,"ts_us":1791841025000000},
         {"kind":"day","title":"Your day so far","why":"What you worked on and looked up","action":{"view":"day"},"score":4}]
        """#.utf8))
        XCTAssertEqual(rows.map(\.tsUs), [1_791_841_025_000_000, nil])
    }

    /// Where no answer can be written, Return can only find: the card says
    /// so instead of "Thinking…".
    func testWithoutAnswersARunningRequestSaysSearching() async {
        let (model, memory, _) = rig(answers: false)
        memory.held = ["mci_ask"]
        await open(model, over: safari)
        model.query = "pricing"
        await eventually { !model.hits.isEmpty }
        XCTAssertNil(model.activate())
        XCTAssertEqual(model.mode, .answer)
        XCTAssertEqual(model.answerLine, .searching)
        memory.release("mci_ask")
        await eventually { !model.isAsking }
        XCTAssertEqual(AnswerLine.make(answer: nil, asking: true, notice: nil, answersAvailable: true), .thinking)
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
        XCTAssertFalse(AnswerAvailability(systemSupportsAnswers: false).isAvailable(at: now), "a Mac with no model has none")
    }

    /// Before macOS 26 a model server on this Mac can answer, so Ask offers to
    /// ask until a reply says otherwise. A person can start their model
    /// server at any time, so its reasons are kept for a minute, not half an
    /// hour.
    func testAModelServerIsAskedAgainAfterAMinute() {
        XCTAssertTrue(AnswerAvailability().isAvailable(at: Date()), "learned from the first reply, not the macOS version")
        var availability = AnswerAvailability()
        let now = Date()
        availability.learn(from: BarAnswer(answer: nil, sources: [], unavailable: "needs_apple_intelligence_or_local_model"), at: now)
        XCTAssertFalse(availability.isAvailable(at: now.addingTimeInterval(59)))
        XCTAssertTrue(availability.isAvailable(at: now.addingTimeInterval(60)))
        availability.learn(from: BarAnswer(answer: nil, sources: [], unavailable: "local_server_unreachable"), at: now)
        XCTAssertTrue(availability.isAvailable(at: now.addingTimeInterval(60)))
        availability.learn(from: BarAnswer(answer: nil, sources: [], unavailable: "apple_intelligence_off"), at: now)
        XCTAssertFalse(availability.isAvailable(at: now.addingTimeInterval(60)))
        XCTAssertTrue(availability.isAvailable(at: now.addingTimeInterval(30 * 60)))
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
        XCTAssertEqual(
            AnswerLine.make(answer: BarAnswer(answer: nil, sources: [source], unavailable: "needs_apple_intelligence_or_local_model"),
                            asking: false, notice: nil),
            .note("Answers need Apple Intelligence or your own model. Here’s what matched:")
        )
        XCTAssertEqual(AnswerLine.explain("local_server_unreachable", matched: false), "Your model server isn’t answering.")
        XCTAssertEqual(AnswerLine.explain("local_model_not_local", matched: false),
                       "That model runs in the cloud. Pick one that runs on this Mac.")
        XCTAssertEqual(AnswerLine.make(answer: nil, asking: true, notice: nil), .thinking)
        XCTAssertEqual(
            AnswerLine.make(answer: BarAnswer(answer: "Yes.", sources: [], unavailable: nil), asking: false, notice: "x"),
            .answer("Yes.")
        )
        XCTAssertNil(AnswerLine.make(answer: nil, asking: false, notice: nil))
    }

    /// Rows put off while an answer was written wait for Ask to be home
    /// again, so their failure never replaces the answer's.
    func testRowsPutOffForAnAnswerNeverReplaceItsFailure() async {
        let (model, memory, _) = rig()
        memory.held = ["mci_ask"]
        let id = model.opened()
        model.ask("what is this?")
        model.contextArrived(safari, openID: id)
        await eventually { memory.calls(to: "mci_ask").count == 1 }
        XCTAssertTrue(model.back(), "Esc while it is written: the rows wait for it")
        model.ask("what did we decide?")
        await eventually { memory.calls(to: "mci_ask").count == 2 }
        memory.replies["mci_ask"] = .failure(.timedOut)
        memory.replies["mci_suggest"] = .failure(.timedOut)
        memory.release("mci_ask")
        await eventually { !model.isAsking }
        await settle()
        XCTAssertEqual(model.answerLine, .note("Couldn’t answer that. Try again."))
        XCTAssertTrue(memory.calls(to: "mci_suggest").isEmpty, "not under an answer")

        // Typed over it: still not home, so still no rows.
        model.query = "pricing"
        await settle()
        XCTAssertTrue(memory.calls(to: "mci_suggest").isEmpty)
        XCTAssertNotEqual(model.notice, "Opening your memory…")

        // Home again: the rows load, and their failure is said there.
        XCTAssertTrue(model.back())
        await eventually { memory.calls(to: "mci_suggest").count == 1 }
        await eventually { model.notice == "Opening your memory…" }
    }

    func testCopyForAIIsDroppedOnceAskHasClosedOrOpenedAgain() async {
        let (model, memory, _) = rig()
        memory.replies["mci_context"] = .success(##"{"content":[{"type":"text","text":"# Hippocampus context"}]}"##)
        await open(model, over: safari)
        let copied = await model.copyForAI()
        XCTAssertEqual(copied, .text("# Hippocampus context"))

        // Closed before it arrived: the person may have copied something since.
        memory.held = ["mci_context"]
        let afterClose = Task { await model.copyForAI() }
        await eventually { memory.calls(to: "mci_context").count == 2 }
        model.closed()
        memory.release("mci_context")
        let closedResult = await afterClose.value
        XCTAssertEqual(closedResult, .dropped)

        // Closed and opened again: it belongs to the earlier open.
        model.opened()
        memory.held = ["mci_context"]
        let afterReopen = Task { await model.copyForAI() }
        await eventually { memory.calls(to: "mci_context").count == 3 }
        model.closed()
        model.opened()
        memory.release("mci_context")
        let reopenedResult = await afterReopen.value
        XCTAssertEqual(reopenedResult, .dropped)

        memory.replies["mci_context"] = .failure(.timedOut)
        let failed = await model.copyForAI()
        XCTAssertEqual(failed, .failed)
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
            // Try Again restarts a running run now (`retryNow()`).
            (.blocked(reason: "x"), "Not saving", .tryAgain, .needsYou),
            (.stale(reason: "x"), "Not saving", .tryAgain, .needsYou),
            (.skipping(reason: "private_browsing"), "Skipping this window", nil, .remembering),
            (.skipping(reason: "secure_input"), "Skipping this window", nil, .skipping),
            // It may still be reading, so the dot stays solid (RULINGS B1).
            (.stopFailed(reason: "x"), "Couldn’t stop", .quit, .remembering),
            // Turn On did not take: Try Again turns it on (never a silent Off).
            (.turnOnFailed(reason: "x"), "Couldn’t turn on", .tryAgain, .needsYou),
        ]
        for (status, text, action, mark) in expected {
            let footer = AskPanelStatus(status)
            XCTAssertEqual(footer.text, text, "\(status)")
            XCTAssertEqual(footer.action, action, "\(status)")
            XCTAssertEqual(footer.mark, mark, "\(status)")
            XCTAssertEqual(footer.mark, status.markState, "Ask's mark matches the menu bar")
        }
        XCTAssertEqual(
            [AskPanelStatus.Action.resume, .turnOn, .openSystemSettings(.screenRecording), .tryAgain, .quit, .finishSetup]
                .map(\.title),
            ["Resume", "Turn On", "Open System Settings…", "Try Again", "Quit Hippocampus", "Finish Setup…"]
        )
        // Nothing is read in this window while it is skipped, stopped or off.
        XCTAssertFalse(AskPanelStatus(.skipping(reason: "private_browsing")).readsThisWindow)
        XCTAssertFalse(AskPanelStatus(.stopFailed(reason: "x")).readsThisWindow)
        XCTAssertFalse(AskPanelStatus(.turnOnFailed(reason: "x")).readsThisWindow)
    }

    /// Start Remembering in onboarding is the only consent, so before setup
    /// nothing in Ask turns remembering on (product critique 4).
    func testBeforeSetupAskOffersOnlyToFinishSetup() {
        let statuses: [MenuBarStatus] = [
            .idle, .starting, .recording, .unchanged, .noMemory, .paused, .needsPermission(.screenRecording),
            .error(reason: "x"), .blocked(reason: "x"), .stale(reason: "x"), .skipping(reason: "secure_input"),
            .stopFailed(reason: "x"), .turnOnFailed(reason: "x"),
        ]
        for status in statuses {
            let closed = AskPanelStatus(status, setup: .notFinished)
            XCTAssertEqual(closed.text, "Not set up yet", "\(status)")
            XCTAssertEqual(closed.action, .finishSetup, "\(status)")
            XCTAssertFalse(closed.readsThisWindow, "\(status)")
            XCTAssertFalse(closed.isRemembering, "\(status)")
            XCTAssertEqual(closed.mark, status.markState, "the mark never shows less than is happening")
            let open = AskPanelStatus(status, setup: .inProgress)
            XCTAssertEqual(open.text, "Not set up yet", "\(status)")
            XCTAssertNil(open.action, "onboarding is on screen; a second copy would only compete with it")
        }
        XCTAssertEqual(AskPanelStatus.Setup(sentinelPresent: false, hasOnboarding: true, onboardingOpen: false), .notFinished)
        XCTAssertEqual(AskPanelStatus.Setup(sentinelPresent: false, hasOnboarding: true, onboardingOpen: true), .inProgress)
        XCTAssertEqual(AskPanelStatus.Setup(sentinelPresent: true, hasOnboarding: true, onboardingOpen: true), .complete)
        XCTAssertEqual(AskPanelStatus.Setup(sentinelPresent: false, hasOnboarding: false, onboardingOpen: false), .complete,
                       "a build without onboarding has no setup to finish")
    }

    func testBeforeSetupThePlaceholderAndChipPromiseNothingAboutThisWindow() async {
        let (model, _, _) = rig()
        model.setStatus(AskPanelStatus(.recording, setup: .inProgress))
        await open(model, over: safari)
        await eventually { model.savedRead == true }
        XCTAssertFalse(model.windowRead)
        XCTAssertEqual(model.placeholder, "Ask about anything you’ve seen")
        XCTAssertEqual(model.footerText, "Not set up yet")
        XCTAssertNil(model.footerAction)
    }

    /// Every button the footer shows changes something in the state it is
    /// shown for; one that could not act is not shown.
    func testEveryFooterButtonActsInTheStateItIsShownFor() async throws {
        var opened: [URL] = []

        // Paused: Resume starts remembering again.
        let (paused, pausedTopology) = footerSupervisor(captureEnabled: true)
        pausedTopology.readinessResults = [.success(()), .success(())]
        try await paused.startAndWaitForReadiness()
        try await paused.setPausedAndWait(true)
        XCTAssertEqual(paused.askPanelStatus(setupFinished: true).action, .resume)
        paused.performAskStatusAction(.resume, setupFinished: true) { opened.append($0) }
        await eventually { paused.state == .running }

        // Off: Turn On turns remembering on.
        let (off, offTopology) = footerSupervisor(captureEnabled: false)
        offTopology.readinessResults = [.success(())]
        XCTAssertEqual(off.askPanelStatus(setupFinished: true).action, .turnOn)
        off.performAskStatusAction(.turnOn, setupFinished: true) { opened.append($0) }
        await eventually { off.captureEnabled && off.state == .running }

        // A failed start: Try Again starts again.
        let (failed, failedTopology) = footerSupervisor(captureEnabled: true)
        failedTopology.readinessResults = [.failure(MemorySessionError.timedOut), .success(())]
        try? await failed.startAndWaitForReadiness()
        await settle()
        XCTAssertNotEqual(failed.state, .running, "a failed start does not retry by itself")
        XCTAssertEqual(failed.askPanelStatus(setupFinished: true).action, .tryAgain)
        failed.performAskStatusAction(.tryAgain, setupFinished: true) { opened.append($0) }
        await eventually { failed.state == .running }

        // Running with nothing confirmed saved ("Not saving"): Try Again
        // restarts the running run now.
        let clock = TestClock()
        let (running, runningTopology) = footerSupervisor(captureEnabled: true, clock: clock)
        runningTopology.readinessResults = [.success(()), .success(())]
        try await running.startAndWaitForReadiness()
        // Past the 45 s a start may take before missing evidence counts.
        clock.now = clock.now.addingTimeInterval(46)
        XCTAssertEqual(running.askPanelStatus(setupFinished: true).text, "Not saving")
        XCTAssertEqual(running.askPanelStatus(setupFinished: true).action, .tryAgain)
        running.performAskStatusAction(.tryAgain, setupFinished: true) { opened.append($0) }
        await eventually { runningTopology.launchPlans.count == 2 && running.state == .running }
        XCTAssertEqual(runningTopology.launchPlans.count, 2)

        // A permission turned off: Open System Settings… opens its pane.
        running.tccRevokedSurface = .screenRecording
        XCTAssertEqual(running.askPanelStatus(setupFinished: true).action, .openSystemSettings(.screenRecording))
        running.performAskStatusAction(.openSystemSettings(.screenRecording), setupFinished: true) {
            opened.append($0)
        }
        XCTAssertEqual(opened, [URL(string: TCCRevokedReason.screenRecording.settingsPaneURLString)!])

        // A failed stop: Quit Hippocampus, which the app carries out; the
        // supervisor starts nothing.
        let (stuck, stuckTopology) = footerSupervisor(captureEnabled: true)
        try await stuck.startAndWaitForReadiness()
        stuckTopology.stopResults = [.failure(MemorySessionError.timedOut)]
        try? await stuck.applyCaptureEnabled(false)
        XCTAssertEqual(stuck.askPanelStatus(setupFinished: true).text, "Couldn’t stop")
        XCTAssertEqual(stuck.askPanelStatus(setupFinished: true).action, .quit)
        stuck.performAskStatusAction(.quit, setupFinished: true) { opened.append($0) }
        await settle()
        XCTAssertEqual(stuckTopology.launchPlans.count, 1)

        // Before setup, with onboarding closed: Finish Setup… opens it, and
        // while it is open there is nothing to press.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let onboarding = dir.appendingPathComponent("onboarding")
        try "#!/bin/sh\nsleep 0.4\n".write(to: onboarding, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onboarding.path)
        let (setup, _) = footerSupervisor(captureEnabled: false, onboarding: onboarding)
        XCTAssertEqual(setup.askPanelStatus(setupFinished: false).action, .finishSetup)
        setup.performAskStatusAction(.finishSetup, setupFinished: false) { opened.append($0) }
        XCTAssertTrue(setup.onboardingIsRunning)
        XCTAssertNil(setup.askPanelStatus(setupFinished: false).action)
        // Whatever asks, nothing turns remembering on before Start Remembering.
        for action in [AskPanelStatus.Action.turnOn, .resume, .tryAgain] {
            setup.performAskStatusAction(action, setupFinished: false) { opened.append($0) }
        }
        await settle()
        XCTAssertFalse(setup.captureEnabled, "setup is never skipped")
        XCTAssertEqual(setup.state, .idle)
    }

    private func footerSupervisor(
        captureEnabled: Bool, onboarding: URL? = nil, clock: TestClock = TestClock()
    ) -> (ProcessSupervisor, FakeSupervisorTopology) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        locator.onboardingURL = onboarding
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: keyStore,
            runtimeConfig: FakeRuntimeConfig(captureEnabled: captureEnabled),
            topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(),
            readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) },
            clock: { clock.now }
        )
        return (supervisor, topology)
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
