import XCTest
@testable import OnboardingKit

/// What Welcome's demo shows when: the script alone decides, so these hold
/// the timing a person sees.
final class WelcomeDemoScriptTests: XCTestCase {
    private typealias Script = WelcomeDemoScript

    func testTheTimingsAreUnchanged() {
        // SPEC 7.3: the loop keeps its script and timings.
        XCTAssertEqual(Script.length(of: .ask), 6)
        XCTAssertEqual(Script.length(of: .today), 5.4)
        XCTAssertEqual(Script.length(of: .ai), 6)
        XCTAssertEqual(Script.fadeOut, 0.3)
        XCTAssertEqual(Script.cycle, 17.4, accuracy: 0.0001)
        XCTAssertEqual(Script.keyPresses, [0.7, 1.0])
        XCTAssertEqual(Script.sessionTimes, [0.45, 0.65, 0.85, 1.05, 1.25])
        XCTAssertEqual(Script.sessionCardAt, 1.75)
    }

    func testTheDayUsesTheLegendsThreeKindsInTheWindowsColours() {
        // Documents, Code and Calls, coloured as the window colours them:
        // no amber, no red, no second green (SPEC 2.14, 7.3).
        XCTAssertEqual(OnboardingCopy.Demo.legend, ["Documents", "Code", "Calls"])
        XCTAssertEqual(OnboardingPalette.demoKinds.count, OnboardingCopy.Demo.legend.count)
        XCTAssertEqual(OnboardingPalette.demoKinds, [0xEB6834, 0x2A78D6, 0xE87BA4])
        for retired: UInt32 in [0xEDA100, 0xE34948, 0x008300] {
            XCTAssertFalse(OnboardingPalette.demoKinds.contains(retired), String(format: "%06X", retired))
        }
        XCTAssertEqual(Set(Script.day.map(\.kind)), Set(0..<OnboardingCopy.Demo.legend.count), "every kind shows")
    }

    func testUnderReduceMotionEachMomentShowsWholeForSixSecondsThenTheNext() {
        XCTAssertEqual(Script.stillMomentLength, 6)
        XCTAssertEqual(Script.stillFrame(at: 0), Script.finalFrame(.ask))
        XCTAssertEqual(Script.stillFrame(at: 5.9), Script.finalFrame(.ask))
        XCTAssertEqual(Script.stillFrame(at: 6), Script.finalFrame(.today))
        XCTAssertEqual(Script.stillFrame(at: 12.5), Script.finalFrame(.ai))
        XCTAssertEqual(Script.stillFrame(at: 18), Script.finalFrame(.ask), "it loops")
        for second in 0..<40 {
            let frame = Script.stillFrame(at: Double(second) / 2)
            XCTAssertEqual(frame, Script.finalFrame(frame.moment), "nothing inside a moment moves")
        }
    }

    func testTheDemoPausesWhileItIsReadOrUnseenAndPicksUpWhereItWas() {
        var playback = WelcomeDemoPlayback()
        XCTAssertTrue(playback.isPlaying)
        playback.advance(by: 2)
        XCTAssertEqual(playback.elapsed, 2)
        // The pointer over it: it holds still so it can be read.
        playback.hovering = true
        XCTAssertFalse(playback.isPlaying)
        playback.advance(by: 5)
        XCTAssertEqual(playback.elapsed, 2, "paused time doesn't count")
        playback.hovering = false
        // Setup's window behind another: nothing runs.
        playback.windowIsKey = false
        XCTAssertFalse(playback.isPlaying)
        playback.advance(by: 5)
        playback.windowIsKey = true
        // Past Welcome: stopped.
        playback.onWelcome = false
        XCTAssertFalse(playback.isPlaying)
        playback.advance(by: 5)
        playback.onWelcome = true
        playback.advance(by: 0.5)
        XCTAssertEqual(playback.elapsed, 2.5, accuracy: 0.0001)
        XCTAssertEqual(playback.frame(presses: 2, reduceMotion: false), Script.frame(at: 2.5))
        XCTAssertEqual(playback.frame(presses: 2, reduceMotion: true), Script.finalFrame(.ask))
        // Time never runs backwards.
        playback.advance(by: -3)
        XCTAssertEqual(playback.elapsed, 2.5, accuracy: 0.0001)
    }

