import Foundation

public enum OnboardingStep: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case welcome = 0
    case howItWorks = 1
    case trust = 2
    case permissions = 3
    case browserExtension = 4
    case livePreview = 5
    case retention = 6
    case prepareBrain = 7
    case connectClaudeCode = 8
    case done = 9

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcome: "Welcome to Hippocampus"
        case .howItWorks: "How It Works"
        case .trust: "Built for Trust"
        case .permissions: "Permissions"
        case .browserExtension: "Browser Extension"
        case .livePreview: "Live Preview"
        case .retention: "Retention & Privacy"
        case .prepareBrain: "Preparing Your Brain"
        case .connectClaudeCode: "Connect Claude Code"
        case .done: "You're All Set"
        }
    }

    public var stepLabel: String {
        "\(rawValue + 1) of \(Self.allCases.count)"
    }
}
