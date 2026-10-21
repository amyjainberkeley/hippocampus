// SPDX-License-Identifier: Apache-2.0
//
// The Ask panel as Spotlight for your memory (SPEC-DELTA 4, SPEC 5.3.9):
// items, pages and moments found as you type, each with its keys (↩ opens,
// ⌘↩ asks the person's AI tool, ⌥↩ resumes an item), and Ask {Tool} from
// the panel: choosing a tool once, its one-time sheet, the builder asked
// just before anything opens, a second press ignored, and nothing ever
// opening after the panel closed. Fixtures only: no real memory, no real
// apps, nothing opens.

import Foundation
import XCTest
@testable import HippocampusKit

/// The builder and the work read, from fixtures. `hold()` makes the next
/// cards wait until `release()`.
actor FakePanelAgent: PanelAgent {
    private(set) var requests: [SendCardRequest] = []
    private var result: Result<SendCard, Error> = .failure(SendCardError.unavailable)
    private var workResult = PanelWork()
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func reply(_ result: Result<SendCard, Error>) { self.result = result }
    func setWork(_ work: PanelWork) { workResult = work }
    func hold() { holding = true }

    func release() {
        holding = false
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }

    func card(_ request: SendCardRequest) async throws -> SendCard {
        requests.append(request)
        if holding { await withCheckedContinuation { waiting.append($0) } }
        return try result.get()
    }

    func work() async throws -> PanelWork { workResult }

    nonisolated func handoff(tools: [InstalledTool] = [], choices: HandoffChoices = .ephemeral()) -> PanelHandoff {
        PanelHandoff(agent: self, tools: { tools }, choices: choices, home: "/Users/sam")
    }
}


