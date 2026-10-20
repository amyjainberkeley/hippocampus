import Foundation
import XCTest
@testable import RecallUIKit

/// History's rows, one or several at a time (SPEC 3.4): ⌘-click and
/// ⇧-click pick several, the detail counts them in saved moments, the menu
/// and ⌘⌫ forget whole runs, an hour heading forgets its hour, and the list
/// ends at the oldest day kept with how long moments are kept.
@MainActor
final class HistoryMultiSelectTests: XCTestCase {
    private let minute: UInt64 = 60_000_000
    private var nowUs: UInt64 { UInt64(SampleDay.now.timeIntervalSince1970 * 1_000_000) }

    /// Sam's afternoon: an article read twice (one row of two moments), a
    /// chat and a message.
    private func afternoon() -> [Hit] {
        let article = "Reading \u{201C}Rounding half to even\u{201D}"
        return [
            MomentFactory.hit(5, "com.google.Chrome", title: "Rounding half to even \u{00B7} Dev Notes",
                              url: "https://devnotes.example/rounding", at: nowUs - 2 * minute, caption: article),
            MomentFactory.hit(4, "com.google.Chrome", title: "Rounding half to even \u{00B7} Dev Notes",
                              url: "https://devnotes.example/rounding", at: nowUs - 4 * minute, caption: article),
            MomentFactory.hit(3, "com.tinyspeck.slackmacgap", title: "launch (Channel) - Northwind Studio - Slack",
                              at: nowUs - 9 * minute, caption: "Chatting in #launch"),
            MomentFactory.hit(2, "com.apple.MobileSMS", title: "Sam Lee", at: nowUs - 13 * minute,
                              caption: "Messaging Sam Lee"),
        ]
    }

    private func rows(_ hits: [Hit]) -> [HistoryRow] {
        HistorySections.group(hits: hits, sessions: [], calendar: SampleDay.calendar).flatMap(\.rows)
    }

    private func history(_ moments: [Hit]) -> TimelineViewModel {
        TimelineViewModel(reader: MomentsReader(moments), pageSize: 200,
                          day: MemoryDay(date: SampleDay.now, calendar: SampleDay.calendar),
                          now: { SampleDay.now }, deletions: MemoryDeletionSignal(center: NotificationCenter()))
    }

    func testSeveralRowsAreCountedInSavedMomentsAndForgetTheirWholeRuns() {
        let rows = rows(afternoon())
        XCTAssertEqual(rows.map(\.count), [2, 1, 1], "the article read twice is one row")
        let picked = MomentSelection(picked: [5, 3, 2], in: rows)
        XCTAssertEqual(picked.momentCount, 4, "three rows hold four moments")
        XCTAssertEqual(picked.momentIds, [5, 4, 3, 2], "a row's whole run, newest first")
        XCTAssertEqual(picked.captions, ["Reading \u{201C}Rounding half to even\u{201D}", "Chatting in #launch",
                                         "Messaging Sam Lee"])
        XCTAssertEqual(LibraryCopy.History.selected(picked.momentCount), "4 moments selected")
        XCTAssertEqual(LibraryCopy.History.forgetMomentsMenu(picked.momentCount), "Forget 4 Moments\u{2026}")
        XCTAssertEqual(LibraryCopy.History.forgetHelp(picked.momentCount), "Forget 4 Moments (\u{2318}\u{232B})")
        XCTAssertEqual(ForgetRequest.moments(picked.momentIds).momentCount, 4)
    }

    func testARowsMenuSaysHowManyMomentsItForgets() {
        let rows = rows(afternoon())
        XCTAssertEqual(LibraryCopy.History.forgetMomentsMenu(MomentSelection(picked: [5], in: rows).momentCount),
                       "Forget 2 Moments\u{2026}")
        XCTAssertEqual(LibraryCopy.History.forgetMomentsMenu(MomentSelection(picked: [3], in: rows).momentCount),
                       "Forget This Moment\u{2026}")
        XCTAssertTrue(MomentSelection(picked: [99], in: rows).isEmpty, "a row no longer shown is not picked")
    }

