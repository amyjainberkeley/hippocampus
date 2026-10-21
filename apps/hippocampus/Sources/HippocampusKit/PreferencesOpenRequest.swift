import Foundation

/// Untrusted, content-free navigation only. The distributed channel is not an
/// authorization boundary: a valid request may show a pane, never change it.
public struct PreferencesOpenRequest: Equatable, Sendable {
    public static let flag = "--open-preferences"
    public static let notificationName = Notification.Name("ai.hippocampus.preferences.open.v1")
    public static let acknowledgementName = Notification.Name("ai.hippocampus.preferences.opened.v1")

    /// What a request shows: a Preferences pane, or one of setup's panels
    /// (the window's Add Browser Extension…, SPEC 3.5). Either only shows;
    /// nothing is installed or allowed until the person clicks there.
    public enum Target: Equatable, Sendable {
        case preferences(PreferencesSection)
        case setupPanel(SetupPanelRoute)

        /// The value on the wire, as the window's
        /// `WorkspacePreferencesDestination` writes it.
        var value: String {
            switch self {
            case .preferences(let section): section.rawValue.lowercased()
            case .setupPanel(let panel): panel.rawValue
            }
        }
    }

    public let target: Target
    public let id: UUID

    /// The Preferences pane asked for; nil for one of setup's panels.
    public var section: PreferencesSection? {
        if case .preferences(let section) = target { return section }
        return nil
    }

    public init(section: PreferencesSection, id: UUID = UUID()) {
        self.init(target: .preferences(section), id: id)
    }

    public init(target: Target, id: UUID = UUID()) {
        self.target = target
        self.id = id
    }

    public init?(arguments: [String]) {
        guard arguments.count == 2, arguments[0] == Self.flag,
              let target = Self.target(arguments[1]) else { return nil }
        self.init(target: target)
    }

    public init?(notification: Notification, executableURL: URL) {
        guard notification.name == Self.notificationName,
              notification.object as? String == executableURL.resolvingSymlinksInPath().path,
              let info = notification.userInfo, info.count == 2,
              let value = info["section"] as? String, let target = Self.target(value),
              let identifier = info["request_id"] as? String, let id = UUID(uuidString: identifier)
        else { return nil }
        self.init(target: target, id: id)
    }

    public var userInfo: [String: String] {
        ["section": target.value, "request_id": id.uuidString]
    }

    public func post(to executableURL: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.notificationName, object: executableURL.resolvingSymlinksInPath().path,
            userInfo: userInfo, deliverImmediately: true)
    }

    public func acknowledge(from executableURL: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.acknowledgementName, object: executableURL.resolvingSymlinksInPath().path,
            userInfo: ["request_id": id.uuidString], deliverImmediately: true)
    }

    /// A pane by its lower-case name, or a setup panel by its exact route
    /// name; anything else is no request.
    private static func target(_ value: String) -> Target? {
        if let section = PreferencesSection.allCases.first(where: { $0.rawValue.lowercased() == value }) {
            return .preferences(section)
        }
        return SetupPanelRoute(rawValue: value).map(Target.setupPanel)
    }
}
