// MomentCaptionTests — a History row says what the moment was about.
//
// The FFI's `HitJson.caption` and `EventReadingJson.caption` reach `Hit` and
// `EventReading`; `MomentRowText` makes the row's headline, its one or two
// lines of text and the line under them. Every moment here is made up.

import XCTest

@testable import RecallUIKit

final class MomentCaptionTests: XCTestCase {
    private func hit(caption: String?, title: String? = "How to type accents on a Mac - Apple Support",
                     snippet: String = "How to type accents on a Mac\nPress and hold a letter key.\nChoose an accent from the menu.",
                     sourceKind: String? = "screen_ocr") -> Hit {
        Hit(eventId: 1, tsUs: 1, appBundleId: "com.google.Chrome", windowTitle: title, url: nil,
            ocrTextSnippet: snippet, source: "recent", score: nil, sourceKind: sourceKind, caption: caption)
    }

    // MARK: Wire

    func testTheFFICaptionReachesTheHit() throws {
        let json = """
            {"event_id": 7, "ts_us": 100, "app_bundle_id": "com.google.Chrome", "window_title": "Accents",
             "url": null, "ocr_text_snippet": "How to type accents", "source": "recent", "score": null,
             "caption": "Looking up how to type accents"}
            """
        let hit = try JSONDecoder().decode(HitWire.self, from: Data(json.utf8)).toHit()
        XCTAssertEqual(hit.caption, "Looking up how to type accents")
    }

    func testAPayloadWithoutACaptionStillDecodes() throws {
        let json = """
            {"event_id": 7, "ts_us": 100, "app_bundle_id": null, "window_title": null, "url": null,
             "ocr_text_snippet": "", "source": "recent", "score": null}
            """
        XCTAssertNil(try JSONDecoder().decode(HitWire.self, from: Data(json.utf8)).toHit().caption)
    }

    func testTheDetailReadingCarriesTheCaption() throws {
        let json = """
            {"event_id": 7, "ts_us": 100, "app_bundle_id": "com.google.Chrome", "source_kind": "screen_ocr",
             "main": "How to type accents on a Mac", "rest": "Trailhead - Sched", "match_in": null,
             "truncated": false, "caption": "Looking up how to type accents"}
            """
        let reading = try XCTUnwrap(FFIBrainReader.decodeEventReading(Data(json.utf8), eventId: 7))
        XCTAssertEqual(reading.caption, "Looking up how to type accents")
        XCTAssertEqual(reading.main, "How to type accents on a Mac")
        let older = """
            {"event_id": 7, "ts_us": 100, "app_bundle_id": null, "source_kind": "screen_ocr",
             "main": "Text", "rest": "", "match_in": null, "truncated": false}
            """
        XCTAssertNil(try XCTUnwrap(FFIBrainReader.decodeEventReading(Data(older.utf8), eventId: 7)).caption)
    }

    func testACaptionIsOneShownLineOrNone() {
        XCTAssertEqual(MomentRowText.caption("  Reading the launch plan  "), "Reading the launch plan")
        XCTAssertEqual(MomentRowText.caption("Reading the plan\nand more"), "Reading the plan")
        XCTAssertEqual(MomentRowText.caption("Reading\u{1E}the plan"), "Reading the plan")
        XCTAssertNil(MomentRowText.caption(""))
        XCTAssertNil(MomentRowText.caption("   "))
        XCTAssertNil(MomentRowText.caption(nil))
        XCTAssertNil(MomentRowText.caption(String(repeating: "a", count: 201)))
    }

    // MARK: Row

    func testTheHeadlineIsTheCaptionOrTheWindowName() {
        XCTAssertEqual(MomentRowText.headline(hit(caption: "Looking up how to type accents")),
                       "Looking up how to type accents")
        XCTAssertEqual(MomentRowText.headline(hit(caption: nil)), "How to type accents on a Mac - Apple Support")
        XCTAssertEqual(MomentRowText.headline(hit(caption: nil, title: nil)), "Chrome")
    }

