import Foundation
import XCTest
@testable import RecallUIKit

/// Documents, Code and Conversations are History filtered by kind
/// (SPEC-DELTA 1): History's own moments, newest first across days, a page
/// at a time, none skipped or shown twice between pages, nothing History
/// doesn't have.
@MainActor
final class LibraryLensModelTests: XCTestCase {
    private let minute: UInt64 = 60_000_000

    /// Notes and Chrome take turns; half of Chrome's pages are Google Docs.
    private func afternoon(count: Int) -> [Hit] {
        let start = UInt64(SampleDay.now.timeIntervalSince1970 * 1_000_000) - UInt64(count) * minute
        return (0..<count).map { index -> Hit in
            let ts = start + UInt64(index) * minute
            switch index % 4 {
            case 0: return MomentFactory.hit(UInt64(1_000 + index), "com.apple.Notes", title: "Note \(index)", at: ts)
            case 1: return MomentFactory.hit(UInt64(1_000 + index), "com.google.Chrome", title: "Doc \(index)",
                                             url: "https://docs.google.com/document/d/\(index)", at: ts)
            case 2: return MomentFactory.hit(UInt64(1_000 + index), "com.google.Chrome", title: "Page \(index)",
                                             url: "https://devnotes.example/\(index)", at: ts)
            default: return MomentFactory.hit(UInt64(1_000 + index), "com.tinyspeck.slackmacgap",
                                              title: "Chat \(index)", at: ts)
            }
        }
    }

    func testALensShowsOnlyItsKindNewestFirstAndPagesWithoutGapsOrRepeats() async {
        let moments = afternoon(count: 103)
        let reader = MomentsReader(moments)
        let model = LibraryLensModel(lens: .documents, reader: reader, pageSize: 10,
                                     deletions: MemoryDeletionSignal())
        await model.reload()
        XCTAssertFalse(model.hits.isEmpty)
        XCTAssertTrue(model.hits.allSatisfy { LibraryLens.documents.includes($0) })
        XCTAssertEqual(model.hits.map(\.tsUs), model.hits.map(\.tsUs).sorted(by: >))
        var pages = 1
        while model.canLoadEarlier, pages < 50 {
            await model.loadEarlier()
            pages += 1
        }
        let expected = moments.filter { LibraryLens.documents.includes($0) }.map(\.id).sorted()
        XCTAssertEqual(model.hits.map(\.id).sorted(), expected, "every document moment, once")
        XCTAssertEqual(Set(model.hits.map(\.id)).count, model.hits.count)
        XCTAssertFalse(model.canLoadEarlier)
        let asked = reader.searches
        XCTAssertTrue(asked.allSatisfy(\.browse))
        XCTAssertTrue(asked.contains { $0.appFilters == LibraryLens.documents.apps },
                      "the lens's own apps are filtered by the memory itself")
        XCTAssertTrue(asked.contains { $0.appFilters == MomentKinds.browsers }, "browsers are read apart")
    }

    func testMomentsSharingATimeAreNeitherLostNorRepeatedAcrossPages() async {
        let ts = UInt64(SampleDay.now.timeIntervalSince1970 * 1_000_000)
        let moments = (0..<25).map { MomentFactory.hit(UInt64(500 + $0), "com.microsoft.VSCode", at: ts) }
            + (0..<5).map { MomentFactory.hit(UInt64(600 + $0), "com.apple.Terminal", at: ts - minute) }
        let model = LibraryLensModel(lens: .code, reader: MomentsReader(moments), pageSize: 8,
                                     deletions: MemoryDeletionSignal())
        await model.reload()
        while model.canLoadEarlier { await model.loadEarlier() }
        XCTAssertEqual(model.hits.map(\.id).sorted(), moments.map(\.id).sorted())
    }

    func testABrowserFullOfOtherPagesIsReadOnUntilTheLensHasRows() async {
        let start = UInt64(SampleDay.now.timeIntervalSince1970 * 1_000_000) - 400 * minute
        var moments = (0..<300).map { index in
            MomentFactory.hit(UInt64(2_000 + index), "com.google.Chrome", title: "Page \(index)",
                              url: "https://devnotes.example/\(index)", at: start + 100 * minute + UInt64(index) * 1_000)
        }
        moments.append(MomentFactory.hit(9, "com.google.Chrome", title: "Inbox - Gmail",
                                         url: "https://mail.google.com/mail/u/0", at: start))
        let model = LibraryLensModel(lens: .conversations, reader: MomentsReader(moments), pageSize: 40,
                                     deletions: MemoryDeletionSignal())
        await model.reload()
        while model.hits.isEmpty, model.canLoadEarlier { await model.loadEarlier() }
        XCTAssertEqual(model.hits.map(\.id), [9])
    }