    func testAtMostSixPicturesAndEachCaptionOnce() {
        let moments = (0..<9).map { index in
            MomentFactory.hit(UInt64(100 + index), index.isMultiple(of: 2) ? "com.apple.Notes" : "com.apple.TextEdit",
                              title: "Draft \(index)", at: nowUs - UInt64(index) * minute, caption: "Writing a draft")
        }
        let rows = rows(moments)
        let picked = MomentSelection(picked: Set(rows.map(\.id)), in: rows)
        XCTAssertEqual(picked.pictures.count, MomentSelection.maxPictures)
        XCTAssertEqual(picked.captions, ["Writing a draft"])
    }

    func testOnePickedRowOpensItsDetailAndSeveralOpenTheSummary() async {
        let history = history(afternoon())
        await history.reload()
        history.selectedHitId = 5
        XCTAssertEqual(history.selectedHit?.id, 5)
        XCTAssertEqual(history.selection, [5])
        history.selection = [5, 3]
        XCTAssertNil(history.selectedHitId, "several rows show their summary, not one moment")
        history.focusDetail()
        XCTAssertTrue(history.isDetailFocused, "the summary opens like a detail")
        history.selection = []
        history.focusDetail()
        history.dismissDetail()
        XCTAssertFalse(history.isDetailFocused)
    }

    func testAReadKeepsOnlyThePickedRowsStillThere() async {
        let moments = afternoon()
        let deletions = MemoryDeletionSignal(center: NotificationCenter())
        let reader = MomentsReader(moments)
        let history = TimelineViewModel(reader: reader, pageSize: 200,
                                        day: MemoryDay(date: SampleDay.now, calendar: SampleDay.calendar),
                                        now: { SampleDay.now }, deletions: deletions)
        await history.reload()
        history.selection = [5, 3, 77]
        await history.reload()
        XCTAssertEqual(history.selection, [5, 3], "a row that is gone is no longer picked")
    }

