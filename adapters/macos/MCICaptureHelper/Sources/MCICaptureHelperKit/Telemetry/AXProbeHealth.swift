import Foundation

/// No attributes or captured content can enter this health snapshot.
public struct AXProbeHealthSnapshot: Sendable, Equatable {
    public let focusResult: Int32
    public let focusedElementMatched: Bool
    public let subroleResult: Int32?
    public let valueHidden: AXBackstopOutcome?
    public let identifierMatch: AXBackstopOutcome?
    public let descendantSecure: AXBackstopOutcome?
    public let classification: Bool?
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
        return "mci-capture-helper: helper_health ax_unclassified "
            + "focus_result=\(snapshot.focusResult) "
            + "focused=\(snapshot.focusedElementMatched ? "present" : "absent") "
            + "subrole_result=\(snapshot.subroleResult.map(String.init) ?? "unobserved") "
            + "value_hidden=\(label(snapshot.valueHidden)) "
            + "identifier=\(label(snapshot.identifierMatch)) "
            + "descendant=\(label(snapshot.descendantSecure))\n"
    }
}
