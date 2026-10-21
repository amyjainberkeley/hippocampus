// SPDX-License-Identifier: Apache-2.0
//
// Ask {Tool} opens a tool's link only in the tool's own app (SPEC 5.3.5):
// macOS gives claude://, codex://, cursor:// and vscode:// links to
// whichever app claims the scheme, and the link carries the question and
// what was on screen. Every lookup here is a fake: no test asks Launch
// Services or reads an app on this Mac.

import XCTest
@testable import HippocampusKit

final class ToolLinkOwnerTests: XCTestCase {
    private static let claude = URL(fileURLWithPath: "/Applications/Claude.app")
    private static let codex = URL(fileURLWithPath: "/Applications/Codex.app")
    private static let cursor = URL(fileURLWithPath: "/Applications/Cursor.app")
    private static let other = URL(fileURLWithPath: "/Applications/Link Catcher.app")

    /// The apps Launch Services would name for each link, and the bundle id
    /// each of those apps says it has.
    private func detector(
        schemes: [String: URL], ids: [URL: String], executables: Set<String> = []
    ) -> DestinationDetector {
        DestinationDetector(
            appForScheme: { schemes[$0] },
            appForBundle: { _ in nil },
            isExecutable: { executables.contains($0) },
            environment: ["HOME": "/Users/sam", "PATH": "/usr/bin:/bin"],
            bundleIdentifier: { ids[$0] }
        )
    }

    private static let ownIds = [
        claude: "com.anthropic.claudefordesktop",
        codex: "com.openai.codex",
        cursor: "com.todesktop.230313mzl4w4u92",
        other: "com.example.linkcatcher",
    ]

    func testEachToolsOwnAppOpensItsLinks() {
        let found = detector(schemes: ["claude": Self.claude, "codex": Self.codex, "cursor": Self.cursor],
                             ids: Self.ownIds).installed()
        XCTAssertEqual(found.map(\.tool), [.claude, .claudeCode, .codex, .cursor])
        XCTAssertEqual(found.map(\.appURL), [Self.claude, Self.claude, Self.codex, Self.cursor])
    }

    /// Another app that claims claude:// is never opened as Claude: Claude
    /// is offered without an app, so its message is copied, and Claude Code
    /// falls back to its command line.
    func testAnotherAppThatClaimsAToolsLinkIsNeverOpenedAsTheTool() {
        let found = detector(schemes: ["claude": Self.other, "codex": Self.other, "cursor": Self.cursor],
                             ids: Self.ownIds, executables: ["/opt/homebrew/bin/claude"]).installed()
        XCTAssertEqual(found.map(\.tool), [.claude, .claudeCode, .codex, .cursor])
        XCTAssertFalse(found.contains { $0.appURL == Self.other }, "the other app is never the tool's app")
        XCTAssertEqual(found.first { $0.tool == .claude }?.hasApp, false)
        XCTAssertEqual(found.first { $0.tool == .codex }?.hasApp, false)
        XCTAssertEqual(found.first { $0.tool == .claudeCode }?.commandLine, "/opt/homebrew/bin/claude")
        XCTAssertEqual(found.first { $0.tool == .cursor }?.appURL, Self.cursor, "a tool's own app still opens")
        // An app whose bundle id can't be read is not taken on trust.
        let unread = detector(schemes: ["cursor": Self.cursor], ids: [:]).installed()
        XCTAssertEqual(unread.map(\.tool), [.cursor])
        XCTAssertNil(unread.first?.appURL)
    }

    /// What Ask {Tool} then does: it copies, and opens the tool's site or
    /// nothing. No step opens the other app or a link it would be handed.
    func testWithAnotherAppOnTheLinkTheMessageIsCopiedNotSent() throws {
        let found = detector(schemes: ["claude": Self.other, "codex": Self.other], ids: Self.ownIds).installed()
        let message = "What did we decide about yearly billing?"
        let card = SendCard(message: message, words: 7, open: nil, copy: true, included: [7])
        let claude = HandoffDelivery.plan(card: card, tool: .claude, installed: found.first { $0.tool == .claude },
                                          home: "/Users/sam")
        XCTAssertEqual(claude.steps, [.copy(message), .open(URL(string: "https://claude.ai/new")!)])
        let codex = HandoffDelivery.plan(card: card, tool: .codex, installed: found.first { $0.tool == .codex },
                                         home: "/Users/sam")
        XCTAssertEqual(codex.steps, [.copy(message)])
        for step in claude.steps + codex.steps {
            if case .open(let url) = step {
                XCTAssertNotEqual(url, Self.other)
                XCTAssertEqual(url.scheme, "https", "only the tool's site, never a link another app is handed")
            }
        }
    }

    /// The bundle ids each tool's app gives itself, and the link it
    /// handles, from each app's own Info.plist.
    func testEachLinkBelongsToItsToolsOwnApp() {
        XCTAssertEqual(DestinationDetector.linkOwners, [
            "claude": ["com.anthropic.claudefordesktop"],
            "codex": ["com.openai.codex"],
            "cursor": ["com.todesktop.230313mzl4w4u92"],
            "vscode": ["com.microsoft.VSCode"],
        ])
        for tool in AskTool.allCases {
            guard let scheme = tool.scheme else { continue }
            XCTAssertNotNil(DestinationDetector.linkOwners[scheme], "\(tool) has its own app")
        }
    }

    /// The app on this Mac checks each link's app: it is built with a bundle
    /// id lookup. (Building it asks the system nothing.)
    func testTheDetectorTheAppUsesChecksEachLinksApp() {
        XCTAssertNotNil(DestinationDetector.live(environment: [:]).bundleIdentifier)
    }
}
