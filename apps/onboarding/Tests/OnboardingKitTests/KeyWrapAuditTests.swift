import XCTest
@testable import OnboardingKit

final class KeyWrapAuditTests: XCTestCase {

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keywrap-audit-onboarding-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_inspectFile_when_missing_unsealed() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("absent.key")

        let report = KeyWrapAuditor.inspectFile(at: path)

        XCTAssertFalse(report.sealed)
        XCTAssertEqual(report.severity, .interim)
        XCTAssertEqual(report.identifier, path.path)
    }

    func test_inspectFile_when_present_with_0600_sealed() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("dev.key")
        let bytes = Data(repeating: 0x55, count: 64)
        try bytes.write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )

        let report = KeyWrapAuditor.inspectFile(at: path)

        XCTAssertTrue(report.sealed)
        XCTAssertEqual(report.severity, .interim)
        XCTAssertTrue(report.aclDescription.contains("0600"))
        XCTAssertTrue(report.aclDescription.contains("verified"))
    }

    func test_inspectFile_when_world_readable_flags_unexpected() throws {
        let dir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("loose.key")
        try Data("x".utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: path.path
        )

        let report = KeyWrapAuditor.inspectFile(at: path)

        XCTAssertTrue(report.aclDescription.contains("UNEXPECTED"))
    }

    func test_keychainReport_is_production() {
        let r = KeyWrapAuditor.keychainReport(
            itemName: "ai.hippocampus.brain.key.v1",
            accessControlDescription: "kSecAttrAccessibleWhenUnlocked",
            sealed: true
        )
        XCTAssertEqual(r.severity, .production)
        XCTAssertEqual(r.implementationName, "macOS Keychain")
    }

    func test_inMemoryReport_is_devOnly_and_loud() {
        let r = KeyWrapAuditor.inMemoryReport()
        XCTAssertEqual(r.severity, .devOnly)
        XCTAssertTrue(r.implementationName.contains("DEV ONLY"))
        XCTAssertTrue(r.notes.contains(where: { $0.contains("NO at-rest confidentiality") }))
    }

    func test_defaultKeyWrapLocation_points_to_app_support_MCI_devkey() {
        let url = DefaultKeyWrapLocation.devKeyURL()
        XCTAssertEqual(url.lastPathComponent, "dev.key")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "MCI")
    }
}
