import Foundation
import XCTest
@testable import RecallUIKit

/// History pages through a day, opens on a session's own time, and reads
/// again on the tick only when it must (RULINGS W8, critique-recall-engineering
/// finding 7).
@MainActor
final class TimelinePagingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Monday 2026-10-12, UTC.
    private var day: MemoryDay {
        MemoryDay(date: Date(timeIntervalSince1970: 1_791_806_400), calendar: calendar)
    }

    private func at(_ seconds: UInt64, id: UInt64, app: String = "com.apple.Notes", title: String = "Notes") -> Hit {
        Hit(eventId: id, tsUs: day.startUs + seconds * 1_000_000, appBundleId: app, windowTitle: title,
            url: nil, ocrTextSnippet: "moment \(id)", source: "recent", score: nil, sourceKind: "screen_ocr")
    }

    private func model(_ reader: PagingReader, pageSize: Int = 3, day: MemoryDay? = nil,
                       now: Date? = nil, deletions: MemoryDeletionSignal = MemoryDeletionSignal()) -> TimelineViewModel {
        let clock = now ?? Date(timeIntervalSince1970: Double(self.day.startUs) / 1_000_000 + 20 * 3600)
        return TimelineViewModel(reader: reader, pageSize: pageSize, day: day, now: { clock }, deletions: deletions)
    }

    func testADayShowsItsNewestPageAndSaysWhenMoreLieBelow() async {
        let reader = PagingReader((1...7).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, day: day)
        await history.reload()
        XCTAssertEqual(history.hits.map(\.id), [7, 6, 5])
        XCTAssertTrue(history.canLoadEarlier)
        let read = await reader.searches.first
        XCTAssertEqual(read?.browse, true)
        XCTAssertEqual(read?.text, "")
        XCTAssertEqual(read?.timeFromUs, day.startUs)
        XCTAssertEqual(read?.timeToUs, day.endUs)
        XCTAssertEqual(read?.limit, 4, "one more than a page says whether more lie below")
    }

    func testShowEarlierPagesThroughTheWholeDayWithoutSkippingOrRepeatingAMoment() async {
        // Moments 3, 4 and 5 share one time, across a page's edge.
        var moments = (1...9).map { at(UInt64($0) * 60, id: UInt64($0)) }
        moments[3] = at(3 * 60, id: 4)
        moments[4] = at(3 * 60, id: 5)
        let reader = PagingReader(moments)
        let history = model(reader, day: day)
        await history.reload()
        var pages = 0
        while history.canLoadEarlier, pages < 10 {
            await history.loadEarlier()
            pages += 1
        }
        XCTAssertEqual(history.hits.map(\.id), [9, 8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(Set(history.hits.map(\.id)).count, history.hits.count)
        XCTAssertFalse(history.canLoadEarlier)
        XCTAssertFalse(history.loadEarlierFailed)
        let earlier = await reader.searches.dropFirst()
        XCTAssertTrue(earlier.allSatisfy { $0.browse && $0.timeFromUs == day.startUs })
    }

    func testOtherDaysMomentsNeverShow() async {
        let reader = PagingReader([
            at(60, id: 1), at(120, id: 2),
            Hit(eventId: 3, tsUs: day.endUs + 1, appBundleId: nil, windowTitle: nil, url: nil,
                ocrTextSnippet: "tomorrow", source: "recent", score: nil),
            Hit(eventId: 4, tsUs: day.startUs - 1, appBundleId: nil, windowTitle: nil, url: nil,
                ocrTextSnippet: "yesterday", source: "recent", score: nil),
        ])
        let history = model(reader, day: day)
        await history.reload()
        XCTAssertEqual(history.hits.map(\.id), [2, 1])
        XCTAssertFalse(history.canLoadEarlier)
    }

    func testShowInHistoryLoadsTheSessionsOwnTimeAndGoesOnBeforeIt() async {
        let reader = PagingReader((1...9).map { at(UInt64($0) * 600, id: UInt64($0)) })
        let history = model(reader, pageSize: 5)
        let session = (day.startUs + 4 * 600_000_000)...(day.startUs + 6 * 600_000_000)
        await history.show(day: day, around: session, selecting: 6)
        XCTAssertEqual(history.day, day)
        XCTAssertEqual(history.range, session)
        XCTAssertEqual(history.hits.map(\.id), [6, 5, 4], "only the session's own moments, newest first")
        XCTAssertEqual(history.selectedHitId, 6)
        XCTAssertTrue(history.canLoadEarlier, "the rest of its day lies below the session")
        await history.loadEarlier()
        XCTAssertEqual(history.hits.map(\.id), [6, 5, 4, 3, 2, 1])
        XCTAssertFalse(history.canLoadEarlier)
        XCTAssertEqual(history.selectedHitId, 6)
    }

    func testASessionWithNothingLeftInItStillGoesOnBeforeIt() async {
        let reader = PagingReader([at(60, id: 1), at(120, id: 2)])
        let history = model(reader)
        await history.show(day: day, around: (day.startUs + 3_600_000_000)...(day.startUs + 7_200_000_000), selecting: 9)
        XCTAssertTrue(history.hits.isEmpty)
        XCTAssertNil(history.selectedHitId, "a moment that is not there is not selected")
        XCTAssertTrue(history.canLoadEarlier)
        await history.loadEarlier()
        XCTAssertEqual(history.hits.map(\.id), [2, 1])
    }

    func testARangeOutsideTheDayShowsTheWholeDayAndLeavingARangeKeepsTheSelection() async {
        let reader = PagingReader((1...4).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, pageSize: 10)
        await history.show(day: day, around: (day.endUs + 10)...(day.endUs + 20))
        XCTAssertNil(history.range)
        XCTAssertEqual(history.hits.map(\.id), [4, 3, 2, 1])

        await history.show(day: day, around: (day.startUs + 120_000_000)...(day.startUs + 180_000_000), selecting: 2)
        XCTAssertEqual(history.hits.map(\.id), [3, 2])
        await history.showWholeDay()
        XCTAssertNil(history.range)
        XCTAssertEqual(history.hits.map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(history.selectedHitId, 2)
    }

    func testTheTickReadsTodayOnlyWhenSomethingNewerWasSavedAndKeepsTheEarlierPages() async {
        let reader = PagingReader((1...5).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, pageSize: 2, day: day)
        await history.reload()
        await history.loadEarlier()
        XCTAssertEqual(history.hits.map(\.id), [5, 4, 3, 2])
        let reads = await reader.searches.count

        await history.refresh()
        let quiet = await reader.searches.count
        XCTAssertEqual(quiet, reads, "nothing newer: History is not read again")
        let probes = await reader.recentCalls
        XCTAssertEqual(probes, 1)

        await reader.add([at(600, id: 6)])
        await history.refresh()
        XCTAssertEqual(history.hits.map(\.id), [6, 5, 4, 3, 2], "the newer moment goes on top; the pages below stay")
        let newer = await reader.searches.last
        XCTAssertEqual(newer?.timeFromUs, day.startUs + 300_000_000)
        XCTAssertEqual(newer?.timeToUs, day.endUs)
    }

    func testMoreThanAPageOfNewMomentsStartsHistoryAgainFromTheTop() async {
        let reader = PagingReader((1...4).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, pageSize: 2, day: day)
        await history.reload()
        await history.loadEarlier()
        XCTAssertEqual(history.hits.map(\.id), [4, 3, 2, 1])
        await reader.add([at(600, id: 5), at(660, id: 6), at(720, id: 7)])
        await history.refresh()
        XCTAssertEqual(history.hits.map(\.id), [7, 6], "the rows below would not follow on from the new ones")
        XCTAssertTrue(history.canLoadEarlier)
    }

    func testTheTickLeavesAPastDayAndASessionsTimeAlone() async {
        let reader = PagingReader((1...3).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let tomorrow = Date(timeIntervalSince1970: Double(day.endUs) / 1_000_000 + 3600)
        let pastDay = model(reader, day: day, now: tomorrow)
        await pastDay.reload()
        await reader.add([at(600, id: 4)])
        await pastDay.refresh()
        XCTAssertEqual(pastDay.hits.map(\.id), [3, 2, 1])
        var probes = await reader.recentCalls
        XCTAssertEqual(probes, 0, "a past day is not even checked")

        let session = model(reader, day: day)
        await session.show(day: day, around: (day.startUs + 60_000_000)...(day.startUs + 120_000_000))
        await session.refresh()
        XCTAssertEqual(session.hits.map(\.id), [2, 1])
        probes = await reader.recentCalls
        XCTAssertEqual(probes, 0, "a session's own time is not checked either")
    }

    func testWithoutADayTheTickReadsTheNewestMomentsOnlyWhenSomethingNewerWasSaved() async {
        let reader = PagingReader((1...3).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, pageSize: 10)
        await history.reload()
        XCTAssertEqual(history.hits.map(\.id), [3, 2, 1])
        await history.refresh()
        var calls = await reader.recentCalls
        XCTAssertEqual(calls, 2, "one read, one check")
        await reader.add([at(600, id: 4)])
        await history.refresh()
        calls = await reader.recentCalls
        XCTAssertEqual(calls, 4, "a check, then a read")
        XCTAssertEqual(history.hits.map(\.id), [4, 3, 2, 1])
    }

    func testAReadForADayLeftBehindNeverLands() async {
        let reader = PagingReader([at(60, id: 1), at(90_000, id: 2)])
        let history = model(reader, day: day)
        await reader.holdNextRead()
        let first = Task { await history.reload() }
        await assertEventually { await reader.waiting }
        let tomorrow = MemoryDay(date: Date(timeIntervalSince1970: Double(day.endUs) / 1_000_000 + 3600), calendar: calendar)
        await history.show(day: tomorrow)
        XCTAssertEqual(history.hits.map(\.id), [2])
        await reader.release()
        await first.value
        XCTAssertEqual(history.day, tomorrow)
        XCTAssertEqual(history.hits.map(\.id), [2], "the first day's read came back after the second day's")
        XCTAssertFalse(history.isLoading)
    }

    func testADeleteClearsHistoryAtOnceAndReadsItAgain() async {
        let signal = MemoryDeletionSignal()
        let reader = PagingReader((1...3).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, day: day, deletions: signal)
        await history.reload()
        history.selectedHitId = 2
        await reader.remove(3)
        signal.post()
        XCTAssertTrue(history.hits.isEmpty, "nothing deleted may stay on screen while History is read again")
        await assertEventually { await MainActor.run { history.hits.map(\.id) == [2, 1] } }
        XCTAssertEqual(history.selectedHitId, 2, "a selection still there stays")
    }

    func testAFailedShowEarlierKeepsTheRowsAndCanBeTriedAgain() async {
        let reader = PagingReader((1...5).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, pageSize: 2, day: day)
        await history.reload()
        await reader.failNextRead()
        await history.loadEarlier()
        XCTAssertEqual(history.hits.map(\.id), [5, 4])
        XCTAssertTrue(history.loadEarlierFailed)
        XCTAssertTrue(history.canLoadEarlier)
        await history.loadEarlier()
        XCTAssertEqual(history.hits.map(\.id), [5, 4, 3, 2])
        XCTAssertFalse(history.loadEarlierFailed)
    }

    func testAMomentNoLongerThereIsNoLongerSelected() async {
        let reader = PagingReader((1...3).map { at(UInt64($0) * 60, id: UInt64($0)) })
        let history = model(reader, day: day)
        await history.reload()
        history.selectedHitId = 3
        history.isDetailFocused = true
        await reader.remove(3)
        await history.reload()
        XCTAssertNil(history.selectedHitId)
        XCTAssertFalse(history.isDetailFocused)
    }
}

/// A day of moments for History: browsing returns them newest first inside
/// a time window, as the FFI does (time, then id, both descending). Every
/// read is recorded. Synthetic data only.
private actor PagingReader: BrainReader {
    private(set) var moments: [Hit]
    private(set) var searches: [SearchOptions] = []
    private(set) var recentCalls = 0
    private(set) var waiting = false
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?
    private var failNext = false

    init(_ moments: [Hit]) {
        self.moments = moments
    }

    func add(_ more: [Hit]) { moments += more }
    func remove(_ id: UInt64) { moments.removeAll { $0.id == id } }
    /// The next read waits until `release()`; the reads after it do not.
    func holdNextRead() { holdNext = true }
    func failNextRead() { failNext = true }

    func release() {
        waiting = false
        gate?.resume()
        gate = nil
    }

    private var newestFirst: [Hit] {
        moments.sorted { $0.tsUs == $1.tsUs ? $0.id > $1.id : $0.tsUs > $1.tsUs }
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        searches.append(opts)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                waiting = true
                gate = continuation
            }
        }
        if failNext {
            failNext = false
            throw BrainReaderError.queryFailed("synthetic")
        }
        guard opts.browse else { return [] }
        let from = opts.timeFromUs ?? 0
        let to = opts.timeToUs ?? .max
        return Array(newestFirst.filter { $0.tsUs >= from && $0.tsUs <= to }.prefix(opts.limit))
    }

    func recentEvents(limit: Int) async throws -> [Hit] {
        recentCalls += 1
        return Array(newestFirst.prefix(limit))
    }

    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        ids.compactMap { id in moments.first { $0.id == id } }
    }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: UInt64(moments.count), oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}
