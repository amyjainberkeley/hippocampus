// SPDX-License-Identifier: TBD-private
import Foundation
import Security

public struct KeychainDatabaseKeyReference: Sendable, Equatable {
    public static let storageModel = "file-keychain-acl-v1"
    public static let defaultDatabaseKey = KeychainDatabaseKeyReference(
        service: "ai.hippocampus.brain",
        account: "database-key-v1",
        storageModel: storageModel
    )

    public let service: String
    public let account: String
    public let storageModel: String

    public init(service: String, account: String, storageModel: String = storageModel) {
        self.service = service
        self.account = account
        self.storageModel = storageModel
    }

    public static func from(environment: [String: String]) -> Self {
        Self(
            service: environment["MCI_DB_KEYCHAIN_SERVICE"] ?? defaultDatabaseKey.service,
            account: environment["MCI_DB_KEYCHAIN_ACCOUNT"] ?? defaultDatabaseKey.account,
            storageModel: environment["MCI_DB_KEYCHAIN_STORAGE_MODEL"] ?? storageModel
        )
    }
}

public struct KeychainDatabaseKeyQuery: Sendable, Equatable {
    public let service: String
    public let account: String
    public let useDataProtectionKeychain: Bool
    public let synchronizable: Bool

    public init(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) {
        self.service = service
        self.account = account
        self.useDataProtectionKeychain = useDataProtectionKeychain
        self.synchronizable = synchronizable
    }

    public init(reference: KeychainDatabaseKeyReference) {
        self.init(
            service: reference.service,
            account: reference.account,
            useDataProtectionKeychain: false,
            synchronizable: false
        )
    }

    fileprivate var attributes: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }
}

public enum KeychainDatabaseKeyReadResult: Sendable {
    case success(Data)
    case failure(OSStatus)
}

public protocol KeychainDatabaseKeyClient: Sendable {
    func readGenericPassword(query: KeychainDatabaseKeyQuery) -> KeychainDatabaseKeyReadResult
}

private struct SecurityKeychainDatabaseKeyClient: KeychainDatabaseKeyClient {
    func readGenericPassword(query: KeychainDatabaseKeyQuery) -> KeychainDatabaseKeyReadResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(status == errSecSuccess ? errSecDecode : status)
        }
        return .success(data)
    }
}

public enum KeychainDatabaseKeyError: Error, Sendable, Equatable {
    case missing
    case accessDenied
    case interactionNotAllowed
    case domainMismatch
    case malformed
    case readFailure(OSStatus)
    case developmentKeyPathMissing
    case invalidDevelopmentKeyPath
    case developmentKeyMissing
    case developmentKeyUnreadable
    case malformedDevelopmentKey
}

extension KeychainDatabaseKeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missing: "Database key was not found in Keychain."
        case .accessDenied: "The capture helper was denied access to the database key."
        case .interactionNotAllowed: "Keychain is locked or interaction is unavailable."
        case .domainMismatch: "The capture helper received an unsupported Keychain domain."
        case .malformed: "The Keychain database key is malformed."
        case .readFailure(let status): "Keychain read failed with status \(status)."
        case .developmentKeyPathMissing: "Development file-key mode did not include a key path."
        case .invalidDevelopmentKeyPath: "Development file-key mode rejected a nonstandard key path."
        case .developmentKeyMissing: "The development database key is missing."
        case .developmentKeyUnreadable: "The development database key could not be read."
        case .malformedDevelopmentKey: "The development database key is malformed."
        }
    }
}

public struct KeychainDatabaseKeyResolver: Sendable {
    private let client: any KeychainDatabaseKeyClient

    public init() {
        self.client = SecurityKeychainDatabaseKeyClient()
    }

    init(client: any KeychainDatabaseKeyClient) {
        self.client = client
    }

    public func resolveBytes(reference: KeychainDatabaseKeyReference) throws -> [UInt8] {
        guard reference.storageModel == KeychainDatabaseKeyReference.storageModel else {
            throw KeychainDatabaseKeyError.domainMismatch
        }
        let data: Data
        switch client.readGenericPassword(query: KeychainDatabaseKeyQuery(reference: reference)) {
        case .success(let value): data = value
        case .failure(errSecItemNotFound): throw KeychainDatabaseKeyError.missing
        case .failure(errSecAuthFailed), .failure(errSecMissingEntitlement):
            throw KeychainDatabaseKeyError.accessDenied
        case .failure(errSecInteractionNotAllowed), .failure(errSecNotAvailable),
             .failure(errSecUserCanceled):
            throw KeychainDatabaseKeyError.interactionNotAllowed
        case .failure(let status): throw KeychainDatabaseKeyError.readFailure(status)
        }
        guard let hex = String(data: data, encoding: .utf8),
              hex.count == 64,
              hex.utf8.allSatisfy({ $0.isASCIIHexDigit })
        else {
            throw KeychainDatabaseKeyError.malformed
        }
        return stride(from: 0, to: 64, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        }
    }

    /// Resolve a development file only when the parent explicitly marks the
    /// child as development-only and names the fixed, user-owned key path.
    /// Every other launch remains Keychain-only, regardless of ambient env.
    public func resolveBytes(
        environment: [String: String],
        developmentKeyPath: URL
    ) throws -> [UInt8] {
        guard environment["MCI_DEVELOPMENT_FILE_KEY"] == "1" else {
            return try resolveBytes(reference: .from(environment: environment))
        }
        guard let rawPath = environment["MCI_DB_KEY_FILE"] else {
            throw KeychainDatabaseKeyError.developmentKeyPathMissing
        }
        let suppliedPath = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard suppliedPath == developmentKeyPath.standardizedFileURL else {
            throw KeychainDatabaseKeyError.invalidDevelopmentKeyPath
        }
        let data: Data
        do {
            data = try Data(contentsOf: suppliedPath)
        } catch CocoaError.fileNoSuchFile {
            throw KeychainDatabaseKeyError.developmentKeyMissing
        } catch {
            throw KeychainDatabaseKeyError.developmentKeyUnreadable
        }
        guard let hex = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              hex.count == 64,
              hex.utf8.allSatisfy({ $0.isASCIIHexDigit })
        else {
            throw KeychainDatabaseKeyError.malformedDevelopmentKey
        }
        return stride(from: 0, to: 64, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        }
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}
