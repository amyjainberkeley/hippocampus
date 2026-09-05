import Foundation

public enum WorkspacePreferencesDestination: String, CaseIterable, Sendable {
    case general, capture, sources, privacy, advanced, about

    public var url: URL {
        URL(string: "hippocampus://preferences/\(rawValue)")!
    }

    // Explicitly target the running bundle; backups can register the same scheme.
    public static func hostApplication(bundleURL: URL) -> URL? {
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
    }
}
