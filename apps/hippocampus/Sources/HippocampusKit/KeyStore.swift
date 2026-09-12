// SPDX-License-Identifier: TBD-private
import Foundation
import Security

public protocol KeyStore: Sendable {
    func readKey() throws -> String
    func writeKey(_ hex: String) throws
}

enum KeyStoreAccess {
    static func readValidatedKey(from store: any KeyStore) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try store.readKey()
        }.value
    }
}

public enum KeyStoreError: Error, Sendable, Equatable {
    case noKeyFound
    case accessDenied
    case interactionNotAllowed
    case keyAlreadyExists
    case aclUnavailable(String)
    case invalidKeyLength
    case keyGenerationFailure(OSStatus)
    case writeFailure(String)
    case readFailure(String)
}

extension KeyStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noKeyFound: "Database key was not found in Keychain."
        case .accessDenied: "Hippocampus was denied access to its database key."
        case .interactionNotAllowed: "Keychain is locked or interaction is unavailable."
        case .keyAlreadyExists: "The database key already exists and was not overwritten."
        case .aclUnavailable(let reason): "The bundled Keychain ACL is unavailable: \(reason)"
        case .invalidKeyLength: "Database key must be exactly 64 hexadecimal characters."
        case .keyGenerationFailure(let status): "Secure database-key generation failed with status \(status)."
        case .writeFailure(let reason): "Keychain write failed: \(reason)"
        case .readFailure(let reason): "Keychain read failed: \(reason)"
        }
    }
}

public struct KeychainItemQuery: Sendable, Equatable {
    public let service: String
    public let account: String
    public let useDataProtectionKeychain: Bool
    public let synchronizable: Bool

    public init(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool = false,
        synchronizable: Bool = false
    ) {
        self.service = service
        self.account = account
        self.useDataProtectionKeychain = useDataProtectionKeychain
        self.synchronizable = synchronizable
    }

    fileprivate var attributes: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
            kSecAttrSynchronizable as String: synchronizable,
        ]
    }
}

public enum KeychainReadResult: Sendable {
    case success(Data)
    case failure(OSStatus)
}

public protocol KeychainClient: Sendable {
    func readGenericPassword(query: KeychainItemQuery) -> KeychainReadResult
    func addGenericPassword(
        query: KeychainItemQuery,
        data: Data,
        trustedApplicationPaths: [String]
    ) -> OSStatus
}

