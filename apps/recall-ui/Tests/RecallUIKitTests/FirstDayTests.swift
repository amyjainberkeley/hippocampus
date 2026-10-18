import Foundation
import os
import XCTest
@testable import RecallUIKit

/// Overview on the first day of the person's memory, before its first
/// session: where they land after setup (Oct 18). It welcomes them instead of
/// an empty day, says memory has started only while Hippocampus is
/// remembering, and gives way to the day once the first session is saved.
/// Any other empty day stays as it was.
@MainActor
final class FirstDayTests: XCTestCase {
    /// Whether anything is saved from before a time, as a test scripts it.
    /// Records each time it was asked about.
    private actor EarlierMemory {
        enum Answer: Sendable {
            case nothing
            case something
            case cannotSay
        }

        private var answer: Answer
        private(set) var asked: [Date] = []

        init(_ answer: Answer) {
            self.answer = answer
        }

        func set(_ answer: Answer) {
            self.answer = answer
        }

        func savedBefore(_ date: Date) throws -> Bool {
            asked.append(date)
            switch answer {
            case .nothing: return false
            case .something: return true
            case .cannotSay: throw UnderstandingError.unavailable
            }
        }
    }

    private var startOfToday: Date { SampleDay.calendar.startOfDay(for: SampleDay.now) }

