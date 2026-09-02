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
}

/// Explicit escape hatch for deterministic local fixtures and ad-hoc
/// development bundles. Production bundles do not carry the capability that
/// lets the supervisor set this marker.
public enum DevelopmentDatabaseKeyMaterial {
    public static func hex(from environment: [String: String]) throws -> String? {
        guard environment["MCI_DEVELOPMENT_FILE_KEY"] == "1" else { return nil }
        let value: String
        if let raw = environment["MCI_DB_KEY_HEX"] {
            value = raw
        } else if let path = environment["MCI_DB_KEY_FILE"] {
            value = try String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        guard value.utf8.count == 64,
              value.utf8.allSatisfy(\.isASCIIHexDigit)
        else {
            throw KeychainDatabaseKeyError.malformed
        }
        return value.lowercased()
    }

    public static func bytes(from environment: [String: String]) throws -> Data? {
        guard let value = try hex(from: environment) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var offset = value.startIndex
        for _ in 0 ..< 32 {
            let end = value.index(offset, offsetBy: 2)
            guard let byte = UInt8(value[offset ..< end], radix: 16) else {
                throw KeychainDatabaseKeyError.malformed
            }
            bytes.append(byte)
            offset = end
        }
        return Data(bytes)
    }
}

extension KeychainDatabaseKeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missing: "Database key was not found in Keychain."
        case .accessDenied: "Recall was denied access to the database key."
        case .interactionNotAllowed: "Keychain is locked or interaction is unavailable."
        case .domainMismatch: "Recall received an unsupported Keychain domain."
        case .malformed: "The Keychain database key is malformed."
        case .readFailure(let status): "Keychain read failed with status \(status)."
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

    public func resolveHex(reference: KeychainDatabaseKeyReference) throws -> String {
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
        return hex
    }

    public func resolveBytes(reference: KeychainDatabaseKeyReference) throws -> Data {
        let hex = try resolveHex(reference: reference)
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var offset = hex.startIndex
        for _ in 0 ..< 32 {
            let end = hex.index(offset, offsetBy: 2)
            guard let byte = UInt8(hex[offset ..< end], radix: 16) else {
                throw KeychainDatabaseKeyError.malformed
            }
            bytes.append(byte)
            offset = end
        }
        return Data(bytes)
    }
}

public struct UnavailableBrainReader: BrainReader {
    private let message: String

    public init(message: String) {
        self.message = message
    }

    private func unavailable() -> BrainReaderError {
        .openFailed(message)
    }

    public func search(_ opts: SearchOptions) async throws -> [Hit] { throw unavailable() }
    public func recentEvents(limit: Int) async throws -> [Hit] { throw unavailable() }
    public func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { throw unavailable() }
    public func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] {
        throw unavailable()
    }
    public func listEpisodes(limit: Int) async throws -> [Episode] { throw unavailable() }
    public func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { throw unavailable() }
    public func briefForDate(_ dateLocal: String) async throws -> Brief? { throw unavailable() }
    public func latestBrief() async throws -> Brief? { throw unavailable() }
    public func briefDates(limit: Int) async throws -> [String] { throw unavailable() }
    public func summaryStats() async throws -> SummaryStats { throw unavailable() }
}

extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}
