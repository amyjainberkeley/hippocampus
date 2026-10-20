// SPDX-License-Identifier: Apache-2.0
//
// Ask {Tool} in the window (SPEC 5.3): what the button says and opens, the
// request the builder reads, what happens once it answers, and the words.
// Fixtures only: no agent, no real pasteboard, no app opens.

import AppKit
import XCTest
@testable import RecallUIKit

final class AskAIRequestTests: XCTestCase {
    func testAMomentNamesItsIdsAndTheOnePicked() {
        let request = AskAISource.moments([4812, 4790]).request(
            to: "claude", selected: 4790, appInstalled: true, includeAboutMe: true, includeScreenshot: true
        )
        XCTAssertEqual(request.to, "claude")
        XCTAssertEqual(request.moments, [4812, 4790])
        XCTAssertEqual(request.selected, 4790, "the moment picked never goes to make room")
        XCTAssertEqual(request.appInstalled, true)
        XCTAssertTrue(request.includeAboutMe)
        XCTAssertTrue(request.includeScreenshot)
        XCTAssertNil(request.question)
        XCTAssertNil(request.session)
        XCTAssertNil(request.item)
    }

    func testASessionIsNamedByItsTimeAndTitle() {
        let request = AskAISource.session(title: "Shipping the rounding fix", range: 1_000...2_000).request(to: "codex")
        XCTAssertEqual(request.session, .init(startUs: 1_000, endUs: 2_000, title: "Shipping the rounding fix"))
        XCTAssertEqual(request.moments, [])
    }

    func testAnItemIsNamedByItsIdWithItsMomentsForWhenTheWorkReadIsBehind() {
        let request = AskAISource.item("w_9c41e2").request(to: "claude-code", itemMoments: [4790, 4777])
        XCTAssertEqual(request.item, "w_9c41e2")
        XCTAssertEqual(request.moments, [4790, 4777])
    }

    func testAQuestionCarriesItsWordsAndTheMomentsItsAnswerCited() {
        let request = AskAISource.question("Why do totals drift?", moments: [4812]).request(to: "copy", full: true)
        XCTAssertEqual(request.question, "Why do totals drift?")
        XCTAssertEqual(request.moments, [4812])
        XCTAssertTrue(request.full)
    }

    func testTheSizeLineCountsMomentsUntilTheBuilderSays() {
        XCTAssertEqual(AskAISource.moments([1, 2, 3]).momentCount, 3)
        XCTAssertEqual(AskAISource.moments([]).momentCount, 1)
        XCTAssertEqual(AskAISource.item("w_1").momentCount, 1)
    }
}

