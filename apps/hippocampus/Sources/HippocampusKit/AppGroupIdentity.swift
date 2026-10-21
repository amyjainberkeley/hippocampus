// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum AppGroupIdentity {
    public static let infoPlistKey = "HippocampusAppGroupIdentifier"

    public static var identifier: String? {
        identifier(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    package static func identifier(infoDictionary: [String: Any]) -> String? {
        guard let raw = infoDictionary[infoPlistKey] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The App Group container the app shares with its Safari extension:
    /// capture consent and the extension's inbox live there.
    ///
    /// A release build asks macOS, whose answer is the signed group's
    /// container in the account's own home, wherever `HOME` points. A
    /// development build (one with the development file-key capability)
    /// keeps the container under its home instead, the way it keeps its
    /// memory. So a build every test gate starts with a throwaway home
    /// never writes the real account's container (reports/e2e, finding 7),
    /// and one started normally uses the same folder macOS would.
    public static var containerURL: URL? {
        containerURL(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            home: FileManager.default.homeDirectoryForCurrentUser,
            systemContainer: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        )
    }

    package static func containerURL(
        infoDictionary: [String: Any],
        home: URL,
        systemContainer: (String) -> URL?
    ) -> URL? {
        guard let identifier = identifier(infoDictionary: infoDictionary) else { return nil }
        guard infoDictionary[DevelopmentFileKeyMode.infoPlistKey] as? Bool == true else {
            return systemContainer(identifier)
        }
        return home
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }
}
