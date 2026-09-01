import Foundation
import Security
import XCTest

@testable import RecallUIKit

final class KeychainDatabaseKeyResolverTests: XCTestCase {
    private struct FakeClient: KeychainDatabaseKeyClient {
        let result: KeychainDatabaseKeyReadResult

        func readGenericPassword(query: KeychainDatabaseKeyQuery) -> KeychainDatabaseKeyReadResult {
            result
        }
    }

    func test_resolves_keychain_reference_to_validated_hex() throws {
        let expected = String(repeating: "cd", count: 32)
        let resolver = KeychainDatabaseKeyResolver(
            client: FakeClient(result: .success(Data(expected.utf8)))
        )

        XCTAssertEqual(
            try resolver.resolveHex(reference: .defaultDatabaseKey),
            expected
        )
    }

    func test_locked_keychain_is_distinct_from_missing_item() {
        let resolver = KeychainDatabaseKeyResolver(
            client: FakeClient(result: .failure(errSecInteractionNotAllowed))
        )

        XCTAssertThrowsError(try resolver.resolveHex(reference: .defaultDatabaseKey)) { error in
            guard case KeychainDatabaseKeyError.interactionNotAllowed = error else {
                return XCTFail("expected interactionNotAllowed, got \(error)")
            }
        }
    }

    func test_reference_uses_supervisor_metadata_and_ignores_raw_key_environment() {
        let reference = KeychainDatabaseKeyReference.from(environment: [
            "MCI_DB_KEYCHAIN_SERVICE": "test.service",
            "MCI_DB_KEYCHAIN_ACCOUNT": "test-account",
            "MCI_DB_KEY_HEX": String(repeating: "ee", count: 32),
        ])

        XCTAssertEqual(reference.service, "test.service")
        XCTAssertEqual(reference.account, "test-account")
    }

    func test_query_pins_file_based_non_synchronizable_keychain_domain() {
        XCTAssertEqual(
            KeychainDatabaseKeyQuery(reference: .defaultDatabaseKey),
            KeychainDatabaseKeyQuery(
                service: "ai.hippocampus.brain",
                account: "database-key-v1",
                useDataProtectionKeychain: false,
                synchronizable: false
            )
        )
    }

    func test_rejects_unicode_hex_lookalikes() {
        let resolver = KeychainDatabaseKeyResolver(
            client: FakeClient(result: .success(Data(String(repeating: "Ｆ", count: 64).utf8)))
        )

        XCTAssertThrowsError(try resolver.resolveHex(reference: .defaultDatabaseKey)) { error in
            XCTAssertEqual(error as? KeychainDatabaseKeyError, .malformed)
        }
    }
}
