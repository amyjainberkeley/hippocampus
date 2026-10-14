// SPDX-License-Identifier: Apache-2.0
//
// AskThisWindow.swift — what Ask may promise before anything is asked
// (product critique 2, RULINGS S1 and S9): whether answers can be written on
// this Mac, and whether Hippocampus has read the window in front.

import Foundation

/// Whether answers can be written, learned from the first reply rather than
/// from the macOS version (RULINGS S9): Apple Intelligence or a model server
/// on this Mac (Ollama, LM Studio) writes them, and an answer that came back
/// without text says why. An Apple Intelligence reason is kept for 30
/// minutes, as long as the agent keeps it (`apps/agent/src/understanding/mind.rs`),
/// so no open probes the model. A model server can be started at any time,
/// so its reasons are kept for a minute.
public struct AnswerAvailability: Equatable, Sendable {
    public static let remembered: TimeInterval = 30 * 60
    public static let rememberedForAModelServer: TimeInterval = 60
    /// The reasons the model process gives for having no model.
    public static let modelReasons: Set<String> = Set([
        "apple_intelligence_off", "device_not_eligible", "model_not_ready",
        "unavailable", "not_installed", "cannot_launch", "needs_macos_26",
    ]).union(modelServerReasons)
    /// The reasons that clear once a model server on this Mac answers.
    public static let modelServerReasons: Set<String> = [
        "needs_apple_intelligence_or_local_model", "local_server_unreachable",
        "local_model_missing", "local_model_unset", "local_model_not_local",
        "local_server_not_local",
    ]

    /// False only where a preview or test stands in for a Mac with no model.
    public let systemSupportsAnswers: Bool
    public private(set) var reason: String?
    private var learnedAt: Date?

    public init(systemSupportsAnswers: Bool = true) {
        self.systemSupportsAnswers = systemSupportsAnswers
    }

    public func isAvailable(at now: Date) -> Bool {
        guard systemSupportsAnswers else { return false }
        guard let learnedAt, let reason else { return true }
        let kept = Self.modelServerReasons.contains(reason) ? Self.rememberedForAModelServer : Self.remembered
        return now.timeIntervalSince(learnedAt) >= kept
    }

    /// Why no answer can be written, in the few words Ask's footer has room
    /// for, from the same reason the answer card explains.
    public var footerReason: String {
        guard systemSupportsAnswers else { return "Answers need Apple Intelligence or your own model" }
        switch reason {
        case "apple_intelligence_off", "device_not_eligible": return "Answers need Apple Intelligence"
        case "model_not_ready": return "Apple Intelligence is getting ready"
        case "needs_macos_26": return "Answers need macOS 26"
        case "needs_apple_intelligence_or_local_model": return "Answers need Apple Intelligence or your own model"
        case "local_server_unreachable": return "Your model server isn’t answering"
        case "local_model_missing": return "Your model server doesn’t have that model"
        case "local_model_unset": return "Your model server has no model to answer with"
        case "local_model_not_local": return "Pick a model that runs on this Mac"
        case "local_server_not_local": return "Hippocampus only talks to model servers on this Mac"
        default: return "Answers aren’t available"
        }
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
