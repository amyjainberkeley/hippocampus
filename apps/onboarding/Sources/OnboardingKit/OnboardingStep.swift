import Foundation

public enum OnboardingStep: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case welcome = 0
    case screenRecording = 1
    case accessibility = 2
    case automation = 3
    case done = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .automation: return "Automation"
        case .done: return "You're Set"
        }
    }

    public var stepLabel: String {
        "\(rawValue + 1) of \(Self.allCases.count)"
    }
}
