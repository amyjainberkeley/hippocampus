import Foundation

public struct AllowlistEntry: Sendable, Equatable, Identifiable {
    public var id: String { bundleId }
    public let bundleId: String
    public let rationale: String

    public init(bundleId: String, rationale: String) {
        self.bundleId = bundleId
        self.rationale = rationale
    }
}

// Real impl reads known-safe-apps.toml from the helper bundle.
// This PR: protocol only.
public protocol AllowlistStore: Sendable {
    func entries() async -> [AllowlistEntry]
}

public struct StubAllowlistStore: AllowlistStore {
    private let _entries: [AllowlistEntry]

    public init(entries: [AllowlistEntry] = Self.defaultEntries) {
        self._entries = entries
    }

    public func entries() async -> [AllowlistEntry] {
        _entries
    }

    public static let defaultEntries: [AllowlistEntry] = [
        AllowlistEntry(bundleId: "com.apple.Safari", rationale: "Web browser"),
        AllowlistEntry(bundleId: "com.apple.Terminal", rationale: "Terminal"),
        AllowlistEntry(bundleId: "com.microsoft.VSCode", rationale: "VS Code IDE"),
        AllowlistEntry(bundleId: "com.google.Chrome", rationale: "Chrome browser"),
        AllowlistEntry(bundleId: "com.tinyspeck.slackmacgap", rationale: "Slack"),
        AllowlistEntry(bundleId: "notion.id", rationale: "Notion"),
        AllowlistEntry(bundleId: "com.linear.LinearMac", rationale: "Linear"),
        AllowlistEntry(bundleId: "com.apple.dt.Xcode", rationale: "Xcode IDE"),
        AllowlistEntry(bundleId: "company.thebrowser.Browser", rationale: "Arc browser"),
        AllowlistEntry(bundleId: "com.figma.Desktop", rationale: "Figma"),
    ]
}
