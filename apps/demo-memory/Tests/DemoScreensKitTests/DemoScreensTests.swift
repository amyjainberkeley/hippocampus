// SPDX-License-Identifier: Apache-2.0
import AppKit
import DemoScreensKit
import Foundation
import MCIKeyframeCodec
import XCTest

/// Demo Memory's pictures: every drawing draws, the same list draws the
/// same pictures, and each is sealed as the capture helper seals a
/// screenshot, so the window opens it as it opens a person's own.
@MainActor
final class DemoScreensTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })

    /// One screen of each drawing, as the seeder writes them.
    static let sample = """
        {"version": 1, "now_us": 1792446060000000, "tz_offset_secs": -25200, "screens": [
         {"id": "code-billing-ts", "template": "editor", "app": "com.microsoft.VSCode",
          "title": "billing.ts \\u2014 pebblewick-app", "url": null,
          "main": "import Stripe from \\"stripe\\";\\n\\n// Moves a studio to yearly billing.\\nexport async function switchToYearly(studioId: string) {\\n  return 42;\\n}",
          "rest": "", "meta": {"project": "pebblewick-app", "file": "billing.ts", "tabs": ["plans.ts", "billing.ts"],
          "active_tab": 1, "tree": ["\\u25be src", "billing.ts", "plans.ts", "package.json", "README.md"],
          "language": "TypeScript", "cursor_line": 4, "branch": "annual-billing"}},
         {"id": "terminal-tests", "template": "terminal", "app": "com.apple.Terminal",
          "title": "pebblewick-app \\u2014 -zsh \\u2014 160\\u00d740", "url": null,
          "main": "ren@studio pebblewick-app % pnpm test\\n \\u2713 src/billing.test.ts (4 tests) 41ms\\n      Tests  4 passed (4)\\nren@studio pebblewick-app %",
          "rest": "", "meta": {"prompt": "ren@studio pebblewick-app % "}},
         {"id": "stripe-catalog", "template": "browser", "app": "com.google.Chrome",
          "title": "Product catalog \\u2013 Stripe", "url": "https://dashboard.stripe.com/products",
          "main": "Product catalog", "rest": "", "meta": {"page": "stripe", "account": "Pebblewick",
          "nav": ["Home", "Product catalog"], "selected_nav": "Product catalog", "heading": "Product catalog",
          "subheading": "Products", "columns": ["Name", "Pricing", "Status"],
          "rows": [["Studio", "$49.00 USD / month", "Active"]], "highlight_row": 0, "button": "Add product",
          "tabs": ["Product catalog \\u2013 Stripe", "Q4 investor update - Google Docs"], "active_tab": 0,
          "address": "dashboard.stripe.com/products"}},
         {"id": "docs-q4-1", "template": "browser", "app": "com.google.Chrome",
          "title": "Q4 investor update - Google Docs", "url": "https://docs.google.com/document/d/x/edit",
          "main": "Q4 investor update", "rest": "", "meta": {"page": "gdocs", "doc_title": "Q4 investor update",
          "blocks": [["h1", "Q4 investor update"], ["h2", "Highlights"], ["li", "Monthly revenue reached $84,200."],
          ["p", "Net revenue retention: 108%"]], "tabs": ["Q4 investor update - Google Docs"], "active_tab": 0,
          "address": "docs.google.com/document/d/x/edit"}},
         {"id": "sheets-budget-0", "template": "browser", "app": "com.google.Chrome",
          "title": "2027 budget - Google Sheets", "url": "https://docs.google.com/spreadsheets/d/y/edit",
          "main": "2027 budget", "rest": "", "meta": {"page": "gsheets", "doc_title": "2027 budget",
          "columns": ["", "Q1", "Q2"], "rows": [["Revenue", "$1.12M", "$1.31M"], ["Headcount", "9", "11"]],
          "bold_rows": [0], "sheets": ["Plan", "Hiring"], "active_sheet": 0, "selected_row": 1,
          "tabs": ["2027 budget - Google Sheets"], "active_tab": 0, "address": "docs.google.com/spreadsheets/d/y/edit"}},
         {"id": "search-proration", "template": "browser", "app": "com.google.Chrome",
          "title": "stripe prorate - Google Search", "url": "https://www.google.com/search?q=stripe+prorate",
          "main": "stripe prorate", "rest": "", "meta": {"page": "search", "query": "stripe prorate",
          "results": [["Prorations | Stripe Documentation", "docs.stripe.com \\u203a billing", "Credit the unused time."]],
          "tabs": ["stripe prorate - Google Search"], "active_tab": 0, "address": "google.com/search?q=stripe+prorate"}},
         {"id": "claude-proration", "template": "browser", "app": "com.google.Chrome",
          "title": "Prorating yearly upgrades - Claude", "url": "https://claude.ai/chat/x",
          "main": "Prorating yearly upgrades", "rest": "", "meta": {"page": "claude", "chat_title": "Prorating yearly upgrades",
          "messages": [["user", "How should I prorate?"], ["assistant", "Credit the unused part of the month."]],
          "tabs": ["Prorating yearly upgrades - Claude"], "active_tab": 0, "address": "claude.ai/chat/x"}},
         {"id": "stripe-docs", "template": "browser", "app": "com.google.Chrome",
          "title": "Prorations | Stripe Documentation", "url": "https://docs.stripe.com/billing/subscriptions/prorations",
          "main": "Prorations", "rest": "", "meta": {"page": "docs", "site": "Stripe Docs", "breadcrumb": "Billing",
          "sidebar": ["Subscriptions", "Prorations"], "selected": "Prorations",
          "blocks": [["h1", "Prorations"], ["p", "Credit the unused time."], ["code", "billing_cycle_anchor: \\"now\\""]],
          "tabs": ["Prorations | Stripe Documentation"], "active_tab": 0, "address": "docs.stripe.com/billing"}},
         {"id": "stripe-pricing", "template": "browser", "app": "com.google.Chrome",
          "title": "Pricing & Fees | Stripe", "url": "https://stripe.com/pricing",
          "main": "Pricing", "rest": "", "meta": {"page": "stripe-pricing", "headline": "Pricing built for businesses of all sizes",
          "subheadline": "Pay as you go.", "cards": [["Payments", "2.9% + 30\\u00a2", "per successful card charge"]],
          "tabs": ["Pricing & Fees | Stripe"], "active_tab": 0, "address": "stripe.com/pricing"}},
         {"id": "article-update", "template": "browser", "app": "com.google.Chrome",
          "title": "How to write a monthly investor update", "url": "https://foundernotes.example/investor-updates",
          "main": "How to write", "rest": "", "meta": {"page": "article", "site": "Founder Notes", "nav": ["Essays"],
          "byline": "5 min read", "blocks": [["h1", "How to write a monthly investor update"], ["p", "Lead with the numbers."]],
          "tabs": ["How to write a monthly investor update"], "active_tab": 0, "address": "foundernotes.example/investor-updates"}},
         {"id": "classbook-pricing", "template": "browser", "app": "com.google.Chrome",
          "title": "Pricing \\u00b7 Classbook", "url": "https://classbook.example/pricing",
          "main": "Pricing", "rest": "", "meta": {"page": "pricing", "site": "Classbook", "headline": "Simple pricing",
          "subheadline": "Yearly plans save 15%", "cards": [["Solo", "$25", "a month", "One instructor"]],
          "tabs": ["Pricing \\u00b7 Classbook"], "active_tab": 0, "address": "classbook.example/pricing"}},
         {"id": "slack-team-notes", "template": "slack", "app": "com.tinyspeck.slackmacgap",
          "title": "team (Channel) - Pebblewick - Slack", "url": null, "main": "# team", "rest": "",
          "meta": {"workspace": "Pebblewick", "channel": "team", "channels": ["general", "team"], "dms": ["Iris Lindgren"],
          "messages": [["Ren Alder", "10:20 AM", "Team sync notes"], ["Iris Lindgren", "10:21 AM", "I'll review it."]],
          "topic": "Daily notes"}},
         {"id": "zoom-team-sync", "template": "zoom", "app": "us.zoom.xos", "title": "Zoom Meeting", "url": null,
          "main": "Team sync", "rest": "", "meta": {"meeting": "Team sync",
          "participants": ["Iris Lindgren", "Theo Brandt", "Ren Alder"], "speaker": 0}},
         {"id": "notion-changelog-1", "template": "notion", "app": "notion.id", "title": "October changelog", "url": null,
          "main": "October changelog", "rest": "", "meta": {"workspace": "Pebblewick", "sidebar": ["Product", "October changelog"],
          "selected": "October changelog", "breadcrumb": "Product / October changelog",
          "blocks": [["h1", "October changelog"], ["h2", "Waitlists are here"], ["li", "Reminders follow the time zone."]]}},
         {"id": "figma-pricing-1", "template": "figma", "app": "com.figma.Desktop", "title": "Pricing page v2", "url": null,
          "main": "Pricing page v2", "rest": "", "meta": {"file": "Pricing page v2", "pages": ["Pricing", "Checkout"],
          "layers": ["Hero", "Plans", "Studio"], "headline": "Pricing that grows with your studio",
          "toggle": ["Monthly", "Yearly"], "plans": [["Starter", "$19", "a month", "Two instructors"],
          ["Studio", "$49", "a month", "Waitlists"], ["Pro", "$99", "a month", "Locations"]], "highlight": 1}},
         {"id": "calendar-week-2026-10-19", "template": "calendar", "app": "com.apple.iCal", "title": "Calendar", "url": null,
          "main": "October 2026", "rest": "", "meta": {"month_label": "October 2026",
          "days": [["Mon 19", true], ["Tue 20", false], ["Wed 21", false], ["Thu 22", false], ["Fri 23", false],
          ["Sat 24", false], ["Sun 25", false]], "events": [[0, 600, 620, "Team sync", "Zoom"], [0, 960, 990, "Investor update", "Zoom"]],
          "now_minutes": 545, "today_label": "Monday, October 19"}}
        ]}
        """

    private func list() throws -> DemoScreenList {
        try DemoScreenList.read(Data(Self.sample.utf8))
    }

    func testTheListIsReadAsTheSeederWritesIt() throws {
        let list = try list()
        XCTAssertEqual(list.version, 1)
        XCTAssertEqual(list.nowUs, 1_792_446_060_000_000)
        XCTAssertEqual(list.tzOffsetSecs, -25_200)
        XCTAssertEqual(Set(list.screens.map(\.template)), Set(DemoScreens.templates), "one of each drawing")
        let editor = try XCTUnwrap(list.screens.first)
        XCTAssertEqual(editor.meta["tabs"]?.texts, ["plans.ts", "billing.ts"])
        XCTAssertEqual(editor.meta["cursor_line"]?.int, 4)
        XCTAssertNil(editor.url)
    }

    func testAListItCannotDrawIsRefused() {
        let wrongVersion = #"{"version": 2, "now_us": 1, "tz_offset_secs": 0, "screens": []}"#
        XCTAssertThrowsError(try DemoScreenList.read(Data(wrongVersion.utf8))) { error in
            XCTAssertEqual(error as? DemoScreenList.ReadError, .unsupportedVersion(2))
        }
        let screen = #"{"id": "same", "template": "zoom", "app": "us.zoom.xos", "title": "Zoom", "main": "x"}"#
        let twice = #"{"version": 1, "now_us": 1, "tz_offset_secs": 0, "screens": [\#(screen), \#(screen)]}"#
        XCTAssertThrowsError(try DemoScreenList.read(Data(twice.utf8))) { error in
            XCTAssertEqual(error as? DemoScreenList.ReadError, .duplicateId("same"))
        }
        let path = #"{"id": "../etc", "template": "zoom", "app": "us.zoom.xos", "title": "Zoom", "main": "x"}"#
        let badId = #"{"version": 1, "now_us": 1, "tz_offset_secs": 0, "screens": [\#(path)]}"#
        XCTAssertThrowsError(try DemoScreenList.read(Data(badId.utf8))) { error in
            XCTAssertEqual(error as? DemoScreenList.ReadError, .badId("../etc"))
        }
        let unknown = DemoScreenSpec(id: "x", template: "spreadsheet", app: "a.b", title: "t", main: "m")
        XCTAssertThrowsError(try DemoScreens.jpeg(unknown)) { error in
            XCTAssertEqual(error as? DemoScreens.DrawError, .unknownTemplate("spreadsheet"))
        }
    }

    func testEveryDrawingIsAWholeRetinaWindow() throws {
        for spec in try list().screens {
            let rep = try DemoScreens.bitmap(spec)
            XCTAssertEqual(rep.pixelsWide, 2880, spec.id)
            XCTAssertEqual(rep.pixelsHigh, 1800, spec.id)
            XCTAssertEqual(rep.size, NSSize(width: 1440, height: 900), spec.id)
            // Something was drawn: the picture is not one colour.
            let corner = rep.colorAt(x: 1, y: 1)
            let middle = rep.colorAt(x: 1440, y: 900)
            let somewhere = (0..<40).map { rep.colorAt(x: 70 * $0 + 10, y: 45 * $0 + 10) }
            XCTAssertTrue(somewhere.contains { $0 != corner } || middle != corner, spec.id)
            let jpeg = try DemoScreens.jpeg(spec)
            XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "\(spec.id) is a JPEG")
            XCTAssertLessThan(jpeg.count, 10 * 1024 * 1024, "within the helper's limit")
        }
    }

    func testTheSameListDrawsTheSamePictures() throws {
        for spec in try list().screens {
            XCTAssertEqual(try DemoScreens.jpeg(spec), try DemoScreens.jpeg(spec), spec.id)
        }
    }

    func testEachPictureIsSealedAsTheHelperSealsAScreenshot() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-screens-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blobs = folder.appendingPathComponent("blobs", isDirectory: true)
        let pictures = folder.appendingPathComponent("pictures", isDirectory: true)
        let list = try list()
        let manifest = try DemoScreens.make(list, key: key, blobRoot: blobs, pngFolder: pictures)
        XCTAssertEqual(Set(manifest.screens.keys), Set(list.screens.map(\.id)))
        for spec in list.screens {
            let digest = try XCTUnwrap(manifest.screens[spec.id])
            let url = blobs.appendingPathComponent(digest).appendingPathExtension("bin")
            let sealed = try Data(contentsOf: url)
            XCTAssertEqual(KeyframeBlobCodec.sha256Hex(of: sealed), digest, "named by its sealed bytes")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let opened = try KeyframeBlobCodec.open(blob: sealed, keyMaterial: key)
            XCTAssertEqual(opened, try DemoScreens.jpeg(spec), "the window opens the drawing")
            XCTAssertThrowsError(try KeyframeBlobCodec.open(blob: sealed, keyMaterial: Data(repeating: 1, count: 32)),
                                 "only Demo Memory's key opens it")
            XCTAssertTrue(FileManager.default.fileExists(atPath: pictures.appendingPathComponent("\(spec.id).png").path))
        }
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: blobs.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let json = try JSONSerialization.jsonObject(with: manifest.json()) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertEqual((json?["screens"] as? [String: String])?.count, list.screens.count)
    }
}
