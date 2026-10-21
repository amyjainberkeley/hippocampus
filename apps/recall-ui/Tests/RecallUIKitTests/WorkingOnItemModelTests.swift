import AppKit
import SwiftUI
import XCTest
@testable import RecallUIKit

/// A Working On page in depth (SPEC 3.2, SPEC-DELTA 4): where you left off
/// with its screenshot, the files, what was open alongside, conversations by
/// name only, the meetings that overlapped its sessions, and its History by
/// day. All from fixtures; the calendar is a fake.
@MainActor
final class WorkingOnItemModelTests: XCTestCase {
    private let shop = "w_5c1e8a0d2f9b47e3a6d1"

    private var moments: [Hit] {
        [
            workMoment(9, WorkClock.us(0, 14, 20), app: "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop"),
            workMoment(8, WorkClock.us(0, 14, 12), app: "com.apple.Terminal", title: "trailhead-shop \u{2014} zsh",
                       screenshot: "/tmp/fixture/terminal.jpg"),
            workMoment(7, WorkClock.us(0, 11, 2), app: "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop",
                       screenshot: "/tmp/fixture/editor.jpg"),
            workMoment(6, WorkClock.us(3, 16, 5), app: "com.microsoft.VSCode", title: "cart.rs \u{2014} trailhead-shop"),
            workMoment(5, WorkClock.us(10, 9), app: "com.microsoft.VSCode", title: "money.rs \u{2014} trailhead-shop"),
            // Seen alongside and a conversation, at their own times.
            workMoment(20, WorkClock.us(0, 14, 35), title: "Rounding half to even", url: "https://devnotes.example/rounding"),
            workMoment(21, WorkClock.us(0, 11, 18), title: "rust round half to even - Google Search",
                       url: "https://www.google.com/search?q=rust+round+half+to+even"),
            workMoment(22, WorkClock.us(0, 14, 28), app: "com.tinyspeck.slackmacgap", title: "launch (Channel)"),
        ]
    }

    private func item(files: Int = 8, sessions: [WorkSession] = []) -> WorkItem {
        WorkItem(
            id: shop, kind: .code, name: "trailhead-shop", apps: ["com.microsoft.VSCode", "com.apple.Terminal"],
            lastUs: WorkClock.us(0, 14, 20), weekMinutes: 160, daysThisWeek: 3,
            files: (0..<files).map { WorkFile(name: "file\($0).rs", lastUs: WorkClock.us(0, 14) - UInt64($0), moment: 9) },
            alongside: [
                WorkAlongside(kind: "page", title: "Rounding half to even", host: "devnotes.example",
                              app: "com.google.Chrome", moment: 20, lastUs: 1),
                WorkAlongside(kind: "search", title: "rust round half to even", host: "google.com",
                              app: "com.google.Chrome", moment: 21, lastUs: 1),
                WorkAlongside(kind: "ai_chat", title: "Rounding modes for money", host: "claude.ai",
                              app: "com.google.Chrome", moment: 99, lastUs: WorkClock.us(1, 9, 30)),
            ],
            folderGuess: "~/dev/trailhead-shop", moments: [9, 8, 7, 6, 5], thumbnailMoment: 8, totalMinutes: 640,
            conversations: [WorkConversation(name: "#launch", app: "com.tinyspeck.slackmacgap", moment: 22, lastUs: 1)],
            sessions: sessions)
    }

    private func model(_ item: WorkItem?, calendar: (any CalendarReader)? = nil) -> WorkingOnItemModel {
        WorkingOnItemModel(itemId: shop, work: PreviewWorkReader(snapshot: WorkSnapshot(items: item.map { [$0] } ?? [])),
                           reader: WorkMomentsReader(moments), calendarReader: calendar, calendar: WorkClock.calendar,
                           now: { WorkClock.now })
    }

    func testWhereYouLeftOffIsTheNewestMomentWithTheNewestScreenshotOfItsApp() async {
        let page = model(item())
        await page.reload()
        XCTAssertEqual(page.state, .loaded)
        XCTAssertEqual(page.whereYouLeftOff?.id, 9)
        XCTAssertEqual(page.leftOffScreenshot?.id, 7, "the newest screenshot from the same app, not Terminal's")
        XCTAssertEqual(page.hits.map(\.id), [9, 8, 7, 6, 5])
    }

    func testHistoryGoesByDayNewestFirst() async {
        let page = model(item())
        await page.reload()
        XCTAssertEqual(page.days.map(\.label), [WorkCopy.today, "Fri", "Oct 2"])
        XCTAssertEqual(page.shownDay?.label, WorkCopy.today)
        XCTAssertEqual(page.dayHits.map(\.id), [9, 8, 7])
        page.selectedDay = page.days[1].id
        XCTAssertEqual(page.dayHits.map(\.id), [6])
        page.selectedDay = "1999-01-01"
        XCTAssertEqual(page.shownDay?.label, WorkCopy.today, "a day that isn't there shows the newest")
    }

