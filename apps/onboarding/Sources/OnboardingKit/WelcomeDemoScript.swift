// SPDX-License-Identifier: Apache-2.0
//
// Welcome's demo, as a script: three moments from the product, played in a
// loop from made-up data (`OnboardingCopy.Demo`). Ask finds a pricing link
// and shows its source; Overview fills in the day; your AI starts a session
// with your recent work. The view draws `frame(at:)` and animates between
// frames; the script alone decides what shows when, so the tests and the
// preview renderer see exactly what plays. Under Reduce Motion the view
// shows each moment whole (`finalFrame`) and only fades between them.

import Foundation

/// The three moments, in the order they play.
public enum DemoMoment: Int, CaseIterable, Sendable {
    case ask
    case overview
    case ai
}

/// What the demo shows at one instant.
public struct DemoFrame: Equatable, Sendable {
    public var moment: DemoMoment
    /// The moment's window is on screen. False while it fades out at the
    /// end of the moment.
    public var isShown: Bool
    /// The key that opens Ask is down: Welcome's keycaps dip, right before
    /// Ask drops in.
    public var keyDown: Bool
    /// Ask has dropped in over the page it is about.
    public var askOpen: Bool
    /// Ask: how much of the question is typed, the answer, its source.
    public var typedQuestion: Int
    public var showsAnswer: Bool
    public var showsSource: Bool
    /// Overview: how many of the day's sessions are on the strip, and the
    /// last session's card.
    public var sessionsShown: Int
    public var showsSessionCard: Bool
    /// Your AI: how many lines from Hippocampus have arrived, how much of
    /// the prompt is typed, the reply.
    public var contextLinesShown: Int
    public var typedPrompt: Int
    public var showsReply: Bool

    public init(
        moment: DemoMoment, isShown: Bool = true, keyDown: Bool = false, askOpen: Bool = false,
        typedQuestion: Int = 0, showsAnswer: Bool = false, showsSource: Bool = false,
        sessionsShown: Int = 0, showsSessionCard: Bool = false,
        contextLinesShown: Int = 0, typedPrompt: Int = 0, showsReply: Bool = false
    ) {
        self.moment = moment
        self.isShown = isShown
        self.keyDown = keyDown
        self.askOpen = askOpen
        self.typedQuestion = typedQuestion
        self.showsAnswer = showsAnswer
        self.showsSource = showsSource
        self.sessionsShown = sessionsShown
        self.showsSessionCard = showsSessionCard
        self.contextLinesShown = contextLinesShown
        self.typedPrompt = typedPrompt
        self.showsReply = showsReply
    }
}

/// One session on the demo's day strip: when it ran, in hours of the day,
/// and its kind, by the legend's order.
public struct DemoSession: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let kind: Int
}

public enum WelcomeDemoScript {
    /// How long each moment plays, in seconds.
    public static func length(of moment: DemoMoment) -> TimeInterval {
        switch moment {
        case .ask: 5.2
        case .overview: 4.8
        case .ai: 5.4
        }
    }

    /// Each moment fades out over its last this many seconds.
    public static let fadeOut: TimeInterval = 0.3

    /// One loop of all three.
    public static var cycle: TimeInterval {
        DemoMoment.allCases.reduce(0) { $0 + length(of: $1) }
    }

    /// The day the Overview moment fills in, 9 AM to 3 PM: writing, code,
    /// a meeting, code again, and the Team pricing session the card names.
    public static let day: [DemoSession] = [
        DemoSession(start: 9.1, end: 10.3, kind: 0),
        DemoSession(start: 10.5, end: 11.8, kind: 1),
        DemoSession(start: 13.1, end: 13.55, kind: 2),
        DemoSession(start: 13.7, end: 14.05, kind: 1),
        DemoSession(start: 14.2, end: 14.6, kind: 0),
    ]
    /// The strip's hours, start and end.
    public static let dayHours: ClosedRange<Double> = 9...15

    /// Ask opens as the person opens it: the key first (twice for Shift
    /// twice), then the panel. Each press holds the key this long.
    public static let keyPresses: [TimeInterval] = [0.1, 0.4]
    public static let keyHold: TimeInterval = 0.12
    static let askOpensAt: TimeInterval = 0.6
    static let questionTyping: ClosedRange<TimeInterval> = 0.95...2.05
    static let answerAt: TimeInterval = 2.4
    static let sourceAt: TimeInterval = 2.8
    static let sessionTimes: [TimeInterval] = [0.45, 0.65, 0.85, 1.05, 1.25]
    static let sessionCardAt: TimeInterval = 1.75
    static let contextLineTimes: [TimeInterval] = [0.55, 0.8]
    static let promptTyping: ClosedRange<TimeInterval> = 1.5...2.3
    static let replyAt: TimeInterval = 2.75

    /// The frame `time` seconds into the loop. Any time works: it wraps.
    /// `presses` is how many times the key that opens Ask is pressed: two
    /// for Shift twice, one for any other key.
    public static func frame(at time: TimeInterval, presses: Int = 2) -> DemoFrame {
        var local = time.truncatingRemainder(dividingBy: cycle)
        if local < 0 { local += cycle }
        for moment in DemoMoment.allCases {
            let length = length(of: moment)
            if local < length || moment == DemoMoment.allCases.last {
                return frame(moment, at: min(local, length), presses: presses)
            }
            local -= length
        }
        return finalFrame(.ask)
    }

    /// A moment whole, everything shown: Reduce Motion and the renders.
    public static func finalFrame(_ moment: DemoMoment) -> DemoFrame {
        DemoFrame(
            moment: moment, askOpen: true,
            typedQuestion: OnboardingCopy.Demo.askQuestion.count, showsAnswer: true, showsSource: true,
            sessionsShown: day.count, showsSessionCard: true,
            contextLinesShown: OnboardingCopy.Demo.aiContextLines.count,
            typedPrompt: OnboardingCopy.Demo.aiPrompt.count, showsReply: true
        )
    }

    /// The moment `t` seconds after it began.
    public static func frame(_ moment: DemoMoment, at t: TimeInterval, presses: Int = 2) -> DemoFrame {
        var frame = DemoFrame(moment: moment, isShown: t < length(of: moment) - fadeOut)
        switch moment {
        case .ask:
            frame.askOpen = t >= askOpensAt
            frame.keyDown = keyPresses.prefix(max(1, presses)).contains { t >= $0 && t < $0 + keyHold }
            frame.typedQuestion = typed(OnboardingCopy.Demo.askQuestion.count, during: questionTyping, at: t)
            frame.showsAnswer = t >= answerAt
            frame.showsSource = t >= sourceAt
        case .overview:
            frame.sessionsShown = sessionTimes.filter { t >= $0 }.count
            frame.showsSessionCard = t >= sessionCardAt
        case .ai:
            frame.contextLinesShown = contextLineTimes.filter { t >= $0 }.count
            frame.typedPrompt = typed(OnboardingCopy.Demo.aiPrompt.count, during: promptTyping, at: t)
            frame.showsReply = t >= replyAt
        }
        return frame
    }

    /// Characters typed by `t`, at an even pace across `span`.
    static func typed(_ count: Int, during span: ClosedRange<TimeInterval>, at t: TimeInterval) -> Int {
        guard t > span.lowerBound else { return 0 }
        guard t < span.upperBound else { return count }
        let share = (t - span.lowerBound) / (span.upperBound - span.lowerBound)
        return min(count, Int((share * Double(count)).rounded(.down)) + 1)
    }
}
