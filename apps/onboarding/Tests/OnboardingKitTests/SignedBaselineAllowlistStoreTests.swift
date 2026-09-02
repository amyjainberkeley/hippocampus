import Foundation
import XCTest
@testable import OnboardingKit

final class SignedBaselineAllowlistStoreTests: XCTestCase {
    func testReadsCompleteSignedBaselineEntries() async throws {
        let url = try writeTemporaryBaseline(
            """
            [[entries]]
            bundle_id = "com.apple.MobileSMS"
            rationale = "Messages"
            cso_ratified_by = "security-team"
            ratified_at = "2026-05-29"
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = await SignedBaselineAllowlistStore(url: url).entries()

        XCTAssertEqual(entries, [
            AllowlistEntry(bundleId: "com.apple.MobileSMS", rationale: "Messages"),
        ])
    }

    func testFailsClosedForMalformedSignedInputWithoutUsingStubCatalog() async throws {
        let url = try writeTemporaryBaseline(
            """
            [[entries]]
            bundle_id = "com.apple.MobileSMS"
            rationale = "Messages"
            cso_ratified_by = "security-team"
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = await SignedBaselineAllowlistStore(url: url).entries()

        XCTAssertEqual(entries, [])
    }

    private func writeTemporaryBaseline(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-baseline-\(UUID().uuidString).toml")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
