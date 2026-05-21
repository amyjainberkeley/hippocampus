// SPDX-License-Identifier: TBD-private
import Foundation

public protocol KeyStore: Sendable {
    func readKey() throws -> String
    func writeKey(_ hex: String) throws
}

public enum KeyStoreError: Error, Sendable {
    case noKeyFound
    case invalidKeyLength
    case writeFailure(String)
    case readFailure(String)
}

// TEMP — Phase-4 Keychain integration (ADR-0017 §6) replaces this
// with Security.framework KeychainItem storage. The file-based dev
// key is a documented interim step; the supervisor logs its path at
// startup.
public struct FileKeyStore: KeyStore, Sendable {
    public let path: URL

    public init(path: URL? = nil) {
        if let path {
            self.path = path
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("MCI")
            self.path = appSupport.appendingPathComponent("dev.key")
        }
    }

    public func readKey() throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw KeyStoreError.noKeyFound
        }
        let data = try Data(contentsOf: path)
        guard let hex = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw KeyStoreError.readFailure("could not decode dev.key as UTF-8")
        }
        guard hex.count == 64 else {
            throw KeyStoreError.invalidKeyLength
        }
        return hex
    }

    public func writeKey(_ hex: String) throws {
        guard hex.count == 64 else {
            throw KeyStoreError.invalidKeyLength
        }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = Data(hex.utf8)
        try data.write(to: path, options: .atomic)

        // mode 0600 — owner-only read/write
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }

    public static func generateHexKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
