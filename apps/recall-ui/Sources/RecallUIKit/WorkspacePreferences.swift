import Foundation

public enum WorkspacePreferencesDestination: String, CaseIterable, Sendable {
    case general, capture, sources, privacy, advanced, about

    public static let openFlag = "--open-preferences"
    public static let notificationName = Notification.Name("ai.hippocampus.preferences.open.v1")
    public static let acknowledgementName = Notification.Name("ai.hippocampus.preferences.opened.v1")

    public var url: URL {
        URL(string: "hippocampus://preferences/\(rawValue)")!
    }

    // Backups can register the same scheme. Never resolve a host by bundle ID.
    public static func hostApplication(bundleURL: URL) -> URL? {
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app" else { return nil }
        return bundleURL
    }

    public func routingPlan(
        bundleURL: URL, runningExecutableURLs: [URL], launchedExecutableURL: URL? = nil
    ) -> WorkspacePreferencesRoutingPlan? {
        guard let bundle = Self.hostApplication(bundleURL: bundleURL) else { return nil }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Hippocampus").resolvingSymlinksInPath()
        if (runningExecutableURLs + [launchedExecutableURL].compactMap { $0 }).contains(where: {
            $0.resolvingSymlinksInPath() == executable
        }) {
            return .notify(executable: executable)
        }
        return .launch(executable: executable, arguments: [Self.openFlag, rawValue])
    }

    public func notificationInfo(id: UUID) -> [String: String] {
        ["section": rawValue, "request_id": id.uuidString]
    }
}

public enum WorkspacePreferencesRoutingPlan: Equatable, Sendable {
    case notify(executable: URL)
    case launch(executable: URL, arguments: [String])

    public var executable: URL {
        switch self {
        case .notify(let executable), .launch(let executable, _): return executable
        }
    }
}