    func testThreeMomentsPlayInOrderAndLoop() {
        XCTAssertEqual(DemoMoment.allCases, [.ask, .today, .ai])
        XCTAssertEqual(Script.cycle, Script.length(of: .ask) + Script.length(of: .today) + Script.length(of: .ai))
        XCTAssertEqual(Script.frame(at: 0).moment, .ask)
        XCTAssertEqual(Script.frame(at: Script.length(of: .ask) + 0.1).moment, .today)
        XCTAssertEqual(Script.frame(at: Script.length(of: .ask) + Script.length(of: .today) + 0.1).moment, .ai)
        XCTAssertEqual(Script.frame(at: Script.cycle + 1), Script.frame(at: 1), "it wraps")
        XCTAssertEqual(Script.frame(at: -1), Script.frame(at: Script.cycle - 1))
        for moment in DemoMoment.allCases {
            XCTAssertLessThanOrEqual(Script.length(of: moment), 6, "each moment is short")
        }
    }

    func testAskOpensTheWayThePersonOpensItThenAnswersWithItsSource() {
        // First the message being written, alone, for over half a second.
        for tenth in 0...6 {
            let writing = Script.frame(at: Double(tenth) / 10)
            XCTAssertFalse(writing.keyDown || writing.askOpen, "the message shows first, at \(tenth)")
        }
        // Then the key: twice for Shift twice, once for any other key.
        XCTAssertTrue(Script.frame(at: 0.75).keyDown)
        XCTAssertFalse(Script.frame(at: 0.9).keyDown)
        XCTAssertTrue(Script.frame(at: 1.05).keyDown)
        XCTAssertFalse(Script.frame(at: 1.05, presses: 1).keyDown)
        XCTAssertFalse(Script.frame(at: 1.05).askOpen, "the key comes before Ask")
        // Then Ask, the question typed, the answer, its source.
        let opened = Script.frame(at: 1.3)
        XCTAssertTrue(opened.askOpen)
        XCTAssertEqual(opened.typedQuestion, 0)
        let typing = Script.frame(at: 2)
        XCTAssertGreaterThan(typing.typedQuestion, 0)
        XCTAssertLessThan(typing.typedQuestion, OnboardingCopy.Demo.askQuestion.count)
        XCTAssertFalse(typing.showsAnswer)
        let answered = Script.frame(at: 2.9)
        XCTAssertEqual(answered.typedQuestion, OnboardingCopy.Demo.askQuestion.count)
        XCTAssertTrue(answered.showsAnswer)
        XCTAssertFalse(answered.showsSource)
        XCTAssertTrue(Script.frame(at: 3.3).showsSource)
        XCTAssertTrue(Script.frame(at: 3.3).isShown)
        XCTAssertFalse(Script.frame(at: Script.length(of: .ask) - 0.1).isShown, "it fades before the next")
    }

    func testEachMomentHoldsItsEndLongEnoughToRead() {
        // From the last thing arriving to the fade: the answer and its
        // source, the session card, the reply.
        let fade = Script.fadeOut
        XCTAssertGreaterThanOrEqual(Script.length(of: .ask) - fade - Script.answerAt, 2.5)
        XCTAssertGreaterThanOrEqual(Script.length(of: .ask) - fade - Script.sourceAt, 2.5)
        XCTAssertGreaterThanOrEqual(Script.length(of: .today) - fade - Script.sessionCardAt, 2.5)
        XCTAssertGreaterThanOrEqual(Script.length(of: .ai) - fade - Script.replyAt, 2.5)
    }

    func testTodayFillsInTheDayThenShowsWhatIsGoingOnNow() {
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
        let start = Script.length(of: .ask) + Script.length(of: .today)
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
