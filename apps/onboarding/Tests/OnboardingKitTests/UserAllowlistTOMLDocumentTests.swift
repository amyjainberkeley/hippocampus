import XCTest
@testable import OnboardingKit

final class UserAllowlistTOMLDocumentEmitParseTests: XCTestCase {

    func testEmptyEmitProducesCommentOnly() {
        let s = UserAllowlistTOMLDocument.emit([])
        XCTAssertTrue(s.contains("# MCI user-allowlist v1"))
        XCTAssertFalse(s.contains("[[entries]]"))
    }

    func testEmitParseRoundTripSingleEntry() throws {
        let entries = [
            UserAllowlistEntry(
                bundleId: "com.spotify.client",
                captureEnabled: true,
                deepHookEnabled: false,
                addedAt: "2026-05-29",
                rationale: "Music"
            ),
        ]
        let s = UserAllowlistTOMLDocument.emit(entries)
        let parsed = try UserAllowlistTOMLDocument.parse(s)
        XCTAssertEqual(parsed, entries)
    }

    func testEmitParseRoundTripMultiple() throws {
        let entries = [
            UserAllowlistEntry(
                bundleId: "com.apple.MobileSMS",
                captureEnabled: true,
                deepHookEnabled: true,
                addedAt: "2026-05-29"
            ),
            UserAllowlistEntry(
                bundleId: "com.apple.mail",
                captureEnabled: true,
                deepHookEnabled: false,
                addedAt: "2026-05-29",
                rationale: "Work mail"
            ),
            UserAllowlistEntry(
                bundleId: "com.opted-out.app",
                captureEnabled: false,
                deepHookEnabled: false,
                addedAt: "2026-05-29"
            ),
        ]
        let s = UserAllowlistTOMLDocument.emit(entries)
        let parsed = try UserAllowlistTOMLDocument.parse(s)
        XCTAssertEqual(parsed, entries)
    }

    func testRationaleQuotesAreStrippedOnEmit() throws {
        // Hostile user input with `"` and `\` — emit MUST sanitize so
        // the helper's strict reader doesn't refuse the file.
        let entries = [
            UserAllowlistEntry(
                bundleId: "com.foo.bar",
                captureEnabled: true,
                deepHookEnabled: false,
                addedAt: "2026-05-29",
                rationale: #"Has "quotes" and \backslashes"#
            ),
        ]
        let s = UserAllowlistTOMLDocument.emit(entries)
        let parsed = try UserAllowlistTOMLDocument.parse(s)
        XCTAssertEqual(parsed.first?.bundleId, "com.foo.bar")
        // The hostile chars are stripped — exact form is implementation
        // detail; the contract is that the round-trip is valid.
        XCTAssertNotNil(parsed.first?.rationale)
        XCTAssertFalse(parsed.first?.rationale?.contains("\\") ?? true)
        XCTAssertFalse(parsed.first?.rationale?.contains("\"") ?? true)
    }

    func testParseIgnoresUnknownKeysAndComments() throws {
        let s = """
        # leading comment
        [[entries]]
        bundle_id = "com.example.app"
        # inline comment is tolerated
        capture_enabled = true
        deep_hook_enabled = false
        added_at = "2026-05-29"
        future_field = "ignored"
        """
        let parsed = try UserAllowlistTOMLDocument.parse(s)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].bundleId, "com.example.app")
    }

    func testParseSkipsIncompleteRow() throws {
        let s = """
        [[entries]]
        bundle_id = "com.broken.app"
        # missing capture_enabled / deep_hook_enabled / added_at
        """
        let parsed = try UserAllowlistTOMLDocument.parse(s)
        XCTAssertTrue(parsed.isEmpty)
    }
}

final class FileUserAllowlistStoreTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("user-allowlist-test-\(UUID().uuidString).toml")
    }

    func testSaveThenLoadRoundTrip() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileUserAllowlistStore(url: url)
        let entries = [
            UserAllowlistEntry(
                bundleId: "com.apple.MobileSMS",
                captureEnabled: true,
                deepHookEnabled: true,
                addedAt: "2026-05-29"
            ),
        ]
        try await store.save(entries)
        let loaded = await store.load()
        XCTAssertEqual(loaded, entries)
    }

    func testSaveSetsFileMode0600() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileUserAllowlistStore(url: url)
        try await store.save([
            UserAllowlistEntry(
                bundleId: "com.foo.app",
                captureEnabled: true,
                deepHookEnabled: false,
                addedAt: "2026-05-29"
            ),
        ])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        // No group / world bits MUST be set.
        XCTAssertEqual(perms & 0o077, 0)
    }

    func testLoadOnMissingFileReturnsEmpty() async {
        let store = FileUserAllowlistStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("definitely-missing-\(UUID().uuidString).toml")
        )
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }
}
