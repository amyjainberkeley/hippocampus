// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

final class KeyWrapAuditTests: XCTestCase {

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keywrap-audit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - inspectFile

    func test_inspectFile_when_file_missing_reports_unsealed() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("missing.key")

        let report = KeyWrapAuditor.inspectFile(at: path)

        XCTAssertEqual(report.implementationName, "FileKeyStore (interim)")
        XCTAssertEqual(report.severity, .interim)
        XCTAssertFalse(report.sealed)
        XCTAssertEqual(report.identifier, path.path)
        XCTAssertTrue(report.notes.contains(where: { $0.contains("not found") }),
                      "missing-file note should be present, got: \(report.notes)")
    }

    func test_inspectFile_when_present_with_0600_reports_sealed() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("dev.key")

        let store = FileKeyStore(path: path)
        try store.writeKey(FileKeyStore.generateHexKey())

        let report = KeyWrapAuditor.inspectFile(at: path)

        XCTAssertTrue(report.sealed)
        XCTAssertEqual(report.severity, .interim)
        XCTAssertTrue(report.aclDescription.contains("0600"))
        XCTAssertTrue(report.aclDescription.contains("verified"),
                      "expected ACL string to confirm mode, got: \(report.aclDescription)")
        switch report.reveal {
        case .showInFinder(let url):
            XCTAssertEqual(url.path, path.path)
        default:
            XCTFail("FileKeyStore audit should offer Show-in-Finder, got: \(report.reveal)")
        }
    }

    func test_inspectFile_when_wrong_permissions_flags_unexpected() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("badperm.key")
        try Data("00".utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: path.path
        )

        let report = KeyWrapAuditor.inspectFile(at: path)

        XCTAssertTrue(report.sealed, "file exists, so wrap is technically reachable")
        XCTAssertTrue(report.aclDescription.contains("UNEXPECTED"),
                      "non-0600 should be flagged, got: \(report.aclDescription)")
    }

    // MARK: - keychainReport (forward-compat path)

    func test_keychainReport_carries_production_severity_and_acl() {
        let report = KeyWrapAuditor.keychainReport(
            itemName: "ai.hippocampus.brain.key.v1",
            accessControlDescription: "kSecAttrAccessibleWhenUnlocked",
            sealed: true
        )

        XCTAssertEqual(report.implementationName, "macOS Keychain")
        XCTAssertEqual(report.severity, .production)
        XCTAssertTrue(report.sealed)
        XCTAssertEqual(report.identifier, "ai.hippocampus.brain.key.v1")
        XCTAssertEqual(report.aclDescription, "kSecAttrAccessibleWhenUnlocked")
        switch report.reveal {
        case .showInKeychainAccess(let name):
            XCTAssertEqual(name, "ai.hippocampus.brain.key.v1")
        default:
            XCTFail("Keychain report should offer Show-in-Keychain-Access")
        }
    }

    // MARK: - inMemoryReport (dev-only label is loud)

    func test_inMemoryReport_labels_dev_only_and_carries_warning_notes() {
        let report = KeyWrapAuditor.inMemoryReport()

        XCTAssertEqual(report.severity, .devOnly)
        XCTAssertTrue(report.implementationName.contains("DEV ONLY"),
                      "implementation name must shout DEV ONLY for the panel banner, got: \(report.implementationName)")
        XCTAssertTrue(report.aclDescription.contains("NONE") || report.aclDescription.contains("plaintext"),
                      "dev wrap must call out its lack of confidentiality, got: \(report.aclDescription)")
        XCTAssertEqual(report.reveal, .none)
        XCTAssertTrue(report.notes.contains(where: { $0.contains("NO at-rest confidentiality") }),
                      "dev wrap notes must warn explicitly")
        XCTAssertTrue(report.notes.contains(where: { $0.contains("critical bug") }),
                      "dev wrap notes must flag the shipped-build case as a bug")
    }

    // MARK: - content-free invariant

    func test_report_never_carries_key_bytes() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("witness.key")
        // Distinct, recognisable witness pattern. Both the full hex and a
        // 16-char prefix must be absent from every audit field — the panel
        // must never quote even a sliver of the key.
        let knownHex = "0123456789abcdef" + String(repeating: "a5", count: 24)
        let prefix16 = String(knownHex.prefix(16))
        let store = FileKeyStore(path: path)
        try store.writeKey(knownHex)

        let report = KeyWrapAuditor.inspectFile(at: path)

        let mirrorFields: [String] = [
            report.implementationName,
            report.aclDescription,
            report.identifier,
        ] + report.notes
        for field in mirrorFields {
            XCTAssertFalse(field.contains(knownHex),
                           "audit field leaked the full key bytes: \(field)")
            XCTAssertFalse(field.contains(prefix16),
                           "audit field embedded a 16-hex-char fragment of the key: \(field)")
        }
    }

    // MARK: - FileKeyStore.auditReport convenience

    func test_fileKeyStore_auditReport_matches_inspectFile() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("dev.key")
        let store = FileKeyStore(path: path)
        try store.writeKey(FileKeyStore.generateHexKey())

        let viaExtension = store.auditReport()
        let viaInspector = KeyWrapAuditor.inspectFile(at: path)

        XCTAssertEqual(viaExtension.implementationName, viaInspector.implementationName)
        XCTAssertEqual(viaExtension.severity, viaInspector.severity)
        XCTAssertEqual(viaExtension.sealed, viaInspector.sealed)
        XCTAssertEqual(viaExtension.identifier, viaInspector.identifier)
    }
}
