import XCTest
@testable import RecallUIKit

final class UnderstandingFormatTests: XCTestCase {
    private let pacific = TimeZone(secondsFromGMT: -25_200)!
    private let us = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "en_GB")
    /// 09:05:10 and 14:36:40 on 2026-10-12 in UTC−7, as in the overview sample.
    private let morning: Int64 = 1_791_821_110_000_000
    private let afternoon: Int64 = 1_791_841_000_000_000

    /// ICU may put a narrow no-break space before AM and PM.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The system writes the morning hour with or without a leading zero; either is 24-hour.
    private func twentyFourHour(_ text: String) -> Bool {
        text == "9:05" || text == "09:05"
    }

    func testClockTimesFollowThePersonsLocale() {
        XCTAssertEqual(plain(Formatters.clockTime(us: afternoon, locale: us, timeZone: pacific)), "2:36 PM")
        XCTAssertEqual(plain(Formatters.clockTime(us: morning, locale: us, timeZone: pacific)), "9:05 AM")
        XCTAssertEqual(Formatters.clockTime(us: afternoon, locale: uk, timeZone: pacific), "14:36")
        XCTAssertTrue(twentyFourHour(Formatters.clockTime(us: morning, locale: uk, timeZone: pacific)))
    }

    func testDurationsAreHoursAndMinutesRoundedAndNeverUnderAMinute() {
        let minute: Int64 = 60_000_000
        XCTAssertEqual(Formatters.duration(us: 198 * minute, locale: us), "3h 18m")
        XCTAssertEqual(Formatters.duration(us: 45 * minute, locale: us), "45m")
        XCTAssertEqual(Formatters.duration(us: 300 * minute, locale: us), "5h")
        XCTAssertEqual(Formatters.duration(us: 30_000_000, locale: us), "1m")
        XCTAssertEqual(Formatters.duration(us: 0, locale: us), "1m")
        XCTAssertEqual(Formatters.duration(us: 89_000_000, locale: us), "1m")
        XCTAssertEqual(Formatters.duration(us: 90_000_000, locale: us), "2m")
        XCTAssertEqual(Formatters.duration(us: 198 * minute, locale: uk), "3h 18m")
    }

    func testPlaceholdersAreFilledFromTimesAndDurationsForTwelveHourClocks() {
        let fact = TemplateText(template: "Active {active}, {first} to {last}.",
                                times: ["first": morning, "last": afternoon],
                                durations: ["active": 11_880_000_000])
        XCTAssertEqual(plain(fact.text(locale: us, timeZone: pacific)), "Active 3h 18m, 9:05 AM to 2:36 PM.")
    }

    func testPlaceholdersAreFilledFromTimesAndDurationsForTwentyFourHourClocks() {
        let fact = TemplateText(template: "Active {active}, {first} to {last}.",
                                times: ["first": morning, "last": afternoon],
                                durations: ["active": 11_880_000_000])
        let filled = fact.text(locale: uk, timeZone: pacific)
        XCTAssertNotNil(filled.range(of: #"^Active 3h 18m, 0?9:05 to 14:36\.$"#, options: .regularExpression), filled)
        let line = TemplateText(template: "{start}–{end} · Tax rounding tests: You wrote tests.",
                                times: ["start": 1_791_829_955_000_000, "end": 1_791_831_555_000_000])
        XCTAssertEqual(line.text(locale: uk, timeZone: pacific), "11:32–11:59 · Tax rounding tests: You wrote tests.")
    }

    func testBracesAndUnknownPlaceholdersStayAsWritten() {
        let text = TemplateText(template: "Notes on {{braces}} {missing} {Start} {start", times: ["start": morning])
        XCTAssertEqual(text.text(locale: uk, timeZone: pacific), "Notes on {braces} {missing} {Start} {start")
        XCTAssertEqual(TemplateText(template: "You looked up four things.").text(locale: us, timeZone: pacific),
                       "You looked up four things.")
    }

    func testEverySampleSentenceIsFilledCompletely() throws {
        let overview = try UnderstandingFixture.overview()
        let page = try UnderstandingFixture.modelPage()
        let templates = overview.facts.map(\.text) + overview.blocks.flatMap { $0.sentences.map(\.text) }
            + overview.aiKnows.recentWork + page.recentWork
        XCTAssertFalse(templates.isEmpty)
        for template in templates {
            for locale in [us, uk] {
                let text = template.text(locale: locale, timeZone: pacific)
                XCTAssertNil(text.range(of: #"\{[a-z_]+\}"#, options: .regularExpression), text)
            }
        }
    }

    func testWritersAreNamedAsTheCaptionNamesThem() {
        XCTAssertEqual(UserFacingCopy.writtenOnThisMac(by: "apple-foundation-models"),
                       "Written on this Mac by Apple Intelligence")
        XCTAssertEqual(UserFacingCopy.writtenOnThisMac(by: "local-model-7b"), "Written on this Mac by local-model-7b")
        // A model server on this Mac: the agent stores "local:" and the model.
        XCTAssertEqual(UserFacingCopy.writtenOnThisMac(by: "local:qwen3:4b"), "Written on this Mac by qwen3:4b")
        XCTAssertNil(UserFacingCopy.writerName("local:"))
        XCTAssertNil(UserFacingCopy.writtenOnThisMac(by: "measured"))
        XCTAssertNil(UserFacingCopy.writerName(""))
    }

    func testNoModelOnThisMacReadsTheSameAsAnyModelServerProblem() {
        XCTAssertEqual(ModelUnavailableReason(code: "needs_apple_intelligence_or_local_model"), .needsAModel)
        XCTAssertEqual(ModelUnavailableReason(code: "local_server_unreachable"), .needsAModel)
        XCTAssertEqual(ModelUnavailableReason(code: "apple_intelligence_off"), .appleIntelligenceOff)
        XCTAssertEqual(ModelUnavailableReason(code: "something_new"), .notAvailable)
        XCTAssertEqual(UserFacingCopy.Overview.modelLine(.needsAModel),
                       "Summaries need Apple Intelligence or your own model. New sessions are named after their windows.")
        XCTAssertEqual(UserFacingCopy.noAnswer("needs_apple_intelligence_or_local_model"),
                       "Answers need Apple Intelligence or your own model.")
    }
}
