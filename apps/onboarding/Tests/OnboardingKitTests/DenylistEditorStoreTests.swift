import XCTest
@testable import OnboardingKit

final class DenylistEditorStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var csoFixture: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-test-denylist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        csoFixture = Bundle.module.url(
            forResource: "cso-denylist-fixture",
            withExtension: "toml",
            subdirectory: "Fixtures"
        )!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - TOML parsing

    func testParseCSOFixture() {
        let entries = DiskDenylistEditorStore.parseDenylistToml(at: csoFixture, source: .csoRatified)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].type, .bundleId)
        XCTAssertEqual(entries[0].value, "com.banking.secretapp")
        XCTAssertEqual(entries[0].source, .csoRatified)
        XCTAssertEqual(entries[1].type, .windowTitle)
        XCTAssertEqual(entries[2].type, .urlPattern)
    }

    func testParseEmptyFile() {
        let empty = tmpDir.appendingPathComponent("empty.toml")
        try! "".write(to: empty, atomically: true, encoding: .utf8)
        let entries = DiskDenylistEditorStore.parseDenylistToml(at: empty, source: .userAdded)
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseMissingFile() {
        let missing = tmpDir.appendingPathComponent("nope.toml")
        let entries = DiskDenylistEditorStore.parseDenylistToml(at: missing, source: .userAdded)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Union semantics

    func testUnionCSOAndUser() async {
        let userToml = tmpDir.appendingPathComponent("user-deny.toml")
        try! """
        [[entries]]
        type = "bundleId"
        value = "com.user.blocked"
        """.write(to: userToml, atomically: true, encoding: .utf8)

        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()

        let all = await store.allEntries()
        XCTAssertEqual(all.count, 4) // 3 CSO + 1 user
        let cso = await store.csoEntries()
        XCTAssertEqual(cso.count, 3)
        let user = await store.userEntries()
        XCTAssertEqual(user.count, 1)
    }

    // MARK: - Add user entry

    func testAddUserEntry() async {
        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()

        await store.addUserEntry(type: .bundleId, value: "com.new.deny")
        let user = await store.userEntries()
        XCTAssertEqual(user.count, 1)
        XCTAssertEqual(user[0].value, "com.new.deny")
        XCTAssertEqual(user[0].source, .userAdded)
    }

    func testAddDuplicateIsNoop() async {
        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()

        await store.addUserEntry(type: .bundleId, value: "com.new.deny")
        await store.addUserEntry(type: .bundleId, value: "com.new.deny")
        let user = await store.userEntries()
        XCTAssertEqual(user.count, 1)
    }

    func testAddedEntriesPersist() async {
        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()
        await store.addUserEntry(type: .windowTitle, value: "^Secret.*")

        let store2 = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store2.load()
        let user = await store2.userEntries()
        XCTAssertEqual(user.count, 1)
        XCTAssertEqual(user[0].value, "^Secret.*")
        XCTAssertEqual(user[0].type, .windowTitle)
    }

    // MARK: - NEVER-REMOVE invariant (CSO entries immutable)

    func testCannotRemoveCSOEntry() async {
        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()

        let cso = await store.csoEntries()
        let removed = await store.removeUserEntry(id: cso[0].id)
        XCTAssertFalse(removed, "CSO entries must be immutable")

        let afterAll = await store.allEntries()
        XCTAssertEqual(afterAll.count, 3)
    }

    func testCanRemoveUserEntry() async {
        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()
        await store.addUserEntry(type: .bundleId, value: "com.remove.me")

        let user = await store.userEntries()
        XCTAssertEqual(user.count, 1)

        let removed = await store.removeUserEntry(id: user[0].id)
        XCTAssertTrue(removed)

        let afterUser = await store.userEntries()
        XCTAssertTrue(afterUser.isEmpty)
    }

    func testRemoveNonexistentEntryReturnsFalse() async {
        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()

        let removed = await store.removeUserEntry(id: "bundleId:com.nonexistent")
        XCTAssertFalse(removed)
    }

    // MARK: - Stub invariants

    func testStubNeverRemoveCSO() async {
        let stub = StubDenylistEditorStore(
            cso: [DenylistEntry(type: .bundleId, value: "com.cso.locked", source: .csoRatified)]
        )
        let removed = await stub.removeUserEntry(id: "bundleId:com.cso.locked")
        XCTAssertFalse(removed, "Stub must also enforce CSO immutability")
    }

    // MARK: - TOML escaping round-trip

    func testSpecialCharactersInValueRoundTrip() async {
        let store = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store.load()
        await store.addUserEntry(type: .urlPattern, value: "https://bank\\.com/login\\?user=.*")

        let store2 = DiskDenylistEditorStore(csoPath: csoFixture, userDirectory: tmpDir)
        await store2.load()
        let user = await store2.userEntries()
        XCTAssertEqual(user.count, 1)
        XCTAssertEqual(user[0].value, "https://bank\\.com/login\\?user=.*")
    }
}