private struct SecurityKeychainClient: KeychainClient {
    func readGenericPassword(query: KeychainItemQuery) -> KeychainReadResult {
        var attributes = query.attributes
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(status == errSecSuccess ? errSecDecode : status)
        }
        return .success(data)
    }

    func addGenericPassword(
        query: KeychainItemQuery,
        data: Data,
        trustedApplicationPaths: [String]
    ) -> OSStatus {
        guard !trustedApplicationPaths.isEmpty else { return errSecParam }
        var trustedApplications: [SecTrustedApplication] = []
        for path in trustedApplicationPaths {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &application)
            guard status == errSecSuccess, let application else { return status }
            trustedApplications.append(application)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Hippocampus database key" as CFString,
            trustedApplications as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else { return accessStatus }

        var attributes = query.attributes
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccess as String] = access
        return SecItemAdd(attributes as CFDictionary, nil)
    }
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
    public static let storageModel = "file-keychain-acl-v1"
    public static let trustedExecutableNames = [
        "Hippocampus",
        "MCICaptureHelper",
        "mci-agent",
        "recall-ui",
    ]

    public let reference: KeychainKeyReference
    private let client: any KeychainClient
    private let trustedApplicationPaths: @Sendable () throws -> [String]

    public init(reference: KeychainKeyReference = .defaultDatabaseKey) {
        self.reference = reference
        self.client = SecurityKeychainClient()
        self.trustedApplicationPaths = { try Self.bundledTrustedApplicationPaths() }
    }

    init(
        reference: KeychainKeyReference = .defaultDatabaseKey,
        client: any KeychainClient,
        trustedApplicationPaths: @escaping @Sendable () throws -> [String] = {
            try Self.bundledTrustedApplicationPaths()
        }
    ) {
        self.reference = reference
        self.client = client
        self.trustedApplicationPaths = trustedApplicationPaths
    }

    public static let defaultDatabaseKey = KeychainKeyStore()

    public func readKey() throws -> String {
        let query = KeychainItemQuery(
            service: reference.service,
            account: reference.account,
            useDataProtectionKeychain: false,
            synchronizable: false
        )
        let data: Data
        switch client.readGenericPassword(query: query) {
        case .success(let value): data = value
        case .failure(errSecItemNotFound): throw KeyStoreError.noKeyFound
        case .failure(errSecAuthFailed), .failure(errSecMissingEntitlement):
            throw KeyStoreError.accessDenied
        case .failure(errSecInteractionNotAllowed), .failure(errSecNotAvailable),
             .failure(errSecUserCanceled):
            throw KeyStoreError.interactionNotAllowed
        case .failure(let status):
            throw KeyStoreError.readFailure("SecItemCopyMatching status \(status)")
        }
        guard
              let hex = String(data: data, encoding: .utf8)
        else {
            throw KeyStoreError.readFailure("could not decode Keychain item as UTF-8")
        }
        return try Self.validate(hex)
    }

    public func writeKey(_ hex: String) throws {
        let validated = try Self.validate(hex)
        let data = Data(validated.utf8)
        let paths: [String]
        do {
            paths = try trustedApplicationPaths()
        } catch let error as KeyStoreError {
            throw error
        } catch {
            throw KeyStoreError.aclUnavailable(error.localizedDescription)
        }
        let query = KeychainItemQuery(
            service: reference.service,
            account: reference.account,
            useDataProtectionKeychain: false,
            synchronizable: false
        )
        let status = client.addGenericPassword(
            query: query,
            data: data,
            trustedApplicationPaths: paths
        )
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw KeyStoreError.keyAlreadyExists
        case errSecAuthFailed, errSecMissingEntitlement: throw KeyStoreError.accessDenied
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecUserCanceled:
            throw KeyStoreError.interactionNotAllowed
        default: throw KeyStoreError.writeFailure("SecItemAdd status \(status)")
        }
    }

    private struct SharingManifest: Decodable {
        let storageModel: String
        let service: String
        let account: String
        let trustedExecutables: [String]
        let useDataProtectionKeychain: Bool
        let synchronizable: Bool

        enum CodingKeys: String, CodingKey {
            case storageModel = "storage_model"
            case service, account
            case trustedExecutables = "trusted_executables"
            case useDataProtectionKeychain = "use_data_protection_keychain"
            case synchronizable
        }
    }

    private static func bundledTrustedApplicationPaths() throws -> [String] {
        guard let executable = Bundle.main.executableURL,
              executable.lastPathComponent == "Hippocampus"
        else {
            throw KeyStoreError.aclUnavailable("key creation must run from bundled Hippocampus")
        }
        let macOSDirectory = executable.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents"
        else {
            throw KeyStoreError.aclUnavailable("invalid Hippocampus.app layout")
        }
        let manifestURL = contentsDirectory
            .appendingPathComponent("Resources")
            .appendingPathComponent("keychain-sharing-contract.json")
        let manifest: SharingManifest
        do {
            manifest = try JSONDecoder().decode(
                SharingManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw KeyStoreError.aclUnavailable("cannot validate bundled sharing contract")
        }
        guard manifest.storageModel == storageModel,
              manifest.service == defaultService,
              manifest.account == defaultAccount,
              manifest.trustedExecutables == trustedExecutableNames,
              !manifest.useDataProtectionKeychain,
              !manifest.synchronizable
        else {
            throw KeyStoreError.aclUnavailable("bundled sharing contract does not match the app")
        }
        let paths = trustedExecutableNames.map {
            macOSDirectory.appendingPathComponent($0).path
        }
        guard paths.allSatisfy({ FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw KeyStoreError.aclUnavailable("one or more trusted executables are missing")
        }
        return paths
    }

    static func validate(_ hex: String) throws -> String {
        let bytes = hex.utf8
        guard bytes.count == 64,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...70).contains(byte)
                      || (97...102).contains(byte)
              })
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

    /// Create a local development key on first run. This method is only
    /// reached after `DevelopmentFileKeyMode` validates a signed ad-hoc bundle.
    public func ensureDevelopmentKey() throws {
        guard case .developmentFile = backing else { return }
        do {
            _ = try readKey()
        } catch KeyStoreError.noKeyFound {
            try writeKey(Self.generateHexKey())
        }
    }

    public static func generateHexKey() throws -> String {
        try generateHexKey { count, buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer)
        }
    }

    static func generateHexKey(
        randomCopy: (_ count: Int, _ buffer: UnsafeMutableRawPointer) -> OSStatus
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return randomCopy(buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.keyGenerationFailure(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultDevelopmentKeyPath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("MCI")
        return appSupport.appendingPathComponent("dev.key")
    }
}
