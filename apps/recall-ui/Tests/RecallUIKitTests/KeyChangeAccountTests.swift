import Foundation
import Security
import XCTest

@testable import RecallUIKit

/// Storage-security review S4: during a key change both Keychain items
/// exist and only one opens the memory, so the window tries each, the newer
/// (`database-key-v2`) first; screenshots use the newer one.
final class KeyChangeAccountTests: XCTestCase {
    private final class AccountsClient: KeychainDatabaseKeyClient, @unchecked Sendable {
        let items: [String: KeychainDatabaseKeyReadResult]
        private(set) var accounts: [String] = []

        init(_ items: [String: KeychainDatabaseKeyReadResult]) {
            self.items = items
        }

        func readGenericPassword(query: KeychainDatabaseKeyQuery) -> KeychainDatabaseKeyReadResult {
            XCTAssertFalse(query.useDataProtectionKeychain)
            XCTAssertFalse(query.synchronizable)
            accounts.append(query.account)
            return items[query.account] ?? .failure(errSecItemNotFound)
        }
    }

    private let usual = String(repeating: "aa", count: 32)
    private let rotated = String(repeating: "bb", count: 32)

    func test_both_keys_are_offered_newest_first() throws {
        let client = AccountsClient([
            "database-key-v1": .success(Data(usual.utf8)),
            "database-key-v2": .success(Data(rotated.utf8)),
        ])
        let resolver = KeychainDatabaseKeyResolver(client: client)
        XCTAssertEqual(try resolver.resolveHexCandidates(reference: .defaultDatabaseKey), [rotated, usual])
        XCTAssertEqual(try resolver.resolveHex(reference: .defaultDatabaseKey), rotated)
        XCTAssertEqual(try resolver.resolveBytes(reference: .defaultDatabaseKey), Data(repeating: 0xbb, count: 32))
    }

    func test_without_a_key_change_only_the_usual_key_is_offered() throws {
        let client = AccountsClient(["database-key-v1": .success(Data(usual.utf8))])
        XCTAssertEqual(
            try KeychainDatabaseKeyResolver(client: client).resolveHexCandidates(reference: .defaultDatabaseKey),
            [usual]
        )
    }

    func test_after_a_key_change_the_new_key_alone_is_offered() throws {
        let client = AccountsClient(["database-key-v2": .success(Data(rotated.utf8))])
        XCTAssertEqual(
            try KeychainDatabaseKeyResolver(client: client).resolveHexCandidates(reference: .defaultDatabaseKey),
            [rotated]
        )
    }

    func test_no_key_at_all_is_missing() {
        XCTAssertThrowsError(
            try KeychainDatabaseKeyResolver(client: AccountsClient([:])).resolveHex(reference: .defaultDatabaseKey)
        ) { error in
            XCTAssertEqual(error as? KeychainDatabaseKeyError, .missing)
        }
    }

    func test_another_reference_is_read_exactly() throws {
        let client = AccountsClient([
            "test-account": .success(Data(usual.utf8)),
            "database-key-v2": .success(Data(rotated.utf8)),
        ])
        let reference = KeychainDatabaseKeyReference(service: "ai.hippocampus.brain", account: "test-account")
        XCTAssertEqual(try KeychainDatabaseKeyResolver(client: client).resolveHexCandidates(reference: reference), [usual])
        XCTAssertEqual(client.accounts, ["test-account"])
    }
}

/// Storage-security review S11: a release build never opens the person's
/// memory with a development key; only Demo Memory's own key file opens
/// Demo Memory's own store.
final class DevelopmentKeyGateTests: XCTestCase {
    func testWithoutTheDevelopmentPathOnlyDemoMemorysKeyFileIsRead() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-key-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let demo = DevelopmentDatabaseKeyMaterial.demoMemoryFolder(home: home)
        try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        let mci = home.appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
        try FileManager.default.createDirectory(at: mci, withIntermediateDirectories: true)
        let key = String(repeating: "5a", count: 32)
        try Data(key.utf8).write(to: demo.appendingPathComponent("demo.key"))
        try Data(key.utf8).write(to: mci.appendingPathComponent("dev.key"))
        let demoDB = demo.appendingPathComponent("mci.sqlite").path
        let realDB = mci.appendingPathComponent("mci.sqlite").path

        func ask(_ environment: [String: String], compiledIn: Bool) throws -> String? {
            try DevelopmentDatabaseKeyMaterial.hex(
                from: environment.merging(["MCI_DEVELOPMENT_FILE_KEY": "1"]) { $1 },
                compiledIn: compiledIn, home: home
            )
        }
        // The person's memory: no raw key, no key file, in a release build.
        XCTAssertNil(try ask(["MCI_DB_KEY_HEX": key, "MCI_DB_PATH": realDB], compiledIn: false))
        XCTAssertNil(try ask(["MCI_DB_KEY_FILE": mci.appendingPathComponent("dev.key").path,
                              "MCI_DB_PATH": realDB], compiledIn: false))
        XCTAssertNil(try ask(["MCI_DB_KEY_FILE": demo.appendingPathComponent("demo.key").path,
                              "MCI_DB_PATH": realDB], compiledIn: false))
        XCTAssertNil(try ask(["MCI_DB_KEY_FILE": demo.appendingPathComponent("../../MCI/dev.key").path,
                              "MCI_DB_PATH": demoDB], compiledIn: false))
        // Demo Memory's own key file, for its own store.
        XCTAssertEqual(try ask(["MCI_DB_KEY_FILE": demo.appendingPathComponent("demo.key").path,
                                "MCI_DB_PATH": demoDB], compiledIn: false), key)
        // A debug build keeps the development path.
        XCTAssertEqual(try ask(["MCI_DB_KEY_HEX": key, "MCI_DB_PATH": realDB], compiledIn: true), key)
        XCTAssertEqual(DevelopmentDatabaseKeyMaterial.compiledIn, _isDebugAssertConfiguration())
    }
}