@MainActor
final class AskPanelHandoffTests: XCTestCase {
    private let safari = FrontmostContext(bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Pricing")
    private let claude = InstalledTool(tool: .claude, appURL: URL(fileURLWithPath: "/Applications/Claude.app"))
    private let chatGPT = InstalledTool(tool: .chatgpt, appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
    private let trailhead = PanelItem(
        id: "w_9c41e2", kind: "code", name: "trailhead-shop", apps: ["com.microsoft.VSCode", "com.apple.Terminal"],
        lastUs: 30, folderGuess: "~/dev/trailhead-shop", moments: [4790, 4777]
    )
    private let q4 = PanelItem(id: "w_51d0aa", kind: "document", name: "Q4 planning", apps: ["com.google.Chrome"],
                               lastUs: 20, moments: [4700])
    private let rounding = PanelPage(title: "Rounding half to even", host: "devnotes.example", path: "/rounding",
                                     app: "com.google.Chrome", days: 3, lastUs: 25, moments: [4812, 4811])

    private final class Performed {
        var actions: [BarAction] = []
    }

    private func rig(
        tools: [InstalledTool]? = nil, choices: HandoffChoices = .ephemeral(), readsWindow: Bool = true
    ) async -> (CommandBarModel, FakePanelAgent, Performed, HandoffChoices) {
        let memory = FakeAskMemory()
        let clock = TestClock()
        memory.replies["mci_events_by_app"] = .success(readsWindow
            ? #"{"events":[{"event_id":7,"ts_us":\#(clock.us(minutesAgo: 0.5)),"app_bundle_id":"com.apple.Safari","window_title":"Pricing","url":null,"text_snippet":"Per-seat pricing."}]}"#
            : #"{"events":[]}"#)
        memory.replies["mci_suggest"] = .success(#"{"suggestions":[]}"#)
        memory.replies["mci_recall"] = .success("""
        {"hits":[
          {"event_id":11,"ts_us":1,"app_bundle_id":"com.tinyspeck.slackmacgap","window_title":"#pricing","url":null,"text_snippet":"Ravi: $18 a seat."},
          {"event_id":13,"ts_us":2,"app_bundle_id":"com.apple.Safari","window_title":"Stripe","url":"https://stripe.com/docs/billing","text_snippet":"Per-seat pricing."}]}
        """)
        let agent = FakePanelAgent()
        await agent.setWork(PanelWork(items: [trailhead, q4], pages: [rounding]))
        let model = CommandBarModel(
            memory: memory,
            availability: AnswerAvailability(systemSupportsAnswers: true),
            handoff: agent.handoff(tools: tools ?? [claude, chatGPT], choices: choices),
            now: { clock.now }
        )
        // Never the person's own calendar.
        model.calendarAnswers = CalendarAnswerer(store: FixedCalendarAccess(.notDetermined), setting: .inMemory())
        model.setStatus(AskPanelStatus(.recording))
        let performed = Performed()
        model.perform = { performed.actions.append($0) }
        let id = model.opened()
        model.contextArrived(safari, openID: id)
        await settle()
        return (model, agent, performed, choices)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func type(_ text: String, into model: CommandBarModel) async {
        model.query = text
        await eventually { !model.hits.isEmpty }
    }

    private func card(_ message: String = "Why?\n\nFrom my screen…", open: String? = "claude://claude.ai/new?q=Why") -> SendCard {
        SendCard(message: message, words: 3, open: open, copy: open == nil, included: [11, 13])
    }

    // MARK: Found as you type

    func testItemsPagesAndMomentsAreFoundAsYouType() async {
        let (model, _, _, _) = await rig()
        await type("trail", into: model)
        XCTAssertEqual(model.matchedItems, [trailhead])
        XCTAssertEqual(model.rows.first, .ask("trail"), "Return still asks first (product critique 6)")
        XCTAssertEqual(model.rows[1], .item(trailhead))
        XCTAssertTrue(model.rows.dropFirst(2).allSatisfy { if case .hit = $0 { true } else { false } })

        model.query = "rounding"
        await eventually { model.matchedPages == [rounding] }
        XCTAssertEqual(model.rows[1], .page(rounding))

        // A question's own words don't hide what it names.
        model.query = "why is trailhead failing?"
        await eventually { model.matchedItems == [trailhead] }
        model.query = "q4 plan"
        await eventually { model.matchedItems == [q4] }
    }

    // MARK: Demo Memory

    /// While Demo Memory is in use the panel lists the made-up week's items
    /// and pages, never the person's own: what it kept from one memory is
    /// dropped when the other is in use, and a read that finishes after the
    /// switch is not shown (SPEC-DELTA 6).
    func testWhatThePanelKeptFromOneMemoryIsDroppedWhenTheOtherIsInUse() async {
        let (model, agent, _, _) = await rig()
        await type("trail", into: model)
        XCTAssertEqual(model.matchedItems, [trailhead])
        model.closed()

        let pebblewick = PanelItem(id: "w_0d1e2f", kind: "code", name: "pebblewick-app",
                                   apps: ["com.microsoft.VSCode"], lastUs: 40, moments: [9001])
        await agent.setWork(PanelWork(items: [pebblewick]))
        let demo = URL(fileURLWithPath: "/tmp/demo-memory/mci.sqlite")
        model.memoryInUse = { demo }
        _ = model.opened()
        XCTAssertTrue(model.matchedItems.isEmpty, "nothing from the person's own memory shows under Demo Memory")
        model.query = "trail"
        await settle()
        XCTAssertTrue(model.matchedItems.isEmpty)
        model.query = "pebble"
        await eventually { model.matchedItems == [pebblewick] }
        model.closed()

        // And back: the made-up week's items go too.
        await agent.setWork(PanelWork(items: [trailhead]))
        model.memoryInUse = { nil }
        _ = model.opened()
        XCTAssertTrue(model.matchedItems.isEmpty)
        model.query = "pebble"
        await settle()
        XCTAssertTrue(model.matchedItems.isEmpty)
        model.query = "trail"
        await eventually { model.matchedItems == [trailhead] }
    }

    /// The builder and the work read are run from the launch in use at each
    /// read, so they read Demo Memory's week while it is in use.
    func testThePanelsAgentIsMadeFromTheMemoryInUseAtEachRead() async throws {
        final class Store: @unchecked Sendable { var path = "/own/mci.sqlite" }
        let store = Store()
        let agent = LaunchedPanelAgent(launch: {
            MemorySessionLaunch(executable: URL(fileURLWithPath: "/Applications/Hippocampus.app/agent"),
                                arguments: ["mcp-serve"], environment: ["MCI_DB_PATH": store.path])
        })
        let own = try await agent.current()
        XCTAssertEqual(own.environment["MCI_DB_PATH"], "/own/mci.sqlite")
        store.path = "/demo/mci.sqlite"
        let demo = try await agent.current()
        XCTAssertEqual(demo.environment["MCI_DB_PATH"], "/demo/mci.sqlite")

        let missing = LaunchedPanelAgent(launch: { nil })
        do {
            _ = try await missing.current()
            XCTFail("no agent: nothing to run")
        } catch {
            XCTAssertEqual(error as? SendCardError, .unavailable)
        }
    }

    func testEachResultHasItsKeys() async {
        let (model, _, _, _) = await rig()
        await type("trail", into: model)
        model.select(1)
        XCTAssertEqual(model.keyHints.map(\.keys), ["↩", "⌘↩", "⌥↩"])
        XCTAssertEqual(model.keyHints.map(\.label), ["Open", "Ask Your AI…", "Resume"])
        XCTAssertEqual(model.activate(), .openWindow(tab: "work:w_9c41e2"), "↩ opens the item")
        XCTAssertEqual(model.resumeSelected(), .openWindow(tab: "resume:w_9c41e2"), "⌥↩ resumes it")

        model.query = "rounding"
        await eventually { model.matchedPages == [rounding] }
        model.select(1)
        XCTAssertEqual(model.keyHints.map(\.keys), ["↩", "⌘↩"], "only an item resumes")
        XCTAssertEqual(model.activate(), .openURL(URL(string: "https://devnotes.example/rounding")!))
        XCTAssertNil(model.resumeSelected())

        model.select(0)
        XCTAssertEqual(model.keyHints.map(\.label), ["Ask", "Ask Your AI…"])
    }

    // MARK: ⌘↩: Ask {Tool}

    func testTheFirstCommandReturnChoosesAToolThenItsOneTimeSheetThenOpens() async {
        let (model, agent, performed, choices) = await rig()
        await agent.reply(.success(card()))
        await type("team pricing", into: model)
        model.askAITool()
        guard case .picking = model.stage else { return XCTFail("a tool is chosen first") }
        XCTAssertEqual(model.rows, [.tool(claude), .tool(chatGPT)])
        XCTAssertEqual(model.keyHints.map(\.label), ["Choose", "Cancel"])

        model.select(0)
        XCTAssertNil(model.activate())
        XCTAssertEqual(choices.lastTool, .claude, "remembered on this Mac")
        guard case .firstUse(_, let tool, _, let aboutMe) = model.stage else { return XCTFail("its one-time sheet") }
        XCTAssertEqual(tool, claude)
        XCTAssertFalse(aboutMe, "off at the start of every send")
        await eventually { if case .firstUse(_, _, card: _?, _) = model.stage { true } else { false } }
        XCTAssertEqual(model.keyHints.map(\.label), ["Open Claude", "Cancel"])
        XCTAssertTrue(performed.actions.isEmpty, "nothing opens before Open")

        model.askAITool()  // ⌘↩ is the sheet's default button
        await eventually { !performed.actions.isEmpty }
        XCTAssertTrue(choices.wasTold(.claude))
        guard case .handoff(let plan, let to)? = performed.actions.last else { return XCTFail("opened") }
        XCTAssertEqual(to, .claude)
        XCTAssertEqual(plan.steps, [.open(URL(string: "claude://claude.ai/new?q=Why")!)])
        XCTAssertEqual(plan.note.text, "Opened in Claude. You send it from there.")
        let requests = await agent.requests
        XCTAssertEqual(requests.last?.to, "claude")
        XCTAssertEqual(requests.last?.question, "team pricing")
        XCTAssertEqual(requests.last?.moments, [11, 13], "the question and its top matches")
        XCTAssertEqual(requests.count, 2, "the sheet's preview, then just before it opens")
        XCTAssertNil(model.stage)
    }

    func testOnceChosenAndToldCommandReturnOpensTheToolAtOnce() async {
        let choices = HandoffChoices.ephemeral()
        choices.lastTool = .claude
        choices.markTold(.claude)
        let (model, agent, performed, _) = await rig(choices: choices)
        await agent.reply(.success(card()))
        await type("trail", into: model)
        model.select(1)
        XCTAssertEqual(model.keyHints[1], KeyHintItem("⌘↩", "Ask Claude"))
        model.askAITool()
        await eventually { !performed.actions.isEmpty }
        let request = await agent.requests.last
        XCTAssertEqual(request?.item, "w_9c41e2", "the item, by its id")
        XCTAssertEqual(request?.moments, [4790, 4777])
        XCTAssertEqual(request?.appInstalled, true)
    }

    func testASecondPressWithinTwoSecondsIsIgnored() async {
        let choices = HandoffChoices.ephemeral()
        choices.lastTool = .claude
        choices.markTold(.claude)
        let (model, agent, performed, _) = await rig(choices: choices)
        await agent.reply(.success(card()))
        await type("team pricing", into: model)
        model.askAITool()
        await eventually { performed.actions.count == 1 }
        model.askAITool()
        await settle()
        XCTAssertEqual(performed.actions.count, 1)
        let count = await agent.requests.count
        XCTAssertEqual(count, 1)
    }

    func testClosingBeforeTheMessageIsReadyNeverOpensTheTool() async {
        let choices = HandoffChoices.ephemeral()
        choices.lastTool = .claude
        choices.markTold(.claude)
        let (model, agent, performed, _) = await rig(choices: choices)
        await agent.reply(.success(card()))
        await agent.hold()
        await type("team pricing", into: model)
        model.askAITool()
        XCTAssertEqual(model.stage, .sending(.claude))
        model.closed()
        await agent.release()
        await settle()
        XCTAssertTrue(performed.actions.isEmpty, "never opened late")
        XCTAssertNil(model.stage)
    }

    func testNothingTypedAsksAboutTheWindowInFront() async {
        let choices = HandoffChoices.ephemeral()
        choices.lastTool = .claude
        choices.markTold(.claude)
        let (model, agent, performed, _) = await rig(choices: choices)
        await eventually { model.windowRead }
        XCTAssertEqual(model.keyHints.first, KeyHintItem("⌘↩", "Ask Claude"))
        await agent.reply(.success(card()))
        model.askAITool()
        await eventually { !performed.actions.isEmpty }
        let request = await agent.requests.last
        XCTAssertEqual(request?.moments, [7])
        XCTAssertNil(request?.question)
    }

    func testAWindowHippocampusHasntReadHasNothingToHandOver() async {
        let (model, agent, performed, _) = await rig(readsWindow: false)
        model.askAITool()
        XCTAssertEqual(model.footerText, HandoffCopy.nothingToSend)
        XCTAssertTrue(performed.actions.isEmpty)
        let count = await agent.requests.count
        XCTAssertEqual(count, 0)
    }

    func testWithNoAIToolOnThisMacCommandReturnCopiesForYourAI() async {
        let (model, _, performed, _) = await rig(tools: [])
        await type("team pricing", into: model)
        model.askAITool()
        XCTAssertEqual(performed.actions, [.copyForAI], "never a button that does nothing")
    }

    func testEscLeavesTheSheetAndNothingOpens() async {
        let (model, agent, performed, _) = await rig()
        await agent.reply(.success(card()))
        await type("team pricing", into: model)
        model.askAITool()
        XCTAssertTrue(model.back(), "Esc leaves the picker")
        XCTAssertNil(model.stage)
        XCTAssertEqual(model.mode, .results, "and keeps what was typed")
        XCTAssertTrue(performed.actions.isEmpty)
    }

    func testALockedMemoryIsSaid() async {
        let choices = HandoffChoices.ephemeral()
        choices.lastTool = .claude
        choices.markTold(.claude)
        let (model, agent, performed, _) = await rig(choices: choices)
        await agent.reply(.failure(SendCardError.locked))
        await type("team pricing", into: model)
        model.askAITool()
        await eventually { model.flash != nil }
        XCTAssertEqual(model.footerText, "Hippocampus couldn’t open your memory. Open Hippocampus, then try again.")
        XCTAssertTrue(performed.actions.isEmpty)
    }

    func testTheSheetsCheckboxMakesTheMessageAgain() async {
        let (model, agent, _, _) = await rig()
        await agent.reply(.success(card()))
        await type("team pricing", into: model)
        model.askAITool()
        model.select(0)
        _ = model.activate()
        await eventually { if case .firstUse(_, _, card: _?, _) = model.stage { true } else { false } }
        model.toggleIncludeAboutMe()
        guard case .firstUse(_, _, _, let aboutMe) = model.stage else { return XCTFail("still the sheet") }
        XCTAssertTrue(aboutMe)
        await eventually { if case .firstUse(_, _, card: _?, true) = model.stage { true } else { false } }
        let requests = await agent.requests
        XCTAssertEqual(requests.last?.includeAboutMe, true)
    }
}
