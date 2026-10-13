// SPDX-License-Identifier: TBD-private
//
// AskThisWindow.swift — what Ask may promise before anything is asked
// (product critique 2, RULINGS S1 and S9): whether answers can be written on
// this Mac, and whether Hippocampus has read the window in front.

import Foundation

/// Whether answers can be written, known without asking the model: they need
/// macOS 26 with Apple Intelligence, and an answer that came back without
/// text says why. The reason is kept for 30 minutes, as long as the agent
/// keeps it (`apps/agent/src/understanding/mind.rs`), so no open probes the
/// model.
public struct AnswerAvailability: Equatable, Sendable {
    public static let remembered: TimeInterval = 30 * 60
    /// The reasons the model process gives for having no model.
    public static let modelReasons: Set<String> = [
        "apple_intelligence_off", "device_not_eligible", "model_not_ready",
        "unavailable", "not_installed", "cannot_launch",
    ]

    public let systemSupportsAnswers: Bool
    public private(set) var reason: String?
    private var learnedAt: Date?

    public init(systemSupportsAnswers: Bool = AnswerAvailability.systemIsRecentEnough) {
        self.systemSupportsAnswers = systemSupportsAnswers
    }

    public static var systemIsRecentEnough: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
    }

    public func isAvailable(at now: Date) -> Bool {
        guard systemSupportsAnswers else { return false }
        guard let learnedAt, reason != nil else { return true }
        return now.timeIntervalSince(learnedAt) >= Self.remembered
    }

    /// Learn from a reply to a question. A timeout or another failure says
    /// nothing about the model, so only its own reasons are kept.
    public mutating func learn(from answer: BarAnswer, at now: Date) {
        if answer.answer != nil {
            reason = nil
            learnedAt = nil
        } else if let unavailable = answer.unavailable, Self.modelReasons.contains(unavailable) {
            reason = unavailable
            learnedAt = now
        }
    }
}

/// Whether Hippocampus has a saved read of the window in front, judged the
/// way the agent picks "the screen" for an answer (`pick_on_screen` in
/// `apps/agent/src/understanding/query.rs`): the newest moment of that app
/// with the same title in the last 10 minutes, or else the newest of that app
/// in the last 2 minutes.
public enum ThisWindowRead {
    public static let sameTitleWithin: TimeInterval = 10 * 60
    public static let sameAppWithin: TimeInterval = 2 * 60

    /// `moments` newest first, as `mci_events_by_app` returns them.
    public static func latest(of moments: [BarHit], for context: FrontmostContext, now: Date) -> BarHit? {
        guard let app = context.bundleId else { return nil }
        let nowUs = now.timeIntervalSince1970 * 1_000_000
        func age(_ moment: BarHit) -> TimeInterval { (nowUs - Double(moment.tsUs)) / 1_000_000 }
        let recent = moments.filter {
            $0.appBundleId == app && !$0.body.isEmpty && age($0) <= sameTitleWithin
        }
        if let title = context.windowTitle, let same = recent.first(where: { $0.windowTitle == title }) {
            return same
        }
        return recent.first { age($0) <= sameAppWithin }
    }
}