    func testTheLineUnderACaptionNamesTheAppAndTheWindow() {
        XCTAssertEqual(MomentRowText.origin(hit(caption: "Looking up how to type accents")),
                       "Chrome \u{00B7} How to type accents on a Mac \u{00B7} Apple Support")
        XCTAssertEqual(MomentRowText.origin(hit(caption: "Looking up how to type accents"), count: 3),
                       "Chrome \u{00B7} How to type accents on a Mac \u{00B7} Apple Support, 3 moments")
        let parts = MomentRowText.originParts(hit(caption: "Looking up how to type accents"), count: 3)
        XCTAssertEqual(parts.place, "Chrome \u{00B7} How to type accents on a Mac \u{00B7} Apple Support")
        XCTAssertEqual(parts.count, "3 moments")
        // Without a caption the title is the headline, so the line says what
        // kind of moment it was, as before.
        XCTAssertEqual(MomentRowText.origin(hit(caption: nil)),
                       "Chrome \u{00B7} \(UserFacingCopy.momentSource(sourceKind: "screen_ocr"))")
    }

    func testThePreviewLeavesOutALineThatRepeatsTheTitleAndRunsTwoLinesTogether() {
        XCTAssertEqual(MomentRowText.preview(hit(caption: "x")),
                       "Press and hold a letter key. Choose an accent from the menu.")
        let long = String(repeating: "word ", count: 100)
        let preview = MomentRowText.preview(hit(caption: "x", snippet: long))
        XCTAssertLessThanOrEqual(preview.count, 220)
        XCTAssertTrue(preview.hasSuffix("\u{2026}"))
    }

    func testAHeadingOrANameNeverRunsIntoTheLineAfterIt() {
        XCTAssertEqual(
            Formatters.rowPreview("Hero\nBig headline, one line of copy\nThree columns", title: "Checkout redesign"),
            "Hero \u{00B7} Big headline, one line of copy \u{00B7} Three columns")
        XCTAssertEqual(
            Formatters.rowPreview("Maya Chen 10:42 AM\nPushed the new onboarding flow.", title: "launch-plan"),
            "Maya Chen 10:42 AM \u{00B7} Pushed the new onboarding flow.")
        // A wrapped sentence reads on.
        XCTAssertEqual(
            Formatters.rowPreview("Most teams choose between seats\nand tiers.", title: nil),
            "Most teams choose between seats and tiers.")
    }

    func testTheLineUnderACaptionSaysOnlyWhatTheCaptionDoesNot() {
        func row(_ app: String, _ title: String, _ caption: String) -> Hit {
            Hit(eventId: 1, tsUs: 1, appBundleId: app, windowTitle: title, url: nil, ocrTextSnippet: "",
                source: "recent", score: nil, sourceKind: "screen_ocr", caption: caption)
        }
        XCTAssertEqual(MomentRowText.origin(row("com.tinyspeck.slackmacgap",
                                                "Sam Lee (DM) - Northwind Studio - Slack",
                                                "Chatting with Sam Lee")),
                       "Slack \u{00B7} Northwind Studio")
        XCTAssertEqual(MomentRowText.origin(row("com.apple.Notes", "Notes", "Using Notes")), "Notes")
        XCTAssertEqual(MomentRowText.origin(row("com.apple.Terminal",
                                                "\u{2733} Fix rounding in tax.rs \u{2014} claude \u{2014} 160\u{00D7}40",
                                                "Working in Terminal: Fix rounding in tax.rs")),
                       "Terminal")
        XCTAssertEqual(MomentRowText.origin(row("com.google.Chrome", "Q4 planning - Google Docs",
                                                "Working on \u{201C}Q4 planning\u{201D}")),
                       "Chrome")
        XCTAssertEqual(MomentRowText.origin(row("com.apple.ActivityMonitor", "Activity Monitor (All Processes)",
                                                "Using Activity Monitor")),
                       "Activity Monitor")
        XCTAssertEqual(MomentRowText.origin(row("us.zoom.xos", "Zoom Workplace", "Using Zoom")), "Zoom")
        XCTAssertEqual(MomentRowText.origin(row("com.google.Chrome",
                                                "Re: Invoice 1042 - sam@northwind.example - Northwind Mail",
                                                "Reading the email \u{201C}Invoice 1042\u{201D}")),
                       "Chrome \u{00B7} sam@northwind.example \u{00B7} Northwind Mail")
    }

