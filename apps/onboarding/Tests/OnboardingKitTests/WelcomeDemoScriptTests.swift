import XCTest
@testable import OnboardingKit

/// What Welcome's demo shows when: the script alone decides, so these hold
/// the timing a person sees.
final class WelcomeDemoScriptTests: XCTestCase {
    private typealias Script = WelcomeDemoScript

    func testThreeMomentsPlayInOrderAndLoop() {
        XCTAssertEqual(DemoMoment.allCases, [.ask, .overview, .ai])
        XCTAssertEqual(Script.cycle, Script.length(of: .ask) + Script.length(of: .overview) + Script.length(of: .ai))
        XCTAssertEqual(Script.frame(at: 0).moment, .ask)
        XCTAssertEqual(Script.frame(at: Script.length(of: .ask) + 0.1).moment, .overview)
        XCTAssertEqual(Script.frame(at: Script.length(of: .ask) + Script.length(of: .overview) + 0.1).moment, .ai)
        XCTAssertEqual(Script.frame(at: Script.cycle + 1), Script.frame(at: 1), "it wraps")
        XCTAssertEqual(Script.frame(at: -1), Script.frame(at: Script.cycle - 1))
        for moment in DemoMoment.allCases {
            XCTAssertLessThanOrEqual(Script.length(of: moment), 6, "each moment is short")
        }
    }

    func testAskOpensTheWayThePersonOpensItThenAnswersWithItsSource() {
        // The key first: twice for Shift twice, once for any other key.
        XCTAssertFalse(Script.frame(at: 0).keyDown)
        XCTAssertTrue(Script.frame(at: 0.15).keyDown)
        XCTAssertFalse(Script.frame(at: 0.3).keyDown)
        XCTAssertTrue(Script.frame(at: 0.45).keyDown)
        XCTAssertFalse(Script.frame(at: 0.45, presses: 1).keyDown)
        XCTAssertFalse(Script.frame(at: 0.45).askOpen, "the key comes before Ask")
        // Then Ask, the question typed, the answer, its source.
        let opened = Script.frame(at: 0.7)
        XCTAssertTrue(opened.askOpen)
        XCTAssertEqual(opened.typedQuestion, 0)
        let typing = Script.frame(at: 1.5)
        XCTAssertGreaterThan(typing.typedQuestion, 0)
        XCTAssertLessThan(typing.typedQuestion, OnboardingCopy.Demo.askQuestion.count)
        XCTAssertFalse(typing.showsAnswer)
        let answered = Script.frame(at: 2.5)
        XCTAssertEqual(answered.typedQuestion, OnboardingCopy.Demo.askQuestion.count)
        XCTAssertTrue(answered.showsAnswer)
        XCTAssertFalse(answered.showsSource)
        XCTAssertTrue(Script.frame(at: 3).showsSource)
        XCTAssertTrue(Script.frame(at: 3).isShown)
        XCTAssertFalse(Script.frame(at: Script.length(of: .ask) - 0.1).isShown, "it fades before the next")
    }

    func testOverviewFillsInTheDayThenShowsTheSessionItEndsOn() {
        let start = Script.length(of: .ask)
        XCTAssertEqual(Script.frame(at: start).sessionsShown, 0)
        var shown: [Int] = []
        for tenth in 0...20 {
            shown.append(Script.frame(at: start + Double(tenth) / 10).sessionsShown)
        }
        XCTAssertEqual(shown, shown.sorted(), "sessions only arrive")
        XCTAssertEqual(shown.last, Script.day.count)
        XCTAssertFalse(Script.frame(at: start + 1.5).showsSessionCard)
        XCTAssertTrue(Script.frame(at: start + 2).showsSessionCard)
        // The day ends on the Team pricing session, 2:12 to 2:36 PM.
        let last = Script.day.last
        XCTAssertEqual(last?.start ?? 0, 14.2, accuracy: 0.001)
        XCTAssertEqual(last?.end ?? 0, 14.6, accuracy: 0.001)
        for session in Script.day {
            XCTAssertTrue(Script.dayHours.contains(session.start) && Script.dayHours.contains(session.end))
            XCTAssertLessThan(session.start, session.end)
            XCTAssertLessThan(session.kind, OnboardingCopy.Demo.legend.count)
        }
    }

    func testYourAIStartsWithWhatHippocampusSharesThenAnswers() {
        let start = Script.length(of: .ask) + Script.length(of: .overview)
        XCTAssertEqual(Script.frame(at: start).contextLinesShown, 0)
        XCTAssertEqual(Script.frame(at: start + 1).contextLinesShown, OnboardingCopy.Demo.aiContextLines.count)
        XCTAssertEqual(Script.frame(at: start + 1).typedPrompt, 0, "the context comes first")
        XCTAssertGreaterThan(Script.frame(at: start + 2).typedPrompt, 0)
        XCTAssertFalse(Script.frame(at: start + 2.5).showsReply)
        let replied = Script.frame(at: start + 3)
        XCTAssertTrue(replied.showsReply)
        XCTAssertEqual(replied.typedPrompt, OnboardingCopy.Demo.aiPrompt.count)
    }

    func testAMomentWholeShowsEverything() {
        for moment in DemoMoment.allCases {
            let whole = Script.finalFrame(moment)
            XCTAssertEqual(whole.moment, moment)
            XCTAssertTrue(whole.isShown)
            XCTAssertTrue(whole.askOpen)
            XCTAssertFalse(whole.keyDown)
            XCTAssertEqual(whole.typedQuestion, OnboardingCopy.Demo.askQuestion.count)
            XCTAssertTrue(whole.showsAnswer && whole.showsSource && whole.showsSessionCard && whole.showsReply)
            XCTAssertEqual(whole.sessionsShown, Script.day.count)
            XCTAssertEqual(whole.contextLinesShown, OnboardingCopy.Demo.aiContextLines.count)
            XCTAssertEqual(whole.typedPrompt, OnboardingCopy.Demo.aiPrompt.count)
        }
    }

    func testTypingKeepsAnEvenPace() {
        let count = 20
        var last = 0
        for step in 0...40 {
            let typed = Script.typed(count, during: 1...2, at: 0.9 + Double(step) / 30)
            XCTAssertGreaterThanOrEqual(typed, last)
            XCTAssertLessThanOrEqual(typed - last, 2, "no jumps")
            last = typed
        }
        XCTAssertEqual(Script.typed(count, during: 1...2, at: 1), 0)
        XCTAssertEqual(Script.typed(count, during: 1...2, at: 2), count)
    }
}
