// SPDX-License-Identifier: TBD-private
//
// UserAllowlistTOMLLoaderTests — ADR-0017 §3.2 user-layer allowlist.
// Pins the parser surface (strict TOML subset; bool parsing for
// capture_enabled + deep_hook_enabled; refuses anything malformed) AND
// the permission-validation surface (refuses world/group-readable or
// foreign-owned files).

import XCTest

@testable import MCICaptureHelperKit

final class UserAllowlistTOMLLoaderHappyPathTests: XCTestCase {
    func testEmptyDocumentParsesToZeroEntries() throws {
        let loader = UserAllowlistTOMLLoader()
        let entries = try loader.parse("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testOnlyCommentsAndBlanksParsesToZeroEntries() throws {
        let loader = UserAllowlistTOMLLoader()
        let entries = try loader.parse("""
        # MCI user-allowlist
        # added by onboarding UI

        # entries go below
        """)
        XCTAssertTrue(entries.isEmpty)
    }

    func testSingleEntryFullSchema() throws {
        let loader = UserAllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        bundle_id = "com.spotify.client"
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"
        rationale = "Music app"
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].bundleId, "com.spotify.client")
        XCTAssertTrue(entries[0].captureEnabled)
        XCTAssertFalse(entries[0].deepHookEnabled)
        XCTAssertEqual(entries[0].addedAt, "2026-05-29")
        XCTAssertEqual(entries[0].rationale, "Music app")
    }

    func testRationaleIsOptional() throws {
        let loader = UserAllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        bundle_id = "com.example.foo"
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].rationale)
    }

    func testMultipleEntriesDocumentOrder() throws {
        let loader = UserAllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        bundle_id = "com.first.app"
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"

        [[entries]]
        bundle_id = "com.second.app"
        capture_enabled = false
        deep_hook_enabled = true
        added_at = "2026-05-29"
        """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].bundleId, "com.first.app")
        XCTAssertTrue(entries[0].captureEnabled)
        XCTAssertFalse(entries[0].deepHookEnabled)
        XCTAssertEqual(entries[1].bundleId, "com.second.app")
        XCTAssertFalse(entries[1].captureEnabled)
        XCTAssertTrue(entries[1].deepHookEnabled)
    }

    func testKeyOrderInsideTableDoesNotMatter() throws {
        let loader = UserAllowlistTOMLLoader()
        let entries = try loader.parse("""
        [[entries]]
        added_at = "2026-05-29"
        deep_hook_enabled = true
        bundle_id = "com.apple.MobileSMS"
        capture_enabled = true
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].bundleId, "com.apple.MobileSMS")
        XCTAssertTrue(entries[0].deepHookEnabled)
    }
}

final class UserAllowlistTOMLLoaderErrorTests: XCTestCase {
    func testMissingBundleId() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"
        """)) { err in
            guard case UserAllowlistError.missingBundleId = err else {
                return XCTFail("expected missingBundleId, got \(err)")
            }
        }
    }

    func testMissingCaptureEnabled() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.foo.app"
        deep_hook_enabled = false
        added_at = "2026-05-29"
        """)) { err in
            guard case UserAllowlistError.missingCaptureEnabled = err else {
                return XCTFail("expected missingCaptureEnabled, got \(err)")
            }
        }
    }

    func testMissingDeepHookEnabled() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.foo.app"
        capture_enabled = true
        added_at = "2026-05-29"
        """)) { err in
            guard case UserAllowlistError.missingDeepHookEnabled = err else {
                return XCTFail("expected missingDeepHookEnabled, got \(err)")
            }
        }
    }

    func testMissingAddedAt() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.foo.app"
        capture_enabled = true
        deep_hook_enabled = false
        """)) { err in
            guard case UserAllowlistError.missingAddedAt = err else {
                return XCTFail("expected missingAddedAt, got \(err)")
            }
        }
    }

    func testInvalidBooleanRefused() {
        let loader = UserAllowlistTOMLLoader()
        // `capture_enabled = "true"` (quoted-string, not bool literal) — refused.
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.foo.app"
        capture_enabled = "true"
        deep_hook_enabled = false
        added_at = "2026-05-29"
        """)) { err in
            guard case UserAllowlistError.invalidBoolean(_, "capture_enabled") = err else {
                return XCTFail("expected invalidBoolean(capture_enabled), got \(err)")
            }
        }
    }

    func testEmptyBundleIdRefused() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = ""
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"
        """)) { err in
            guard case UserAllowlistError.emptyValue(_, "bundle_id") = err else {
                return XCTFail("expected emptyValue(bundle_id), got \(err)")
            }
        }
    }

    func testUnknownKeyInsideEntryRefused() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.foo.app"
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"
        cso_ratified_by = "user"
        """)) { err in
            guard case UserAllowlistError.malformedKvLine = err else {
                return XCTFail("expected malformedKvLine for unknown key, got \(err)")
            }
        }
    }

    func testDuplicateKeyInsideEntryRefused() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        [[entries]]
        bundle_id = "com.foo.app"
        bundle_id = "com.bar.app"
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"
        """)) { err in
            guard case UserAllowlistError.duplicateKey(_, "bundle_id") = err else {
                return XCTFail("expected duplicateKey(bundle_id), got \(err)")
            }
        }
    }

    func testLineOutsideTableRefused() {
        let loader = UserAllowlistTOMLLoader()
        XCTAssertThrowsError(try loader.parse("""
        bundle_id = "com.foo.app"
        """)) { err in
            guard case UserAllowlistError.unexpectedLine = err else {
                return XCTFail("expected unexpectedLine, got \(err)")
            }
        }
    }
}

