import Foundation
import Security
import XCTest

@testable import MCICaptureHelperKit

/// Storage-security review S4: while a key change moves the memory to a new
/// key, the new key is under `database-key-v2`. The helper starts only once
/// `ensure-key` has finished or undone the change, so an item there is the
/// memory's key, and screenshots must be sealed under it.
final class KeyChangeAccountTests: XCTestCase {
    private final class AccountsClient: KeychainDatabaseKeyClient, @unchecked Sendable {
        var items: [String: KeychainDatabaseKeyReadResult]
        private(set) var accounts: [String] = []

        init(_ items: [String: KeychainDatabaseKeyReadResult]) {
            self.items = items
        }

        func readGenericPassword(query: KeychainDatabaseKeyQuery) -> KeychainDatabaseKeyReadResult {
            XCTAssertFalse(query.useDataProtectionKeychain)
            XCTAssertFalse(query.synchronizable)
            XCTAssertEqual(query.service, "ai.hippocampus.brain")
            accounts.append(query.account)
            return items[query.account] ?? .failure(errSecItemNotFound)
        }
    }

    private let usual = String(repeating: "11", count: 32)
    private let rotated = String(repeating: "22", count: 32)

    func test_a_key_under_the_key_change_account_seals_screenshots() throws {
        let client = AccountsClient([
            "database-key-v1": .success(Data(usual.utf8)),
            "database-key-v2": .success(Data(rotated.utf8)),
        ])
        let bytes = try KeychainDatabaseKeyResolver(client: client)
            .resolveBytes(reference: .defaultDatabaseKey)
        XCTAssertEqual(bytes, [UInt8](repeating: 0x22, count: 32))
        XCTAssertEqual(client.accounts, ["database-key-v2"])
    }

    func test_without_a_key_change_the_usual_item_is_used() throws {
        let client = AccountsClient(["database-key-v1": .success(Data(usual.utf8))])
        let bytes = try KeychainDatabaseKeyResolver(client: client)
            .resolveBytes(reference: .defaultDatabaseKey)
        XCTAssertEqual(bytes, [UInt8](repeating: 0x11, count: 32))
        XCTAssertEqual(client.accounts, ["database-key-v2", "database-key-v1"])
    }

    func test_a_locked_key_change_item_is_an_error_not_a_reason_to_use_the_old_key() {
        let client = AccountsClient([
            "database-key-v1": .success(Data(usual.utf8)),
            "database-key-v2": .failure(errSecInteractionNotAllowed),
        ])
        XCTAssertThrowsError(
            try KeychainDatabaseKeyResolver(client: client).resolveBytes(reference: .defaultDatabaseKey)
        ) { error in
            XCTAssertEqual(error as? KeychainDatabaseKeyError, .interactionNotAllowed)
        }
    }

    func test_another_reference_is_read_exactly() throws {
        let client = AccountsClient([
            "test-account": .success(Data(usual.utf8)),
            "database-key-v2": .success(Data(rotated.utf8)),
        ])
        let reference = KeychainDatabaseKeyReference(service: "ai.hippocampus.brain", account: "test-account")
        _ = try KeychainDatabaseKeyResolver(client: client).resolveBytes(reference: reference)
        XCTAssertEqual(client.accounts, ["test-account"])
    }
}

/// Storage-security review S11: a release build of the helper reads the
/// Keychain even when the environment asks for the development key.
final class DevelopmentKeyGateTests: XCTestCase {
    private struct Client: KeychainDatabaseKeyClient {
        func readGenericPassword(query: KeychainDatabaseKeyQuery) -> KeychainDatabaseKeyReadResult {
            query.account == "database-key-v1"
                ? .success(Data(String(repeating: "33", count: 32).utf8))
                : .failure(errSecItemNotFound)
        }
    }

    func testAReleaseBuildIgnoresTheDevelopmentKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dev-\(UUID().uuidString).key")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(String(repeating: "44", count: 32).utf8).write(to: file)
        let environment = ["MCI_DEVELOPMENT_FILE_KEY": "1", "MCI_DB_KEY_FILE": file.path]
        let resolver = KeychainDatabaseKeyResolver(client: Client())
        let release = try resolver.resolveBytes(
            environment: environment, developmentKeyPath: file, developmentCompiledIn: false
        )
        XCTAssertEqual(release, [UInt8](repeating: 0x33, count: 32), "the Keychain's key, not the file's")
        let debug = try resolver.resolveBytes(
            environment: environment, developmentKeyPath: file, developmentCompiledIn: true
        )
        XCTAssertEqual(debug, [UInt8](repeating: 0x44, count: 32))
        XCTAssertEqual(KeychainDatabaseKeyResolver.developmentKeyCompiledIn, _isDebugAssertConfiguration())
    }
}