    func testAnHourHeadingForgetsItsWholeHour() {
        let calendar = SampleDay.calendar
        let twoPM = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: SampleDay.now)!
        let startUs = Int64(twoPM.timeIntervalSince1970 * 1_000_000)
        let hour = HistorySections.hour(startingAt: startUs, calendar: calendar)
        XCTAssertEqual(hour.lowerBound, startUs)
        XCTAssertEqual(hour.upperBound, startUs + 3_600_000_000 - 1, "up to the last microsecond before 3 PM")
        XCTAssertEqual(LibraryCopy.History.forgetHour(LibraryCopy.History.hourRange("2 PM", "3 PM")),
                       "Forget 2 PM to 3 PM\u{2026}")
    }

    func testTheOldestDayKeptEndsWithHowLongMomentsAreKept() async {
        let today = afternoon()
        let history = history(today)
        await history.reload()
        XCTAssertTrue(history.isOldestDay, "nothing is saved before today")

        let yesterday = MomentFactory.hit(1, "com.apple.Notes", at: nowUs - 30 * 60 * minute)
        let older = self.history(today + [yesterday])
        await older.reload()
        XCTAssertFalse(older.isOldestDay, "yesterday still holds a moment")
        XCTAssertEqual(LibraryCopy.olderDeleted(days: 90), "Older moments are deleted after 90 days.")
    }

    func testAPageWithMoreBelowIsNeverTheOldestDay() async {
        let moments = (0..<5).map { MomentFactory.hit(UInt64(10 + $0), "com.apple.Notes", title: "Note \($0)",
                                                      at: nowUs - UInt64($0) * minute) }
        let history = TimelineViewModel(reader: MomentsReader(moments), pageSize: 2,
                                        day: MemoryDay(date: SampleDay.now, calendar: SampleDay.calendar),
                                        now: { SampleDay.now }, deletions: MemoryDeletionSignal(center: NotificationCenter()))
        await history.reload()
        XCTAssertTrue(history.canLoadEarlier)
        XCTAssertFalse(history.isOldestDay, "Show Earlier comes first")
    }

    // MARK: Retention, read as the agent's worker reads it

    func testRetentionIsReadAsTheWorkerReadsIt() throws {
        func decode(_ json: String) -> RetentionSetting? { RetentionSetting.decode(Data(json.utf8)) }
        XCTAssertEqual(decode(#"{"schema_version": 2, "mode": "ninetyDays"}"#), .days(90))
        XCTAssertEqual(decode(#"{"schema_version": 2, "mode": "sevenDays"}"#), .days(7))
        XCTAssertEqual(decode(#"{"schema_version": 2, "mode": "custom", "days": 45}"#), .days(45))
        XCTAssertEqual(decode(#"{"schema_version": 1, "mode": "forever"}"#), .forever)
        XCTAssertNil(decode(#"{"schema_version": 1, "mode": "thirtyDays"}"#), "a limit not yet reviewed deletes nothing")
        XCTAssertNil(decode(#"{"schema_version": 2, "mode": "custom", "days": 0}"#))
        XCTAssertNil(decode(#"{"schema_version": 2, "mode": "custom", "days": 366}"#))
        XCTAssertNil(decode(#"{"schema_version": 3, "mode": "forever"}"#))
        XCTAssertNil(decode(#"{"mode": "sometimes"}"#))
        XCTAssertNil(decode("not json"))

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("retention.json")
        XCTAssertEqual(RetentionSetting.read(from: file), .days(90), "nothing saved is the 90-day default")
        try Data(#"{"schema_version": 2, "mode": "thirtyDays"}"#.utf8).write(to: file)
        XCTAssertEqual(RetentionSetting.read(from: file)?.days, 30)
        XCTAssertNil(RetentionSetting.forever.days)
    }

    // MARK: A moment's actions

    func testOpenLinkOpensOnlyWebPagesAndTheDetailShowsTheAddressPlainly() {
        XCTAssertEqual(MomentActions.link(of: MomentFactory.hit(1, "com.google.Chrome",
                                                                url: "https://devnotes.example/rounding"))?.host,
                       "devnotes.example")
        XCTAssertNil(MomentActions.link(of: MomentFactory.hit(2, "com.apple.finder", url: "file:///etc/hosts")))
        XCTAssertNil(MomentActions.link(of: MomentFactory.hit(3, "com.apple.Notes", url: "notes://x")))
        XCTAssertNil(MomentActions.link(of: MomentFactory.hit(4, "com.apple.Notes")))
        XCTAssertEqual(MomentActions.shownLink("https://devnotes.example/rounding?ref=feed#top"),
                       "devnotes.example/rounding")
        XCTAssertEqual(MomentActions.shownLink("https://www.example.com/"), "www.example.com")
    }

    func testCopyTextCopiesTheReadingAndFallsBackToTheRowsExcerpt() async {
        let hit = MomentFactory.hit(1, "com.apple.Notes", title: "Launch checklist")
        let text = await MomentActions.text(of: hit, reader: nil)
        XCTAssertEqual(text, "Text of Launch checklist")
    }

    // MARK: Part of

    func testPartOfNamesTheItemOnlyWhenTheCaptionDoesntAlready() async {
        let shop = WorkItem(id: "w_shop", kind: .code, name: "trailhead-shop", apps: ["com.microsoft.VSCode"],
                            lastUs: nowUs, weekMinutes: 90, daysThisWeek: 2, moments: [5, 6])
        let work = PreviewWorkReader(snapshot: WorkSnapshot(items: [shop], momentItems: [5: "w_shop", 6: "w_shop"]))
        let items = MomentItems(reader: work)
        await items.load([5, 6, 7])
        let reading = MomentFactory.hit(5, "com.google.Chrome", caption: "Reading \u{201C}Rounding half to even\u{201D}")
        let editing = MomentFactory.hit(6, "com.microsoft.VSCode", caption: "Working on tax.rs in trailhead-shop")
        let other = MomentFactory.hit(7, "com.apple.Notes", caption: "Writing a note")
        XCTAssertEqual(items.partOf(reading)?.name, "trailhead-shop")
        XCTAssertNil(items.partOf(editing), "the caption already says it")
        XCTAssertNil(items.partOf(other), "not part of anything")
        XCTAssertEqual(LibraryCopy.History.partOf("trailhead-shop"), "Part of trailhead-shop")
    }

    func testMomentsAreAskedAboutOncePerPage() async {
        let counter = CountingWorkReader()
        let items = MomentItems(reader: counter)
        await items.load([1, 2, 3])
        await items.load([1, 2, 3])
        await items.load([2, 3, 4])
        let asked = await counter.asked
        XCTAssertEqual(asked, [[1, 2, 3], [4]])
    }
}

/// A work read that counts which moments it was asked about.
private actor CountingWorkReader: WorkReader {
    private(set) var asked: [[UInt64]] = []

    func work(days: Int) async throws -> WorkSnapshot { .empty }
    func item(id: String, before: UInt64?) async throws -> WorkItem? { nil }
    func items(forMoments moments: [UInt64]) async throws -> [UInt64: String] {
        asked.append(moments)
        return [:]
    }
}
