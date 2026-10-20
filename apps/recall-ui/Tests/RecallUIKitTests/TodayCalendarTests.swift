import Foundation
import XCTest
@testable import RecallUIKit

/// The calendar on Today (SPEC-DELTA 5), from a fake calendar only: nothing
/// here asks macOS for access. Events are thin labelled bars over the strip,
/// a call or meeting takes its event's name, and when the calendar can't be
/// read nothing breaks: there are no bars and sessions keep their names.
@MainActor
final class TodayCalendarTests: XCTestCase {
    private var events: [CalendarEvent] {
        [event("standup", "Stand-up", (9, 0), (9, 15)),
         event("sync", "Team sync", (13, 0), (13, 30)),
         event("investors", "Investor update", (16, 0), (16, 30))]
    }

    func testACallTakesTheNameOfTheEventItOverlaps() throws {
        let overview = try UnderstandingFixture.overview()
        let review = try XCTUnwrap(overview.blocks.first { $0.title == "Weekly design review" })
        XCTAssertEqual(TodayCalendar.title(of: review, events: events), "Team sync")
        XCTAssertEqual(SessionDetail(block: review, events: events).title, "Team sync")
        XCTAssertEqual(SessionDetail(block: review).title, "Weekly design review", "no calendar, its own name")
    }

    func testOnlyCallsAreRenamedAndOnlyByEnoughSharedTime() throws {
        let overview = try UnderstandingFixture.overview()
        let code = try XCTUnwrap(overview.blocks.first { $0.kind == .code })
        let covering = [event("all", "Focus", (11, 0), (13, 0))]
        XCTAssertEqual(TodayCalendar.title(of: code, events: covering), code.title, "a code session keeps its name")

        let call = DayBlock.make(id: mondayUs(13, 0), end: mondayUs(13, 40), kind: .meetings, title: "Zoom Meeting")
        XCTAssertEqual(TodayCalendar.title(of: call, events: [event("brief", "Hello", (13, 35), (13, 50))]),
                       "Zoom Meeting", "five minutes shared is not enough for a 40-minute call")
        XCTAssertEqual(TodayCalendar.title(of: call, events: [event("a", "Short", (13, 0), (13, 12)),
                                                              event("b", "Longer", (13, 10), (13, 40))]),
                       "Longer", "the event sharing the most time wins")
        let allDay = CalendarEvent(id: "day", title: "Offsite", start: SampleDay.calendar.startOfDay(for: SampleDay.now),
                                   end: SampleDay.calendar.startOfDay(for: SampleDay.now).addingTimeInterval(86_400),
                                   calendarName: "Work")
        XCTAssertEqual(TodayCalendar.title(of: call, events: [allDay]), "Zoom Meeting", "all-day events never name")
    }

    func testBarsSitOnTheStripInTwoRowsAtMost() {
        let start = mondayUs(9, 0)
        let end = mondayUs(17, 0)
        let overlapping = events + [event("x", "Lunch", (13, 15), (14, 0)), event("y", "Third", (13, 20), (13, 40))]
        let bars = TodayCalendar.bars(overlapping, startUs: start, endUs: end)
        XCTAssertEqual(bars.map(\.title), ["Stand-up", "Team sync", "Lunch", "Investor update"],
                       "earliest first; one needing a third row is left off")
        XCTAssertEqual(bars.map(\.lane), [0, 0, 1, 0])
        let sync = bars[1]
        XCTAssertEqual(sync.x, 0.5, accuracy: 0.0001, "1 PM is halfway through 9 AM to 5 PM")
        XCTAssertEqual(sync.width, 0.5 / 8, accuracy: 0.0001)
        XCTAssertTrue(TodayCalendar.bars(overlapping, startUs: end, endUs: start).isEmpty)
        let outside = TodayCalendar.bars([event("late", "Dinner", (19, 0), (20, 0))], startUs: start, endUs: end)
        XCTAssertTrue(outside.isEmpty, "an event outside the strip has no bar")
    }

    func testTheStripWidensToTheDaysEventsWithinTheDay() throws {
        let overview = try UnderstandingFixture.overview()
        let strip = try XCTUnwrap(overview.strip)
        let span = TodayCalendar.span(strip: strip, events: events, dayStartUs: overview.dayStartUs,
                                      dayEndUs: overview.dayEndUs, calendar: SampleDay.calendar)
        XCTAssertEqual(span.startUs, strip.startUs, "the sessions already start at 9 AM")
        XCTAssertEqual(span.endUs, mondayUs(17, 0), "the 4 PM update widens it to 5 PM")
        let layout = try XCTUnwrap(DayStripLayout(overview: overview, calendar: SampleDay.calendar, span: span))
        XCTAssertEqual(layout.endUs, mondayUs(17, 0))
        XCTAssertEqual(layout.nothingSaved.last?.endUs, overview.nowUs, "what is still to come is not empty time")
    }

    func testTheModelReadsTheCalendarOnlyWhenItMayAndDropsItWhenItIsTakenBack() async throws {
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(try UnderstandingFixture.overview())
        for (access, count) in [(CalendarAccess.allowed, 3), (.denied, 0), (.notAsked, 0)] {
            let model = OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now,
                                          calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                          now: { SampleDay.now }, deletions: MemoryDeletionSignal(),
                                          calendarReader: FixtureCalendar(access: access, events: events))
            await model.reload()
            XCTAssertEqual(model.calendarAccess, access)
            XCTAssertEqual(model.events.count, count, "\(access)")
            let review = try XCTUnwrap(model.blocks.first { $0.kind == .meetings })
            XCTAssertEqual(model.title(of: review), access == .allowed ? "Team sync" : "Weekly design review")
        }
    }

    func testTheFirstDayOffersTheCalendarOnce() async throws {
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(try UnderstandingFixture.overview().with(blocks: []).with(now: .nothing))
        let offers = MemoryKeyValueStore()
        func model(_ access: CalendarAccess) -> OverviewViewModel {
            OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now, calendar: SampleDay.calendar,
                              healthLoader: { SampleDay.receipt() }, now: { SampleDay.now },
                              deletions: MemoryDeletionSignal(), savedBefore: { _ in false },
                              calendarReader: FixtureCalendar(access: access), offers: offers)
        }
        let first = model(.notAsked)
        await first.reload()
        XCTAssertTrue(first.showsFirstDay)
        XCTAssertTrue(first.showsCalendarOffer)
        let allowed = model(.allowed)
        await allowed.reload()
        XCTAssertFalse(allowed.showsCalendarOffer, "never once macOS was asked")
        first.calendarOffered()
        XCTAssertFalse(first.showsCalendarOffer)
        let again = model(.notAsked)
        await again.reload()
        XCTAssertFalse(again.showsCalendarOffer, "offered once, never again")
        XCTAssertNotNil(offers.data(forKey: OverviewViewModel.calendarOfferKey))
    }

    func testWithoutACalendarReaderTodayNeverOffersIt() async throws {
        let understanding = ScriptedUnderstanding()
        await understanding.setOverview(try UnderstandingFixture.overview().with(blocks: []).with(now: .nothing))
        let model = OverviewViewModel(understanding: understanding, selectedDate: SampleDay.now,
                                      calendar: SampleDay.calendar, healthLoader: { SampleDay.receipt() },
                                      now: { SampleDay.now }, deletions: MemoryDeletionSignal(),
                                      savedBefore: { _ in false }, offers: MemoryKeyValueStore())
        await model.reload()
        XCTAssertTrue(model.showsFirstDay)
        XCTAssertFalse(model.showsCalendarOffer)
        XCTAssertTrue(model.events.isEmpty)
    }
}
