import XCTest
@testable import RecallUIKit

/// How Working On says time and places: Screen Time's lengths, Apple's
/// relative days, an item's apps or its site, in the person's calendar.
final class WorkFormatTests: XCTestCase {
    private let calendar = WorkClock.calendar
    private let now = WorkClock.now

    private func names(_ bundle: String) -> String {
        [
            "com.microsoft.VSCode": "VS Code", "com.apple.Terminal": "Terminal", "com.google.Chrome": "Chrome",
            "com.figma.Desktop": "Figma", "com.apple.Notes": "Notes", "com.apple.Safari": "Safari",
            "com.apple.Preview": "Preview",
        ][bundle] ?? bundle
    }

    func testLengthsAreWrittenTheWayScreenTimeWritesThem() {
        XCTAssertEqual(WorkFormat.duration(minutes: 160), "2 hr 40 min")
        XCTAssertEqual(WorkFormat.duration(minutes: 55), "55 min")
        XCTAssertEqual(WorkFormat.duration(minutes: 180), "3 hr")
        XCTAssertEqual(WorkFormat.duration(minutes: 0), "1 min", "never under a minute")
        XCTAssertEqual(WorkFormat.duration(minutes: -5), "1 min")
    }

    func testWhenSaysTodayYesterdayTheWeekdayOrTheDate() {
        func when(_ us: UInt64) -> String { spaced(WorkFormat.when(us: us, now: now, calendar: calendar)) }
        func short(_ us: UInt64) -> String { spaced(WorkFormat.whenShort(us: us, now: now, calendar: calendar)) }
        func row(_ us: UInt64) -> String { spaced(WorkFormat.rowTime(us: us, now: now, calendar: calendar)) }
        XCTAssertEqual(when(WorkClock.us(0, 14, 20)), "today at 2:20 PM")
        XCTAssertEqual(when(WorkClock.us(1, 18, 12)), "yesterday at 6:12 PM")
        XCTAssertEqual(when(WorkClock.us(3, 16, 5)), "Friday at 4:05 PM")
        XCTAssertEqual(when(WorkClock.us(10, 16, 5)), "Oct 2 at 4:05 PM")
        XCTAssertEqual(when(WorkClock.us(400, 9)), "Sep 7, 2025")

        XCTAssertEqual(short(WorkClock.us(0, 14, 20)), "Today 2:20 PM")
        XCTAssertEqual(short(WorkClock.us(1, 18, 12)), "Yesterday 6:12 PM")
        XCTAssertEqual(short(WorkClock.us(3, 16, 5)), "Fri 4:05 PM")
        XCTAssertEqual(short(WorkClock.us(10, 16, 5)), "Oct 2")

        XCTAssertEqual(row(WorkClock.us(0, 14, 35)), "2:35 PM")
        XCTAssertEqual(row(WorkClock.us(3, 15, 16)), "Fri 3:16 PM")
        XCTAssertEqual(WorkingOnItemModel.dayLabel(Date(timeIntervalSince1970: Double(WorkClock.us(3, 9)) / 1e6),
                                                   now: now, calendar: calendar), "Fri")
        XCTAssertEqual(WorkingOnItemModel.dayLabel(Date(timeIntervalSince1970: Double(WorkClock.us(10, 9)) / 1e6),
                                                   now: now, calendar: calendar), "Oct 2")
        XCTAssertEqual(WorkingOnItemModel.dayLabel(now, now: now, calendar: calendar), WorkCopy.today)
    }

    func testPlacesNameTheAppsOrTheSiteADocumentLivesOn() {
        let code = WorkItem(id: "w_a", kind: .code, name: "trailhead-shop",
                            apps: ["com.microsoft.VSCode", "com.apple.Terminal"], lastUs: WorkClock.us(0, 14, 20),
                            weekMinutes: 160, daysThisWeek: 3)
        XCTAssertEqual(WorkFormat.placesSentence(code, appName: names), "VS Code and Terminal")
        XCTAssertEqual(WorkFormat.placesList(code, appName: names), "VS Code, Terminal")
        XCTAssertEqual(spaced(WorkFormat.headerLine(code, now: now, calendar: calendar, appName: names)),
                       "Code project \u{00B7} VS Code and Terminal \u{00B7} Last worked on today at 2:20 PM")
        XCTAssertEqual(WorkFormat.weekLine(code), "On 3 days this week \u{00B7} 2 hr 40 min")

        let doc = WorkItem(id: "w_b", kind: .document, name: "Q4 planning", apps: ["com.google.Chrome"],
                           hosts: ["docs.google.com"], lastUs: WorkClock.us(0, 13, 59))
        XCTAssertEqual(WorkFormat.placesSentence(doc, appName: names), "Google Docs in Chrome")
        XCTAssertEqual(WorkFormat.placesList(doc, appName: names), "Google Docs", "the browser goes unsaid")

        let three = WorkItem(id: "w_c", kind: .design, name: "Trailhead pricing v3",
                             apps: ["com.figma.Desktop", "com.apple.Notes", "com.apple.Safari", "com.apple.Preview"],
                             lastUs: WorkClock.us(0, 13, 46))
        XCTAssertEqual(WorkFormat.placesSentence(three, appName: names), "Figma, Notes and Preview",
                       "a browser goes unsaid beside the apps")
        let webOnly = WorkItem(id: "w_e", kind: .design, name: "Moodboard", apps: ["com.apple.Safari"],
                               lastUs: WorkClock.us(0, 13))
        XCTAssertEqual(WorkFormat.placesSentence(webOnly, appName: names), "Safari", "unless it is all there is")
        XCTAssertEqual(WorkFormat.siteName(host: "www.Figma.com", kind: .design), "Figma")
        XCTAssertEqual(WorkFormat.siteName(host: "docs.google.com", kind: .spreadsheet), "Google Sheets")
        XCTAssertNil(WorkFormat.siteName(host: "devnotes.example", kind: .document))
        XCTAssertEqual(WorkFormat.placesSentence(WorkItem(id: "w_d", kind: .document, name: "x", lastUs: 1)), "")
    }

