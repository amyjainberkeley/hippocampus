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
}
