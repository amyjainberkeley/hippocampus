import Darwin
import XCTest
@testable import OnboardingKit

/// Storage-security review S9: every settings file setup writes is mode 0600
/// from the moment it exists, and the MCP servers file, which can carry an
/// `Authorization` header, lives in a `.noindex` folder Spotlight skips.
final class PrivateSettingsFilesTests: XCTestCase {
    private var dataDir: URL!

    override func setUp() {
        super.setUp()
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mci-private-settings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("MCI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dataDir.deletingLastPathComponent())
        super.tearDown()
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testTheMcpServersFileLivesInANoindexFolderAndIsPrivate() async throws {
        XCTAssertEqual(FileMcpServersStore.defaultURL.deletingLastPathComponent().lastPathComponent,
                       "Config.noindex")
        XCTAssertEqual(FileMcpServersStore.defaultURL.lastPathComponent, "mcp-servers.toml")

        let url = dataDir.appendingPathComponent("Config.noindex/mcp-servers.toml")
        let store = FileMcpServersStore(url: url)
        let header = ["Bearer", "synthetic-header-value"].joined(separator: " ")
        try await store.save([McpServerEntry(name: "local", url: "http://127.0.0.1:7890/mcp",
                                             authHeader: header)])
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
        let loaded = await store.load()
        XCTAssertEqual(loaded.first?.authHeader, header)
    }

    func testAnEarlierMcpServersFileIsReadThenRemovedOnceSavedAgain() async throws {
        let legacy = dataDir.appendingPathComponent("mcp-servers.toml")
        try "[[server]]\nname = \"old\"\nurl = \"http://127.0.0.1:1/mcp\"\n"
            .write(to: legacy, atomically: true, encoding: .utf8)
        let url = dataDir.appendingPathComponent("Config.noindex/mcp-servers.toml")
        let store = FileMcpServersStore(url: url)

        let loaded = await store.load()
        XCTAssertEqual(loaded.map(\.name), ["old"], "the earlier file is still read")
        try await store.save(loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "the copy Spotlight indexed is removed once the new one is saved")
    }

    func testTheDenyListIsPrivate() async throws {
        let store = DiskDenylistEditorStore(csoPath: dataDir.appendingPathComponent("none.toml"),
                                            userDirectory: dataDir)
        await store.addUserEntry(type: .urlPattern, value: "bank.example")
        let file = dataDir.appendingPathComponent("user-deny.toml")
        XCTAssertEqual(try mode(file), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dataDir.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testTheAllowListIsPrivate() async throws {
        let url = dataDir.appendingPathComponent("user-allowlist.toml")
        try await FileUserAllowlistStore(url: url).save([
            UserAllowlistEntry(bundleId: "com.example.Notes", captureEnabled: true,
                               deepHookEnabled: false, addedAt: "2026-10-20T00:00:00Z"),
        ])
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testSetupProgressAndConsentFilesArePrivate() throws {
        let route = dataDir.appendingPathComponent(".onboarding-route")
        let state = FileOnboardingStateStore(path: route)
        state.saveRoute("try-it")
        state.saveAsked([.screenRecording])
        XCTAssertEqual(try mode(route), 0o600)
        XCTAssertEqual(try mode(dataDir.appendingPathComponent(".onboarding-asked")), 0o600)

        let consent = dataDir.appendingPathComponent(".onboarding-complete")
        try FileOnboardingConsentStore(url: consent).give(openAtLogin: false)
        XCTAssertEqual(try mode(consent), 0o600)
    }

    func testThePrivateWriterNeverCreatesAReadableFileEvenWithAnOpenUmask() throws {
        let previous = umask(0)
        defer { umask(previous) }
        let url = dataDir.appendingPathComponent("probe.toml")
        try PrivateFileWriter.write(Data("a = 1\n".utf8), to: url)
        XCTAssertEqual(try mode(url), 0o600)
        try PrivateFileWriter.write(Data("a = 2\n".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a = 2\n")
        XCTAssertEqual(try mode(url), 0o600)
    }
}
