import Foundation
import Security
import XCTest

@testable import MCICaptureHelperKit

final class KeychainDatabaseKeyResolverTests: XCTestCase {
    private struct FakeClient: KeychainDatabaseKeyClient {
        let result: KeychainDatabaseKeyReadResult

        func readGenericPassword(query: KeychainDatabaseKeyQuery) -> KeychainDatabaseKeyReadResult {
            result
        }
    }

    func test_resolves_default_keychain_item_to_32_key_bytes() throws {
        let hex = String(repeating: "ab", count: 32)
        let resolver = KeychainDatabaseKeyResolver(
            client: FakeClient(result: .success(Data(hex.utf8)))
        )

        let bytes = try resolver.resolveBytes(reference: .defaultDatabaseKey)

        XCTAssertEqual(bytes.count, 32)
        XCTAssertEqual(bytes.first, 0xab)
    }

    func test_access_denied_is_not_reported_as_missing() {
        let resolver = KeychainDatabaseKeyResolver(
            client: FakeClient(result: .failure(errSecAuthFailed))
        )

        XCTAssertThrowsError(try resolver.resolveBytes(reference: .defaultDatabaseKey)) { error in
            guard case KeychainDatabaseKeyError.accessDenied = error else {
                return XCTFail("expected accessDenied, got \(error)")
            }
        }
    }

    func test_reference_reads_only_service_and_account_metadata() {
        let reference = KeychainDatabaseKeyReference.from(environment: [
            "MCI_DB_KEYCHAIN_SERVICE": "test.service",
            "MCI_DB_KEYCHAIN_ACCOUNT": "test-account",
            "MCI_DB_KEY_HEX": String(repeating: "ff", count: 32),
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
            client: FakeClient(result: .success(Data(String(repeating: "Ａ", count: 64).utf8)))
        )

        XCTAssertThrowsError(try resolver.resolveBytes(reference: .defaultDatabaseKey)) { error in
            XCTAssertEqual(error as? KeychainDatabaseKeyError, .malformed)
        }
    }
}
