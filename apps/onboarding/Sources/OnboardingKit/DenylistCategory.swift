import Foundation

public struct DenylistCategory: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

// Content-free denylist category descriptions per ADR-0013 §1.
// Never display per-row deny content.
public enum DenylistCategories {
    public static let v1: [DenylistCategory] = [
        DenylistCategory(
            name: "App Bundle",
            description: "Apps you tell Hippocampus to ignore, by bundle identifier."
        ),
        DenylistCategory(
            name: "URL Pattern",
            description: "Web pages matching a URL pattern you set."
        ),
        DenylistCategory(
            name: "Window Title",
            description: "Windows whose title matches a pattern you set."
        ),
    ]
}