final class AskAIButtonRulesTests: XCTestCase {
    private let claude = InstalledTool(tool: .claude, appURL: URL(fileURLWithPath: "/Applications/Claude.app"))
    private let claudeCode = InstalledTool(tool: .claudeCode, appURL: URL(fileURLWithPath: "/Applications/Claude.app"))
    private let claudeCodeLine = InstalledTool(tool: .claudeCode, appURL: nil, commandLine: "/opt/homebrew/bin/claude")
    private let chatGPT = InstalledTool(tool: .chatgpt, appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
    private let codex = InstalledTool(tool: .codex, appURL: URL(fileURLWithPath: "/Applications/Codex.app"))

    func testTheButtonOpensTheLastToolChosenWhileItIsStillHere() {
        let tools = [claude, chatGPT]
        XCTAssertEqual(AskAIButtonRules.primaryTool(in: tools, codeProject: nil, lastTool: .chatgpt), chatGPT)
        XCTAssertNil(AskAIButtonRules.primaryTool(in: tools, codeProject: nil, lastTool: nil),
                     "before a tool is chosen it reads Ask Your AI and opens its menu")
        XCTAssertNil(AskAIButtonRules.primaryTool(in: tools, codeProject: nil, lastTool: .cursor),
                     "a tool taken off this Mac is never opened")
    }

    func testACodeProjectOpensInClaudeCodeOrCodex() {
        XCTAssertEqual(AskAIButtonRules.primaryTool(in: [claude, claudeCode, codex], codeProject: "trailhead-shop",
                                                    lastTool: .claude), claudeCode)
        XCTAssertEqual(AskAIButtonRules.primaryTool(in: [claude, codex], codeProject: "trailhead-shop",
                                                    lastTool: .claude), codex)
        XCTAssertEqual(AskAIButtonRules.primaryTool(in: [claude, claudeCodeLine], codeProject: "trailhead-shop",
                                                    lastTool: .claude), claude,
                       "Claude Code's command line alone can't open a session in the folder")
    }

    func testTheButtonsWords() {
        XCTAssertEqual(AskAIButtonRules.label(primary: claude, codeProject: nil), "Ask Claude")
        XCTAssertEqual(AskAIButtonRules.label(primary: nil, codeProject: nil), "Ask Your AI")
        XCTAssertEqual(AskAIButtonRules.label(primary: claudeCode, codeProject: "trailhead-shop"), "Open in Claude Code")
        XCTAssertEqual(AskAIButtonRules.label(primary: codex, codeProject: "trailhead-shop"), "Open in Codex")
        XCTAssertEqual(AskAIButtonRules.label(primary: claudeCodeLine, codeProject: nil), "Copy for Claude Code")
    }

    func testAScreenshotIsOfferedForOneMomentWithOneAndAToolThatTakesPictures() {
        XCTAssertEqual(AskAIButtonRules.screenshotMoment(of: .moments([4812]), selected: nil), 4812)
        XCTAssertEqual(AskAIButtonRules.screenshotMoment(of: .moments([4812, 4790]), selected: 4790), 4790)
        XCTAssertNil(AskAIButtonRules.screenshotMoment(of: .moments([4812, 4790]), selected: nil))
        XCTAssertNil(AskAIButtonRules.screenshotMoment(of: .session(title: "s", range: 1...2), selected: nil))
        XCTAssertNil(AskAIButtonRules.screenshotMoment(of: .item("w_1"), selected: nil))
        XCTAssertTrue(AskAIButtonRules.offersScreenshot(.claude, hasScreenshot: true))
        XCTAssertFalse(AskAIButtonRules.offersScreenshot(.claude, hasScreenshot: false))
        XCTAssertFalse(AskAIButtonRules.offersScreenshot(.claudeCode, hasScreenshot: true),
                       "Claude Code is never offered one")
    }

    func testASecondPressWithinTwoSecondsIsIgnored() {
        var guardian = SendGuard()
        let start = Date(timeIntervalSince1970: 1_791_841_025)
        XCTAssertTrue(guardian.allows(at: start))
        XCTAssertFalse(guardian.allows(at: start.addingTimeInterval(0.4)))
        XCTAssertFalse(guardian.allows(at: start.addingTimeInterval(1.9)))
        XCTAssertTrue(guardian.allows(at: start.addingTimeInterval(2.1)))
        XCTAssertFalse(guardian.allows(at: start.addingTimeInterval(3)))
    }

    func testCopyForYourAISaysWhatWasLeftOut() {
        let card = SendCard(message: "## Moment", words: 2, open: nil, copy: true, included: [1],
                            leftOut: .init(forgotten: 2, secretLines: 1), peopleMessages: true)
        XCTAssertEqual(AskAIButtonRules.copiedNote(card), """
        Copied. Clears in 2 minutes.
        1 line left out: it looked like a password or code.
        2 moments were forgotten, so they’re left out.
        Includes messages from other people.
        """)
        let forgotten = SendCard(message: "", words: 0, open: nil, copy: true, included: [],
                                 leftOut: .init(forgotten: 1))
        XCTAssertEqual(AskAIButtonRules.copiedNote(forgotten), "1 moment was forgotten, so it’s left out.")
    }

    func testALockedMemoryIsSaidAsSuch() {
        XCTAssertEqual(AskAIButtonRules.failureNote(SendCardError.locked),
                       "Hippocampus couldn’t open your memory. Open Hippocampus, then try again.")
        XCTAssertEqual(AskAIButtonRules.failureNote(SendCardError.failed), "Couldn’t copy. Try again.")
        XCTAssertEqual(AskAIButtonRules.failureNote(CancellationError()), "Couldn’t copy. Try again.")
    }

    func testToolsAreOfferedInTheMenusOrderWithTheirOwnRules() {
        XCTAssertEqual(AskTool.menuOrder, [.claude, .claudeCode, .chatgpt, .codex, .cursor],
                       "VS Code waits until its link is verified")
        XCTAssertEqual(AskTool.allCases.filter(\.isPasted), [.chatgpt])
        XCTAssertEqual(AskTool.allCases.filter { !$0.takesImages }, [.claudeCode])
        for tool in AskTool.allCases {
            if let site = tool.site { XCTAssertNil(site.url.query, "memory never goes in an https link") }
        }
        XCTAssertEqual(AskTool.allCases.compactMap { $0.site?.name }, ["claude.ai", "chatgpt.com"])
    }

    /// The window and the menu-bar app open the same tool: the same keys in
    /// the app's defaults (the app's HandoffChoices).
    func testChoicesAreKeptWhereTheMenuBarAppReadsThem() {
        XCTAssertEqual(HandoffChoices.lastToolKey, "ai.hippocampus.handoff.lastTool")
        XCTAssertEqual(HandoffChoices.toldKeyPrefix, "ai.hippocampus.handoff.told.")
        var kept: [String: Any] = [:]
        let choices = HandoffChoices(read: { kept[$0] }, write: { kept[$1] = $0 })
        XCTAssertNil(choices.lastTool)
        choices.lastTool = .codex
        XCTAssertEqual(kept["ai.hippocampus.handoff.lastTool"] as? String, "codex")
        XCTAssertFalse(choices.wasTold(.codex))
        choices.markTold(.codex)
        XCTAssertEqual(kept["ai.hippocampus.handoff.told.codex"] as? Bool, true)
        XCTAssertFalse(choices.wasTold(.claude), "each tool is told once, on its own")
        kept[HandoffChoices.lastToolKey] = "not-a-tool"
        XCTAssertNil(choices.lastTool)
        choices.lastTool = nil
        XCTAssertNil(kept[HandoffChoices.lastToolKey])
    }

    func testPreviewsAndTestsKeepChoicesInMemoryOnly() {
        let one = HandoffChoices.ephemeral()
        let other = HandoffChoices.ephemeral()
        one.lastTool = .cursor
        one.markTold(.cursor)
        XCTAssertEqual(one.lastTool, .cursor)
        XCTAssertTrue(one.wasTold(.cursor))
        XCTAssertNil(other.lastTool, "each keeps its own")
        XCTAssertFalse(other.wasTold(.cursor))
    }
}

final class HandoffPlanTests: XCTestCase {
    private let claude = InstalledTool(tool: .claude, appURL: URL(fileURLWithPath: "/Applications/Claude.app"))
    private let chatGPT = InstalledTool(tool: .chatgpt, appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
    private let link = "claude://claude.ai/new?q=%23%23%20Moment"

    private func card(
        open: String? = nil, folder: String? = nil, leftOut: SendCard.LeftOut = .init(), shortened: Bool = false,
        people: Bool = false, message: String = "## Moment"
    ) -> SendCard {
        SendCard(message: message, words: 2, open: open, copy: open == nil, folder: folder, included: [4812],
                 leftOut: leftOut, shortened: shortened, peopleMessages: people)
    }

    func testALinkOpensTheToolAndOffersCopyInstead() {
        let plan = HandoffPlan.make(card: card(open: link), tool: .claude, installed: claude, home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.open(URL(string: link)!)])
        XCTAssertEqual(plan.note, HandoffNote(text: "Opened in Claude. You send it from there.",
                                              action: .copyInstead("## Moment")))
        XCTAssertEqual(plan.fallbackCopy, "## Moment")
    }

