// SPDX-License-Identifier: Apache-2.0
//
// The menu-bar app's half of Ask {Tool} (SPEC 5.3): the clipboard rules on
// every copy, which tools are on this Mac, what happens once the builder
// has answered, the request the builder reads, and every word. Fixtures
// only: no real pasteboard, no real apps, nothing opens.

import AppKit
import XCTest
@testable import HippocampusKit

/// A pasteboard that records what was asked of it.
@MainActor
final class FakePasteboard: HandoffPasteboard {
    var changeCount = 0
    var options: [NSPasteboard.ContentsOptions] = []
    var contents: [NSPasteboard.PasteboardType: Data] = [:]
    var cleared = 0

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        self.options.append(options)
        contents = [:]
        changeCount += 1
        return changeCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        contents[dataType] = Data(string.utf8)
        return true
    }

    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        contents[dataType] = data
        return true
    }

    func clearContents() -> Int {
        contents = [:]
        cleared += 1
        changeCount += 1
        return changeCount
    }
}

@MainActor
final class ClipboardHygieneTests: XCTestCase {
    func testACopyStaysOnThisMacAndOutOfClipboardHistory() {
        let board = FakePasteboard()
        var later: (Duration, () -> Void)?
        XCTAssertTrue(ClipboardHygiene.copy("## Moment", to: board, schedule: { delay, work in later = (delay, work) }))
        XCTAssertEqual(board.options, [.currentHostOnly], "never Universal Clipboard")
        XCTAssertEqual(board.contents[.string], Data("## Moment".utf8))
        XCTAssertNotNil(board.contents[NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
        XCTAssertNotNil(board.contents[NSPasteboard.PasteboardType("org.nspasteboard.TransientType")])
        XCTAssertEqual(later?.0, .seconds(120), "cleared after 2 minutes")
        later?.1()
        XCTAssertEqual(board.cleared, 1)
        XCTAssertNil(board.contents[.string])
    }

    func testItIsNotClearedWhenSomethingElseWasCopiedSince() {
        let board = FakePasteboard()
        var later: (() -> Void)?
        ClipboardHygiene.copy("## Moment", to: board, schedule: { _, work in later = work })
        board.changeCount += 1  // the person copied something else
        later?()
        XCTAssertEqual(board.cleared, 0)
    }

    func testAScreenshotFollowsTheSameRules() {
        let board = FakePasteboard()
        ClipboardHygiene.copy(jpeg: Data([0xFF, 0xD8]), to: board, schedule: { _, _ in })
        XCTAssertEqual(board.options, [.currentHostOnly])
        XCTAssertEqual(board.contents[NSPasteboard.PasteboardType("public.jpeg")], Data([0xFF, 0xD8]))
        XCTAssertNotNil(board.contents[ClipboardHygiene.concealed])
    }

    /// Ask's own Copy: on this Mac only and concealed from clipboard-history
    /// apps, but not transient and never cleared.
    func testACopyToKeepStaysOnThisMacConcealedAndIsNeverCleared() {
        let board = FakePasteboard()
        XCTAssertTrue(ClipboardHygiene.copyToKeep("Thursday", to: board))
        XCTAssertEqual(board.options, [.currentHostOnly], "never Universal Clipboard")
        XCTAssertEqual(board.contents[.string], Data("Thursday".utf8))
        XCTAssertNotNil(board.contents[ClipboardHygiene.concealed])
        XCTAssertNil(board.contents[ClipboardHygiene.transient], "meant to stay")
        XCTAssertEqual(board.cleared, 0)
    }

    /// Every clipboard write in the menu-bar app goes through
    /// `ClipboardHygiene`: no other source file touches a pasteboard (Ask's
    /// Copy wrote straight to it before; storage review S7).
    func testNoOtherFileInTheMenuBarAppWritesToAPasteboard() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let writes = [".setString(", ".setData(", "writeObjects(", ".clearContents()", "declareTypes(",
                      "prepareForNewContents(", "NSPasteboard.general", "NSPasteboard(name:"]
        var checked = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", file.lastPathComponent != "ClipboardHygiene.swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            for write in writes {
                XCTAssertFalse(source.contains(write), "\(file.lastPathComponent) writes to a pasteboard: \(write)")
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }
}

final class DestinationDetectorTests: XCTestCase {
    private func detector(
        schemes: [String: String] = [:], bundles: [String: String] = [:], executables: Set<String> = [],
        path: String = "/usr/bin:/bin"
    ) -> DestinationDetector {
        DestinationDetector(
            appForScheme: { scheme in schemes[scheme].map { URL(fileURLWithPath: $0) } },
            appForBundle: { bundle in bundles[bundle].map { URL(fileURLWithPath: $0) } },
            isExecutable: { executables.contains($0) },
            environment: ["HOME": "/Users/sam", "PATH": path]
        )
    }

    func testNoToolsMeansCopyForYourAI() {
        XCTAssertEqual(detector().installed(), [])
    }

    func testOnlyToolsOnThisMacAreOfferedInTheMenusOrder() {
        let found = detector(
            schemes: ["claude": "/Applications/Claude.app", "cursor": "/Applications/Cursor.app",
                      "codex": "/Applications/Codex.app", "vscode": "/Applications/Visual Studio Code.app"],
            bundles: ["com.openai.chat": "/Applications/ChatGPT.app"]
        ).installed()
        XCTAssertEqual(found.map(\.tool), [.claude, .claudeCode, .chatgpt, .codex, .cursor],
                       "VS Code waits until its link is verified")
        XCTAssertTrue(found.allSatisfy(\.hasApp))
    }

    func testTheAppThatHandlesTheLinkWins() {
        // Two versions installed: Launch Services names the handler.
        let found = detector(schemes: ["claude": "/Users/sam/Applications/Claude.app"],
                             executables: ["/opt/homebrew/bin/claude"]).installed()
        XCTAssertEqual(found.first { $0.tool == .claudeCode }?.appURL?.path, "/Users/sam/Applications/Claude.app")
        XCTAssertNil(found.first { $0.tool == .claudeCode }?.commandLine)
    }

    func testClaudeCodesCommandLineAloneIsCopiedForTerminal() {
        for place in ["/usr/local/bin/claude", "/opt/homebrew/bin/claude", "/Users/sam/.local/bin/claude"] {
            let found = detector(executables: [place]).installed()
            XCTAssertEqual(found.map(\.tool), [.claudeCode], place)
            XCTAssertEqual(found.first?.commandLine, place)
            XCTAssertFalse(found.first?.hasApp ?? true)
        }
        let onPath = detector(executables: ["/Users/sam/bin/claude"], path: "/usr/bin:/Users/sam/bin").installed()
        XCTAssertEqual(onPath.first?.commandLine, "/Users/sam/bin/claude")
    }

    func testChoicesAreRemembered() {
        let choices = HandoffChoices.ephemeral()
        XCTAssertNil(choices.lastTool)
        choices.lastTool = .chatgpt
        XCTAssertEqual(choices.lastTool, .chatgpt)
        XCTAssertFalse(choices.wasTold(.chatgpt))
        choices.markTold(.chatgpt)
        XCTAssertTrue(choices.wasTold(.chatgpt))
        XCTAssertFalse(choices.wasTold(.claude))
    }
}

final class HandoffDeliveryTests: XCTestCase {
    private let claude = InstalledTool(tool: .claude, appURL: URL(fileURLWithPath: "/Applications/Claude.app"))
    private let chatGPT = InstalledTool(tool: .chatgpt, appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))

    private func card(open: String? = nil, folder: String? = nil, leftOut: SendCard.LeftOut = .init(),
                      shortened: Bool = false, people: Bool = false, message: String = "## Moment") -> SendCard {
        SendCard(message: message, words: 2, open: open, copy: open == nil, folder: folder, included: [1],
                 leftOut: leftOut, shortened: shortened, peopleMessages: people)
    }

    func testALinkOpensTheToolAndOffersCopyInstead() {
        let plan = HandoffDelivery.plan(card: card(open: "claude://claude.ai/new?q=x"), tool: .claude,
                                        installed: claude, home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.open(URL(string: "claude://claude.ai/new?q=x")!)])
        XCTAssertEqual(plan.note, HandoffNote(text: "Opened in Claude. You send it from there.",
                                              action: .copyInstead("## Moment")))
        XCTAssertEqual(plan.fallbackCopy, "## Moment", "a link that won't open is copied instead")
        XCTAssertEqual(HandoffDelivery.couldNotOpen(.claude).text, "Couldn’t open Claude. It’s copied instead.")
    }

