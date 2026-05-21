import Foundation

public enum BrowserKind: String, Sendable, Equatable {
    case chromium
    case safari
}

public struct DetectedBrowser: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: BrowserKind

    public init(id: String, name: String, kind: BrowserKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum ExtensionStatus: String, Sendable, Equatable {
    case unknown
    case installed
    case notInstalled
}

@MainActor
public protocol BrowserDetector: AnyObject, Sendable {
    func installedBrowsers() -> [DetectedBrowser]
    func checkExtensionInstalled(for browser: DetectedBrowser) -> ExtensionStatus
}

public let knownBrowsers: [(bundleId: String, name: String, kind: BrowserKind)] = [
    ("com.apple.Safari", "Safari", .safari),
    ("com.google.Chrome", "Chrome", .chromium),
    ("company.thebrowser.Browser", "Arc", .chromium),
    ("com.brave.Browser", "Brave", .chromium),
    ("com.microsoft.edgemac", "Edge", .chromium),
]