    func testChatGPTIsCopiedThenItsAppOpens() {
        let plan = HandoffPlan.make(card: card(), tool: .chatgpt, installed: chatGPT, home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.copy("## Moment"), .open(URL(fileURLWithPath: "/Applications/ChatGPT.app"))])
        XCTAssertEqual(plan.note.fullText, "Copied. In ChatGPT, start a new chat and press ⌘V.\nClears in 2 minutes.")
        XCTAssertNil(plan.note.action)
    }

    func testAToolMissingFromThisMacOpensItsSiteWithNothingInTheAddress() {
        let plan = HandoffPlan.make(card: card(), tool: .chatgpt, installed: nil, home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.copy("## Moment"), .open(URL(string: "https://chatgpt.com/")!)])
        XCTAssertEqual(plan.note.text, "ChatGPT isn’t on this Mac. Copied, and opened chatgpt.com.")
        let web = HandoffPlan.make(card: card(), tool: .claude, installed: nil, home: "/Users/sam")
        XCTAssertEqual(web.steps.last, .open(URL(string: "https://claude.ai/new")!))
        for case .open(let url) in plan.steps + web.steps {
            XCTAssertNil(url.query, "memory never goes in an https link")
        }
    }

    func testClaudeCodesCommandLineIsCopiedWithOpenTerminalHere() {
        let line = InstalledTool(tool: .claudeCode, appURL: nil, commandLine: "/opt/homebrew/bin/claude")
        let plan = HandoffPlan.make(card: card(folder: "~/dev/trailhead-shop"), tool: .claudeCode, installed: line,
                                    home: "/Users/sam")
        XCTAssertEqual(plan.steps, [.copy("## Moment")])
        XCTAssertEqual(plan.note.text, "Copied. Run claude in trailhead-shop, then press ⌘V.")
        XCTAssertEqual(plan.note.action,
                       .openTerminal(URL(fileURLWithPath: "/Users/sam/dev/trailhead-shop", isDirectory: true)))
        let nowhere = HandoffPlan.make(card: card(), tool: .claudeCode, installed: line, home: "/Users/sam")
        XCTAssertEqual(nowhere.note.text, "Copied. Run claude in your project, then press ⌘V.")
        XCTAssertNil(nowhere.note.action)
    }

    func testWhatWasLeftOutIsSaidAndTheFullVersionOffered() {
        let plan = HandoffPlan.make(
            card: card(open: link, leftOut: .init(forgotten: 2, secretLines: 1), shortened: true, people: true),
            tool: .claude, installed: claude, home: "/Users/sam"
        )
        XCTAssertEqual(plan.note.lines, [
            "Shortened to fit Claude’s message box.",
            "1 line left out: it looked like a password or code.",
            "2 moments were forgotten, so they’re left out.",
            "Includes messages from other people.",
        ])
        XCTAssertEqual(plan.note.action, .copyFullVersion)
    }

    func testNothingOpensWhenEverythingWasForgotten() {
        let plan = HandoffPlan.make(card: card(leftOut: .init(forgotten: 1), message: ""), tool: .claude,
                                    installed: claude, home: "/Users/sam")
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.note.text, "1 moment was forgotten, so it’s left out.")
    }

    func testATickedScreenshotIsPastedAfterTheLinkOrCopiedByItsOwnButton() {
        let linked = HandoffPlan.make(card: card(open: link), tool: .claude, installed: claude, home: "/Users/sam",
                                      screenshot: true)
        XCTAssertEqual(linked.note.lines.first, "Press ⌘V to add the screenshot.")
        let pasted = HandoffPlan.make(card: card(), tool: .chatgpt, installed: chatGPT, home: "/Users/sam",
                                      screenshot: true)
        XCTAssertEqual(pasted.note.action, .copyScreenshot, "the text goes first; the picture by its own button")
    }
}