    func testConversationsChipsFilterWhatShows() async {
        let moments = [
            MomentFactory.hit(1, "com.tinyspeck.slackmacgap", minutesAgo: 1),
            MomentFactory.hit(2, "com.apple.mail", minutesAgo: 2),
            MomentFactory.hit(3, "com.openai.chat", minutesAgo: 3),
        ]
        let model = LibraryLensModel(lens: .conversations, reader: MomentsReader(moments),
                                     deletions: MemoryDeletionSignal())
        await model.reload()
        XCTAssertEqual(model.shownHits.map(\.id), [1, 2, 3])
        model.selection = [2]
        model.filter = .chat
        XCTAssertEqual(model.shownHits.map(\.id), [1])
        XCTAssertTrue(model.selection.isEmpty, "a picked row the chip hides is no longer picked")
        model.filter = .email
        XCTAssertEqual(model.shownHits.map(\.id), [2])
        model.filter = .ai
        XCTAssertEqual(model.shownHits.map(\.id), [3])
    }

    // MARK: "No email yet." only when there is none (the verifier's probe)

    /// 30 Slack moments, then one email an hour and a half before them. The
    /// lens's first page holds only Slack: the Email chip used to say "No
    /// email yet." with no Show Earlier (the button lives in the list, which
    /// isn't drawn), while an email was saved.
    func testTheEmailChipSaysNoEmailOnlyWhenThereIsNone() async {
        var moments: [Hit] = (0..<30).map { index in
            MomentFactory.hit(UInt64(100 + index), "com.tinyspeck.slackmacgap", minutesAgo: Double(index + 1))
        }
        moments.append(MomentFactory.hit(7, "com.apple.mail", minutesAgo: 120))
        let model = LibraryLensModel(lens: .conversations, reader: MomentsReader(moments), pageSize: 10,
                                     deletions: MemoryDeletionSignal())
        await model.reload()
        XCTAssertTrue(model.hits.allSatisfy { $0.appBundleId == "com.tinyspeck.slackmacgap" }, "the first page: Slack")
        await model.choose(.email)
        XCTAssertFalse(model.shownHits.isEmpty && model.canLoadEarlier,
                       "Email shows \"\(LibraryCopy.emptyConversations(.email))\" with no Show Earlier, while an email is saved")
        XCTAssertEqual(model.shownHits.map(\.id), [7], "the chip reads on to the email")
    }

    /// Past the pages a chip reads on by itself, it says since when there
    /// is none, never "No email yet.", and Show Earlier reads on.
    func testAChipWithNoneReadYetSaysSinceWhenAndShowEarlierReadsOn() async throws {
        var moments: [Hit] = (0..<200).map { index in
            MomentFactory.hit(UInt64(1_000 + index), "com.tinyspeck.slackmacgap", minutesAgo: Double(index + 1))
        }
        moments.append(MomentFactory.hit(7, "com.apple.mail", minutesAgo: 400))
        let model = LibraryLensModel(lens: .conversations, reader: MomentsReader(moments), pageSize: 10,
                                     deletions: MemoryDeletionSignal())
        await model.reload()
        await model.choose(.email)
        XCTAssertTrue(model.shownHits.isEmpty)
        XCTAssertTrue(model.canLoadEarlier)
        let since = try XCTUnwrap(model.readBackTo, "how far back it read")
        let words = LibraryCopy.noneSince(.conversations, .email,
                                          day: LibraryCopy.sinceDay(since, now: SampleDay.now, calendar: SampleDay.calendar,
                                                                    locale: SampleDay.locale))
        XCTAssertTrue(words.hasPrefix("No email since "), words)
        XCTAssertNotEqual(words, LibraryCopy.emptyConversations(.email))
        var clicks = 0
        while model.shownHits.isEmpty, model.canLoadEarlier, clicks < 40 {
            await model.loadEarlier()
            clicks += 1
        }
        XCTAssertEqual(model.shownHits.map(\.id), [7], "Show Earlier reads on to it")
        XCTAssertNil(model.readBackTo, "a chip with rows says nothing of the kind")
    }

