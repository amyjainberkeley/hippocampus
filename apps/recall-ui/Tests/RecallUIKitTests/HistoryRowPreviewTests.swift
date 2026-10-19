// HistoryRowPreviewTests — a History row's text starts with what the window
// said, not with what the row already shows, and a terminal or code keeps
// its lines. Every moment here is made up.

import XCTest

@testable import RecallUIKit

final class HistoryRowPreviewTests: XCTestCase {
    private func hit(app: String, title: String?, snippet: String) -> Hit {
        Hit(eventId: 1, tsUs: 1, appBundleId: app, windowTitle: title, url: nil,
            ocrTextSnippet: snippet, source: "recent", score: nil, sourceKind: "screen_ocr")
    }

    // MARK: Leading lines the row already shows

    func testTheWindowsOwnNameReadOffTheScreenIsLeftOut() {
        // A document's name with the star beside it, then its name again.
        XCTAssertEqual(
            Formatters.rowPreview("Q4 planning \u{2606}\nQ4 planning\nOwner: Priya Shah\nGoals",
                                  title: "Q4 planning - Google Docs"),
            "Owner: Priya Shah \u{00B7} Goals")
        // A results page's search box, read with its clear and search buttons.
        XCTAssertEqual(
            Formatters.rowPreview("Google per seat vs tiered pricing X Q\nPer-seat or tiered? How to price a team plan",
                                  title: "per seat vs tiered pricing - Google Search"),
            "Per-seat or tiered? How to price a team plan")
    }

    func testADayOrATimeAloneOnItsLineIsLeftOut() {
        XCTAssertEqual(
            Formatters.rowPreview("Sam Lee\nToday 2:21 PM\nAre we still on for 3?", title: "Sam Lee"),
            "Are we still on for 3?")
        for line in ["Today 2:21 PM", "Yesterday", "Mon, Oct 12 at 2:21 PM", "14:05", "2:21pm"] {
            XCTAssertTrue(Formatters.isDayOrTime(line), line)
        }
        for line in ["Maya Chen 10:42 AM", "May 2026", "Today we ship", "Oct 12 launch plan", "3:1 odds", "12"] {
            XCTAssertFalse(Formatters.isDayOrTime(line), line)
        }
    }

    func testALabelInCapitalsOverAHeadingIsLeftOut() {
        XCTAssertEqual(
            Formatters.rowPreview("MONEY & ROUNDING\nRounding half to even\nWhy banker\u{2019}s rounding keeps totals exact",
                                  title: "Rounding half to even \u{00B7} Dev Notes"),
            "Why banker\u{2019}s rounding keeps totals exact")
        XCTAssertEqual(Formatters.rowPreview("TEAM PLANS\nPer-seat or tiered?", title: nil), "Per-seat or tiered?")
        XCTAssertTrue(Formatters.isLabel("OPINION"))
        XCTAssertFalse(Formatters.isLabel("Maya Chen 10:42 AM"))
        XCTAssertFalse(Formatters.isLabel("ONE TWO THREE FOUR FIVE SIX"))
        XCTAssertFalse(Formatters.isLabel("2:21"))
        // A terminal keeps its own lines, capitals and all.
        let build = Hit(eventId: 1, tsUs: 1, appBundleId: "com.apple.Terminal", windowTitle: "zsh", url: nil,
                        ocrTextSnippet: "BUILD SUCCESSFUL\nTotal time: 3 secs", source: "recent", score: nil)
        XCTAssertEqual(MomentRowText.codeLines(build), ["BUILD SUCCESSFUL", "Total time: 3 secs"])
    }

    func testALineWithMoreThanTheTitleStays() {
        XCTAssertFalse(Formatters.repeatsTitle("Hero", title: "Pricing page"))
        XCTAssertFalse(Formatters.repeatsTitle("Q4 planning notes", title: "Q4 planning - Google Docs"))
        XCTAssertFalse(Formatters.repeatsTitle("\u{2606}", title: "Q4 planning"))
        XCTAssertFalse(Formatters.repeatsTitle("Q4 planning", title: nil))
        XCTAssertTrue(Formatters.repeatsTitle("Sam Lee", title: "Sam Lee"))
    }

