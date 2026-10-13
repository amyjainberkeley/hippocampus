import Combine
import Foundation
import XCTest
@testable import RecallUIKit

/// Overview keeps a session selected across reads by its time, decides the
/// Right now card, and reads the day and the saved status (RULINGS I2, W5).
@MainActor
final class OverviewViewModelTests: XCTestCase {
    private func model(_ understanding: ScriptedUnderstanding,
                       receipt: CaptureHealthReceipt? = nil,
                       now: Date = SampleDay.now,
                       deletions: MemoryDeletionSignal = MemoryDeletionSignal()) -> OverviewViewModel {
        OverviewViewModel(understanding: understanding, selectedDate: now, calendar: SampleDay.calendar,
                          healthLoader: { receipt }, now: { now }, deletions: deletions)
    }

    private func loaded(receipt: CaptureHealthReceipt? = nil) async throws -> (OverviewViewModel, ScriptedUnderstanding) {
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(try UnderstandingFixture.overview())
        let model = model(understanding, receipt: receipt)
        await model.reload()
        return (model, understanding)
    }

    func testItReadsTheDayInThePersonsCalendarAndTheSavedStatus() async throws {
        let receipt = SampleDay.receipt()
        let (model, understanding) = try await loaded(receipt: receipt)
        let asked = await understanding.overviewDays
        XCTAssertEqual(asked, [UnderstandingDay(dateLocal: SampleDay.date, tzOffsetSeconds: -25_200)])
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.overview?.blocks.count, 8)
        XCTAssertEqual(model.captureHealth, receipt)
        XCTAssertTrue(model.isToday)
    }

    func testADayThatCannotBeReadIsUnavailable() async {
        let understanding = ScriptedUnderstanding()
        await understanding.failOverview(SampleDay.date)
        let model = model(understanding)
        await model.reload()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.overview)
        XCTAssertNil(model.rightNow)
        XCTAssertTrue(model.blocks.isEmpty)
    }

    func testTheDaysLastSessionIsSelectedUntilAnotherIsPicked() async throws {
        let (model, _) = try await loaded()
        XCTAssertEqual(model.selectedBlock?.id, 1_791_839_523_000_000)
        let morning = model.blocks[1]
        model.select(morning)
        XCTAssertEqual(model.selectedBlock, morning)
    }

    func testAPickedSessionIsFoundAgainByItsTimeWhenItsIdChanges() async throws {
        let (model, understanding) = try await loaded()
        let overview = try XCTUnwrap(model.overview)
        let provisional = try XCTUnwrap(overview.blocks.last)
        XCTAssertTrue(provisional.provisional)
        model.select(overview.blocks[3])
        model.select(provisional)
        // Its note landed: a new id, bounds a little different, and a new
        // session after it, which would be "the last" by default.
        var blocks = Array(overview.blocks.dropLast())
        blocks.append(.make(id: 1_791_839_530_000_000, end: 1_791_841_060_000_000, kind: .design, title: "Pricing tiers in Figma"))
        blocks.append(.make(id: 1_791_841_500_000_000, end: 1_791_841_800_000_000))
        await understanding.setOverview(overview.with(blocks: blocks))
        await model.feed.load(model.day)
        XCTAssertEqual(model.selectedBlock?.id, 1_791_839_530_000_000)
        XCTAssertEqual(model.selectedBlock?.title, "Pricing tiers in Figma")
    }

    func testASplitSessionKeepsTheSelectionOnTheLargerPart() {
        let picked: ClosedRange<Int64> = 1_000...2_000
        let blocks: [DayBlock] = [
            .make(id: 900, end: 1_200),
            .make(id: 1_250, end: 2_000),
            .make(id: 2_100, end: 2_500),
        ]
        XCTAssertEqual(SessionMatch.best(for: picked, in: blocks)?.id, 1_250)
        XCTAssertNil(SessionMatch.best(for: 3_000...3_100, in: blocks))
        let point: ClosedRange<Int64> = 2_000...2_000
        XCTAssertEqual(SessionMatch.best(for: point, in: [.make(id: 1_000, end: 2_000), .make(id: 2_000, end: 2_400)])?.id,
                       2_000, "touching at one moment, the session starting nearest wins")
    }

    func testAPickedSessionThatIsGoneGivesWayToTheLast() async throws {
        let (model, understanding) = try await loaded()
        let overview = try XCTUnwrap(model.overview)
        model.select(overview.blocks[0])
        await understanding.setOverview(overview.with(blocks: Array(overview.blocks.dropFirst())))
        await model.feed.load(model.day)
        XCTAssertEqual(model.selectedBlock?.id, overview.blocks.last?.id)
    }

    func testArrowsMoveBetweenSessionsAndStopAtTheEnds() async throws {
        let (model, _) = try await loaded()
        let ids = model.blocks.map(\.id)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedBlock?.id, ids[ids.count - 2])
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedBlock?.id, ids.last)
        for _ in 0..<20 { model.moveSelection(by: -1) }
        XCTAssertEqual(model.selectedBlock?.id, ids.first)
    }

    func testAnotherDayStartsAgainFromItsLastSessionAndNeverPassesToday() async throws {
        let (model, understanding) = try await loaded()
        model.select(model.blocks[0])
        model.toggleHighlight(.code)
        XCTAssertFalse(model.canMoveForward)
        model.moveDay(1)
        XCTAssertEqual(model.day.dateLocal, SampleDay.date, "no day after today")
        let sunday = try UnderstandingFixture.overview().with(blocks: [
            .make(id: 1_791_730_000_000_000, end: 1_791_731_000_000_000),
            .make(id: 1_791_740_000_000_000, end: 1_791_741_000_000_000),
        ])
        let sundayOverview = DayOverview(
            version: 1, date: "2026-10-11", isToday: false, nowUs: sunday.nowUs, tzOffsetSecs: -25_200,
            dayStartUs: 1_791_702_000_000_000, dayEndUs: 1_791_788_400_000_000, basis: .measured,
            truncated: false, modelStatus: .unknown, now: .nothing, strip: sunday.strip, blocks: sunday.blocks,
            gaps: [], kinds: [], facts: [], searches: [], account: nil, aiKnows: .nothing)
        await understanding.setOverview(sundayOverview)
        model.moveDay(-1)
        XCTAssertEqual(model.day.dateLocal, "2026-10-11")
        XCTAssertNil(model.highlightedKind)
        XCTAssertNil(model.overview, "Monday's sessions never show under Sunday")
        await model.reload()
        XCTAssertEqual(model.selectedBlock?.id, 1_791_740_000_000_000)
        XCTAssertTrue(model.canMoveForward)
        XCTAssertNil(model.rightNow, "the card is today's only")
        model.goToToday()
        XCTAssertEqual(model.day.dateLocal, SampleDay.date)
    }

    func testTheLegendDimsOtherKindsAndAKindWithNoSessionDimsNothing() async throws {
        let (model, _) = try await loaded()
        model.toggleHighlight(.code)
        let dimmed = model.blocks.filter(model.isDimmed)
        XCTAssertFalse(dimmed.isEmpty)
        XCTAssertTrue(dimmed.allSatisfy { $0.kind != .code })
        XCTAssertTrue(model.blocks.filter { $0.kind == .code }.allSatisfy { !model.isDimmed($0) })
        model.toggleHighlight(.code)
        XCTAssertTrue(model.blocks.allSatisfy { !model.isDimmed($0) })
        model.toggleHighlight(.media)
        XCTAssertTrue(model.blocks.allSatisfy { !model.isDimmed($0) }, "clicking a kind never dims everything")
    }

    func testAFactPicksItsSessionsOrOpensTheSearches() async throws {
        let (model, _) = try await loaded()
        let overview = try XCTUnwrap(model.overview)
        let longest = try XCTUnwrap(overview.facts.first { $0.kind == .longest })
        model.perform(longest)
        XCTAssertEqual(model.highlightedBlocks.map(\.id), [1_791_828_150_000_000, 1_791_829_955_000_000])
        XCTAssertEqual(model.selectedBlock?.id, 1_791_828_150_000_000)
        XCTAssertFalse(model.isDimmed(model.blocks[3]))
        XCTAssertTrue(model.isDimmed(model.blocks[0]))
        model.select(model.blocks[0])
        XCTAssertTrue(model.highlightedBlocks.isEmpty)

        let searched = try XCTUnwrap(overview.facts.first { $0.kind == .searched })
        model.perform(searched)
        XCTAssertTrue(model.showsSearches)
        model.hideSearches()
        XCTAssertFalse(model.showsSearches)
        model.perform(try XCTUnwrap(overview.facts.first { $0.kind == .active }))
        XCTAssertEqual(model.selectedBlock?.id, model.blocks[0].id, "a fact with no action changes nothing")
    }

    func testShowInHistoryAsksForTheSessionsOwnTime() async throws {
        let (model, _) = try await loaded()
        let block = model.blocks[3]
        XCTAssertEqual(model.historyRoute(for: block),
                       .history(of: block.startUs...block.endUs, selecting: block.openEventId))
    }

    func testASessionRowOnYouOpensItsDayWithTheSessionSelected() async throws {
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(try UnderstandingFixture.overview())
        let model = model(understanding, now: SampleDay.now.addingTimeInterval(2 * 86_400))
        model.open(.overview(showing: 1_791_823_265_000_000...1_791_825_055_000_000))
        XCTAssertEqual(model.day.dateLocal, SampleDay.date)
        await model.reload()
        XCTAssertEqual(model.selectedBlock?.id, 1_791_823_265_000_000)
    }

    // MARK: Right now (RULINGS W5)

    func testWhileWorkingTheCardSaysNowSinceTheRunsStart() async throws {
        let (model, _) = try await loaded(receipt: SampleDay.receipt())
        let card = try XCTUnwrap(model.rightNow)
        XCTAssertEqual(card.moment, .now(sinceUs: 1_791_839_523_000_000))
        XCTAssertEqual(spaced(card.caption(locale: SampleDay.locale, timeZone: SampleDay.timeZone)), "Now \u{00B7} since 2:12 PM")
        XCTAssertEqual(card.title, "Trailhead pricing v3")
        XCTAssertEqual(card.copyRange, 1_791_839_523_000_000...1_791_841_000_000_000)
        XCTAssertEqual(card.reopen, .app(bundleId: "com.apple.Notes", name: "Notes"))
        XCTAssertEqual(card.reopen?.label, "Open Notes")
        XCTAssertEqual(card.openEventId, 90_269)
        guard case let .lines(recentWork, aboutYou) = card.aiKnows else {
            return XCTFail("a hook is installed: the lines show")
        }
        XCTAssertEqual(recentWork.count, 4)
        XCTAssertEqual(aboutYou.map(\.id), [41, 37, 29, 45, 22, 33])
    }

    func testCopyForYourAICopiesTheTimeTheCaptionNames() throws {
        let overview = try UnderstandingFixture.overview()
        let touching = RightNow(state: .inProgress, sinceUs: 1_000, startUs: 5_000, lastSavedUs: 9_000, blockId: 5_000,
                                title: "Draft", writtenBy: "measured", appName: "Notes", openEventId: 7, reopen: nil)
        let card = try XCTUnwrap(RightNowCard(overview: overview.with(now: touching), receipt: nil, now: SampleDay.now))
        XCTAssertEqual(card.moment, .now(sinceUs: 1_000))
        XCTAssertEqual(card.copyRange, 1_000...9_000, "since the start of the run, as the caption says")
        let stopped = RightNow(state: .lastSaved, sinceUs: nil, startUs: 5_000, lastSavedUs: 9_000, blockId: 5_000,
                               title: "Draft", writtenBy: "measured", appName: "Notes", openEventId: 7, reopen: nil)
        let last = try XCTUnwrap(RightNowCard(overview: overview.with(now: stopped), receipt: nil, now: SampleDay.now))
        XCTAssertEqual(last.moment, .lastSaved(atUs: 9_000))
        XCTAssertEqual(last.copyRange, 5_000...9_000)
        XCTAssertEqual(spaced(last.caption(locale: SampleDay.locale, timeZone: TimeZone(identifier: "UTC")!)),
                       "Last saved 12:00 AM")
    }

    func testTheCardNeverSaysNowWhileNothingIsBeingSaved() async throws {
        for receipt in [
            SampleDay.receipt(suppressed: "secure_input"),
            SampleDay.receipt(blocked: "capture_disabled"),
            SampleDay.receipt(age: 300),
        ] {
            let (model, _) = try await loaded(receipt: receipt)
            let card = try XCTUnwrap(model.rightNow)
            XCTAssertEqual(card.moment, .lastSaved(atUs: 1_791_841_000_000_000))
            XCTAssertEqual(spaced(card.caption(locale: SampleDay.locale, timeZone: SampleDay.timeZone)), "Last saved 2:36 PM")
            XCTAssertEqual(card.copyRange, 1_791_839_523_000_000...1_791_841_000_000_000)
        }
        let (trusting, _) = try await loaded(receipt: nil)
        XCTAssertEqual(trusting.rightNow?.moment, .now(sinceUs: 1_791_839_523_000_000),
                       "with no status of its own the window keeps the agent's word")
    }

    func testWithoutASessionHookTheCardOffersConnectInsteadOfLines() throws {
        let overview = try UnderstandingFixture.overview()
        let unhooked = overview.with(now: overview.now, aiKnows: AIKnows(recentWork: overview.aiKnows.recentWork,
                                                                        aboutYou: overview.aiKnows.aboutYou,
                                                                        hookInstalled: false))
        let card = try XCTUnwrap(RightNowCard(overview: unhooked, receipt: nil, now: SampleDay.now))
        XCTAssertEqual(card.aiKnows, .connect)
    }

    func testThereIsNoCardOnAnotherDayOrWhenNothingWasSaved() throws {
        let overview = try UnderstandingFixture.overview()
        XCTAssertNil(RightNowCard(overview: overview.with(now: overview.now, isToday: false), receipt: nil, now: SampleDay.now))
        XCTAssertNil(RightNowCard(overview: overview.with(now: .nothing), receipt: nil, now: SampleDay.now))
    }

    func testReopenOpensAPageOnlyForAWebAddressAndNothingWithoutAnApp() throws {
        XCTAssertEqual(ReopenAction(Reopen(url: "https://www.velocycles.example/pricing", bundleId: "com.apple.Safari", appName: "Safari")),
                       .page(try XCTUnwrap(URL(string: "https://www.velocycles.example/pricing"))))
        XCTAssertEqual(ReopenAction(Reopen(url: "https://x.example", bundleId: "com.apple.Safari", appName: "Safari"))?.label,
                       "Open Page")
        XCTAssertEqual(ReopenAction(Reopen(url: "file:///etc/passwd", bundleId: "com.apple.Safari", appName: "Safari")),
                       .app(bundleId: "com.apple.Safari", name: "Safari"))
        XCTAssertEqual(ReopenAction(Reopen(url: nil, bundleId: "com.microsoft.VSCode", appName: "")),
                       .app(bundleId: "com.microsoft.VSCode", name: "VS Code"))
        XCTAssertNil(ReopenAction(Reopen(url: nil, bundleId: "unknown", appName: "Unknown")))
        XCTAssertNil(ReopenAction(nil))
    }

    func testThePreviewsCardRendersAndWhatItCopiesIsInThePreviewsMemory() async throws {
        let reader = NativePreviewReader(date: SampleDay.now, now: SampleDay.now, calendar: SampleDay.calendar)
        let model = OverviewViewModel(understanding: PreviewUnderstandingReader(), selectedDate: SampleDay.now,
                                      calendar: SampleDay.calendar, healthLoader: { nil }, now: { SampleDay.now },
                                      deletions: MemoryDeletionSignal())
        await model.reload()
        let card = try XCTUnwrap(model.rightNow)
        XCTAssertEqual(card.moment, .now(sinceUs: 1_791_839_523_000_000))
        let recent = try await reader.fetchEventsByIds([NativePreviewReader.recentEventId])
        let moment = try XCTUnwrap(recent.first)
        XCTAssertTrue(card.copyRange.contains(Int64(moment.tsUs)))
        XCTAssertEqual(card.openEventId, Int64(moment.id))
        let newest = try await reader.recentEvents(limit: 1)
        XCTAssertEqual(newest.map(\.id), [NativePreviewReader.recentEventId])
    }

    func testOverviewRedrawsWhenItsDayIsRead() async throws {
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(try UnderstandingFixture.overview())
        let model = model(understanding)
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        await model.reload()
        XCTAssertGreaterThan(changes, 0)
        watch.cancel()
    }
}