@MainActor
final class HandoffPlanPerformTests: XCTestCase {
    private let claude = InstalledTool(tool: .claude, appURL: URL(fileURLWithPath: "/Applications/Claude.app"))
    private let chatGPT = InstalledTool(tool: .chatgpt, appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"))
    private let link = "claude://claude.ai/new?q=%23%23%20Moment"

    private var copied: [String] = []
    private var pictures: [Data] = []
    private var opened: [URL] = []

    private func perform(_ plan: HandoffPlan, tool: AskTool, screenshot: Data? = nil, opens: Bool = true,
                         copies: Bool = true) -> HandoffNote? {
        plan.perform(
            tool: tool, screenshot: screenshot,
            copy: { text in
                guard copies else { return false }
                self.copied.append(text)
                return true
            },
            copyJPEG: { data in
                self.pictures.append(data)
                return true
            },
            open: { url in
                self.opened.append(url)
                return opens
            }
        )
    }

    private func card(open: String?) -> SendCard {
        SendCard(message: "## Moment", words: 2, open: open, copy: open == nil, included: [4812])
    }

    func testALinkLeavesTheClipboardAlone() {
        let plan = HandoffPlan.make(card: card(open: link), tool: .claude, installed: claude, home: "/Users/sam")
        let note = perform(plan, tool: .claude)
        XCTAssertEqual(opened, [URL(string: link)!])
        XCTAssertEqual(copied, [])
        XCTAssertEqual(note?.text, "Opened in Claude. You send it from there.")
    }

    func testALinkThatWontOpenIsCopiedInstead() {
        let plan = HandoffPlan.make(card: card(open: link), tool: .claude, installed: claude, home: "/Users/sam")
        let note = perform(plan, tool: .claude, opens: false)
        XCTAssertEqual(copied, ["## Moment"])
        XCTAssertEqual(note, HandoffNote(text: "Couldn’t open Claude. It’s copied instead.",
                                         lines: ["Clears in 2 minutes."]))
    }

    func testTheScreenshotGoesOnTheClipboardOnceTheLinkOpened() {
        let plan = HandoffPlan.make(card: card(open: link), tool: .claude, installed: claude, home: "/Users/sam",
                                    screenshot: true)
        _ = perform(plan, tool: .claude, screenshot: Data([0xFF, 0xD8]))
        XCTAssertEqual(pictures, [Data([0xFF, 0xD8])])
        pictures = []
        _ = perform(plan, tool: .claude, screenshot: Data([0xFF, 0xD8]), opens: false)
        XCTAssertEqual(pictures, [], "the message took the clipboard: the picture waits")
    }

    func testPastedTextIsCopiedBeforeTheAppOpensAndThePictureWaitsForItsButton() {
        let plan = HandoffPlan.make(card: card(open: nil), tool: .chatgpt, installed: chatGPT, home: "/Users/sam",
                                    screenshot: true)
        let note = perform(plan, tool: .chatgpt, screenshot: Data([0xFF, 0xD8]))
        XCTAssertEqual(copied, ["## Moment"])
        XCTAssertEqual(opened, [URL(fileURLWithPath: "/Applications/ChatGPT.app")])
        XCTAssertEqual(pictures, [])
        XCTAssertEqual(note?.action, .copyScreenshot)
    }

    func testNothingOpensWhenTheMessageCouldntBeCopied() {
        let plan = HandoffPlan.make(card: card(open: nil), tool: .chatgpt, installed: chatGPT, home: "/Users/sam")
        XCTAssertNil(perform(plan, tool: .chatgpt, copies: false))
        XCTAssertEqual(opened, [], "a tool never opens to an empty message box")
    }
}

final class WindowHandoffCopyTests: XCTestCase {
    func testTheWordsAreTheSpecs() {
        XCTAssertEqual(HandoffCopy.firstUseTitle("Claude"), "Ask Claude opens Claude with what you picked.")
        XCTAssertEqual(HandoffCopy.firstUseBody("Claude"),
                       "Nothing is sent until you press send in Claude. What you send goes to the company that runs Claude.")
        XCTAssertEqual(HandoffCopy.firstUseTitleProject("trailhead-shop"),
                       "Open in Claude Code starts a new session in trailhead-shop with what you picked.")
        XCTAssertEqual(HandoffCopy.size(words: 151, moments: 1), "About 151 words · 1 moment")
        XCTAssertEqual(HandoffCopy.size(words: 218, moments: 7), "About 218 words · 7 moments")
        XCTAssertEqual(HandoffCopy.opened("Claude"), "Opened in Claude. You send it from there.")
        XCTAssertEqual(HandoffCopy.copyAndOpen("ChatGPT"), "Copy and Open ChatGPT")
        XCTAssertEqual(HandoffCopy.lead, "Your memory leaves this Mac only when you send it, or a tool you connected asks for it.")
        // The exact text opens "From the user's screen": the size line says
        // what it is made from, never that the screen is left out.
        XCTAssertEqual(HandoffCopy.startsWithSize(words: 120),
                       "About 120 words, written on this Mac from what you read on screen.")
    }