    func testSixFilesThenAndMore() async {
        let page = model(item(files: 8))
        await page.reload()
        XCTAssertEqual(page.shownFiles.count, WorkingOnItemModel.filesShown)
        XCTAssertEqual(page.moreFiles, 2)
        page.showsAllFiles = true
        XCTAssertEqual(page.shownFiles.count, 8)
        XCTAssertEqual(page.moreFiles, 0)
        let few = model(item(files: 3))
        await few.reload()
        XCTAssertEqual(few.moreFiles, 0)
    }

    func testAlongsideAndConversationsSayWhereAndWhenByNameOnly() async {
        let page = model(item())
        await page.reload()
        XCTAssertEqual(page.alongside.map(\.kind), [.page, .search, .aiChat])
        XCTAssertEqual(page.alongside.map(\.title),
                       ["Rounding half to even", "\u{201C}rust round half to even\u{201D}", "Rounding modes for money"])
        XCTAssertEqual(page.alongside.map { spaced($0.detail) }, [
            "devnotes.example \u{00B7} Chrome \u{00B7} Today 2:35 PM",
            "Google \u{00B7} Today 11:18 AM",
            "Claude \u{00B7} Yesterday 9:30 AM",
        ], "a moment's own time, or the read's when the moment is gone")
        XCTAssertEqual(page.conversations.map(\.title), ["#launch"])
        XCTAssertEqual(page.conversations.map { spaced($0.detail) }, ["Slack \u{00B7} Today 2:28 PM"])
        XCTAssertNil(page.nearHits[99])
        XCTAssertEqual(page.nearHits[22]?.windowTitle, "launch (Channel)")
    }

    func testMeetingsComeFromTheCalendarOnlyWhenItIsOn() async throws {
        let sessions = [WorkSession(startUs: WorkClock.us(0, 14), endUs: WorkClock.us(0, 14, 35)),
                        WorkSession(startUs: WorkClock.us(3, 15, 30), endUs: WorkClock.us(3, 16, 6))]
        let events = [
            CalendarEvent(id: "sync", title: "Team sync", start: date(WorkClock.us(0, 14)), end: date(WorkClock.us(0, 14, 15)),
                          calendarName: "Work"),
            CalendarEvent(id: "pairing", title: "Checkout tax pairing", start: date(WorkClock.us(3, 15, 35)),
                          end: date(WorkClock.us(3, 16, 5)), calendarName: "Work"),
            CalendarEvent(id: "lunch", title: "Lunch", start: date(WorkClock.us(0, 12)), end: date(WorkClock.us(0, 13)),
                          calendarName: "Home"),
        ]
        let on = model(item(sessions: sessions), calendar: FixtureCalendar(access: .allowed, events: events))
        await on.reload()
        XCTAssertEqual(on.meetings.map(\.title), ["Team sync", "Checkout tax pairing"], "newest first, only overlaps")
        let off = model(item(sessions: sessions), calendar: FixtureCalendar(access: .notAsked, events: events))
        await off.reload()
        XCTAssertTrue(off.meetings.isEmpty, "never asked: no meetings")
        let none = model(item(sessions: sessions))
        await none.reload()
        XCTAssertTrue(none.meetings.isEmpty)
    }

    func testAnItemThatIsGoneOrCantBeReadSaysSo() async {
        let gone = model(nil)
        await gone.reload()
        XCTAssertEqual(gone.state, .gone)
        XCTAssertNil(gone.item)

        let broken = WorkingOnItemModel(itemId: shop, work: UnavailableWorkReader(), reader: WorkMomentsReader([]),
                                        calendar: WorkClock.calendar, now: { WorkClock.now })
        await broken.reload()
        XCTAssertEqual(broken.state, .failed)
    }

