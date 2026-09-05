import XCTest
@testable import OnboardingKit

final class DiskRetentionStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-test-retention-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testDefaultPolicyIsNinetyDays() async {
        let store = DiskRetentionStore(directory: tmpDir)
        let policy = await store.currentPolicy()
        XCTAssertEqual(policy, .ninetyDays)
        let days = await store.currentCustomDays()
        XCTAssertNil(days)
    }

    func testWriteReadRoundTrip() async throws {
        let store = DiskRetentionStore(directory: tmpDir)
        try await store.setPolicy(.thirtyDays, customDays: nil)

        let store2 = DiskRetentionStore(directory: tmpDir)
        let policy = await store2.currentPolicy()
        XCTAssertEqual(policy, .thirtyDays)
    }

    func testCustomDaysRoundTrip() async throws {
        let store = DiskRetentionStore(directory: tmpDir)
        try await store.setPolicy(.custom, customDays: 42)

        let store2 = DiskRetentionStore(directory: tmpDir)
        let policy = await store2.currentPolicy()
        let days = await store2.currentCustomDays()
        XCTAssertEqual(policy, .custom)
        XCTAssertEqual(days, 42)
    }

    func testOverwritePolicy() async throws {
        let store = DiskRetentionStore(directory: tmpDir)
        try await store.setPolicy(.sevenDays, customDays: nil)
        try await store.setPolicy(.forever, customDays: nil)

        let store2 = DiskRetentionStore(directory: tmpDir)
        let policy = await store2.currentPolicy()
        XCTAssertEqual(policy, .forever)
    }

    func testRetentionJsonFileCreated() async throws {
        let store = DiskRetentionStore(directory: tmpDir)
        try await store.setPolicy(.thirtyDays, customDays: nil)

        let filePath = tmpDir.appendingPathComponent("retention.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath.path))

        let data = try! Data(contentsOf: filePath)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["mode"] as? String, "thirtyDays")
        XCTAssertNotNil(json["updated_at"])
    }

    func testCorruptFileDefaultsToForever() async {
        let filePath = tmpDir.appendingPathComponent("retention.json")
        try! "not json".write(to: filePath, atomically: true, encoding: .utf8)

        let store = DiskRetentionStore(directory: tmpDir)
        let policy = await store.currentPolicy()
        XCTAssertEqual(policy, .forever)
    }

    func testAllPoliciesRoundTrip() async throws {
        for p in RetentionPolicy.allCases {
            let store = DiskRetentionStore(directory: tmpDir)
            try await store.setPolicy(p, customDays: p == .custom ? 99 : nil)

            let store2 = DiskRetentionStore(directory: tmpDir)
            let loaded = await store2.currentPolicy()
            XCTAssertEqual(loaded, p, "Policy \(p) should round-trip")
        }
    }

    func testLegacyFiniteChoiceNeedsExplicitReview() async throws {
        let file = tmpDir.appendingPathComponent("retention.json")
        let original = Data(#"{"mode":"sevenDays","days":null,"updated_at":"2026-09-01T00:00:00Z"}"#.utf8)
        try original.write(to: file)
        let store = DiskRetentionStore(directory: tmpDir)
        let policy = await store.currentPolicy()
        let needsReview = await store.needsReview()
        XCTAssertEqual(policy, .sevenDays)
        XCTAssertTrue(needsReview)
        let protocolStore: any RetentionStore = store
        let protocolReview = await protocolStore.needsReview()
        XCTAssertTrue(protocolReview, "The view model must see persisted review state through the protocol")
        XCTAssertEqual(try Data(contentsOf: file), original)
        try await store.setPolicy(.ninetyDays, customDays: nil)
        let reviewed = await store.needsReview()
        XCTAssertFalse(reviewed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 2)
        XCTAssertEqual(json["mode"] as? String, "ninetyDays")
    }

    func testCustomSchemaRejectsMissingZeroAndAboveMaximum() async throws {
        let store = DiskRetentionStore(directory: tmpDir)
        try await store.setPolicy(.sevenDays, customDays: nil)

        for invalidDays in [nil, 0, 366] as [Int?] {
            await XCTAssertThrowsErrorAsync(
                try await store.setPolicy(.custom, customDays: invalidDays)
            )
            let policy = await store.currentPolicy()
            let customDays = await store.currentCustomDays()
            XCTAssertEqual(policy, .sevenDays)
            XCTAssertNil(customDays)
        }
    }

    func testFailedAtomicWriteDoesNotMutateCache() async throws {
        let seed = DiskRetentionStore(directory: tmpDir)
        try await seed.setPolicy(.sevenDays, customDays: nil)
        let store = DiskRetentionStore(
            directory: tmpDir,
            writer: FailingRetentionWriter(code: .fileWriteOutOfSpace)
        )
        let loadedPolicy = await store.currentPolicy()
        XCTAssertEqual(loadedPolicy, .sevenDays)

        await XCTAssertThrowsErrorAsync(
            try await store.setPolicy(.custom, customDays: 30)
        )

        let policyAfterFailure = await store.currentPolicy()
        let daysAfterFailure = await store.currentCustomDays()
        XCTAssertEqual(policyAfterFailure, .sevenDays)
        XCTAssertNil(daysAfterFailure)
    }

    func testInvalidPersistedCustomSchemaDefaultsForever() async throws {
        for payload in [
            #"{"mode":"custom","days":0}"#,
            #"{"mode":"custom","days":366}"#,
            #"{"mode":"custom"}"#,
            #"{"mode":"custom","days":18446744073709551616}"#,
        ] {
            try Data(payload.utf8).write(
                to: tmpDir.appendingPathComponent("retention.json"),
                options: .atomic
            )
            let store = DiskRetentionStore(directory: tmpDir)
            let policy = await store.currentPolicy()
            let days = await store.currentCustomDays()
            XCTAssertEqual(policy, .forever)
            XCTAssertNil(days)
        }
    }
}

private struct FailingRetentionWriter: RetentionFileWriting {
    let code: CocoaError.Code

    func write(_ data: Data, to fileURL: URL) throws {
        _ = (data, fileURL)
        throw CocoaError(code)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
