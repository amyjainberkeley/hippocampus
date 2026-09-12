import Foundation

/// Untrusted, content-free navigation only. The distributed channel is not an
/// authorization boundary: a valid request may show a pane, never change it.
public struct PreferencesOpenRequest: Equatable, Sendable {
    public static let flag = "--open-preferences"
    public static let notificationName = Notification.Name("ai.hippocampus.preferences.open.v1")
    public static let acknowledgementName = Notification.Name("ai.hippocampus.preferences.opened.v1")

    public let section: PreferencesSection
    public let id: UUID

    public init(section: PreferencesSection, id: UUID = UUID()) {
        self.section = section
        self.id = id
    }

    public init?(arguments: [String]) {
        guard arguments.count == 2, arguments[0] == Self.flag,
              let section = Self.section(arguments[1]) else { return nil }
        self.init(section: section)
    }

    public init?(notification: Notification, executableURL: URL) {
        guard notification.name == Self.notificationName,
              notification.object as? String == executableURL.resolvingSymlinksInPath().path,
              let info = notification.userInfo, info.count == 2,
              let value = info["section"] as? String, let section = Self.section(value),
              let identifier = info["request_id"] as? String, let id = UUID(uuidString: identifier)
        else { return nil }
        self.init(section: section, id: id)
    }

    public var userInfo: [String: String] {
        ["section": section.rawValue.lowercased(), "request_id": id.uuidString]
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

    private static func section(_ value: String) -> PreferencesSection? {
        PreferencesSection.allCases.first { $0.rawValue.lowercased() == value }
    }
}
