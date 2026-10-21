// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Development file-key authority exists only when the assembled app bundle
/// carries this capability. Release source and Developer ID artifacts omit it.
public struct DevelopmentFileKeyMode: Sendable, Equatable {
    public static let infoPlistKey = "MCIDevelopmentFileKeyEnabled"

    public let keyURL: URL

    public init(keyURL: URL) {
        self.keyURL = keyURL.standardizedFileURL
    }

    /// Whether this build can use a development file key at all: a debug
    /// build, or one compiled with `-DMCI_DEVELOPMENT_FILE_KEY`. A release
    /// build never does, whatever its Info.plist says (storage-security
    /// review S11).
    public static let compiledIn: Bool = {
        #if DEBUG || MCI_DEVELOPMENT_FILE_KEY
        return true
        #else
        return false
        #endif
    }()

    public static func active(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Self? {
        guard compiledIn else { return nil }
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
