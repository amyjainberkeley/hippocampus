import Foundation

/// Closed categories only; no AX values, identifiers or element references.
public enum AXTraversalFailureReason: String, Sendable, Equatable {
    case focusedRead = "focused-read"
    case focusedMalformed = "focused-malformed"
    case childrenRead = "children-read"
    case childrenMalformed = "children-malformed"
    case childrenIncomplete = "children-incomplete"
    case depthLimit = "depth-limit"
    case nodeLimit = "node-limit"
    case subroleRead = "subrole-read"
    case subroleMalformed = "subrole-malformed"
}

/// State at the first traversal failure, not a summary of later traversal.
public struct AXTraversalFailure: Sendable, Equatable {
    public let reason: AXTraversalFailureReason
    public let status: Int32?
    public let depth: Int
    /// Descendants visited; the root is excluded from the existing node budget.
    public let visitedDescendants: Int
    public let ancestorLinkObserved: Bool
}

/// No attributes or captured content can enter this health snapshot.
public struct AXProbeHealthSnapshot: Sendable, Equatable {
    public let focusResult: Int32
    public let focusedElementMatched: Bool
    public let subroleResult: Int32?
    public let valueHidden: AXBackstopOutcome?
    public let identifierMatch: AXBackstopOutcome?
    public let descendantSecure: AXBackstopOutcome?
    public let classification: Bool?
    public let descendantFailure: AXTraversalFailure?

    init(
        focusResult: Int32, focusedElementMatched: Bool, subroleResult: Int32?,
        valueHidden: AXBackstopOutcome?, identifierMatch: AXBackstopOutcome?,
        descendantSecure: AXBackstopOutcome?, classification: Bool?,
        descendantFailure: AXTraversalFailure? = nil
    ) {
        self.focusResult = focusResult
        self.focusedElementMatched = focusedElementMatched
        self.subroleResult = subroleResult
        self.valueHidden = valueHidden
        self.identifierMatch = identifierMatch
        self.descendantSecure = descendantSecure
        self.classification = classification
        self.descendantFailure = descendantFailure
    }
}

/// Bounds unclassified-probe diagnostics even when focus changes every frame.
/// The lock protects all mutable limiter state.
public final class AXProbeHealthReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission: TimeInterval?

    public init() {}

    public func line(for snapshot: AXProbeHealthSnapshot, at uptime: TimeInterval) -> String? {
        guard snapshot.classification == nil, uptime.isFinite, uptime >= 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let lastEmission, uptime - lastEmission < 30 { return nil }
        lastEmission = uptime

        func label(_ outcome: AXBackstopOutcome?) -> String {
            switch outcome {
            case .positive: return "positive"
            case .negative: return "negative"
            case .errored: return "error"
            case nil: return "unobserved"
            }
        }
        let traversal = snapshot.descendantFailure.map { failure in
            " descendant_reason=\(failure.reason.rawValue)"
                + " descendant_status=\(failure.status.map(String.init) ?? "unobserved")"
                + " descendant_depth=\(failure.depth)"
                + " descendant_visited=\(failure.visitedDescendants)"
                + " descendant_ancestor_link=\(failure.ancestorLinkObserved)"
        } ?? ""
        return "mci-capture-helper: helper_health ax_unclassified "
            + "focus_result=\(snapshot.focusResult) "
            + "focused=\(snapshot.focusedElementMatched ? "present" : "absent") "
            + "subrole_result=\(snapshot.subroleResult.map(String.init) ?? "unobserved") "
            + "value_hidden=\(label(snapshot.valueHidden)) "
            + "identifier=\(label(snapshot.identifierMatch)) "
            + "descendant=\(label(snapshot.descendantSecure))" + traversal + "\n"
    }
}
