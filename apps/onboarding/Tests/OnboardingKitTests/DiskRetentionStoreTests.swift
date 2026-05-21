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

    func testDefaultPolicyIsForever() async {
        let store = DiskRetentionStore(directory: tmpDir)
        let policy = await store.currentPolicy()
        XCTAssertEqual(policy, .forever)
        let days = await store.currentCustomDays()
        XCTAssertNil(days)
    }

    func testWriteReadRoundTrip() async {
        let store = DiskRetentionStore(directory: tmpDir)
        await store.setPolicy(.thirtyDays, customDays: nil)

        let store2 = DiskRetentionStore(directory: tmpDir)
        let policy = await store2.currentPolicy()
        XCTAssertEqual(policy, .thirtyDays)
    }

    func testCustomDaysRoundTrip() async {
        let store = DiskRetentionStore(directory: tmpDir)
        await store.setPolicy(.custom, customDays: 42)

        let store2 = DiskRetentionStore(directory: tmpDir)
        let policy = await store2.currentPolicy()
        let days = await store2.currentCustomDays()
        XCTAssertEqual(policy, .custom)
        XCTAssertEqual(days, 42)
    }

    func testOverwritePolicy() async {
        let store = DiskRetentionStore(directory: tmpDir)
        await store.setPolicy(.sevenDays, customDays: nil)
        await store.setPolicy(.forever, customDays: nil)

        let store2 = DiskRetentionStore(directory: tmpDir)
        let policy = await store2.currentPolicy()
        XCTAssertEqual(policy, .forever)
    }

    func testRetentionJsonFileCreated() async {
        let store = DiskRetentionStore(directory: tmpDir)
        await store.setPolicy(.thirtyDays, customDays: nil)

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

    func testAllPoliciesRoundTrip() async {
        for p in [RetentionPolicy.forever, .thirtyDays, .sevenDays, .custom] {
            let store = DiskRetentionStore(directory: tmpDir)
            await store.setPolicy(p, customDays: p == .custom ? 99 : nil)

            let store2 = DiskRetentionStore(directory: tmpDir)
            let loaded = await store2.currentPolicy()
            XCTAssertEqual(loaded, p, "Policy \(p) should round-trip")
        }
    }
}
