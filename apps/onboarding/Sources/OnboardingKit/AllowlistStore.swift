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

public protocol AllowlistStore: Sendable {
    func entries() async -> [AllowlistEntry]
}

/// Read-only view of the CSO baseline sealed into the signed app bundle.
///
/// The onboarding process runs from `Hippocampus.app/Contents/MacOS`, so
/// `Bundle.main` resolves the same `Contents/Resources/known-safe-apps.toml`
/// consumed by the capture helper. A missing or malformed resource returns an
/// empty set: capture then remains fail-closed rather than falling back to a
/// stale, hard-coded catalog.
public struct SignedBaselineAllowlistStore: AllowlistStore {
    private let url: URL?

    public init(
        url: URL? = Bundle.main.url(
            forResource: "known-safe-apps",
            withExtension: "toml"
        )
    ) {
        self.url = url
    }

    public func entries() async -> [AllowlistEntry] {
        guard let url,
              let source = try? String(contentsOf: url, encoding: .utf8),
              let entries = try? SignedBaselineAllowlistTOML.parse(source) else {
            return []
        }
        return entries
    }
}

/// Strict subset shared with MCICaptureHelper's `AllowlistTOMLLoader`.
///
/// Onboarding cannot import the helper package, so this intentionally mirrors
/// its four-required-key grammar. Signed policy is a trust boundary: reject a
/// whole document on any malformed row instead of presenting partial policy.
private enum SignedBaselineAllowlistTOML {
    private enum ParseError: Error {
        case malformed
    }

    static func parse(_ source: String) throws -> [AllowlistEntry] {
        var entries: [AllowlistEntry] = []
        var bundleId: String?
        var rationale: String?
        var csoRatifiedBy: String?
        var ratifiedAt: String?
        var inTable = false

        func flush() throws {
            guard inTable else { return }
            guard let bundleId,
                  let rationale,
                  csoRatifiedBy != nil,
                  ratifiedAt != nil else {
                throw ParseError.malformed
            }
            entries.append(AllowlistEntry(bundleId: bundleId, rationale: rationale))
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line == "[[entries]]" {
                try flush()
                inTable = true
                bundleId = nil
                rationale = nil
                csoRatifiedBy = nil
                ratifiedAt = nil
                continue
            }

            guard inTable,
                  let equal = line.firstIndex(of: "=") else {
                throw ParseError.malformed
            }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = try quotedValue(
                line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            )

            switch key {
            case "bundle_id" where bundleId == nil:
                bundleId = value
            case "rationale" where rationale == nil:
                rationale = value
            case "cso_ratified_by" where csoRatifiedBy == nil:
                csoRatifiedBy = value
            case "ratified_at" where ratifiedAt == nil:
                ratifiedAt = value
            default:
                throw ParseError.malformed
            }
        }

        try flush()
        return entries
    }

    private static func quotedValue(_ value: String) throws -> String {
        guard value.count >= 2,
              value.first == "\"",
              value.last == "\"" else {
            throw ParseError.malformed
        }
        let inner = value.dropFirst().dropLast()
        guard !inner.isEmpty,
              !inner.contains("\""),
              !inner.contains("\\") else {
            throw ParseError.malformed
        }
        return String(inner)
    }
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
