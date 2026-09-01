// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

final class KeyStoreTests: XCTestCase {

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
}
