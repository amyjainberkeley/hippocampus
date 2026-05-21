import Foundation

public enum RetentionPolicy: String, Sendable, Equatable, CaseIterable, Identifiable {
    case forever
    case thirtyDays
    case sevenDays
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forever: return "Forever"
        case .thirtyDays: return "30 days"
        case .sevenDays: return "7 days"
        case .custom: return "Custom"
        }
    }

    public var days: Int? {
        switch self {
        case .forever: return nil
        case .thirtyDays: return 30
        case .sevenDays: return 7
        case .custom: return nil
        }
    }
}

// Real impl persists to ~/Library/Application Support/MCI/state.json.
// This PR: protocol only. Saves nothing.
public protocol RetentionStore: Sendable {
    func currentPolicy() async -> RetentionPolicy
    func currentCustomDays() async -> Int?
    func setPolicy(_ policy: RetentionPolicy, customDays: Int?) async
}

public actor StubRetentionStore: RetentionStore {
    private var policy: RetentionPolicy = .forever
    private var customDays: Int?

    public init(policy: RetentionPolicy = .forever, customDays: Int? = nil) {
        self.policy = policy
        self.customDays = customDays
    }

    public func currentPolicy() async -> RetentionPolicy {
        policy
    }

    public func currentCustomDays() async -> Int? {
        customDays
    }

    public func setPolicy(_ newPolicy: RetentionPolicy, customDays newDays: Int?) async {
        policy = newPolicy
        customDays = newDays
    }
}
