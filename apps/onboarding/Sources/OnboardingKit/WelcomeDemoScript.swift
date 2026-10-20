// SPDX-License-Identifier: Apache-2.0
//
// Welcome's demo, as a script: three moments from the product, played in a
// loop from made-up data (`OnboardingCopy.Demo`). Someone writing a message
// needs a link they saw earlier: Ask finds it and shows its source; Today
// fills in the day; your AI starts a session with your recent work. The
// view draws `frame(at:)` and animates between frames; the script alone
// decides what shows when, so the tests and the preview renderer see
// exactly what plays. Under Reduce Motion the view shows each moment whole
// (`stillFrame(at:)`) and only crossfades between them, every 6 seconds.
//
// The demo plays only while it can be watched (`WelcomeDemoPlayback`): it
// pauses while the pointer is over it, so it can be read, and while setup's
// window is not the key window, and it stops when the person moves past
// Welcome. Paused, nothing runs, so it costs nothing in the background.

import Foundation

/// The three moments, in the order they play.
public enum DemoMoment: Int, CaseIterable, Sendable {
    case ask
    /// The window on Today, its day filling in (SPEC 7.3).
    case today
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
    /// Today: how many of the day's sessions are on the strip, and the
    /// card for what is going on now.
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
    /// How long each moment plays, in seconds. Each holds its last state
    /// for close to three seconds, long enough to read the answer.
    public static func length(of moment: DemoMoment) -> TimeInterval {
        switch moment {
        case .ask: 6
        case .today: 5.4
        case .ai: 6
        }
    }

    /// Each moment fades out over its last this many seconds.
    public static let fadeOut: TimeInterval = 0.3

    /// One loop of all three.
    public static var cycle: TimeInterval {
        DemoMoment.allCases.reduce(0) { $0 + length(of: $1) }
    }

    /// The day the Today moment fills in, 9 AM to 3 PM, by the legend's
    /// kinds: documents, code, a call, code again, and the Team pricing
    /// session the card names.
    public static let day: [DemoSession] = [
        DemoSession(start: 9.1, end: 10.3, kind: 0),
        DemoSession(start: 10.5, end: 11.8, kind: 1),
        DemoSession(start: 13.1, end: 13.55, kind: 2),
        DemoSession(start: 13.7, end: 14.05, kind: 1),
        DemoSession(start: 14.2, end: 14.6, kind: 0),
    ]
    /// The strip's hours, start and end.
    public static let dayHours: ClosedRange<Double> = 9...15

    /// Ask opens as the person opens it: first the message they are
    /// writing, alone, then the key (twice for Shift twice), then the
    /// panel over the message. Each press holds the key this long.
    public static let keyPresses: [TimeInterval] = [0.7, 1.0]
    public static let keyHold: TimeInterval = 0.12
    static let askOpensAt: TimeInterval = 1.2
    static let questionTyping: ClosedRange<TimeInterval> = 1.5...2.5
    static let answerAt: TimeInterval = 2.8
    static let sourceAt: TimeInterval = 3.15
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

    /// Under Reduce Motion each moment shows whole for this long, then the
    /// next crossfades in (SPEC 7.3).
    public static let stillMomentLength: TimeInterval = 6

    /// The moment shown whole `time` seconds into the still loop, for
    /// Reduce Motion: nothing inside a moment moves.
    public static func stillFrame(at time: TimeInterval) -> DemoFrame {
        let count = DemoMoment.allCases.count
        var index = Int((time / stillMomentLength).rounded(.down)) % count
        if index < 0 { index += count }
        return finalFrame(DemoMoment.allCases[index])
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
        case .today:
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

/// When Welcome's demo plays (SPEC 7.3). It pauses while the pointer is over
/// it, so it can be read, and while setup's window is not the key window;
/// it stops when the person moves past Welcome. Time only counts while it
/// plays, so it picks up where it paused.
public struct WelcomeDemoPlayback: Equatable, Sendable {
    /// The pointer is over the demo.
    public var hovering = false
    /// Setup's window is the key window.
    public var windowIsKey = true
    /// Welcome is the screen showing.
    public var onWelcome = true
    /// Seconds into the loop, counting only the time it played.
    public private(set) var elapsed: TimeInterval = 0

    public init(hovering: Bool = false, windowIsKey: Bool = true, onWelcome: Bool = true) {
        self.hovering = hovering
        self.windowIsKey = windowIsKey
        self.onWelcome = onWelcome
    }

    /// Whether the demo moves now. When it doesn't, nothing runs for it.
    public var isPlaying: Bool { onWelcome && windowIsKey && !hovering }

    /// `seconds` of wall time passed: counted only while it plays.
    public mutating func advance(by seconds: TimeInterval) {
        guard isPlaying, seconds > 0 else { return }
        elapsed += seconds
    }

    /// What shows now: the script's frame, or the moment whole under
    /// Reduce Motion.
    public func frame(presses: Int, reduceMotion: Bool) -> DemoFrame {
        reduceMotion
            ? WelcomeDemoScript.stillFrame(at: elapsed)
            : WelcomeDemoScript.frame(at: elapsed, presses: presses)
    }
}