    func testTheSidebarsTooltipAndVoiceOverSayNameKindAndWhen() {
        let item = WorkItem(id: "w_a", kind: .code, name: "trailhead-shop", lastUs: WorkClock.us(0, 14, 20))
        XCTAssertEqual(spaced(WorkFormat.tooltip(item, now: now, calendar: calendar)),
                       "trailhead-shop \u{00B7} Last worked on today at 2:20 PM")
        XCTAssertEqual(spaced(WorkFormat.accessibilityLabel(item, now: now, calendar: calendar)),
                       "trailhead-shop, code project, last worked on 2:20 PM")
        XCTAssertEqual(WorkCopy.showAllAccessibility(8), "Show all, 8 items")
        XCTAssertEqual(WorkCopy.showAllAccessibility(1), "Show all, 1 item")
    }

    func testEveryWordWorkingOnShowsIsCalmAndPlain() {
        let words = [
            WorkCopy.workingOnLead, WorkCopy.thisWeek, WorkCopy.earlier, WorkCopy.notShownInSidebar,
            WorkCopy.youHidIt, WorkCopy.looksPersonal, WorkCopy.showInSidebar, WorkCopy.hideFromSidebar,
            WorkCopy.workingOnEmptyTitle, WorkCopy.workingOnEmptyBody, WorkCopy.fieldPlaceholder,
            WorkCopy.searchEverything, WorkCopy.sidebarFootnote, WorkCopy.retention(days: 90), WorkCopy.change,
            WorkCopy.codeProject, WorkCopy.document, WorkCopy.design, WorkCopy.spreadsheet,
            WorkCopy.claudeCodeStarts, WorkCopy.seeWhatItGets, WorkCopy.whereYouLeftOff, WorkCopy.files,
            WorkCopy.seenAlongside, WorkCopy.seenAlongsideLead, WorkCopy.conversations, WorkCopy.conversationsLead,
            WorkCopy.meetings, WorkCopy.meetingsLead, WorkCopy.history, WorkCopy.andMore(2), WorkCopy.showEarlier,
            WorkCopy.showInHistory, WorkCopy.openPage, WorkCopy.open("VS Code"), WorkCopy.contextForThisFolder,
            WorkCopy.copyForYourAI, WorkCopy.nothingYet, WorkCopy.nothingLeft("trailhead-shop"),
            WorkCopy.nothingLeftToShow, WorkCopy.notShownLine, WorkCopy.loadFailed, WorkCopy.tryAgain,
            WorkCopy.webPagesLead, WorkCopy.allBrowsers, WorkCopy.onDays(3), WorkCopy.readOnDays(3),
            WorkCopy.readTimes(2, "today"), WorkCopy.openLink, WorkCopy.copyLink, WorkCopy.forgetThisPage,
            WorkCopy.noAddressesNote, WorkCopy.addBrowserExtension, WorkCopy.webPagesEmptyTitle,
            WorkCopy.webPagesEmptyBody, WorkCopy.noPagesFrom("Safari"), WorkCopy.nothingMatched("Working On"),
            WorkCopy.inAllTime("3 hr"), WorkCopy.thisWeekTime("55 min"), WorkCopy.screenshotOf("Q4 planning"),
        ]
        for word in words {
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
            XCTAssertFalse(CopyStyleValidator.containsRawErrorCode(word), word)
            for machine in ["event", "episode", "snapshot", "context packet"] {
                XCTAssertFalse(word.lowercased().contains(machine), "\(word) says \(machine)")
            }
        }
    }
}