    func testChatGPTIsCopiedThenOpened() {
        let plan = HandoffDelivery.plan(card: card(), tool: .chatgpt, installed: chatGPT, home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.copy("## Moment"), .open(URL(fileURLWithPath: "/Applications/ChatGPT.app"))])
        XCTAssertEqual(plan.note.text, "Copied. In ChatGPT, start a new chat and press ⌘V.")
        XCTAssertEqual(plan.note.lines, ["Clears in 2 minutes."])
    }

    func testATooMissingFromThisMacOpensItsSiteWithNothingInTheAddress() {
        let plan = HandoffDelivery.plan(card: card(), tool: .chatgpt, installed: nil, home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.copy("## Moment"), .open(URL(string: "https://chatgpt.com/")!)])
        XCTAssertEqual(plan.note.text, "ChatGPT isn’t on this Mac. Copied, and opened chatgpt.com.")
        let claudeWeb = HandoffDelivery.plan(card: card(), tool: .claude, installed: nil, home: "/Users/sam")
        XCTAssertEqual(claudeWeb.steps.last, .open(URL(string: "https://claude.ai/new")!))
        for step in plan.steps + claudeWeb.steps {
            if case .open(let url) = step { XCTAssertNil(url.query, "memory never goes in an https link") }
        }
    }

    func testClaudeCodesCommandLineIsCopiedWithOpenTerminalHere() {
        let line = InstalledTool(tool: .claudeCode, appURL: nil, commandLine: "/opt/homebrew/bin/claude")
        let plan = HandoffDelivery.plan(card: card(folder: "~/dev/trailhead-shop"), tool: .claudeCode,
                                        installed: line, home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.copy("## Moment")])
        XCTAssertEqual(plan.note.text, "Copied. Run claude in trailhead-shop, then press ⌘V.")
        XCTAssertEqual(plan.note.action, .openTerminal(URL(fileURLWithPath: "/Users/sam/dev/trailhead-shop", isDirectory: true)))
    }

    func testWhatWasLeftOutIsSaid() {
        let plan = HandoffDelivery.plan(
            card: card(open: "claude://claude.ai/new?q=x", leftOut: .init(forgotten: 2, secretLines: 1),
                       shortened: true, people: true),
            tool: .claude, installed: claude, home: "/Users/sam")
        XCTAssertEqual(plan.note.lines, [
            "Shortened to fit Claude’s message box.",
            "1 line left out: it looked like a password or code.",
            "2 moments were forgotten, so they’re left out.",
            "Includes messages from other people.",
        ])
        XCTAssertEqual(plan.note.action, .copyFullVersion)
    }

    func testNothingOpensWhenEverythingWasForgotten() {
        let plan = HandoffDelivery.plan(card: card(open: nil, leftOut: .init(forgotten: 1), message: ""),
                                        tool: .claude, installed: claude, home: "/Users/sam")
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.note.text, "1 moment was forgotten, so it’s left out.")
    }
}

