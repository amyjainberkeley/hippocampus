import Foundation

public enum WorkspacePreferencesDestination: String, CaseIterable, Sendable {
    case general, capture, sources, privacy, advanced, about
    /// Setup's browser extension panel (SPEC 3.5): the window's Add Browser
    /// Extension…, which the app opens as it opens a pane, through this same
    /// typed route to the exact app that started the window, never a link
    /// that another copy, or this window itself, could answer.
    case browserExtension = "browser-extension"

    public static let openFlag = "--open-preferences"
    public static let notificationName = Notification.Name("ai.hippocampus.preferences.open.v1")
    public static let acknowledgementName = Notification.Name("ai.hippocampus.preferences.opened.v1")

    /// The link the app answers with the same page.
    public var url: URL {
        switch self {
        case .browserExtension: URL(string: "hippocampus://setup/browser-extension")!
        default: URL(string: "hippocampus://preferences/\(rawValue)")!
        }
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