    func testSinceSaysTheDayAsAPersonWould() throws {
        let calendar = SampleDay.calendar
        let now = SampleDay.now
        func us(_ days: Int, _ hour: Int, _ minute: Int = 0) throws -> UInt64 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)))
            return UInt64((day.timeIntervalSince1970 + Double(hour * 3_600 + minute * 60)) * 1_000_000)
        }
        func since(_ us: UInt64) -> String { LibraryCopy.sinceDay(us, now: now, calendar: calendar, locale: SampleDay.locale) }
        let morning = since(try us(0, 9, 5))
        XCTAssertTrue(morning.hasPrefix("9:05") && morning.hasSuffix("AM"), morning)
        XCTAssertEqual(since(try us(1, 16)), "yesterday")
        let weekday = since(try us(3, 10))
        var english = Calendar(identifier: .gregorian)
        english.locale = SampleDay.locale
        XCTAssertTrue(english.weekdaySymbols.contains(weekday), weekday)
        XCTAssertFalse(since(try us(20, 10)).contains(","), "the same year: no year")
        XCTAssertTrue(since(try us(400, 10)).contains(","), "another year says it")
        for lens in LibraryLens.allCases {
            for chip in ConversationFilter.allCases {
                let text = LibraryCopy.noneSince(lens, chip, day: "Tuesday")
                XCTAssertTrue(text.hasSuffix(" since Tuesday."), text)
                XCTAssertNil(CopyStyleValidator.containsJargon(text), text)
                XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(text), text)
                XCTAssertFalse(CopyStyleValidator.containsExclamation(text), text)
            }
        }
        XCTAssertEqual(LibraryCopy.noneSince(.conversations, .email, day: "Tuesday"), "No email since Tuesday.")
    }

    func testRowsSitUnderAppleNotesDayHeadingsAndRunsOfOneWindowAreOneRow() {
        let now = SampleDay.now
        let day: UInt64 = 86_400_000_000
        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
        let hits = [
            MomentFactory.hit(1, "com.apple.Notes", title: "Launch checklist", at: nowUs - minute),
            MomentFactory.hit(2, "com.apple.Notes", title: "Launch checklist", at: nowUs - 2 * minute),
            MomentFactory.hit(3, "com.apple.Notes", title: "Draft", at: nowUs - day),
            MomentFactory.hit(4, "com.apple.Notes", title: "Draft", at: nowUs - 3 * day),
            MomentFactory.hit(5, "com.apple.Notes", title: "Draft", at: nowUs - 20 * day),
            MomentFactory.hit(6, "com.apple.Notes", title: "Draft", at: nowUs - 45 * day),
            MomentFactory.hit(7, "com.apple.Notes", title: "Draft", at: nowUs - 400 * day),
        ]
        let sections = LibrarySections.group(hits, now: now, calendar: SampleDay.calendar)
        let titles = sections.map { $0.title(now: now, calendar: SampleDay.calendar, locale: SampleDay.locale) }
        XCTAssertEqual(titles, ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August",
                                "September 2025"])
        XCTAssertEqual(sections[0].rows.count, 1, "two moments of one window are one row")
        XCTAssertEqual(sections[0].rows[0].count, 2)
    }

    func testARowSaysItsTimeAsItsDayHeadingLeavesIt() {
        let now = SampleDay.now
        let day: UInt64 = 86_400_000_000
        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
        let hits = [
            MomentFactory.hit(1, "com.apple.Notes", title: "A", at: nowUs - minute),
            MomentFactory.hit(2, "com.apple.Notes", title: "B", at: nowUs - day),
            MomentFactory.hit(3, "com.apple.Notes", title: "C", at: nowUs - 3 * day),
            MomentFactory.hit(4, "com.apple.Notes", title: "D", at: nowUs - 20 * day),
        ]
        let sections = LibrarySections.group(hits, now: now, calendar: SampleDay.calendar)
        let times = sections.map { section in
            section.time(of: section.rows[0].hit, calendar: SampleDay.calendar, locale: SampleDay.locale)
        }
        XCTAssertEqual(times.count, 4)
        XCTAssertFalse(times[0].contains(","), "today shows the clock: \(times[0])")
        XCTAssertTrue(times[0].hasSuffix("PM") || times[0].hasSuffix("AM"), times[0])
        XCTAssertFalse(times[1].contains(","), "yesterday shows the clock: \(times[1])")
        XCTAssertTrue(times[2].hasPrefix("Fri "), "the last week shows its weekday: \(times[2])")
        XCTAssertTrue(times[3].hasPrefix("Sep 22, "), "older shows its date: \(times[3])")
    }

    func testADeleteClearsTheRowsAtOnceAndReadsAgain() async {
        let deletions = MemoryDeletionSignal()
        let model = LibraryLensModel(lens: .code, reader: MomentsReader([MomentFactory.hit(1, "com.apple.Terminal")]),
                                     deletions: deletions)
        await model.reload()
        XCTAssertEqual(model.hits.count, 1)
        deletions.post()
        XCTAssertTrue(model.hits.isEmpty)
        for _ in 0..<20 where model.hits.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.hits.count, 1)
    }

    func testALensHoldsMomentsOnlyOnceItHasOne() async {
        let reader = MomentsReader([MomentFactory.hit(1, "com.google.Chrome", url: "https://docs.google.com/d/1")])
        let documents = await LibraryLensModel.holdsMoments(.documents, reader: reader)
        let code = await LibraryLensModel.holdsMoments(.code, reader: reader)
        let conversations = await LibraryLensModel.holdsMoments(.conversations, reader: MomentsReader([]))
        XCTAssertTrue(documents)
        XCTAssertFalse(code)
        XCTAssertFalse(conversations)
    }

    func testOneSelectionOpensTheDetailAndSeveralDont() async {
        let model = LibraryLensModel(lens: .code, reader: MomentsReader([
            MomentFactory.hit(1, "com.apple.Terminal", minutesAgo: 1),
            MomentFactory.hit(2, "com.microsoft.VSCode", minutesAgo: 2),
        ]), deletions: MemoryDeletionSignal())
        await model.reload()
        model.selectedHitId = 2
        XCTAssertEqual(model.selectedHit?.id, 2)
        model.selection = [1, 2]
        XCTAssertNil(model.selectedHit)
        XCTAssertNil(model.selectedHitId)
    }
}
