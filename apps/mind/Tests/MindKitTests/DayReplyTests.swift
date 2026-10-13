import XCTest
@testable import MindKit

/// The day's reply states only lengths the facts state. The sentences below
/// are ones the model wrote for made-up days.
final class DayReplyTests: XCTestCase {
    /// The account's prompt for the reviewers' full day: sessions with clock
    /// times, when the day began and ended, and the searches.
    private let shown = Prompts.day(DayInput(userName: "Sam", facts: [
        "Active at the computer: 5 h 30 min.",
        "First activity 09:12, last 17:40.",
        "By kind of work: Code 2 h 15 min, Writing 1 h 10 min, Communication 50 min.",
        "Searches (2): \"swiftui list selection\", \"sqlite fts5 bm25\".",
    ].joined(separator: "\n"), episodes: [
        "09:40–10:10 Invoice list in SwiftUI: You were building the invoice list view.",
        "14:02–14:31 Pricing the Team plan: You were settling the Team plan price before the beta.",
    ], propositions: []))

    private let facts = [
        "Active at the computer: 5 h 30 min.",
        "First activity 09:12, last 17:40.",
        "By kind of work: Code 2 h 15 min, Writing 1 h 10 min, Communication 50 min.",
        "By app: Xcode 2 h 15 min, Notes 1 h 10 min, Slack 50 min.",
        "Searches (2): \"swiftui list selection\", \"sqlite fts5 bm25\".",
    ]

    func testALengthIsReadInDigitsOrInWords() {
        let lengths = [
            "5 h 30 min": [330], "5h 30m": [330], "1 hour and 5 minutes": [65], "35 min": [35],
            "two hours and fifteen minutes": [135], "an hour and thirty-one minutes": [91],
            "one hour and fifty minutes": [110], "forty-eight minutes": [48], "ninety minutes": [90],
            "half an hour": [30], "1.5 hours": [90], "a few minutes": [0], "for the first 2 hours of the day": [120],
            "You spent your day working on the grant proposal.": [0], "You spent the day planning your trip.": [0],
            "for the first half of the day": [0],
            "1 minute and 31 seconds": [1, -1],
        ]
        for (text, minutes) in lengths {
            XCTAssertEqual(DayReply.minutes(in: text), minutes, text)
        }
        // Clock times, counts and "am" are not lengths.
        for text in ["From 9:40 to 10:40 AM you built the invoice list view.", "At 5:40 PM you settled the price.",
                     "You started the day by building the invoice list view.",
                     "You started at 9:12 am.", "You worked on two sessions and looked up 3 things.", "I am here."] {
            XCTAssertEqual(DayReply.minutes(in: text), [], text)
        }
    }

    func testAnAccountThatStatesALengthIsAskedForAgain() throws {
        // Written with no length in view, the model worked these out from
        // clock times or made them up.
        for (headline, narrative) in [
            ("Work on the invoice list and Team plan",
             "You worked on the invoice list in SwiftUI for 20 minutes, then settled the Team plan price for 29 minutes. You searched for 'swiftui list selection'."),
            ("Beta announcement", "You drafted the beta announcement in Notes. You paused for a minute to review your draft."),
            ("You worked on the invoice list view for 2 hours and 15 minutes in Xcode.", "You built the invoice list view."),
        ] {
            XCTAssertNil(DayReply.account(headline: headline, narrative: narrative, shown: shown), narrative)
        }
        let untouched = "You built the Release 2.1 notes. Then you settled the Team plan price before the beta."
        let account = try XCTUnwrap(DayReply.account(headline: "The release notes and the Team plan", narrative: untouched, shown: shown))
        XCTAssertEqual(account.headline, "The release notes and the Team plan")
        XCTAssertEqual(account.narrative, untouched)
    }

    func testAnAccountMaySayALengthItsSessionsOrSearchesHold() throws {
        let shown = Prompts.day(DayInput(userName: "Sam", facts: "Searches (1): \"10 minute timer\".", episodes: [
            "08:30–08:45 Daily 15 min standup: You were on the standup call.",
        ], propositions: []))
        XCTAssertNotNil(DayReply.account(headline: "The daily 15 min standup",
                                         narrative: "You were on the daily 15 min standup. You looked up '10 minute timer'.", shown: shown))
        XCTAssertNil(DayReply.account(headline: "The daily standup", narrative: "You were on the standup for 15 minutes and 2 seconds.", shown: shown))
    }

    func testTheAccountSaysEachSentenceOnce() throws {
        let account = try XCTUnwrap(DayReply.account(
            headline: "Beta announcement",
            narrative: "You drafted the beta announcement in Notes. You worked on the beta announcement in Notes. "
                + "you worked on the beta announcement in Notes. You worked on the beta announcement in Notes", shown: shown))
        XCTAssertEqual(account.narrative, "You drafted the beta announcement in Notes. You worked on the beta announcement in Notes.")
    }

    func testAnInsightStatesOnlyLengthsTheFactsState() {
        XCTAssertEqual(DayReply.insights([
            "you were active at the computer for 5 hours and 30 minutes.",
            "You were active at the computer for one hour and fifty minutes.",
            "You spent 2 hours and 15 minutes coding in Xcode, 1 hour and 10 minutes writing in Notes, and 50 minutes in Slack.",
            "You searched for 'sqlite fts5 bm25' for 1 minute and 31 seconds.",
            "Your first activity was at 09:12 and your last was at 17:40.",
        ], facts: facts), [
            "You were active at the computer for 5 hours and 30 minutes.",
            "You spent 2 hours and 15 minutes coding in Xcode, 1 hour and 10 minutes writing in Notes, and 50 minutes in Slack.",
            "Your first activity was at 09:12 and your last was at 17:40.",
        ])
    }

    func testASentenceStartsWithACapitalYou() {
        XCTAssertEqual(DayReply.capitalizingYou("you drafted the beta announcement in Notes. you looked up your notes."),
                       "You drafted the beta announcement in Notes. You looked up your notes.")
        XCTAssertEqual(DayReply.capitalizingYou("your first activity was at 13:10."), "Your first activity was at 13:10.")
    }
}