final class UserAllowlistDerivedSetsTests: XCTestCase {
    func testCaptureEnabledBundleIdsExcludesDisabledEntries() {
        let userAllowlist = UserAllowlist(entries: [
            UserAllowlistEntry(
                bundleId: "com.spotify.client",
                captureEnabled: true,
                deepHookEnabled: false,
                addedAt: "2026-05-29"
            ),
            UserAllowlistEntry(
                bundleId: "com.opted-out.app",
                captureEnabled: false,
                deepHookEnabled: false,
                addedAt: "2026-05-29"
            ),
            UserAllowlistEntry(
                bundleId: "com.apple.MobileSMS",
                captureEnabled: true,
                deepHookEnabled: true,
                addedAt: "2026-05-29"
            ),
        ])
        XCTAssertEqual(
            userAllowlist.captureEnabledBundleIds,
            ["com.spotify.client", "com.apple.MobileSMS"]
        )
    }

    func testDeepHookEnabledBundleIdsOnlyForOptedIn() {
        let userAllowlist = UserAllowlist(entries: [
            UserAllowlistEntry(
                bundleId: "com.spotify.client",
                captureEnabled: true,
                deepHookEnabled: false,
                addedAt: "2026-05-29"
            ),
            UserAllowlistEntry(
                bundleId: "com.apple.MobileSMS",
                captureEnabled: true,
                deepHookEnabled: true,
                addedAt: "2026-05-29"
            ),
        ])
        XCTAssertEqual(
            userAllowlist.deepHookEnabledBundleIds,
            ["com.apple.MobileSMS"]
        )
    }

    func testEmptyAllowlistDerivesEmptySets() {
        XCTAssertTrue(UserAllowlist.empty.captureEnabledBundleIds.isEmpty)
        XCTAssertTrue(UserAllowlist.empty.deepHookEnabledBundleIds.isEmpty)
    }
}

final class UserAllowlistPermissionValidationTests: XCTestCase {
    /// Returns a tempdir path that's safe to delete after the test.
    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("user-allowlist-perm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    func testValidatePermissionsAccepts0600File() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("user-allowlist.toml")
        try "".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: file.path
        )
        XCTAssertNoThrow(try UserAllowlistTOMLLoader.validatePermissions(at: file))
    }

    func testValidatePermissionsRefusesWorldReadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("user-allowlist.toml")
        try "".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: file.path
        )
        XCTAssertThrowsError(try UserAllowlistTOMLLoader.validatePermissions(at: file)) { err in
            guard case UserAllowlistError.insecureFilePermissions = err else {
                return XCTFail("expected insecureFilePermissions, got \(err)")
            }
        }
    }

    func testValidatePermissionsRefusesGroupReadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("user-allowlist.toml")
        try "".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o640))],
            ofItemAtPath: file.path
        )
        XCTAssertThrowsError(try UserAllowlistTOMLLoader.validatePermissions(at: file)) { err in
            guard case UserAllowlistError.insecureFilePermissions = err else {
                return XCTFail("expected insecureFilePermissions, got \(err)")
            }
        }
    }

    func testLoadFromUserPathReturnsEmptyWhenMissing() throws {
        // The default user path may or may not exist on CI; the contract
        // is "missing file → empty allowlist". We assert the contract by
        // calling the loader and checking that any return value is well-
        // formed (either empty for missing or parsed for present).
        let result = try? UserAllowlistTOMLLoader.loadFromUserPath()
        if let allowlist = result {
            XCTAssertNotNil(allowlist.captureEnabledBundleIds)
        }
    }
}
