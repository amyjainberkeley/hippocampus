// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import HippocampusKit

/// Ask's "When did I last meet with …?" from the calendar's titles and times
/// (SPEC-DELTA 5). Made-up meetings, a fixed clock and a fake store: nothing
/// here touches EventKit or the real system's permissions.
final class CalendarQuestionTests: XCTestCase {
    /// Thursday, October 15, 2026, 4:00 PM in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_792_105_200)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")

    private func meeting(_ title: String, daysAgo: Int, hour: Int, minutes: Int = 30, allDay: Bool = false)
        -> CalendarMeeting {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        let start = calendar.date(byAdding: .hour, value: hour, to: day)!
        return CalendarMeeting(title: title, start: start,
                               end: start.addingTimeInterval(TimeInterval(allDay ? 86_400 : minutes * 60)),
                               isAllDay: allDay)
    }

    // MARK: Which questions

    func testTheWaysPeopleAskAreRecognized() {
        let asked: [(String, String, CalendarQuestion.Link)] = [
            ("When did I last meet with Mira?", "Mira", .with),
            ("when did i last meet mira", "mira", .with),
            ("When did I last meet up with Teo and Noor?", "Teo and Noor", .with),
            ("When did I meet Mira last?", "Mira", .with),
            ("When was the last time I met with the design team?", "the design team", .with),
            ("When’s the last time I met Mira", "Mira", .with),
            ("When did I last have a meeting with Northwind?", "Northwind", .with),
            ("When did I last have a call about pricing?", "pricing", .about),
            ("When was my last meeting about Q4 planning?", "Q4 planning", .about),
            ("When’s my latest call with Teo?", "Teo", .with),
            ("Last meeting with Mira", "Mira", .with),
            ("my most recent call with Trailhead", "Trailhead", .with),
        ]
        for (text, subject, link) in asked {
            let question = CalendarQuestion(text)
            XCTAssertEqual(question?.subject, subject, text)
            XCTAssertEqual(question?.link, link, text)
        }
    }

    func testOtherQuestionsAreLeftToAsk() {
        for text in [
            "", "When did I last meet", "When did I last open Figma?", "What did I work on today?",
            "meeting notes", "Who did I meet yesterday?", "When did I last see the pricing page?",
            "When did I last meet with one two three four five six seven?",
        ] {
            XCTAssertNil(CalendarQuestion(text), text)
        }
    }

    // MARK: Which meeting

    func testTheLatestMatchingMeetingBeforeNowIsTheAnswer() throws {
        let question = try XCTUnwrap(CalendarQuestion("When did I last meet with Mira?"))
        let meetings = [
            meeting("Pricing review with Mira", daysAgo: 9, hour: 10),
            meeting("Mira / Sam 1:1", daysAgo: 2, hour: 14),
            meeting("Team sync", daysAgo: 0, hour: 9),
            meeting("Mira's offsite", daysAgo: 1, hour: 0, allDay: true),
            meeting("Mira planning", daysAgo: -1, hour: 11),
        ]
        let last = question.lastMeeting(in: meetings, before: now)
        XCTAssertEqual(last?.title, "Mira / Sam 1:1",
                       "never an all-day event, never one that hasn't started, never another name")
    }

    func testNamesMatchInAnyCaseWithOrWithoutAccentsAndAsWholeWords() throws {
        let zoe = try XCTUnwrap(CalendarQuestion("when did I last meet zoe"))
        XCTAssertEqual(zoe.lastMeeting(in: [meeting("Coffee with Zoë", daysAgo: 3, hour: 9)], before: now)?.title,
                       "Coffee with Zoë")
        let teo = try XCTUnwrap(CalendarQuestion("When did I last meet Teo?"))
        XCTAssertNil(teo.lastMeeting(in: [meeting("Teodora intro", daysAgo: 3, hour: 9)], before: now),
                     "a name inside a longer word isn't that name")
        let investors = try XCTUnwrap(CalendarQuestion("When was my last meeting with investors?"))
        XCTAssertEqual(investors.lastMeeting(in: [meeting("Investor update", daysAgo: 4, hour: 16)], before: now)?
            .title, "Investor update")
        let team = try XCTUnwrap(CalendarQuestion("When did I last meet the design team?"))
        XCTAssertEqual(team.lastMeeting(in: [meeting("Design team crit", daysAgo: 5, hour: 15)], before: now)?
            .title, "Design team crit", "small words like “the” don't have to be in the title")
    }

    // MARK: The answer