    private func model(
        _ understanding: ScriptedUnderstanding,
        earlier: EarlierMemory,
        receipt: CaptureHealthReceipt? = SampleDay.receipt(),
        deletions: MemoryDeletionSignal = MemoryDeletionSignal()
    ) -> OverviewViewModel {
        OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now, calendar: SampleDay.calendar,
                          healthLoader: { receipt }, now: { SampleDay.now }, deletions: deletions,
                          savedBefore: { try await earlier.savedBefore($0) })
    }

    /// Today with nothing saved, as the agent writes it.
    private func emptyToday(hooked: Bool = false) async throws -> ScriptedUnderstanding {
        let understanding = ScriptedUnderstanding()
        let empty = try UnderstandingFixture.overview().with(blocks: [])
            .with(now: .nothing, aiKnows: AIKnows(recentWork: [], aboutYou: [], hookInstalled: hooked))
            .with(strip: nil)
        await understanding.setOverview(empty)
        return understanding
    }

    // MARK: When it shows

    func testTheFirstDayWelcomesThePersonBeforeTheFirstSession() async throws {
        let earlier = EarlierMemory(.nothing)
        let model = model(try await emptyToday(), earlier: earlier)
        await model.reload()

        XCTAssertTrue(model.isFirstDay)
        XCTAssertTrue(model.showsFirstDay)
        XCTAssertNil(model.rightNow)
        XCTAssertTrue(model.isRemembering)
        XCTAssertTrue(model.offersConnectOnEmptyDay, "no AI tool is connected yet")
        XCTAssertNotNil(model.firstDayStrip)
        let asked = await earlier.asked
        XCTAssertEqual(asked, [startOfToday], "asks about everything before today")
    }

    func testAnEmptyDayAfterTheFirstStaysAsItWas() async throws {
        let model = model(try await emptyToday(), earlier: EarlierMemory(.something))
        await model.reload()
        XCTAssertFalse(model.isFirstDay)
        XCTAssertFalse(model.showsFirstDay)
        XCTAssertTrue(model.offersConnectOnEmptyDay, "the empty day keeps its own Connect")
    }

    /// When the memory cannot say, Overview never claims a first day: the
    /// empty day shows as before.
    func testWhenItCannotSayItNeverClaimsTheFirstDay() async throws {
        let model = model(try await emptyToday(), earlier: EarlierMemory(.cannotSay))
        await model.reload()
        XCTAssertFalse(model.isFirstDay)
        XCTAssertFalse(model.showsFirstDay)
    }

    /// Left out, the question cannot be answered: every Overview built
    /// without it (the previews, other tests) is unchanged.
    func testAnOverviewWithoutTheQuestionNeverShowsTheFirstDay() async throws {
        let model = OverviewViewModel(understanding: try await emptyToday(), selectedDate: SampleDay.now,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { SampleDay.now }, deletions: MemoryDeletionSignal())
        await model.reload()
        XCTAssertFalse(model.showsFirstDay)
    }

    func testTheFirstSessionTakesOver() async throws {
        let understanding = try await emptyToday()
        let model = model(understanding, earlier: EarlierMemory(.nothing))
        await model.reload()
        XCTAssertTrue(model.showsFirstDay)

        await understanding.setOverview(try UnderstandingFixture.overview())
        await model.reload()

        XCTAssertTrue(model.isFirstDay, "still the first day")
        XCTAssertFalse(model.showsFirstDay, "but the day has its first session")
        XCTAssertNotNil(model.rightNow)
        XCTAssertFalse(model.blocks.isEmpty)
    }

    func testAnotherDayIsNeverTheFirstDay() async throws {
        let model = model(try await emptyToday(), earlier: EarlierMemory(.nothing))
        await model.reload()
        XCTAssertTrue(model.showsFirstDay)

        model.moveDay(-1)
        await model.reload()

        XCTAssertFalse(model.isFirstDay)
        XCTAssertFalse(model.showsFirstDay)
    }

    // MARK: Asking

    /// Something saved before today stays so on every later day, so the
    /// answer is kept; a delete can change it, so a delete asks again; while
    /// nothing is found, each read asks again.
    func testSomethingEarlierIsKeptUntilADelete() async throws {
        let deletions = MemoryDeletionSignal()
        let earlier = EarlierMemory(.something)
        let model = model(try await emptyToday(), earlier: earlier, deletions: deletions)
        await model.reload()
        await model.reload()
        let kept = await earlier.asked.count
        XCTAssertEqual(kept, 1, "a found moment is kept")

        deletions.post()
        await earlier.set(.nothing)
        await model.reload()
        let afterDelete = await earlier.asked.count
        XCTAssertEqual(afterDelete, 2, "a delete asks again")
        XCTAssertTrue(model.showsFirstDay, "everything deleted: memory starts again now")

        await model.reload()
        let whileNothing = await earlier.asked.count
        XCTAssertEqual(whileNothing, 3, "while nothing is found, each read asks again")
    }

    func testAnotherDayDoesNotAsk() async throws {
        let earlier = EarlierMemory(.nothing)
        let model = model(try await emptyToday(), earlier: earlier)
        model.moveDay(-1)
        await model.reload()
        let asked = await earlier.asked
        XCTAssertEqual(asked, [])
    }

    /// The question reads one moment at most, newest first, through the
    /// time index: a browse that ends just before the day starts.
    func testTheQuestionIsOneBrowsedMomentBeforeTheDay() async throws {
        let reader = SearchRecordingReader()
        reader.hits = []
        let empty = try await reader.isAnythingSaved(before: startOfToday)
        XCTAssertFalse(empty)
        reader.hits = [Hit(eventId: 7, tsUs: 1, appBundleId: nil, windowTitle: nil, url: nil,
                           ocrTextSnippet: "", source: "recent", score: nil)]
        let found = try await reader.isAnythingSaved(before: startOfToday)
        XCTAssertTrue(found)

        let options = try XCTUnwrap(reader.searches.last)
        XCTAssertTrue(options.browse)
        XCTAssertEqual(options.text, "")
        XCTAssertEqual(options.limit, 1)
        XCTAssertNil(options.timeFromUs)
        XCTAssertEqual(options.timeToUs, UInt64(startOfToday.timeIntervalSince1970 * 1_000_000) - 1)
        XCTAssertNil(options.appFilter)
        XCTAssertTrue(options.appFilters.isEmpty)
        XCTAssertFalse(options.hasUrl)
    }

    // MARK: What it says about remembering

    /// The welcome follows the sidebar footer's rule, so the two never
    /// disagree: "Your memory starts now." only while it is remembering.
    func testTheWelcomeSaysRememberingOnlyWhenTheFooterDoes() async throws {
        let cases: [(String, CaptureHealthReceipt?, Bool)] = [
            ("fresh", SampleDay.receipt(), true),
            ("no status yet", nil, false),
            ("old status", SampleDay.receipt(age: 200), false),
            ("turned off", SampleDay.receipt(blocked: "capture_disabled"), false),
            ("skipping one window", SampleDay.receipt(suppressed: "private_browsing"), true),
        ]
        for (name, receipt, remembering) in cases {
            let model = model(try await emptyToday(), earlier: EarlierMemory(.nothing), receipt: receipt)
            await model.reload()
            XCTAssertTrue(model.showsFirstDay, name)
            XCTAssertEqual(model.isRemembering, remembering, name)
            XCTAssertEqual(model.isRemembering, SidebarStatus(receipt: receipt, now: SampleDay.now).remembering, name)
        }
    }

    // MARK: The strip

    private func hour(_ us: Int64) -> Int {
        SampleDay.calendar.component(.hour, from: Date(timeIntervalSince1970: Double(us) / 1_000_000))
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        startOfToday.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    /// The agent's strip for a day whose first session starts now: the hour
    /// of now to the hour after it, four hours at least. At 2:37:05 PM that
    /// is 11 AM to 3 PM, with now nine tenths of the way along.
    func testTheStripSpansTheHoursTheFirstSessionWillHave() throws {
        let layout = try XCTUnwrap(FirstDayStripLayout(now: SampleDay.now, calendar: SampleDay.calendar))
        XCTAssertEqual(hour(layout.startUs), 11)
        XCTAssertEqual(hour(layout.endUs), 15)
        XCTAssertEqual(layout.endUs - layout.startUs, 4 * 3_600_000_000)
        XCTAssertEqual(layout.nowX, Double(3 * 3_600 + 37 * 60 + 5) / Double(4 * 3_600), accuracy: 1e-9)
        XCTAssertEqual(layout.ticks.map(\.x), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(layout.ticks.map { hour($0.atUs) }, [11, 12, 13, 14, 15])
    }

    func testOnTheHourNowIsTheStripsEnd() throws {
        let layout = try XCTUnwrap(FirstDayStripLayout(now: at(15, 0), calendar: SampleDay.calendar))
        XCTAssertEqual(hour(layout.startUs), 11)
        XCTAssertEqual(hour(layout.endUs), 15)
        XCTAssertEqual(layout.nowX, 1)
    }

    func testJustAfterMidnightTheStripStartsAtMidnight() throws {
        let layout = try XCTUnwrap(FirstDayStripLayout(now: at(0, 20), calendar: SampleDay.calendar))
        XCTAssertEqual(layout.startUs, Int64(startOfToday.timeIntervalSince1970 * 1_000_000))
        XCTAssertEqual(hour(layout.endUs), 4)
        XCTAssertEqual(layout.nowX, 20.0 / 240.0, accuracy: 1e-9)
    }

    func testLateInTheEveningTheStripStopsAtMidnight() throws {
        let layout = try XCTUnwrap(FirstDayStripLayout(now: at(23, 40), calendar: SampleDay.calendar))
        XCTAssertEqual(hour(layout.startUs), 20)
        XCTAssertEqual(layout.endUs, Int64(startOfToday.addingTimeInterval(86_400).timeIntervalSince1970 * 1_000_000))
        XCTAssertEqual(layout.nowX, 220.0 / 240.0, accuracy: 1e-9)
    }
}

/// A reader that answers searches with the hits a test sets, and records
/// what it was asked. Nothing else is read.
private final class SearchRecordingReader: BrainReader, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (hits: [Hit](), searches: [SearchOptions]()))

    var hits: [Hit] {
        get { state.withLock { $0.hits } }
        set { state.withLock { $0.hits = newValue } }
    }

    var searches: [SearchOptions] { state.withLock { $0.searches } }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        state.withLock { state in
            state.searches.append(opts)
            return state.hits
        }
    }

    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}
