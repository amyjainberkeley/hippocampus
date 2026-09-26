// SPDX-License-Identifier: TBD-private
import Foundation

/// Development file-key authority exists only when the assembled app bundle
/// carries this capability. Release source and Developer ID artifacts omit it.
public struct DevelopmentFileKeyMode: Sendable, Equatable {
    public static let infoPlistKey = "MCIDevelopmentFileKeyEnabled"

    public let keyURL: URL

    public init(keyURL: URL) {
        self.keyURL = keyURL.standardizedFileURL
    }

    public static func active(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Self? {
        guard let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return from(
            infoDictionary: bundle.infoDictionary ?? [:],
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    public static func from(
        infoDictionary: [String: Any],
        applicationSupportDirectory: URL
    ) -> Self? {
        guard infoDictionary[infoPlistKey] as? Bool == true else {
            return nil
        }
        return Self(
            keyURL: applicationSupportDirectory
                .appendingPathComponent("MCI")
                .appendingPathComponent("dev.key")
        )
    }
}
