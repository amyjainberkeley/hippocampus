import Foundation

public enum OnboardingStep: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case welcome = 0
    case howItWorks = 1
    case trust = 2
    case permissions = 3
    case allowlist = 4
    case browserExtension = 5
    case livePreview = 6
    case retention = 7
    case prepareBrain = 8
    case connectClaudeCode = 9
    // V2-MCP-2 — optional registration of locally-running MCP servers
    // (gchat, Slack, Linear, etc.) for the Hippocampus aggregator.
    // Loopback-only per ADR-0001 amendment 2026-05-31. Placed after
    // Claude Code because both surfaces are "connect an MCP-speaking
    // tool"; users familiar with one understand the other. Optional
    // by design — the slide ships with a Skip path.
    case mcpServers = 10
    case done = 11

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcome: "Welcome to Hippocampus"
        case .howItWorks: "How It Works"
        case .trust: "Built for Trust"
        case .permissions: "Permissions"
        case .allowlist: "Which apps should Hippocampus remember?"
        case .browserExtension: "Browser Extension"
        case .livePreview: "Live Preview"
        case .retention: "Retention & Privacy"
        case .prepareBrain: "Preparing Your Brain"
        case .connectClaudeCode: "Connect Claude Code"
        case .mcpServers: "Connect MCP Servers (optional)"
        case .done: "You're All Set"
        }
    }

    public var stepLabel: String {
        "\(rawValue + 1) of \(Self.allCases.count)"
    }
}