    func testAppNamesComeFromTheReadersOneTable() {
        XCTAssertEqual(Formatters.appDisplayName("com.apple.systempreferences"), "System Settings")
        XCTAssertEqual(Formatters.appDisplayName("com.apple.ActivityMonitor"), "Activity Monitor")
        XCTAssertEqual(Formatters.appDisplayName("com.apple.AppStore"), "App Store")
        XCTAssertEqual(Formatters.appDisplayName("com.microsoft.edgemac"), "Microsoft Edge")
    }

    func testAStatusMarkInATitleIsNotPartOfIt() {
        XCTAssertEqual(Formatters.titleWithoutMarks("\u{2733} Fix rounding in tax.rs"), "Fix rounding in tax.rs")
        XCTAssertEqual(Formatters.titleWithoutMarks("\u{2810} Fix rounding in tax.rs"), "Fix rounding in tax.rs")
        XCTAssertEqual(Formatters.titleWithoutMarks("(3) Inbox"), "(3) Inbox")
        XCTAssertEqual(Formatters.titleWithoutMarks("~/hippo-work"), "~/hippo-work")
        // A coding assistant's spinner changes its mark: one session, one row.
        let hits = ["\u{2733}", "\u{2810}", "\u{2733}"].enumerated().map { index, mark in
            Hit(eventId: UInt64(3 - index), tsUs: UInt64(300 - index * 100), appBundleId: "com.apple.Terminal",
                windowTitle: "\(mark) Fix rounding in tax.rs", url: nil, ocrTextSnippet: "", source: "recent",
                score: nil, sourceKind: "screen_ocr")
        }
        let rows = HistorySections.group(hits: hits, sessions: [], calendar: Calendar(identifier: .gregorian))
            .flatMap(\.rows)
        XCTAssertEqual(rows.map(\.count), [3])
    }

    func testANameAndATimeNeverRunIntoAMessage() {
        XCTAssertEqual(
            Formatters.rowPreview(
                "Sam Lee 2:02 PM\ncan you look at the tax test before 4?\nPriya Shah 2:05 PM\non it, it\u{2019}s the half-cent case",
                title: "Messages"),
            "Sam Lee 2:02 PM \u{00B7} can you look at the tax test before 4? \u{00B7} Priya Shah 2:05 PM \u{00B7} on it, it\u{2019}s the half-cent case")
    }

    func testASearchResultsAddressLineIsNotTheRowsText() {
        XCTAssertTrue(Formatters.isCitation("pricingnotes.example \u{203A} team-plans"))
        XCTAssertTrue(Formatters.isCitation("https://saasguide.example \u{203A} pricing \u{203A} seats"))
        XCTAssertFalse(Formatters.isCitation("Settings \u{203A} Privacy"))
        XCTAssertEqual(
            Formatters.rowPreview("How to price a team plan\npricingnotes.example \u{203A} team-plans\nMost teams choose between seats and tiers.",
                                  title: "pricing - Google Search", isPassage: true),
            "How to price a team plan \u{00B7} Most teams choose between seats and tiers.")
    }

    func testThePreviewNeverShowsTheStoredHeader() {
        let stored = "[app=com.google.Chrome | title=Accents | url=? | ts=2026-10-12T14:00:00.000Z]\nChoose an accent from the menu."
        XCTAssertEqual(Formatters.rowPreview(stored, title: "Accents"), "Choose an accent from the menu.")
    }
}
