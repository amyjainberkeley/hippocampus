// SPDX-License-Identifier: TBD-private
import Security
import XCTest
@testable import HippocampusKit

final class KeyWrapAuditTests: XCTestCase {
    private final class FakeKeychainClient: KeychainClient, @unchecked Sendable {
        var result: KeychainReadResult
        private(set) var queries: [KeychainItemQuery] = []

        init(result: KeychainReadResult) {
            self.result = result
        }

        func readGenericPassword(query: KeychainItemQuery) -> KeychainReadResult {
            queries.append(query)
            return result
        }

        func addGenericPassword(
            query: KeychainItemQuery,
            data: Data,
            trustedApplicationPaths: [String]
        ) -> OSStatus {
            XCTFail("audit must never write Keychain state")
            return errSecParam
        }
    }

    private func store(client: FakeKeychainClient) -> KeychainKeyStore {
        KeychainKeyStore(client: client, trustedApplicationPaths: { [] })
    }

    func test_keychain_audit_uses_exact_file_domain_reference_and_reports_readable() async {
        let key = String(repeating: "ab", count: 32)
        let client = FakeKeychainClient(result: .success(Data(key.utf8)))

        let report = await KeyWrapAuditor.inspectKeychain(store(client: client))

        XCTAssertTrue(report.keyReadable)
        XCTAssertEqual(report.accessControlVerification, .unverified)
        XCTAssertEqual(report.severity, .production)
        XCTAssertEqual(report.implementationName, "macOS file-based Keychain")
        XCTAssertEqual(client.queries, [KeychainItemQuery(
            service: "ai.hippocampus.brain",
            account: "database-key-v1",
            useDataProtectionKeychain: false,
            synchronizable: false
        )])
        XCTAssertTrue(report.identifier.contains("ai.hippocampus.brain"))
        XCTAssertFalse(report.identifier.contains(key))
    }

    func test_keychain_audit_reports_missing_or_denied_without_claiming_readable() async {
        for status in [errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed] {
            let client = FakeKeychainClient(result: .failure(status))
            let report = await KeyWrapAuditor.inspectKeychain(store(client: client))

            XCTAssertFalse(report.keyReadable)
            XCTAssertEqual(report.accessControlVerification, .unverified)
            XCTAssertTrue(report.notes.contains(where: { $0.contains("unavailable") }))
        }
    }

    func test_report_never_carries_key_bytes() async {
        let key = "0123456789abcdef" + String(repeating: "a5", count: 24)
        let client = FakeKeychainClient(result: .success(Data(key.utf8)))
        let report = await KeyWrapAuditor.inspectKeychain(store(client: client))
        let fields = [
            report.implementationName,
            report.accessControlDescription,
            report.identifier,
        ] + report.notes

        XCTAssertFalse(fields.contains(where: { $0.contains(key) }))
        XCTAssertFalse(fields.contains(where: { $0.contains(String(key.prefix(16))) }))
    }

    func test_in_memory_report_is_loudly_development_only() {
        let report = KeyWrapAuditor.inMemoryReport()

        XCTAssertEqual(report.severity, .devOnly)
        XCTAssertTrue(report.implementationName.contains("DEV ONLY"))
        XCTAssertEqual(report.reveal, .none)
    }
}
