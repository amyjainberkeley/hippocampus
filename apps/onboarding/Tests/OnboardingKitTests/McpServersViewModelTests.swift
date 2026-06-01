import XCTest
@testable import OnboardingKit

@MainActor
final class McpServersViewModelTests: XCTestCase {
    func testAddPendingPersistsLoopbackURL() async {
        let store = InMemoryMcpServersStore()
        let vm = McpServersViewModel(store: store)
        await vm.load()
        vm.pendingName = "gchat"
        vm.pendingURL = "http://127.0.0.1:7890/mcp"
        let added = await vm.addPending()
        XCTAssertTrue(added)
        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].name, "gchat")
        let persisted = await store.entriesForTest()
        XCTAssertEqual(persisted.count, 1)
    }

    func testAddPendingRejectsNonLoopback() async {
        let store = InMemoryMcpServersStore()
        let vm = McpServersViewModel(store: store)
        vm.pendingName = "bad"
        vm.pendingURL = "http://192.168.1.1:9000/mcp"
        let added = await vm.addPending()
        XCTAssertFalse(added)
        XCTAssertEqual(vm.lastError, .nonLoopback)
        XCTAssertEqual(vm.entries.count, 0)
    }

    func testAddPendingRejectsUserinfo() async {
        let vm = McpServersViewModel(store: InMemoryMcpServersStore())
        vm.pendingName = "x"
        vm.pendingURL = "http://user:pass@127.0.0.1/mcp"
        let added = await vm.addPending()
        XCTAssertFalse(added)
        XCTAssertEqual(vm.lastError, .userinfoNotAllowed)
    }

    func testAddPendingRejectsZeroAddress() async {
        let vm = McpServersViewModel(store: InMemoryMcpServersStore())
        vm.pendingName = "x"
        vm.pendingURL = "http://0.0.0.0/mcp"
        let added = await vm.addPending()
        XCTAssertFalse(added)
        XCTAssertEqual(vm.lastError, .nonLoopback)
    }

    func testAddPendingRejectsBadScheme() async {
        let vm = McpServersViewModel(store: InMemoryMcpServersStore())
        vm.pendingName = "x"
        vm.pendingURL = "ftp://127.0.0.1/mcp"
        let added = await vm.addPending()
        XCTAssertFalse(added)
        XCTAssertEqual(vm.lastError, .badScheme)
    }

    func testDuplicateNameRejected() async {
        let store = InMemoryMcpServersStore(entries: [
            McpServerEntry(name: "x", url: "http://127.0.0.1/a"),
        ])
        let vm = McpServersViewModel(store: store)
        await vm.load()
        vm.pendingName = "x"
        vm.pendingURL = "http://127.0.0.1/b"
        let added = await vm.addPending()
        XCTAssertFalse(added)
        XCTAssertEqual(vm.lastError, .duplicateName("x"))
    }

    func testInvalidNameRejected() async {
        let vm = McpServersViewModel(store: InMemoryMcpServersStore())
        vm.pendingName = "has spaces"
        vm.pendingURL = "http://127.0.0.1/m"
        let added = await vm.addPending()
        XCTAssertFalse(added)
        XCTAssertEqual(vm.lastError, .invalidName)
    }

    func testRemoveDropsEntry() async {
        let store = InMemoryMcpServersStore(entries: [
            McpServerEntry(name: "x", url: "http://127.0.0.1/a"),
            McpServerEntry(name: "y", url: "http://127.0.0.1/b"),
        ])
        let vm = McpServersViewModel(store: store)
        await vm.load()
        await vm.remove("x")
        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries[0].name, "y")
    }

    func testLoopbackIpv6LiteralAccepted() {
        XCTAssertNil(McpServersViewModel.preCheckLoopbackURL("http://[::1]/mcp"))
    }

    func testLoopback127SlashEightAccepted() {
        XCTAssertNil(McpServersViewModel.preCheckLoopbackURL("http://127.1.2.3/mcp"))
    }

    func testHTTPSLoopbackAccepted() {
        XCTAssertNil(McpServersViewModel.preCheckLoopbackURL("https://127.0.0.1/mcp"))
    }

    func testDNSHostnameWarnsSoftly() {
        // Pre-check defers to the agent's full DNS check.
        XCTAssertEqual(
            McpServersViewModel.preCheckLoopbackURL("http://example.com/mcp"),
            .dnsUnverified
        )
    }
}