    func testTheOnlyLineIsKeptAndAtMostThreeLeadingLinesGo() {
        XCTAssertEqual(Formatters.rowPreview("Q4 planning \u{2606}", title: "Q4 planning - Google Docs"),
                       "Q4 planning \u{2606}")
        XCTAssertEqual(
            Formatters.previewLines("Today\nToday\nToday\nToday\nShip it.", title: nil),
            ["Today", "Ship it."])
    }

    func testASearchRowKeepsTheLinesItsWordsWereFoundIn() {
        let found = Hit(eventId: 1, tsUs: 1, appBundleId: "com.google.Chrome",
                        windowTitle: "Rounding half to even \u{00B7} Dev Notes", url: nil,
                        ocrTextSnippet: "MONEY & ROUNDING\nRounding half to even", source: "lexical", score: 1)
        XCTAssertEqual(MomentRowText.preview(found), "MONEY & ROUNDING \u{00B7} Rounding half to even")
        let listed = Hit(eventId: 1, tsUs: 1, appBundleId: "com.google.Chrome",
                         windowTitle: "Rounding half to even \u{00B7} Dev Notes", url: nil,
                         ocrTextSnippet: "MONEY & ROUNDING\nRounding half to even\nWhy it matters", source: "recent",
                         score: nil)
        XCTAssertEqual(MomentRowText.preview(listed), "Why it matters")
        let terminal = Hit(eventId: 1, tsUs: 1, appBundleId: "com.apple.Terminal", windowTitle: "zsh", url: nil,
                           ocrTextSnippet: "running 6 tests\ntest result: ok", source: "hybrid", score: 1)
        XCTAssertNil(MomentRowText.codeLines(terminal), "a search's passage runs together, its words in view")
    }

    // MARK: Terminals and code keep their lines

    func testATerminalShowsItsFirstLinesOneToALine() {
        let terminal = hit(app: "com.apple.Terminal", title: "trailhead-shop \u{2014} zsh",
                           snippet: "dev@studio trailhead-shop % cargo test tax\n   Compiling trailhead-shop v0.4.2\nrunning 6 tests")
        XCTAssertEqual(MomentRowText.codeLines(terminal),
                       ["dev@studio trailhead-shop % cargo test tax", "Compiling trailhead-shop v0.4.2"])
    }

    func testCodeInAnEditorShowsItsFirstLinesAndProseRunsTogether() {
        let code = hit(app: "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop",
                       snippet: "pub fn order_total(lines: &[Line]) -> Money {\n    let tax = subtotal * TAX_RATE;\n}")
        XCTAssertEqual(MomentRowText.codeLines(code),
                       ["pub fn order_total(lines: &[Line]) -> Money {", "let tax = subtotal * TAX_RATE;"])
        let readme = hit(app: "com.microsoft.VSCode", title: "README.md \u{2014} trailhead-shop",
                         snippet: "Trailhead shop\nThe checkout for the bike shop.\nRun the tests before each release.")
        XCTAssertNil(MomentRowText.codeLines(readme))
        let page = hit(app: "com.google.Chrome", title: "Rounding half to even",
                       snippet: "let tax = subtotal * TAX_RATE;\nround_half_even(subtotal + tax)")
        XCTAssertNil(MomentRowText.codeLines(page), "a browser's text runs together")
    }

    func testALongCodeLineIsCut() {
        let long = "let total = " + String(repeating: "price + ", count: 40) + "tax;"
        let code = hit(app: "dev.zed.Zed", title: "cart.rs", snippet: long + "\n}")
        let lines = try? XCTUnwrap(MomentRowText.codeLines(code))
        XCTAssertEqual(lines?.count, 2)
        XCTAssertLessThanOrEqual(lines?.first?.count ?? 0, 160)
        XCTAssertTrue(lines?.first?.hasSuffix("\u{2026}") ?? false)
    }
}