    func testTheAnswerSaysWhenInPlainWords() throws {
        let question = try XCTUnwrap(CalendarQuestion("When did I last meet with Mira?"))
        func answer(_ meeting: CalendarMeeting) throws -> String {
            try XCTUnwrap(question.answer(from: [meeting], now: now, calendar: calendar, locale: locale))
        }

        let today = try answer(meeting("Pricing review with Mira", daysAgo: 0, hour: 14))
        XCTAssertTrue(today.hasPrefix("Your calendar shows you last met with Mira today, 2:00"), today)
        XCTAssertTrue(today.contains("2:30"), today)
        XCTAssertTrue(today.hasSuffix(", in “Pricing review with Mira”."), today)

        let yesterday = try answer(meeting("Mira 1:1", daysAgo: 1, hour: 9))
        XCTAssertTrue(yesterday.hasPrefix("Your calendar shows you last met with Mira yesterday, 9:00"), yesterday)

        let thisYear = try answer(meeting("Mira 1:1", daysAgo: 2, hour: 11))
        XCTAssertTrue(thisYear.hasPrefix("Your calendar shows you last met with Mira on Tuesday, October 13, 11:00"),
                      thisYear)

        let lastYear = try answer(meeting("Mira 1:1", daysAgo: 300, hour: 11))
        XCTAssertTrue(lastYear.contains(" on December 19, 2025, 11:00"), lastYear)
    }

    func testTheAnswerSaysYourForMy() throws {
        let question = try XCTUnwrap(CalendarQuestion("When did I last meet my manager?"))
        let text = try XCTUnwrap(question.answer(from: [meeting("1:1 with my manager", daysAgo: 2, hour: 10)],
                                                 now: now, calendar: calendar, locale: locale))
        XCTAssertTrue(text.hasPrefix("Your calendar shows you last met with your manager on "), text)
    }

    func testNoMatchingMeetingLeavesTheQuestionToMemory() throws {
        let question = try XCTUnwrap(CalendarQuestion("When did I last meet with Mira?"))
        XCTAssertNil(question.answer(from: [meeting("Team sync", daysAgo: 1, hour: 9)], now: now,
                                     calendar: calendar, locale: locale))
    }

    // MARK: When the calendar answers

    private func answerer(_ store: FakeCalendarAccess, on: Bool?, demo: Bool = false) -> CalendarAnswerer {
        let now = now
        return CalendarAnswerer(store: store, setting: .inMemory(on), now: { now }, demoMemory: { demo },
                                calendar: calendar, locale: locale)
    }

    func testTheCalendarAnswersOnlyWhileItIsOnAndAllowed() async {
        let meetings = [meeting("Pricing review with Mira", daysAgo: 2, hour: 14)]
        let question = "When did I last meet with Mira?"

        let allowed = FakeCalendarAccess(.fullAccess, meetings: meetings)
        let answer = await answerer(allowed, on: true).answer(question)
        XCTAssertNotNil(answer)
        XCTAssertEqual(allowed.readIntervals.map(\.duration), [CalendarAnswerer.lookBack], "it looks back a year")
        XCTAssertEqual(allowed.readIntervals.first?.end, now)

        for (permission, on) in [(CalendarPermission.fullAccess, nil), (.fullAccess, false), (.denied, true),
                                 (.addOnly, true), (.restricted, true), (.notDetermined, true)] {
            let store = FakeCalendarAccess(permission, meetings: meetings)
            let none = await answerer(store, on: on).answer(question)
            XCTAssertNil(none, "\(permission), \(String(describing: on))")
            XCTAssertEqual(store.readCount, 0, "nothing is read: \(permission), \(String(describing: on))")
            XCTAssertEqual(store.requestCount, 0, "Ask never asks macOS")
        }
    }

    func testDemoMemoryKeepsThePersonsCalendarOutOfAsk() async {
        let store = FakeCalendarAccess(.fullAccess, meetings: [meeting("Pricing review with Mira", daysAgo: 2, hour: 14)])
        let answer = await answerer(store, on: true, demo: true).answer("When did I last meet with Mira?")
        XCTAssertNil(answer)
        XCTAssertEqual(store.readCount, 0)
    }

    func testOtherQuestionsNeverReadTheCalendar() async {
        let store = FakeCalendarAccess(.fullAccess, meetings: [meeting("Team sync", daysAgo: 0, hour: 9)])
        let answer = await answerer(store, on: true).answer("What did I work on today?")
        XCTAssertNil(answer)
        XCTAssertEqual(store.readCount, 0)
    }
}
