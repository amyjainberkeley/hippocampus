import Foundation
import XCTest
@testable import RecallUIKit

/// The card at the top of Today (SPEC 3.1): "Now" only while remembering and
/// the newest moment is under 20 minutes old; otherwise "Where you left off",
/// with the last session before the gap: today's, yesterday's in the
/// morning, or the last day with anything after a week away.
@MainActor
final class TodayCardStateTests: XCTestCase {
    private let minute: Int64 = 60_000_000
    private var nowUs: Int64 { Int64(SampleDay.now.timeIntervalSince1970 * 1_000_000) }

    private func card(lastSavedAgo minutes: Int64, receipt: CaptureHealthReceipt? = SampleDay.receipt()) throws
        -> RightNowCard? {
        let overview = try UnderstandingFixture.overview()
        let now = RightNow(state: .inProgress, sinceUs: nowUs - 40 * minute, startUs: nowUs - 40 * minute,
                           lastSavedUs: nowUs - minutes * minute, blockId: 1_791_839_523_000_000,
                           title: "Trailhead pricing v3", writtenBy: "measured", appName: "Figma",
                           openEventId: 90_269, reopen: nil)
        return RightNowCard(overview: overview.with(now: now), receipt: receipt, now: SampleDay.now)
    }

    func testNowWhileRememberingAndTheNewestMomentIsUnderTwentyMinutesOld() throws {
        let fresh = try XCTUnwrap(card(lastSavedAgo: 19))
        XCTAssertEqual(fresh.moment, .now(sinceUs: nowUs - 40 * minute))
        XCTAssertEqual(spaced(fresh.caption(locale: SampleDay.locale, timeZone: SampleDay.timeZone)),
                       "Now \u{00B7} since 1:57 PM")
    }

    func testTwentyMinutesWithNothingNewIsWhereYouLeftOff() throws {
        for minutes: Int64 in [20, 45, 300] {
            let stale = try XCTUnwrap(card(lastSavedAgo: minutes))
            XCTAssertEqual(stale.moment, .leftOff(atUs: nowUs - minutes * minute), "\(minutes) minutes")
            XCTAssertTrue(spaced(stale.caption(locale: SampleDay.locale, timeZone: SampleDay.timeZone))
                .hasPrefix("Where you left off \u{00B7} Today at "))
        }
    }

    func testPausedOrOffIsNeverNow() throws {
        for receipt in [SampleDay.receipt(blocked: "capture_disabled"), SampleDay.receipt(age: 600),
                        SampleDay.receipt(suppressed: "secure_input")] {
            let paused = try XCTUnwrap(card(lastSavedAgo: 1, receipt: receipt))
            XCTAssertEqual(paused.moment, .leftOff(atUs: nowUs - minute))
        }
    }

    func testTheDayIsSaidFromNow() {
        let zone = SampleDay.timeZone
        let locale = SampleDay.locale
        XCTAssertEqual(RightNowCard.day(mondayUs(9, 0), from: nowUs, locale: locale, timeZone: zone), "Today")
        XCTAssertEqual(RightNowCard.day(mondayUs(9, 0) - 24 * 60 * minute, from: nowUs, locale: locale, timeZone: zone),
                       "Yesterday")
        XCTAssertEqual(RightNowCard.day(mondayUs(18, 12) - 3 * 24 * 60 * minute, from: nowUs, locale: locale,
                                        timeZone: zone), "Friday")
        XCTAssertEqual(RightNowCard.day(mondayUs(18, 12) - 10 * 24 * 60 * minute, from: nowUs, locale: locale,
                                        timeZone: zone), "Oct 2")
        XCTAssertEqual(RightNowCard.day(mondayUs(18, 12) - 400 * 24 * 60 * minute, from: nowUs, locale: locale,
                                        timeZone: zone), "Sep 7, 2025")
        XCTAssertEqual(spaced(RightNowCard.when(mondayUs(18, 12) - 24 * 60 * minute, from: nowUs, locale: locale,
                                                timeZone: zone)), "Yesterday at 6:12 PM")
    }

    // MARK: A morning, and a week away

    /// Tuesday, 8:43 AM: nothing saved yet today, so the card is Monday's
    /// last session, "Where you left off · Yesterday at 2:36 PM".
    func testOvernightIsAGapSoTheMorningOpensOnYesterdaysLastSession() async throws {
        let monday = try UnderstandingFixture.overview()
        let tuesday = Date(timeIntervalSince1970: SampleDay.now.timeIntervalSince1970 + 18 * 3_600 + 3 * 60)
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(monday.with(now: .nothing, isToday: false))
        await understanding.setOverview(emptyDay("2026-10-13", startUs: monday.dayStartUs + 86_400_000_000))
        let reader = MomentsReader([MomentFactory.hit(90_269, "com.figma.Desktop", title: "Trailhead pricing v3",
                                                      minutesAgo: 1, caption: "Designing pricing")])
        let model = OverviewViewModel(understanding: understanding, selectedDate: tuesday,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { tuesday }, deletions: MemoryDeletionSignal(),
                                      savedBefore: { _ in true }, reader: reader)
        await model.reload()
        let card = try XCTUnwrap(model.rightNow)
        XCTAssertEqual(card.title, "Trailhead pricing v3")
        XCTAssertEqual(card.blockId, 1_791_839_523_000_000)
        XCTAssertEqual(spaced(card.caption(locale: SampleDay.locale, timeZone: SampleDay.timeZone)),
                       "Where you left off \u{00B7} Yesterday at 2:36 PM")
        XCTAssertTrue(card.isFromEarlierDay(timeZone: SampleDay.timeZone))
        XCTAssertEqual(model.cardMoment?.id, 90_269, "the card's newest moment, drawn as History draws it")
        XCTAssertEqual(model.cardTitle, "Trailhead pricing v3")
    }