    /// Every window word for handing context passes the launch copy rules.
    func testEveryWordPassesTheCopyRules() {
        let words = [
            HandoffCopy.ask("Claude"), HandoffCopy.ask(nil), HandoffCopy.openIn("Claude Code"),
            HandoffCopy.copyFor("Claude Code"), HandoffCopy.copyForYourAI, HandoffCopy.includeScreenshot,
            HandoffCopy.includeAboutMe, HandoffCopy.opened("Claude"), HandoffCopy.copyInstead,
            HandoffCopy.screenshotPaste, HandoffCopy.copyScreenshot, HandoffCopy.copiedPaste("ChatGPT"),
            HandoffCopy.clears, HandoffCopy.copied, HandoffCopy.copiedRunClaude("trailhead-shop"),
            HandoffCopy.openTerminalHere, HandoffCopy.shortened("Codex"), HandoffCopy.copyFullVersion,
            HandoffCopy.heldBack(1), HandoffCopy.heldBack(3), HandoffCopy.forgotten(1), HandoffCopy.forgotten(2),
            HandoffCopy.people, HandoffCopy.notInstalled("ChatGPT", site: "chatgpt.com"),
            HandoffCopy.couldNotOpen("Claude"), HandoffCopy.locked, HandoffCopy.couldNotCopy,
            HandoffCopy.couldNotOpenTerminal,
            HandoffCopy.firstUseTitle("Claude"), HandoffCopy.firstUseTitleProject("trailhead-shop"),
            HandoffCopy.firstUseBody("Claude"), HandoffCopy.firstUseBodyPasted("ChatGPT"),
            HandoffCopy.firstUseFolderLead() + "~/dev/trailhead-shop" + HandoffCopy.firstUseFolderTail,
            HandoffCopy.openTool("Claude"), HandoffCopy.copyAndOpen("ChatGPT"), HandoffCopy.whatGoes,
            HandoffCopy.size(words: 98, moments: 1), HandoffCopy.pageTitle, HandoffCopy.lead,
            HandoffCopy.onTheirOwn, HandoffCopy.withOneKey, HandoffCopy.alsoOnThisMac, HandoffCopy.connected,
            HandoffCopy.notConnected, HandoffCopy.getsRecentWork, HandoffCopy.looksThingsUp,
            HandoffCopy.turnedOffIn("Codex"), HandoffCopy.codexAsked, HandoffCopy.chatGPTShares,
            HandoffCopy.codexNeedsStep, HandoffCopy.codexStep, HandoffCopy.overridden, HandoffCopy.lookUpsSwitch,
            HandoffCopy.sessionSwitch, HandoffCopy.whatItStartsWith, HandoffCopy.showExactText,
            HandoffCopy.startsWithSize(words: 120), HandoffCopy.notConnectedNote("Claude Code"),
            HandoffCopy.codexNotConnectedNote, HandoffCopy.connectButton, HandoffCopy.oneKeyTail,
            HandoffCopy.chatGPTUse, HandoffCopy.use("Cursor"), HandoffCopy.companyLine, HandoffCopy.whileQuit,
            HandoffCopy.changeInPreferences, HandoffCopy.empty, HandoffCopy.unavailable, HandoffCopy.tryAgain,
            HandoffCopy.youConfirmed, HandoffCopy.seenOnDays(1), HandoffCopy.seenOnDays(3),
        ]
        let machineWords = ["mcp", "provider", "packet", "captured", "context window", "token", "nothing leaves your mac",
                            "remembers everything"]
        for text in words {
            XCTAssertNil(CopyStyleValidator.containsJargon(text), text)
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(text), text)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(text), text)
            XCTAssertFalse(CopyStyleValidator.containsRawErrorCode(text), text)
            for word in machineWords {
                XCTAssertFalse(text.lowercased().contains(word), "\(word) in \(text)")
            }
        }
    }
}
