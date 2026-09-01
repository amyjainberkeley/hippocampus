// SPDX-License-Identifier: TBD-private
import Foundation
import Security

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

public struct KeychainKeyReference: Sendable, Equatable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static let defaultDatabaseKey = KeychainKeyReference(
        service: KeychainKeyStore.defaultService,
        account: KeychainKeyStore.defaultAccount
    )
}

public struct KeychainKeyStore: KeyStore, Sendable {
    public static let defaultService = "ai.hippocampus.brain"
    public static let defaultAccount = "database-key-v1"

    public let reference: KeychainKeyReference

    public init(reference: KeychainKeyReference = .defaultDatabaseKey) {
        self.reference = reference
    }

    public static let defaultDatabaseKey = KeychainKeyStore()

    public func readKey() throws -> String {
        let query = baseQuery().merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw KeyStoreError.noKeyFound
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.readFailure("SecItemCopyMatching status \(status)")
        }
        guard let data = result as? Data,
              let hex = String(data: data, encoding: .utf8)
        else {
            throw KeyStoreError.readFailure("could not decode Keychain item as UTF-8")
        }
        return try Self.validate(hex.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func writeKey(_ hex: String) throws {
        let validated = try Self.validate(hex)
        let data = Data(validated.utf8)

        let query = baseQuery()
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeyStoreError.writeFailure("SecItemUpdate status \(updateStatus)")
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.writeFailure("SecItemAdd status \(status)")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: reference.service,
            kSecAttrAccount as String: reference.account,
        ]
    }

    static func validate(_ hex: String) throws -> String {
        guard hex.count == 64,
              hex.allSatisfy({ $0.isHexDigit })
        else {
            throw KeyStoreError.invalidKeyLength
        }
        return hex
    }
}

// File-based storage is retained for tests and explicit development mode.
public struct FileKeyStore: KeyStore, Sendable {
    public enum StorageKind: Sendable, Equatable {
        case keychain
        case developmentFile
    }

    private enum Backing: Sendable {
        case keychain(KeychainKeyStore)
        case developmentFile(URL)
    }

    public let path: URL
    public let storageKind: StorageKind
    private let backing: Backing

    public init(path: URL? = nil) {
        if let path {
            self.path = path
            self.storageKind = .developmentFile
            self.backing = .developmentFile(path)
        } else {
            self.path = Self.defaultDevelopmentKeyPath()
            self.storageKind = .keychain
            self.backing = .keychain(KeychainKeyStore.defaultDatabaseKey)
        }
    }

    public var keychainReference: KeychainKeyReference? {
        switch backing {
        case .keychain(let store): store.reference
        case .developmentFile: nil
        }
    }

    public func readKey() throws -> String {
        if case .keychain(let store) = backing {
            return try store.readKey()
        }

        guard FileManager.default.fileExists(atPath: path.path) else {
            throw KeyStoreError.noKeyFound
        }
        let data = try Data(contentsOf: path)
        guard let hex = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw KeyStoreError.readFailure("could not decode dev.key as UTF-8")
        }
        return try KeychainKeyStore.validate(hex)
    }

    public func writeKey(_ hex: String) throws {
        if case .keychain(let store) = backing {
            try store.writeKey(hex)
            return
        }
        _ = try KeychainKeyStore.validate(hex)
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

    private static func defaultDevelopmentKeyPath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("MCI")
        return appSupport.appendingPathComponent("dev.key")
    }
}