    func testAfterAWeekAwayTheCardIsTheLastDayWithAnythingAndAlsoFromNamesIt() async throws {
        let monday = try UnderstandingFixture.overview()
        let later = Date(timeIntervalSince1970: SampleDay.now.timeIntervalSince1970 + 10 * 86_400)
        let laterDay = UnderstandingDay(date: later, calendar: SampleDay.calendar)
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(monday.with(now: .nothing, isToday: false))
        await understanding.setOverview(emptyDay(laterDay.dateLocal, startUs: monday.dayStartUs + 10 * 86_400_000_000))
        let reader = MomentsReader([MomentFactory.hit(90_269, "com.figma.Desktop", minutesAgo: 1)])
        let work = PreviewWorkReader(snapshot: WorkSnapshot(items: [
            WorkItem(id: "w_card", kind: .design, name: "Trailhead pricing v3", lastUs: UInt64(mondayUs(14, 36))),
            WorkItem(id: "w_q4", kind: .document, name: "Q4 planning", lastUs: UInt64(mondayUs(11, 0))),
            WorkItem(id: "w_shop", kind: .code, name: "trailhead-shop", lastUs: UInt64(mondayUs(12, 19))),
            WorkItem(id: "w_hidden", kind: .document, name: "Hidden note", lastUs: UInt64(mondayUs(13, 0)),
                     inSidebar: false),
            WorkItem(id: "w_old", kind: .document, name: "Older", lastUs: UInt64(mondayUs(9, 0) - 86_400_000_000)),
        ], momentItems: [90_269: "w_card"]))
        let model = OverviewViewModel(understanding: understanding, selectedDate: later,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { later }, deletions: MemoryDeletionSignal(),
                                      savedBefore: { _ in true }, reader: reader, work: work)
        await model.reload()
        let card = try XCTUnwrap(model.rightNow)
        XCTAssertEqual(spaced(card.caption(locale: SampleDay.locale, timeZone: SampleDay.timeZone)),
                       "Where you left off \u{00B7} Oct 12 at 2:36 PM")
        XCTAssertEqual(model.cardItem?.id, "w_card", "Resume goes on the card")
        XCTAssertFalse(model.showsPartOf, "the card already says the item's name")
        let also = try XCTUnwrap(model.alsoFrom(locale: SampleDay.locale))
        XCTAssertEqual(also.day, "Oct 12")
        XCTAssertEqual(also.items.map(\.name), ["trailhead-shop", "Q4 planning"],
                       "the last day of use, newest first; never the card's item or one the person hid")
    }