final class SendCardWireTests: XCTestCase {
    func testTheRequestIsWrittenAsTheBuilderReadsIt() throws {
        let request = SendCardRequest(
            to: "claude", question: "Why?", moments: [4812], selected: 4812,
            session: .init(startUs: 1, endUs: 2, title: "Shipping"), item: "w_1", includeAboutMe: true,
            includeScreenshot: false, appInstalled: true, full: false
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(object["to"] as? String, "claude")
        XCTAssertEqual(object["include_about_me"] as? Bool, true)
        XCTAssertEqual(object["include_screenshot"] as? Bool, false)
        XCTAssertEqual(object["app_installed"] as? Bool, true)
        XCTAssertEqual((object["session"] as? [String: Any])?["start_us"] as? Int, 1)
        XCTAssertEqual(object["moments"] as? [Int], [4812])
    }

    func testTheCardIsReadAsTheBuilderWritesIt() throws {
        let json = #"""
        {"message":"m","chars":1,"words":1,"open":"claude://claude.ai/new?q=m","copy":false,"folder":"~/dev/x",
         "included":[4812],"left_out":{"forgotten":1,"kept_out":2,"secret_lines":3,"trimmed_moments":4},
         "shortened":true,"people_messages":true,"screenshot_moment":4812}
        """#
        let card = try JSONDecoder().decode(SendCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.leftOut, SendCard.LeftOut(forgotten: 1, keptOut: 2, secretLines: 3, trimmedMoments: 4))
        XCTAssertEqual(card.folder, "~/dev/x")
        XCTAssertTrue(card.shortened && card.peopleMessages)
        XCTAssertEqual(card.screenshotMoment, 4812)
    }

    func testTheWorkReadIsReadLeniently() throws {
        let json = #"""
        {"generated_us":1,"items":[{"id":"w_1","kind":"code","name":"trailhead-shop","apps":["com.microsoft.VSCode"],
         "last_us":5,"folder_guess":"~/dev/trailhead-shop","moments":[3,2],"future_field":true}],
         "pages":[{"title":"Rounding half to even","host":"devnotes.example","path":"/rounding","app":"com.google.Chrome",
         "days":3,"last_us":4,"moments":[9]}],"moment_items":{}}
        """#
        let work = try JSONDecoder().decode(PanelWork.self, from: Data(json.utf8))
        XCTAssertEqual(work.items.first?.name, "trailhead-shop")
        XCTAssertEqual(work.pages.first?.url, URL(string: "https://devnotes.example/rounding"))
        XCTAssertEqual(try JSONDecoder().decode(PanelWork.self, from: Data("{}".utf8)), PanelWork())
    }

    /// The agent's exit codes: the memory couldn't be opened is said as such.
    func testALockedMemoryIsTold() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = dir.appendingPathComponent("mci-agent")
        // It reads its request from standard input, and exits 10 when the key
        // can't be read.
        try "#!/bin/sh\ncat > \(dir.path)/request.json\nexit 10\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        do {
            _ = try await AgentProcess(executable: agent, environment: ["PATH": "/usr/bin:/bin"])
                .card(SendCardRequest(to: "copy", question: "private words"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SendCardError, .locked)
        }
        let request = try String(contentsOf: dir.appendingPathComponent("request.json"), encoding: .utf8)
        XCTAssertTrue(request.contains("private words"), "the question went on standard input")
    }

    func testTheQuestionNeverGoesInTheArguments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = dir.appendingPathComponent("mci-agent")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > \(dir.path)/arguments.txt
        cat > /dev/null
        printf '{"message":"m","words":1,"open":null,"copy":true,"included":[]}\\n'
        """.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let card = try await AgentProcess(executable: agent, environment: ["PATH": "/usr/bin:/bin"])
            .card(SendCardRequest(to: "copy", question: "private words"))
        XCTAssertEqual(card.message, "m")
        let arguments = try String(contentsOf: dir.appendingPathComponent("arguments.txt"), encoding: .utf8)
        XCTAssertEqual(arguments, "send-card\n--json\n")
    }
}

final class HandoffCopyTests: XCTestCase {
    func testTheWordsAreTheSpecs() {
        XCTAssertEqual(HandoffCopy.askHint("Claude"), "Ask Claude")
        XCTAssertEqual(HandoffCopy.askHint(nil), "Ask Your AI…")
        XCTAssertEqual(HandoffCopy.firstUseTitle("Claude"), "Ask Claude opens Claude with what you picked.")
        XCTAssertEqual(HandoffCopy.firstUseBody("Claude"),
                       "Nothing is sent until you press send in Claude. What you send goes to the company that runs Claude.")
        XCTAssertEqual(HandoffCopy.firstUseTitleProject("trailhead-shop"),
                       "Open in Claude Code starts a new session in trailhead-shop with what you picked.")
        XCTAssertEqual(HandoffCopy.size(words: 151, moments: 1), "About 151 words · 1 moment")
        XCTAssertEqual(HandoffCopy.size(words: 218, moments: 7), "About 218 words · 7 moments")
        XCTAssertEqual(HandoffCopy.copyAndOpen("ChatGPT"), "Copy and Open ChatGPT")
        XCTAssertEqual(HandoffCopy.lead, "Nothing leaves this Mac unless you send it, or a tool you connected asks for it.")
        XCTAssertEqual(HandoffCopy.disconnectTitle("Claude Code"), "Disconnect Claude Code?")
        XCTAssertEqual(HandoffCopy.disconnectMessage,
                       "It stops looking things up and starting sessions with your work. What it already read stays in its history.")
        XCTAssertEqual(HandoffCopy.connectTitle("Claude Code and Codex"),
                       "Let Claude Code and Codex look things up in your memory?")
        XCTAssertEqual(HandoffCopy.connectMessage("Claude Code and Codex", count: 2, chatGPTInstalled: true),
                       "They can search what you’ve seen and read your sessions, your day and what Hippocampus learned about you, "
                       + "when a question needs it. What they read goes to the companies that run them. They can read while "
                       + "Hippocampus is quit. They also keep what they read in their own history on this Mac, unencrypted. "
                       + "Forgetting something in Hippocampus doesn’t remove it there. "
                       + "ChatGPT’s desktop app uses Codex’s settings, so it can look things up too.")
        XCTAssertEqual(HandoffCopy.connectMessage("Claude Code", count: 1, chatGPTInstalled: false),
                       "It can search what you’ve seen and read your sessions, your day and what Hippocampus learned about you, "
                       + "when a question needs it. What it reads goes to the company that runs Claude Code. It can read while "
                       + "Hippocampus is quit. It also keeps what it reads in its own history on this Mac, unencrypted. "
                       + "Forgetting something in Hippocampus doesn’t remove it there.")
        // A connected tool's own history (storage review S6).
        XCTAssertEqual(HandoffCopy.privateHistoryTitle(["Codex"]), "Make Codex’s history private?")
        XCTAssertEqual(HandoffCopy.privateHistoryTitle(["Claude Code", "Codex"]),
                       "Make Claude Code’s and Codex’s history private?")
        XCTAssertEqual(HandoffCopy.privateHistoryMessage(["Codex"], folders: ["~/.codex"]),
                       "Codex keeps its sessions in ~/.codex, with what it reads from your memory, and other accounts on "
                       + "this Mac can open them. Make Private lets only you open that folder. Codex works as before.")
        XCTAssertEqual(HandoffCopy.privateHistoryMessage(["Claude Code", "Codex"], folders: ["~/.claude", "~/.codex"]),
                       "Claude Code and Codex keep their sessions in ~/.claude and ~/.codex, with what they read from your "
                       + "memory, and other accounts on this Mac can open them. Make Private lets only you open those "
                       + "folders. They work as before.")
        XCTAssertEqual(HandoffCopy.makePrivate, "Make Private")
        XCTAssertEqual(HandoffCopy.couldNotMakePrivate("Codex"), "Couldn’t make all of Codex’s history private.")
    }

