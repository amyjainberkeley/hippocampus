import Foundation
import XCTest
@testable import RecallUIKit

/// The kind rules in one place (SPEC 2.14, SPEC-DELTA 1): the agent's app
/// table, mirrored, and which of History's lenses a moment belongs to.
final class MomentKindsTests: XCTestCase {
    private static let appsSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/brain/src/apps.rs")

    /// The window's table is the agent's, entry for entry, so a moment's kind
    /// and its session's colour can never disagree.
    func testTheWindowsAppTableIsTheAgents() throws {
        let source = try String(contentsOf: Self.appsSource, encoding: .utf8)
        let catalog = try XCTUnwrap(source.components(separatedBy: "const CATALOG").dropFirst().first?
            .components(separatedBy: "];").first)
        let pattern = try NSRegularExpression(
            pattern: #"\(\s*"([^"]+)",\s*"[^"]+",\s*WorkKind::(\w+),?\s*\)"#)
        let range = NSRange(catalog.startIndex..., in: catalog)
        let rust: [(String, String)] = pattern.matches(in: catalog, range: range).map { match in
            let id = String(catalog[Range(match.range(at: 1), in: catalog)!])
            let kind = String(catalog[Range(match.range(at: 2), in: catalog)!])
            return (id, kind.prefix(1).lowercased() + kind.dropFirst())
        }
        XCTAssertGreaterThan(rust.count, 100)
        XCTAssertEqual(rust.map(\.0), MomentKinds.catalog.map(\.bundleId), "same apps, same order")
        XCTAssertEqual(rust.map(\.1), MomentKinds.catalog.map(\.kind.rawValue), "same kinds")
    }

    func testAPageInABrowserCountsAsWhatItIs() {
        let cases: [(String?, WorkKind)] = [
            ("https://mail.google.com/mail/u/0/#inbox", .communication), ("https://docs.google.com/document/d/x", .writing),
            ("https://www.github.com/acme/shop/pull/4", .code), ("https://claude.ai/chat/1", .ai),
            ("https://meet.google.com/abc", .meetings), ("https://www.figma.com/file/x", .design),
            ("https://calendar.google.com/", .planning), ("https://www.youtube.com/watch?v=1", .media),
            ("https://devnotes.example/rounding", .research), (nil, .research),
        ]
        for (url, kind) in cases {
            let hit = MomentFactory.hit(1, "com.google.Chrome", url: url)
            XCTAssertEqual(MomentKinds.workKind(of: hit), kind, url ?? "no address")
        }
        XCTAssertEqual(MomentKinds.workKind(bundleId: "COM.MICROSOFT.VSCODE", host: nil), .code, "ids ignore case")
        XCTAssertEqual(MomentKinds.workKind(bundleId: "com.apple.Notes", host: "github.com"), .writing,
                       "only a browser's page changes its kind")
        XCTAssertEqual(MomentKinds.host(of: "https://WWW.Example.com:8443/a?b#c"), "example.com")
        XCTAssertNil(MomentKinds.host(of: "file:///etc/hosts"))
    }

    func testEachLensHoldsItsKindsAndNothingElse() {
        let documents = [
            MomentFactory.hit(1, "com.apple.Notes"), MomentFactory.hit(2, "com.figma.Desktop"),
            MomentFactory.hit(3, "com.apple.iWork.Numbers"), MomentFactory.hit(4, "com.apple.Preview"),
            MomentFactory.hit(5, "com.google.Chrome", url: "https://docs.google.com/document/d/q4"),
            MomentFactory.hit(6, "com.apple.Safari", title: "Q4 planning - Google Docs"),
            MomentFactory.hit(7, "com.google.Chrome", url: "https://sheets.google.com/s/1"),
        ]
        let code = [
            MomentFactory.hit(10, "com.microsoft.VSCode"), MomentFactory.hit(11, "com.apple.Terminal"),
            MomentFactory.hit(12, "com.google.Chrome", url: "https://github.com/acme/shop"),
        ]
        let conversations = [
            MomentFactory.hit(20, "com.tinyspeck.slackmacgap"), MomentFactory.hit(21, "com.apple.mail"),
            MomentFactory.hit(22, "com.openai.chat"), MomentFactory.hit(23, "com.apple.MobileSMS"),
            MomentFactory.hit(24, "com.google.Chrome", url: "https://mail.google.com/mail/u/0"),
            MomentFactory.hit(25, "company.thebrowser.Browser", title: "Inbox (3) - sam@northwind.example - Gmail"),
        ]
        let none = [
            MomentFactory.hit(30, "com.apple.iCal"), MomentFactory.hit(31, "us.zoom.xos"),
            MomentFactory.hit(32, "com.spotify.client"), MomentFactory.hit(33, "com.apple.Safari"),
            MomentFactory.hit(34, "com.google.Chrome", url: "https://devnotes.example/rounding"),
            MomentFactory.hit(35, "com.apple.finder"), MomentFactory.hit(36, "unknown"),
        ]
        for hit in documents { XCTAssertEqual(LibraryLens.lens(of: hit), .documents, "\(hit.id)") }
        for hit in code { XCTAssertEqual(LibraryLens.lens(of: hit), .code, "\(hit.id)") }
        for hit in conversations { XCTAssertEqual(LibraryLens.lens(of: hit), .conversations, "\(hit.id)") }
        for hit in none { XCTAssertNil(LibraryLens.lens(of: hit), "\(hit.id)") }
    }

    func testConversationsChipsSayChatEmailOrAI() {
        XCTAssertEqual(ConversationFilter.kind(of: MomentFactory.hit(1, "com.tinyspeck.slackmacgap")), .chat)
        XCTAssertEqual(ConversationFilter.kind(of: MomentFactory.hit(2, "com.apple.mail")), .email)
        XCTAssertEqual(ConversationFilter.kind(of: MomentFactory.hit(3, "com.google.Chrome",
                                                                     url: "https://mail.google.com/x")), .email)
        XCTAssertEqual(ConversationFilter.kind(of: MomentFactory.hit(4, "com.anthropic.claudefordesktop")), .ai)
        XCTAssertEqual(ConversationFilter.kind(of: MomentFactory.hit(5, "com.google.Chrome",
                                                                     url: "https://chatgpt.com/c/1")), .ai)
        XCTAssertEqual(ConversationFilter.allCases.map(\.title), ["All", "Chat", "Email", "AI"])
    }

    /// A lens's own apps fit the reader's filter, and browsers are read apart.
    func testALensAsksForAtMost32AppsAndNeverABrowser() {
        for lens in LibraryLens.allCases {
            XCTAssertLessThanOrEqual(lens.apps.count, 32, "\(lens)")
            XCTAssertFalse(lens.apps.contains(where: MomentKinds.isBrowser), "\(lens)")
            XCTAssertEqual(Set(lens.apps).count, lens.apps.count, "\(lens) lists an app twice")
            for app in lens.apps {
                XCTAssertEqual(LibraryLens.lens(of: MomentFactory.hit(1, app)), lens, app)
            }
        }
        XCTAssertLessThanOrEqual(MomentKinds.browsers.count, 32)
    }
}