    private func date(_ us: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(us) / 1_000_000)
    }

    /// An item's menus (SPEC 3.2, 3.3): Show All's right-click used to have
    /// no Copy for Your AI.
    func testAnItemsMenusOfferWhatTheSpecSays() {
        XCTAssertEqual(WorkItemMenuItem.items(kind: .code, keptOut: false, in: .showAll),
                       [.hideFromSidebar, .showInHistory, .copyForYourAI])
        XCTAssertEqual(WorkItemMenuItem.items(kind: .document, keptOut: true, in: .showAll),
                       [.showInSidebar, .showInHistory, .copyForYourAI])
        XCTAssertEqual(WorkItemMenuItem.items(kind: .code, keptOut: false, in: .itemPage),
                       [.hideFromSidebar, .showInHistory, .contextForThisFolder, .copyForYourAI])
        XCTAssertEqual(WorkItemMenuItem.items(kind: .design, keptOut: true, in: .itemPage),
                       [.showInSidebar, .showInHistory, .copyForYourAI], "a folder only for a code project")
    }

    // MARK: Every day of an item's History is reachable (the verifier's probe)

    /// The agent's item read as `work --item <id> --before <us>` pages it:
    /// 200 moment ids older than `before`, newest first, with the item's
    /// sessions when it lists them.
    private final class PagingWorkReader: WorkReader, @unchecked Sendable {
        let hits: [Hit]
        let sessions: [WorkSession]
        let id = "w_0f1e2d3c4b5a69788796"
        private(set) var asked: [UInt64?] = []

        init(hits: [Hit], sessions: [WorkSession] = []) {
            self.hits = hits.sorted { $0.tsUs > $1.tsUs }
            self.sessions = sessions
        }

        func work(days: Int) async throws -> WorkSnapshot { WorkSnapshot(items: []) }

        func item(id: String, before: UInt64?) async throws -> WorkItem? {
            asked.append(before)
            let older = hits.filter { hit in before.map { hit.tsUs < $0 } ?? true }
            return WorkItem(id: self.id, kind: .code, name: "harbor-app", apps: ["com.microsoft.VSCode"],
                            lastUs: hits[0].tsUs, moments: Array(older.prefix(200)).map(\.id), sessions: sessions)
        }

        func items(forMoments moments: [UInt64]) async throws -> [UInt64: String] { [:] }
    }

    /// Each planned day's moments, two minutes apart from `hour`, with a
    /// session a day when `sessions`.
    private func harbor(_ plan: [(day: Int, moments: Int)], hour: Int = 9,
                        sessions: Bool = true) -> (PagingWorkReader, WorkingOnItemModel) {
        var hits: [Hit] = []
        var spans: [WorkSession] = []
        for (day, count) in plan {
            for index in 0..<count {
                hits.append(workMoment(UInt64(day * 1_000 + index + 1), WorkClock.us(day, hour, index * 2),
                                       app: "com.microsoft.VSCode", title: "billing.ts \u{2014} harbor-app"))
            }
            spans.append(WorkSession(startUs: WorkClock.us(day, hour), endUs: WorkClock.us(day, hour, (count - 1) * 2)))
        }
        let work = PagingWorkReader(hits: hits, sessions: sessions ? spans.sorted { $0.startUs > $1.startUs } : [])
        let page = WorkingOnItemModel(itemId: work.id, work: work, reader: WorkMomentsReader(hits),
                                      calendar: WorkClock.calendar, now: { WorkClock.now })
        return (work, page)
    }

    /// Ten days of work, 25 moments a day: the first read holds eight days,
    /// and the page used to draw a button for seven of them, so the eighth
    /// day and the two before it couldn't be opened, and Show Earlier added
    /// rows to days that weren't shown.
    func testEveryDayOfAnItemIsReachableAndChoosingOneReadsIt() async {
        let (work, page) = harbor((0..<10).map { ($0, 25) })
        await page.reload()
        XCTAssertEqual(page.state, .loaded)
        XCTAssertEqual(page.hits.count, 200, "the first read: eight days")
        XCTAssertEqual(page.days.count, 10, "its sessions name all ten days")
        XCTAssertEqual(page.dayButtons.count, WorkingOnItemModel.dayButtonsShown - 1)
        XCTAssertEqual(page.dayButtons + page.olderDays, page.days, "the rest are in the Earlier menu, newest first")
        XCTAssertEqual(page.shownDay?.label, WorkCopy.today)
        XCTAssertEqual(page.dayHits.count, 25)
        XCTAssertFalse(page.canLoadEarlier, "today is read through: no Show Earlier that shows nothing")
        for day in page.days {
            await page.show(day: day.id)
            XCTAssertEqual(page.shownDay?.id, day.id)
            XCTAssertEqual(page.dayHits.count, 25, day.label)
            XCTAssertTrue(page.dayHits.allSatisfy { day.contains($0.tsUs) }, day.label)
            XCTAssertFalse(page.canLoadEarlier, day.label)
        }
        XCTAssertEqual(work.asked.count, 2, "each moment is read once: the newest page, then the eighth day's")
        XCTAssertEqual(work.asked.last ?? nil, page.days[7].endUs + 1)
    }

    /// A busy day pages within itself, as History's Show Earlier does, and
    /// Show Earlier goes once the day is read through.
    func testShowEarlierPagesWithinTheDayShownUntilItIsRead() async {
        let (_, page) = harbor([(1, 450), (2, 10)], hour: 0)
        await page.reload()
        XCTAssertEqual(page.shownDay?.label, WorkCopy.yesterday)
        XCTAssertEqual(page.dayHits.count, 200)
        XCTAssertTrue(page.canLoadEarlier)
        let first = page.dayHits.map(\.id)
        await page.loadEarlier()
        XCTAssertEqual(page.dayHits.count, 400, "Show Earlier shows more of the day shown")
        XCTAssertEqual(Array(page.dayHits.prefix(200)).map(\.id), first, "below the rows already shown")
        XCTAssertTrue(page.canLoadEarlier)
        await page.loadEarlier()
        XCTAssertEqual(page.dayHits.count, 450)
        XCTAssertFalse(page.canLoadEarlier, "the day is read through")
        XCTAssertEqual(page.days.count, 2)
    }

    /// Without sessions to name older days (an agent that lists none, or
    /// an item past its last 100), the oldest day known reads on: Show
    /// Earlier there reads the moments before it and shows the newest day
    /// they fall on.
    func testTheOldestDayKnownReadsOnIntoOlderDays() async {
        // A full first page that ends exactly at today's midnight.
        let (_, page) = harbor([(0, 200), (3, 5), (4, 5)], hour: 0, sessions: false)
        await page.reload()
        XCTAssertEqual(page.days.map(\.label), [WorkCopy.today])
        XCTAssertEqual(page.dayHits.count, 200)
        XCTAssertTrue(page.canLoadEarlier, "the first page was full: older moments may remain")
        await page.loadEarlier()
        XCTAssertEqual(page.days.count, 3)
        XCTAssertEqual(page.shownDay?.id, page.days[1].id, "the newest of the older days shows")
        XCTAssertEqual(page.dayHits.count, 5)
        XCTAssertFalse(page.canLoadEarlier, "every moment is read")
    }

    func testTheRefreshKeepsWhatWasReadAndAForgetReadsAgain() async {
        let (_, page) = harbor([(1, 450)], hour: 0)
        await page.reload()
        await page.loadEarlier()
        XCTAssertEqual(page.dayHits.count, 400)
        await page.reload(keepingRead: true)
        XCTAssertEqual(page.dayHits.count, 400, "the two-minute refresh keeps the rows below")
        XCTAssertTrue(page.canLoadEarlier)
        await page.loadEarlier()
        XCTAssertEqual(page.dayHits.count, 450)
        await page.reload()
        XCTAssertEqual(page.dayHits.count, 200, "after a forget, everything is read again")
    }

    // MARK: The header's buttons and the page's column

    /// Resume used a custom 24 pt style beside native bordered buttons (Ask
    /// {Tool}, Open {App}, Show in History, ⋯), so the row mixed heights,
    /// top edges and corners. It is the system's prominent bordered button
    /// now: the same push button as Show in History and Open {App}, at the
    /// same size. (A menu button sizes itself differently offscreen, so Ask
    /// {Tool} and ⋯ are checked in the window's pictures.)
    func testResumeIsTheSamePushButtonAsTheButtonsBesideIt() {
        func size(_ view: some View) -> CGSize {
            NSHostingView(rootView: view.fixedSize()).fittingSize
        }
        let resume = size(Button(WorkCopy.resume) {}.resumeButtonStyle())
        let showInHistory = size(Button(WorkCopy.resume) {}.buttonStyle(.bordered))
        XCTAssertGreaterThan(resume.height, 0)
        XCTAssertEqual(resume.height, showInHistory.height, accuracy: 0.5, "as tall as Show in History and Open {App}")
        XCTAssertEqual(resume.width, showInHistory.width, accuracy: 0.5, "the same bezel and padding for the same words")
    }

    /// AI Tools sat about 70 pt left of About You, Privacy and Working On,
    /// in a left-aligned column of its own, so the page jumped sideways
    /// between them. The pages share one column, centred in the page.
    func testThePagesShareOneCentredColumn() {
        final class Start { var x: CGFloat = -1 }
        func contentStart(inPageWidth width: CGFloat) -> CGFloat {
            let start = Start()
            let content = GeometryReader { proxy -> Color in
                start.x = proxy.frame(in: .global).minX
                return Color.clear
            }
            .frame(height: 20)
            .pageColumn()
            .frame(width: width)
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            hosting.layoutSubtreeIfNeeded()
            return start.x
        }
        XCTAssertEqual(contentStart(inPageWidth: 1_082), (1_082 - 940) / 2 + 32, accuracy: 0.5,
                       "centred, at the width the demo window gives a page")
        XCTAssertEqual(contentStart(inPageWidth: 1_082), PageColumn.contentStart(inPageWidth: 1_082), accuracy: 0.5)
        XCTAssertEqual(contentStart(inPageWidth: 700), 32, accuracy: 0.5, "a narrow window: its margin")
    }
}
