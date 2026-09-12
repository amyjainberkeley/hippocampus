// SPDX-License-Identifier: TBD-private
import XCTest
import Security
@testable import HippocampusKit

final class KeyStoreTests: XCTestCase {

    private final class FakeKeychainClient: KeychainClient, @unchecked Sendable {
        var readResult: KeychainReadResult = .failure(errSecItemNotFound)
        var addStatus: OSStatus = errSecSuccess
        private(set) var addedSecrets: [Data] = []
        private(set) var readQueries: [KeychainItemQuery] = []
        private(set) var trustedPaths: [[String]] = []

        func readGenericPassword(query: KeychainItemQuery) -> KeychainReadResult {
            readQueries.append(query)
            return readResult
        }

        func addGenericPassword(
            query: KeychainItemQuery,
            data: Data,
            trustedApplicationPaths: [String]
        ) -> OSStatus {
            addedSecrets.append(data)
            trustedPaths.append(trustedApplicationPaths)
            return addStatus
        }
    }

    private static let trustedPaths = [
        "/Applications/Hippocampus.app/Contents/MacOS/Hippocampus",
        "/Applications/Hippocampus.app/Contents/MacOS/MCICaptureHelper",
        "/Applications/Hippocampus.app/Contents/MacOS/mci-agent",
        "/Applications/Hippocampus.app/Contents/MacOS/recall-ui",
    ]

    private func makeStore(client: FakeKeychainClient) -> KeychainKeyStore {
        KeychainKeyStore(
            client: client,
            trustedApplicationPaths: { Self.trustedPaths }
        )
    }

    func test_default_database_key_reference_names_keychain_item_not_dev_key() {
        let reference = KeychainKeyStore.defaultDatabaseKey.reference

        XCTAssertEqual(reference.service, "ai.hippocampus.brain")
        XCTAssertEqual(reference.account, "database-key-v1")
        XCTAssertFalse(reference.service.contains("dev.key"))
        XCTAssertFalse(reference.account.contains("dev.key"))
    }

    func test_default_file_key_store_uses_keychain_backing_unless_path_is_explicit() {
        let store = FileKeyStore()

        XCTAssertEqual(store.storageKind, .keychain)
        XCTAssertEqual(store.keychainReference, .defaultDatabaseKey)
    }

    func test_explicit_file_key_store_remains_available_for_development_and_tests() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-keystore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("dev.key")
        let store = FileKeyStore(path: path)

        XCTAssertEqual(store.storageKind, .developmentFile)
        XCTAssertEqual(store.path.path, path.path)
    }

    func test_development_mode_requires_the_signed_bundle_capability() {
        let support = URL(fileURLWithPath: "/tmp/Application Support")

        XCTAssertNil(DevelopmentFileKeyMode.from(
            infoDictionary: [:],
            applicationSupportDirectory: support
        ))
        XCTAssertEqual(
            DevelopmentFileKeyMode.from(
                infoDictionary: [DevelopmentFileKeyMode.infoPlistKey: true],
                applicationSupportDirectory: support
            )?.keyURL.path,
            "/tmp/Application Support/MCI/dev.key"
        )
    }

    func test_keychain_read_distinguishes_not_found_from_access_denied() {
        let client = FakeKeychainClient()
        client.readResult = .failure(errSecAuthFailed)
        let store = makeStore(client: client)

        XCTAssertThrowsError(try store.readKey()) { error in
            guard case KeyStoreError.accessDenied = error else {
                return XCTFail("expected accessDenied, got \(error)")
            }
        }
    }

    func test_keychain_read_distinguishes_locked_or_noninteractive_state() {
        let client = FakeKeychainClient()
        client.readResult = .failure(errSecInteractionNotAllowed)
        let store = makeStore(client: client)

        XCTAssertThrowsError(try store.readKey()) { error in
            guard case KeyStoreError.interactionNotAllowed = error else {
                return XCTFail("expected interactionNotAllowed, got \(error)")
            }
        }
    }

    func test_keychain_write_never_updates_a_duplicate_item() {
        let client = FakeKeychainClient()
        client.addStatus = errSecDuplicateItem
        let store = makeStore(client: client)

        XCTAssertThrowsError(try store.writeKey(String(repeating: "ab", count: 32))) { error in
            guard case KeyStoreError.keyAlreadyExists = error else {
                return XCTFail("expected keyAlreadyExists, got \(error)")
            }
        }
        XCTAssertEqual(client.addedSecrets.count, 1)
    }

    func test_keychain_queries_pin_file_based_non_synchronizable_domain() {
        let client = FakeKeychainClient()
        client.readResult = .success(Data(String(repeating: "ab", count: 32).utf8))
        let store = makeStore(client: client)

        XCTAssertNoThrow(try store.readKey())
        XCTAssertEqual(
            client.readQueries,
            [KeychainItemQuery(
                service: "ai.hippocampus.brain",
                account: "database-key-v1",
                useDataProtectionKeychain: false,
                synchronizable: false
            )]
        )
    }

    func test_keychain_write_attaches_exact_bundled_executable_acl() throws {
        let client = FakeKeychainClient()
        let store = makeStore(client: client)

        try store.writeKey(String(repeating: "cd", count: 32))

        XCTAssertEqual(client.trustedPaths, [Self.trustedPaths])
    }

    func test_validation_rejects_unicode_hex_digits() {
        let fullWidthHex = String(repeating: "Ａ", count: 64)

        XCTAssertThrowsError(try KeychainKeyStore.validate(fullWidthHex)) { error in
            XCTAssertEqual(error as? KeyStoreError, .invalidKeyLength)
        }
    }

    func test_keychain_read_rejects_whitespace_wrapped_key() {
        let client = FakeKeychainClient()
        client.readResult = .success(Data((String(repeating: "ab", count: 32) + "\n").utf8))
        let store = makeStore(client: client)

        XCTAssertThrowsError(try store.readKey()) { error in
            XCTAssertEqual(error as? KeyStoreError, .invalidKeyLength)
        }
    }

    func test_generation_fails_when_secure_random_source_fails() {
        XCTAssertThrowsError(
            try FileKeyStore.generateHexKey(randomCopy: { _, _ in errSecNotAvailable })
        ) { error in
            XCTAssertEqual(error as? KeyStoreError, .keyGenerationFailure(errSecNotAvailable))
        }
    }
}