    /// The same bar as the menu bar's words (MenuBarCopyStyleTests).
    func testEveryWordPassesTheCopyRules() {
        let words = [
            HandoffCopy.askHint("Claude"), HandoffCopy.askHint(nil), HandoffCopy.pickTitle, HandoffCopy.pickDetail,
            HandoffCopy.nothingToSend, HandoffCopy.opened("Claude"), HandoffCopy.copiedPaste("ChatGPT"),
            HandoffCopy.copied, HandoffCopy.copiedRunClaude("trailhead-shop"), HandoffCopy.shortened("Claude"),
            HandoffCopy.heldBack(1), HandoffCopy.heldBack(2), HandoffCopy.forgotten(1), HandoffCopy.forgotten(3),
            HandoffCopy.people, HandoffCopy.notInstalled("ChatGPT", site: "chatgpt.com"),
            HandoffCopy.couldNotOpen("Claude"), HandoffCopy.locked, HandoffCopy.firstUseTitle("Claude"),
            HandoffCopy.firstUseBodyPasted("ChatGPT"), HandoffCopy.firstUseFolder("~/dev/trailhead-shop"),
            HandoffCopy.lead, HandoffCopy.whileQuit, HandoffCopy.companyLine, HandoffCopy.chatGPTShares,
            HandoffCopy.codexStep, HandoffCopy.sessionTitle,
            HandoffCopy.sessionMessage("Claude Code and Codex", count: 2, codex: true),
            HandoffCopy.disconnectMessage, HandoffCopy.disconnectAllMessage, HandoffCopy.disconnected("Codex"),
            HandoffCopy.keepsHistory(count: 1), HandoffCopy.keepsHistory(count: 2),
            HandoffCopy.privateHistoryTitle(["Claude Code", "Codex"]),
            HandoffCopy.privateHistoryMessage(["Codex"], folders: ["~/.codex"]),
            HandoffCopy.privateHistoryMessage(["Claude Code", "Codex"], folders: ["~/.claude", "~/.codex"]),
            HandoffCopy.makePrivate, HandoffCopy.couldNotMakePrivate("Codex"),
        ]
        let banned = ["seamless", "smart", "simply", "unlock", "powerful", "magic", "effortless", "mcp", "captured",
                      "provider", "packet", "nothing leaves your mac", "remembers everything", "!"]
        for text in words {
            for word in banned {
                XCTAssertFalse(text.lowercased().contains(word), "\(word) in \(text)")
            }
            XCTAssertFalse(text.contains("——") || text.contains("— —"), text)
        }
    }
}
