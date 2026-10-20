// SPDX-License-Identifier: Apache-2.0
//
// The AI Tools page (SPEC 3.8): each connectable tool's plain status, the
// tools on this Mac that aren't connected with the truth about each, the
// tool ⌘↩ opens, and the exact words a session starts with and their size.
// Fakes only: no agent, no apps, no memory.

import Foundation
import XCTest
@testable import RecallUIKit

/// What the fake agent was asked, from any thread.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SendCardRequest] = []

    func record(_ request: SendCardRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var all: [SendCardRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

@MainActor
final class AIToolsModelTests: XCTestCase {
    private let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app")
    private let codexApp = URL(fileURLWithPath: "/Applications/Codex.app")
    private let chatGPTApp = URL(fileURLWithPath: "/Applications/ChatGPT.app")
    private let cursorApp = URL(fileURLWithPath: "/Applications/Cursor.app")
    private func choices() -> HandoffChoices {
        .ephemeral()
    }

    private func detector(schemes: [String: URL], chatGPT: Bool) -> DestinationDetector {
        let chatGPTApp = chatGPTApp
        return DestinationDetector(
            appForScheme: { schemes[$0] },
            appForBundle: { chatGPT && $0 == "com.openai.chat" ? chatGPTApp : nil },
            isExecutable: { _ in false },
            environment: ["HOME": "/Users/sam", "PATH": "/usr/bin:/bin"]
        )
    }

    nonisolated private static func status(
        _ id: String, installed: Bool = true, lookUps: String = "on", start: String = "on", kind: String? = "hook",
        step: String? = nil
    ) -> ClientStatus {
        ClientStatus(id: id, name: id == "codex" ? "Codex" : "Claude Code", installed: installed, lookUps: lookUps,
                     sessionStart: start, startKind: kind, needsStep: step)
    }

    // MARK: Each card's words

    func testAConnectedToolSaysWhatItGets() {
        let card = AIToolsModel.card(Self.status("claude-code"), chatGPTInstalled: false, appURL: claudeApp)
        XCTAssertTrue(card.connected)
        XCTAssertEqual(card.lines, ["Gets your recent work at each session start."])
        XCTAssertTrue(card.showsSessionSwitch)
        XCTAssertTrue(card.showsStartsWith)
        XCTAssertNil(card.step)
        let lookUps = AIToolsModel.card(Self.status("claude-code", start: "off", kind: nil), chatGPTInstalled: false,
                                        appURL: claudeApp)
        XCTAssertEqual(lookUps.lines, ["Looks things up when a question needs it."])
        XCTAssertFalse(lookUps.showsStartsWith)
    }

    func testCodexsInstructionIsSaidForWhatItIs() {
        let card = AIToolsModel.card(Self.status("codex", kind: "instruction"), chatGPTInstalled: false,
                                     appURL: codexApp)
        XCTAssertEqual(card.lines, ["Asked to fetch your recent work when a task starts. Codex decides."])
        XCTAssertFalse(card.showsSessionSwitch)
        XCTAssertFalse(card.showsStartsWith, "an instruction starts with no words of ours")
    }

    func testCodexsOneStepIsShownUntilItsHookRan() {
        let card = AIToolsModel.card(Self.status("codex", step: "allow_hooks"), chatGPTInstalled: false,
                                     appURL: codexApp)
        XCTAssertEqual(card.step, "Codex asks you to allow new hooks once. Type /hooks in Codex and allow Hippocampus.")
        XCTAssertEqual(card.lines, [])
    }

    func testSettingsThatWinAreNamed() {
        XCTAssertEqual(AIToolsModel.card(Self.status("codex", start: "turned_off_in_tool"), chatGPTInstalled: false,
                                         appURL: codexApp).lines, ["Turned off in Codex’s own settings"])
        XCTAssertEqual(AIToolsModel.card(Self.status("codex", start: "overridden"), chatGPTInstalled: false,
                                         appURL: codexApp).lines, ["Overridden by your AGENTS.override.md file"])
    }

    func testChatGPTSharesCodexsSettings() {
        let codex = AIToolsModel.card(Self.status("codex", kind: "instruction"), chatGPTInstalled: true,
                                      appURL: codexApp)
        XCTAssertEqual(codex.lines.last, "ChatGPT’s desktop app uses Codex’s settings, so it can look things up too.")
        let off = AIToolsModel.card(Self.status("codex", lookUps: "off", start: "off", kind: nil),
                                    chatGPTInstalled: true, appURL: codexApp)
        XCTAssertFalse(off.connected)
        XCTAssertEqual(off.lines, ["ChatGPT’s desktop app uses Codex’s settings, so connecting Codex lets it look things up too."])
        XCTAssertFalse(off.showsSessionSwitch)
        let claudeOff = AIToolsModel.card(Self.status("claude-code", lookUps: "off", start: "off", kind: nil),
                                          chatGPTInstalled: true, appURL: claudeApp)
        XCTAssertEqual(claudeOff.lines,
                       ["Once connected, it gets your recent work at each session start, and you can read every word here."])
    }

    func testTheSizeIsRoundedToTens() {
        XCTAssertEqual(AIToolsModel.aboutWords(0), 0)
        XCTAssertEqual(AIToolsModel.aboutWords(3), 10, "never zero for some words")
        XCTAssertEqual(AIToolsModel.aboutWords(124), 120)
        XCTAssertEqual(AIToolsModel.aboutWords(125), 130)
        XCTAssertEqual(AIToolsModel.aboutWords(130), 130)
    }

    // MARK: Reading the page

    func testThePageReadsEachToolAndTheExactWords() async {
        let asked = Asked()
        let client = SendCardClient(
            card: { request in
                asked.record(request)
                return SendCard(message: "Local memory reference only.\n\n## Recent work\n- 13:34–14:10 · Launch",
                                words: 124, open: nil, copy: true, included: [])
            },
            clients: {
                [Self.status("claude-code"), Self.status("codex", kind: "instruction"),
                 Self.status("codex-old", installed: false, lookUps: "off", start: "off", kind: nil)]
            }
        )
        let choices = choices()
        choices.lastTool = .cursor
        let model = AIToolsModel(
            client: client,
            detector: detector(schemes: ["claude": claudeApp, "codex": codexApp, "cursor": cursorApp], chatGPT: true),
            understanding: PreviewUnderstandingReader(),
            choices: choices,
            locale: Locale(identifier: "en_US"),
            timeZone: PreviewUnderstandingReader.sampleTimeZone,
            now: { PreviewUnderstandingReader.sampleNow }
        )
        await model.reload()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.cards.map(\.id), ["claude-code", "codex"], "a tool neither here nor connected isn't shown")
        XCTAssertEqual(model.cards.first?.appURL, claudeApp)
        XCTAssertEqual(model.others.map(\.tool.tool), [.claude, .chatgpt, .cursor])
        XCTAssertEqual(model.others.map(\.line), [
            "Use Ask Claude.", "Chats can’t read your memory yet. Use Ask ChatGPT.", "Use Ask Cursor.",
        ])
        XCTAssertEqual(model.askTool, .cursor, "the tool ⌘↩ opens: the last one chosen")
        XCTAssertEqual(asked.all, [SendCardRequest(to: "session-start", client: "claude-code")],
                       "the exact words come from the builder, which records nothing")
        XCTAssertEqual(model.startsWith?.exactText, "Local memory reference only.\n\n## Recent work\n- 13:34–14:10 · Launch")
        XCTAssertEqual(model.startsWith?.words, 120)
        XCTAssertFalse(model.startsWith?.recentWork.isEmpty ?? true)
        XCTAssertFalse(model.isEmpty)
    }

    func testNoToolStartsSessionsSoThereAreNoWordsToShow() async {
        let asked = Asked()
        let client = SendCardClient(
            card: { request in
                asked.record(request)
                throw SendCardError.failed
            },
            clients: { [Self.status("codex", kind: "instruction")] }
        )
        let model = AIToolsModel(client: client, detector: detector(schemes: ["codex": codexApp], chatGPT: false),
                                 understanding: PreviewUnderstandingReader(), choices: choices())
        await model.reload()
        XCTAssertNil(model.startsWith)
        XCTAssertEqual(asked.all, [])
        XCTAssertEqual(model.askTool, .codex, "with nothing chosen, the first tool here")
    }

    func testNoToolsAtAll() async {
        let model = AIToolsModel(client: SendCardClient(card: { _ in throw SendCardError.failed }, clients: { [] }),
                                 detector: .none, understanding: PreviewUnderstandingReader(), choices: choices())
        await model.reload()
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.askTool)
    }

    func testAPageThatCouldntReadSaysSo() async {
        let model = AIToolsModel(
            client: SendCardClient(card: { _ in throw SendCardError.failed }, clients: { throw SendCardError.failed }),
            detector: .none, understanding: PreviewUnderstandingReader(), choices: choices()
        )
        await model.reload()
        XCTAssertEqual(model.state, .unavailable)
        XCTAssertFalse(model.isEmpty, "a page that couldn't read is never told there are no tools")
    }

    func testChoosingTheToolIsKeptForEveryButton() {
        let choices = choices()
        let model = AIToolsModel(client: .unavailable, detector: .none, understanding: PreviewUnderstandingReader(),
                                 choices: choices)
        model.choose(.chatgpt)
        XCTAssertEqual(model.askTool, .chatgpt)
        XCTAssertEqual(choices.lastTool, .chatgpt)
    }
}
