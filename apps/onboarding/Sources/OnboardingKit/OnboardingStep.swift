import Foundation

public enum OnboardingStep: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case welcome = 0
    case howItWorks = 1
    case trust = 2
    case permissions = 3
    // Cycle 8.48 — Raycast/Cotypist peer-study P0 pattern #1:
    // "Progressive-disclosure onboarding with a single primary-hotkey
    // moment." Placed immediately after the TCC permissions slide so
    // Accessibility is already granted (an NSEvent monitor for
    // ⇧⌘Space works reliably while onboarding is frontmost) and BEFORE
    // the allowlist / capture-setup work — the user learns the recall
    // gesture the moment they've said "yes" to permissions, so they
    // exit onboarding with muscle-memory for the flagship gesture.
    // The slide ships with a Skip button so a SetApp/Alfred conflict
    // never blocks the flow.
    case primaryHotkey = 4
    case allowlist = 5
    case browserExtension = 6
    case livePreview = 7
    case retention = 8
    case prepareBrain = 9
    case connectClaudeCode = 10
    // V2-MCP-2 — optional registration of locally-running MCP servers
    // (gchat, Slack, Linear, etc.) for the Hippocampus aggregator.
    // Loopback-only per ADR-0001 amendment 2026-05-31. Placed after
    // Claude Code because both surfaces are "connect an MCP-speaking
    // tool"; users familiar with one understand the other. Optional
    // by design — the slide ships with a Skip path.
    case mcpServers = 11
    case done = 12

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcome: "Welcome to Hippocampus"
        case .howItWorks: "How It Works"
        case .trust: "Built for Trust"
        case .permissions: "Permissions"
        case .primaryHotkey: "Your Recall Hotkey"
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