    /// A session that ends on a chat with people (never part of an item)
    /// is still the project's: the card finds the item most of the
    /// session's moments belong to, for Resume and "Part of" (SPEC 3.1,
    /// SPEC-DELTA 3). Moments from before the session don't count.
    func testASessionEndingOnAChatKeepsItsProjectsResume() async throws {
        let monday = try UnderstandingFixture.overview()
        let start = nowUs - 30 * minute
        let last = nowUs - 2 * minute
        let now = RightNow(state: .inProgress, sinceUs: start, startUs: start, lastSavedUs: last, blockId: nil,
                           title: "Shipping the fix", writtenBy: "measured", appName: "Slack", openEventId: 7_003,
                           reopen: nil)
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(monday.with(now: now))
        let reader = MomentsReader([
            MomentFactory.hit(7_003, "com.tinyspeck.slackmacgap", title: "#team", minutesAgo: 2,
                              caption: "Chatting in #team"),
            MomentFactory.hit(7_002, "com.apple.Terminal", title: "trailhead-shop \u{2014} zsh", minutesAgo: 10),
            MomentFactory.hit(7_001, "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop", minutesAgo: 20),
            MomentFactory.hit(7_000, "com.figma.Desktop", title: "Trailhead pricing v3", minutesAgo: 25),
            MomentFactory.hit(6_901, "com.figma.Desktop", title: "Trailhead pricing v3", minutesAgo: 80),
            MomentFactory.hit(6_900, "com.figma.Desktop", title: "Trailhead pricing v3", minutesAgo: 90),
        ])
        let work = PreviewWorkReader(snapshot: WorkSnapshot(items: [
            WorkItem(id: "w_shop", kind: .code, name: "trailhead-shop", lastUs: UInt64(last)),
            WorkItem(id: "w_card", kind: .design, name: "Trailhead pricing v3", lastUs: UInt64(start)),
        ], momentItems: [7_002: "w_shop", 7_001: "w_shop", 7_000: "w_card", 6_901: "w_card", 6_900: "w_card"]))
        let model = OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { SampleDay.now }, deletions: MemoryDeletionSignal(),
                                      savedBefore: { _ in true }, reader: reader, work: work)
        await model.reload()
        XCTAssertEqual(model.cardItem?.id, "w_shop",
                       "two of the session's moments are the shop's and one the design's; earlier ones don't count")
        XCTAssertTrue(model.showsPartOf, "the card's chat doesn't name the shop, so Part of says it")
    }

    /// The newest moment's own item wins when it has one.
    func testTheNewestMomentsOwnItemComesFirst() async throws {
        let monday = try UnderstandingFixture.overview()
        let start = nowUs - 30 * minute
        let last = nowUs - 2 * minute
        let now = RightNow(state: .inProgress, sinceUs: start, startUs: start, lastSavedUs: last, blockId: nil,
                           title: "Pricing", writtenBy: "measured", appName: "Figma", openEventId: 7_103,
                           reopen: nil)
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(monday.with(now: now))
        let reader = MomentsReader([
            MomentFactory.hit(7_103, "com.figma.Desktop", title: "Trailhead pricing v3", minutesAgo: 2),
            MomentFactory.hit(7_102, "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop", minutesAgo: 10),
            MomentFactory.hit(7_101, "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop", minutesAgo: 20),
        ])
        let work = PreviewWorkReader(snapshot: WorkSnapshot(items: [
            WorkItem(id: "w_shop", kind: .code, name: "trailhead-shop", lastUs: UInt64(start)),
            WorkItem(id: "w_card", kind: .design, name: "Trailhead pricing v3", lastUs: UInt64(last)),
        ], momentItems: [7_103: "w_card", 7_102: "w_shop", 7_101: "w_shop"]))
        let model = OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { SampleDay.now }, deletions: MemoryDeletionSignal(),
                                      savedBefore: { _ in true }, reader: reader, work: work)
        await model.reload()
        XCTAssertEqual(model.cardItem?.id, "w_card")
        XCTAssertEqual(reader.searches.filter { $0.browse && $0.limit == OverviewViewModel.sessionMomentsAsked }.count,
                       0, "the session is read only when the newest moment belongs to nothing")
    }

    func testAlsoFromYesterdayGoesOnceTodayHoldsHalfAnHour() async throws {
        let monday = try UnderstandingFixture.overview()
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(monday)
        let work = PreviewWorkReader(snapshot: WorkSnapshot(items: [
            WorkItem(id: "w_y", kind: .document, name: "Yesterday's doc",
                     lastUs: UInt64(mondayUs(15, 0) - 86_400_000_000)),
        ]))
        let model = OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { SampleDay.now }, deletions: MemoryDeletionSignal(), work: work)
        await model.reload()
        XCTAssertNil(model.alsoFrom(locale: SampleDay.locale), "Monday already holds hours of work")
        await understanding.setOverview(monday.with(blocks: [
            .make(id: mondayUs(14, 20), end: mondayUs(14, 36), kind: .design),
        ]))
        await model.reload()
        XCTAssertEqual(model.alsoFrom(locale: SampleDay.locale)?.day, "yesterday")
        XCTAssertEqual(model.alsoFrom(locale: SampleDay.locale)?.items.map(\.name), ["Yesterday's doc"])
    }

    func testTheFirstDayCountsWhatIsSavedAndShowsTheNewest() async throws {
        let understanding = ScriptedUnderstanding()
        let empty = try UnderstandingFixture.overview().with(blocks: []).with(now: .nothing)
        await understanding.setOverview(empty)
        let reader = MomentsReader((0..<6).map { MomentFactory.hit(UInt64(100 + $0), "com.apple.Safari",
                                                                   minutesAgo: Double($0)) })
        let model = OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { SampleDay.now }, deletions: MemoryDeletionSignal(),
                                      savedBefore: { _ in false }, reader: reader)
        await model.reload()
        XCTAssertTrue(model.showsFirstDay)
        XCTAssertEqual(model.savedSoFar, 6)
        XCTAssertEqual(model.newestMoment?.id, 100)
        XCTAssertEqual(UserFacingCopy.Overview.savedSoFar(6), "Saved so far: 6 moments.")
        XCTAssertEqual(UserFacingCopy.Overview.savedSoFar(1), "Saved so far: 1 moment.")
    }

    private func emptyDay(_ date: String, startUs: Int64) -> DayOverview {
        DayOverview(version: 1, date: date, isToday: true, nowUs: startUs + 8 * 3_600_000_000, tzOffsetSecs: -25_200,
                    dayStartUs: startUs, dayEndUs: startUs + 86_400_000_000, basis: .estimated, truncated: false,
                    modelStatus: .unknown, now: .nothing, strip: nil, blocks: [], gaps: [], kinds: [], facts: [],
                    searches: [], account: nil, aiKnows: .nothing)
    }
}
