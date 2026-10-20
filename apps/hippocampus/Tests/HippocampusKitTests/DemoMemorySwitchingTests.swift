// SPDX-License-Identifier: Apache-2.0
import Combine
import CryptoKit
import Foundation
import os
import XCTest
@testable import HippocampusKit

/// Using Demo Memory and leaving it (SPEC-DELTA 6), on temporary homes: the
/// person's own memory and the files beside it are byte for byte the same
/// afterwards, the Keychain is never asked, nothing that remembers ever
/// reads the week, and leaving takes back exactly what using changed.
@MainActor
final class DemoMemorySwitchingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_446_060)

    // MARK: Isolation

    func testUsingAndLeavingNeverTouchesThePersonsMemory() async throws {
        let home = try makeHome()
        let before = personsFiles(home)
        let host = FakeDemoHost()
        let controller = makeController(home: home, host: host)

        let used = await controller.use()
        XCTAssertTrue(used)
        XCTAssertEqual(controller.phase, .on)
        let folder = DemoMemoryFolder.standard(home: home)
        XCTAssertEqual(try permissions(folder.url), 0o700, "only this user can open the week's folder")
        XCTAssertEqual(try permissions(folder.keyFile), 0o600)
        let key = try String(contentsOf: folder.keyFile, encoding: .utf8)
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(key, String(repeating: "ab", count: 32), "never the person's key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.captureStatus.path),
                      "the window reads remembering's state beside the week")
        XCTAssertEqual(personsFiles(home), before, "using it writes nothing of the person's")

        await controller.leave()
        XCTAssertEqual(controller.phase, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path), "the week goes when it is left")
        XCTAssertEqual(personsFiles(home), before, "the person's memory is byte for byte as it was")
        XCTAssertEqual(host.calls, ["pause", "readers(open)", "readers(as-is)", "resume"])
        XCTAssertEqual(host.reports, [])
    }

    func testTheWeeksChildrenGetItsStoreAndItsOwnKeyNeverThePersons() async throws {
        let home = try makeHome()
        let controller = makeController(home: home, host: FakeDemoHost())
        _ = await controller.use()
        let folder = DemoMemoryFolder.standard(home: home)
        let own = ownEnvironment(home)

        let demo = controller.childEnvironment(own)
        XCTAssertEqual(demo["MCI_DB_PATH"], folder.database.path)
        XCTAssertEqual(demo["MCI_DB_KEY_FILE"], folder.keyFile.path)
        XCTAssertEqual(demo["MCI_DEVELOPMENT_FILE_KEY"], "1", "the key is a file: the Keychain is never asked")
        XCTAssertEqual(demo["MCI_DEMO_MEMORY"], "1", "the window shows its Demo tag")
        XCTAssertEqual(demo["MCI_EPHEMERAL_UI_STATE"], "1", "no searches are kept from the made-up week")
        XCTAssertEqual(demo["MCI_DB_KEYCHAIN_SERVICE"], DemoMemory.keychainService)
        XCTAssertNotEqual(demo["MCI_DB_KEYCHAIN_SERVICE"], KeychainKeyReference.defaultDatabaseKey.service)
        XCTAssertNil(demo["MCI_DB_KEY_HEX"])
        XCTAssertFalse(demo.values.contains { $0.contains("/Application Support/MCI") },
                       "nothing points a reader of the week at the person's memory")
        // The window starts with it, as the supervisor starts every window.
        XCTAssertNoThrow(try ChildProcessEnvironment.makeProcess(preparedEnvironment: demo))
    }

    func testAReleaseBuildsWindowUsesOnlyTheBundledAgent() async throws {
        let home = try makeHome()
        let controller = makeController(home: home, host: FakeDemoHost())
        _ = await controller.use()
        var own = ownEnvironment(home)
        own["MCI_AGENT_PATH"] = "/tmp/some-other-agent"
        XCTAssertNil(controller.childEnvironment(own)["MCI_AGENT_PATH"])
        own["MCI_DEVELOPMENT_FILE_KEY"] = "1"
        own["MCI_DB_KEY_FILE"] = home.appendingPathComponent("Library/Application Support/MCI/dev.key").path
        XCTAssertEqual(controller.childEnvironment(own)["MCI_AGENT_PATH"], "/tmp/some-other-agent",
                       "a development build keeps the agent it was told")
    }

    func testDemoMemoryNeverCallsTheKeychain() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HippocampusKit")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasPrefix("Demo") && $0.hasSuffix(".swift") }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for call in ["SecItem", "SecKeychain", "KeychainKeyStore(", "KeyStore(", "readValidatedKey", "writeKey"] {
                XCTAssertFalse(text.contains(call), "\(file) calls \(call)")
            }
        }
    }

    // MARK: Nothing that remembers ever reads the week

    func testRememberingStartingAlwaysGetsThePersonsMemoryAndEndsDemoMemory() async throws {
        let home = try makeHome()
        let host = FakeDemoHost()
        let controller = makeController(home: home, host: host)
        _ = await controller.use()
        let own = ownEnvironment(home)

        // Resume pressed: the helper, the agent and the key check before
        // them are started from here.
        host.isQuiet = false
        XCTAssertEqual(controller.childEnvironment(own), own)
        try await waitUntil { controller.phase == .off }
        XCTAssertFalse(host.calls.contains("resume"), "remembering stays as the person set it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DemoMemoryFolder.standard(home: home).url.path))
    }

    func testTurningRememberingOnFromTheMenuEndsDemoMemory() async throws {
        let home = try makeHome()
        let host = FakeDemoHost()
        let controller = makeController(home: home, host: host)
        _ = await controller.use()
        host.isQuiet = false
        host.changed()
        try await waitUntil { controller.phase == .off }
        XCTAssertEqual(host.calls, ["pause", "readers(open)", "readers(as-is)"])
    }

    func testConnectingAIToolsAlwaysWritesThePersonsMemory() async throws {
        let home = try makeHome()
        let host = FakeDemoHost()
        let controller = makeController(home: home, host: host)
        _ = await controller.use()
        let own = ownEnvironment(home)
        host.isConnectingAITools = true
        XCTAssertEqual(controller.childEnvironment(own), own, "the tools' settings never name the week")
        XCTAssertEqual(controller.phase, .on)
        host.isConnectingAITools = false
        XCTAssertEqual(controller.childEnvironment(own)["MCI_DEMO_MEMORY"], "1")
    }

    func testThroughTheSupervisorOnlyWindowsAndAskReadTheWeek() async throws {
        let home = try makeHome()
        let supervisor = ProcessSupervisor(
            locator: FakeBinaryLocator(), keyStore: FakeKeyStore(),
            runtimeConfig: FakeRuntimeConfig(captureEnabled: true), topology: FakeSupervisorTopology(),
            keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }
        )
        let host = SupervisorDemoMemoryHost(
            supervisor: supervisor, locator: BundleBinaryLocator(bundle: Bundle(for: Self.self))
        )
        let folder = DemoMemoryFolder.standard(home: home)
        let controller = DemoMemoryController(host: host, maker: FakeDemoMaker(), folder: folder, home: home)
        DemoMemory.attach(controller)
        defer { DemoMemory.detach() }
        controller.showForPreview(.on)
        let dbPath = home.appendingPathComponent("Library/Application Support/MCI/mci.sqlite")

        // Paused: the window and Ask read the week.
        supervisor.showForPreview(state: .paused, captureEnabled: true, receipt: nil, startedAt: nil)
        XCTAssertTrue(DemoMemory.isActive)
        XCTAssertEqual(DemoMemory.storeURL, folder.database)
        let window = ProcessSupervisorLaunchPlan.recallEnvironment(
            baseEnvironment: [:], dbPath: dbPath, keyReference: .defaultDatabaseKey,
            initialTab: nil, focusEventId: nil, openPopup: false, agentURL: nil
        )
        XCTAssertEqual(window["MCI_DB_PATH"], folder.database.path)
        XCTAssertEqual(window["MCI_DEMO_MEMORY"], "1")

        // A turn-on under way, then a start: the helper and the agent that
        // remember read the person's own memory, and Demo Memory ends.
        supervisor.showForPreview(state: .paused, captureEnabled: true, receipt: nil, startedAt: nil, turningOn: true)
        XCTAssertEqual(ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: [:], dbPath: dbPath, keyReference: .defaultDatabaseKey
        )["MCI_DB_PATH"], dbPath.path)
        supervisor.showForPreview(state: .starting, captureEnabled: true, receipt: nil, startedAt: nil)
        let generation = SupervisorProcessGeneration(
            id: "generation-1", readinessURL: URL(fileURLWithPath: "/tmp/generation-1.json"), captureEnabled: true
        )
        let plan = ProcessSupervisorLaunchPlan.make(
            helperURL: URL(fileURLWithPath: "/bundle/MCICaptureHelper"),
            agentURL: URL(fileURLWithPath: "/bundle/mci-agent"),
            dbPath: dbPath, keyReference: .defaultDatabaseKey, knownSafeAppsURL: nil,
            captureEnabled: true, crashReportOptedIn: false, generation: generation, baseEnvironment: [:]
        )
        for environment in [plan.agentEnvironment, plan.helperEnvironment] {
            XCTAssertEqual(environment["MCI_DB_PATH"], dbPath.path)
            XCTAssertNil(environment["MCI_DEMO_MEMORY"])
            XCTAssertNil(environment["MCI_DB_KEY_FILE"])
            XCTAssertEqual(environment["MCI_DB_KEYCHAIN_SERVICE"], KeychainKeyReference.defaultDatabaseKey.service)
        }
        try await waitUntil { controller.phase == .off }
        XCTAssertFalse(DemoMemory.isActive)
        XCTAssertNil(DemoMemory.storeURL)
    }

    func testAStartWhileItIsInUseRemembersIntoThePersonsMemoryAndEndsIt() async throws {
        let home = try makeHome()
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let custody = FakeKeyCustodyPreparer()
        let supervisor = ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: topology, keyCustodyPreparer: custody, readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }
        )
        let controller = DemoMemoryController(
            host: SupervisorDemoMemoryHost(supervisor: supervisor,
                                           locator: BundleBinaryLocator(bundle: Bundle(for: Self.self))),
            maker: FakeDemoMaker(), folder: .standard(home: home), home: home
        )
        DemoMemory.attach(controller)
        defer { DemoMemory.detach() }
        controller.showForPreview(.on)

        // The supervisor's own start: the key check, then the helper and the
        // agent, all built while the start is under way.
        try await supervisor.startAndWaitForReadiness()
        let plan = try XCTUnwrap(topology.launchPlans.last)
        XCTAssertEqual(plan.agentArguments.last, supervisor.dbPath.path)
        for environment in [plan.agentEnvironment, plan.helperEnvironment] {
            XCTAssertEqual(environment["MCI_DB_PATH"], supervisor.dbPath.path)
            XCTAssertNil(environment["MCI_DEMO_MEMORY"])
            XCTAssertNil(environment["MCI_DB_KEY_FILE"])
        }
        XCTAssertEqual(custody.calls.map(\.1), [supervisor.dbPath])
        try await waitUntil { controller.phase == .off }
    }

    // MARK: Leaving takes back exactly what using changed

    func testAPauseThePersonMadeStaysAfterLeaving() async throws {
        let home = try makeHome()
        let host = FakeDemoHost()
        host.isPaused = true
        let controller = makeController(home: home, host: host)
        _ = await controller.use()
        await controller.leave()
        XCTAssertEqual(host.calls, ["readers(open)", "readers(as-is)"], "already paused: nothing to pause or resume")
    }

    func testWhenTheWeekCantBeMadeNothingChanges() async throws {
        let home = try makeHome()
        let before = personsFiles(home)
        let host = FakeDemoHost()
        let controller = makeController(home: home, host: host,
                                        maker: FakeDemoMaker(error: DemoMemoryMakeError.failed(tool: "x", status: 1)))
        let used = await controller.use()
        XCTAssertFalse(used)
        XCTAssertEqual(controller.phase, .off)
        XCTAssertEqual(host.calls, [], "remembering is never paused for a week that wasn't made")
        XCTAssertEqual(host.reports, [DemoCopy.couldntMake])
        XCTAssertFalse(FileManager.default.fileExists(atPath: DemoMemoryFolder.standard(home: home).url.path))
        XCTAssertEqual(personsFiles(home), before)

        let missing = makeController(home: home, host: host,
                                     maker: FakeDemoMaker(error: DemoMemoryMakeError.missingTool("demo-screens")))
        _ = await missing.use()
        XCTAssertEqual(host.reports.last, DemoCopy.missing)
    }

    func testWhenRememberingWontPauseNothingChanges() async throws {
        let home = try makeHome()
        let before = personsFiles(home)
        let host = FakeDemoHost()
        host.pauseError = DemoMemoryHostError.couldNotPause
        let controller = makeController(home: home, host: host)
        let used = await controller.use()
        XCTAssertFalse(used)
        XCTAssertEqual(controller.phase, .off)
        XCTAssertEqual(host.calls, ["pause", "resume"], "a half-made pause is taken back")
        XCTAssertEqual(host.reports, [DemoCopy.couldntPause])
        XCTAssertFalse(FileManager.default.fileExists(atPath: DemoMemoryFolder.standard(home: home).url.path))
        XCTAssertEqual(personsFiles(home), before)
    }

    func testALeftoverWeekIsClearedAndItsPauseTakenBack() throws {
        let home = try makeHome()
        let folder = DemoMemoryFolder.standard(home: home)
        for (wasPaused, expected) in [(false, ["resume"]), (true, [])] {
            try folder.prepareEmpty(home: home)
            try folder.writeInUse(.init(enteredAt: now, wasPaused: wasPaused))
            XCTAssertEqual(folder.readInUse(), .init(enteredAt: now, wasPaused: wasPaused))
            let host = FakeDemoHost()
            let controller = makeController(home: home, host: host)
            controller.finishLeftover()
            XCTAssertEqual(host.calls, expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
        }
        // Ended while the week was made: nothing was paused yet.
        try folder.prepareEmpty(home: home)
        let host = FakeDemoHost()
        makeController(home: home, host: host).finishLeftover()
        XCTAssertEqual(host.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
    }

    // MARK: Its folder

    func testItNeverLivesInsideThePersonsMemoryFolder() async throws {
        let home = try makeHome()
        let before = personsFiles(home)
        let inside = DemoMemoryFolder(url: home.appendingPathComponent("Library/Application Support/MCI/Demo Memory"))
        XCTAssertFalse(inside.isSafe(home: home))
        let host = FakeDemoHost()
        let controller = DemoMemoryController(host: host, maker: FakeDemoMaker(), folder: inside, home: home)
        let used = await controller.use()
        XCTAssertFalse(used)
        XCTAssertEqual(host.calls, [])
        XCTAssertEqual(personsFiles(home), before)

        // Nor behind a link to it.
        let standard = DemoMemoryFolder.standard(home: home)
        try FileManager.default.createDirectory(at: standard.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: standard.url, withDestinationURL: home.appendingPathComponent("Library/Application Support/MCI")
        )
        XCTAssertFalse(standard.isSafe(home: home))
        let linked = makeController(home: home, host: host)
        let usedThroughLink = await linked.use()
        XCTAssertFalse(usedThroughLink)
        XCTAssertEqual(personsFiles(home), before)
    }

    func testSomethingElseInItsPlaceIsNeverRemoved() async throws {
        let home = try makeHome()
        let folder = DemoMemoryFolder.standard(home: home)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let notes = folder.url.appendingPathComponent("notes.txt")
        try Data("someone's notes".utf8).write(to: notes)
        let host = FakeDemoHost()
        let controller = makeController(home: home, host: host)
        let used = await controller.use()
        XCTAssertFalse(used)
        controller.finishLeftover()
        XCTAssertEqual(try Data(contentsOf: notes), Data("someone's notes".utf8))
    }

    // MARK: The menu

    func testTheMenuOffersItOnlyWithOptionHeldAndShowsItsTagWhileInUse() {
        let controller = makeController(home: FileManager.default.temporaryDirectory, host: FakeDemoHost())
        XCTAssertEqual(controller.menuItems(optionHeld: false), [])
        XCTAssertEqual(controller.menuItems(optionHeld: true), [
            StatusMenuModel.Item(role: .extra(DemoMemoryController.ItemID.use), title: "Use Demo Memory…"),
        ])
        controller.showForPreview(.making)
        XCTAssertEqual(controller.menuItems(optionHeld: false), [
            StatusMenuModel.Item(role: .extra(DemoMemoryController.ItemID.making), title: "Making Demo Memory…",
                                 isEnabled: false),
        ])
        controller.showForPreview(.on)
        let inUse = [StatusMenuModel.Item(role: .extra(DemoMemoryController.ItemID.leave),
                                          title: "Leave Demo Memory", badge: "Demo")]
        XCTAssertEqual(controller.menuItems(optionHeld: false), inUse)
        XCTAssertEqual(controller.menuItems(optionHeld: true), inUse)
        controller.showForPreview(.leaving)
        XCTAssertEqual(controller.menuItems(optionHeld: true).map(\.isEnabled), [false])
    }

    func testUseAsksFirstAndCancelChangesNothing() async throws {
        let home = try makeHome()
        let host = FakeDemoHost()
        host.confirms = false
        let controller = makeController(home: home, host: host)
        controller.perform(DemoMemoryController.ItemID.use)
        try await waitUntil { !controller.isSwitching }
        XCTAssertEqual(controller.phase, .off)
        XCTAssertEqual(host.calls, ["confirm"])

        host.confirms = true
        controller.perform(DemoMemoryController.ItemID.use)
        try await waitUntil { controller.phase == .on && !controller.isSwitching }
        controller.perform(DemoMemoryController.ItemID.leave)
        try await waitUntil { controller.phase == .off }
        XCTAssertEqual(host.calls, ["confirm", "confirm", "pause", "readers(open)", "readers(as-is)", "resume"])
    }

    func testTheFacadeChangesNothingUntilAControllerIsAttached() {
        XCTAssertNil(DemoMemory.controller)
        XCTAssertEqual(DemoMemory.menuItems(optionHeld: true), [])
        let controller = makeController(home: FileManager.default.temporaryDirectory, host: FakeDemoHost())
        DemoMemory.attach(controller)
        XCTAssertEqual(DemoMemory.menuItems(optionHeld: true).map(\.title), ["Use Demo Memory…"])
        DemoMemory.detach()
        XCTAssertEqual(DemoMemory.menuItems(optionHeld: true), [])
        XCTAssertFalse(DemoMemory.isActive)
    }

    // MARK: The week's status stays fresh

    func testTheWindowsStatusBesideTheWeekStaysFresh() async throws {
        let home = try makeHome()
        let clock = OSAllocatedUnfairLock(initialState: now)
        let controller = DemoMemoryController(
            host: FakeDemoHost(), maker: FakeDemoMaker(), folder: .standard(home: home), home: home,
            now: { clock.withLock { $0 } }, refreshInterval: .milliseconds(50)
        )
        _ = await controller.use()
        let status = DemoMemoryFolder.standard(home: home).captureStatus
        let first = try Data(contentsOf: status)
        clock.withLock { $0 = $0.addingTimeInterval(30) }
        try await waitUntil { (try? Data(contentsOf: status)) != first }
        let receipt = try CaptureStatusReceipt.decode(try Data(contentsOf: status))
        XCTAssertEqual(receipt.storedFrameCount, 120)
        await controller.leave()
    }

    // MARK: The words

    func testItsWordsAreCalm() {
        let banned = ["seamless", "effortless", "magic", "powerful", "smart", "simply", "unlock", "oops",
                      "mci", "sqlcipher", "keychain", "seeder", "blob", "database"]
        for text in DemoCopy.all {
            let words = Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted))
            for word in banned where words.contains(word) {
                XCTFail("\(text) says \(word)")
            }
            XCTAssertFalse(text.contains("!"), text)
            XCTAssertLessThan(text.filter { $0 == "\u{2014}" }.count, 2, text)
        }
    }

    // MARK: Helpers

    private func makeController(
        home: URL, host: FakeDemoHost, maker: FakeDemoMaker = FakeDemoMaker()
    ) -> DemoMemoryController {
        let now = self.now
        return DemoMemoryController(host: host, maker: maker, folder: .standard(home: home), home: home,
                                    now: { now }, timeZone: { TimeZone(secondsFromGMT: -7 * 3600)! })
    }

    /// A home with a person's memory in it: their store, its log, their key
    /// file and a screenshot, and the app's own folder beside it.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let own = home.appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
        let blobs = own.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            .write(to: own.appendingPathComponent("mci.sqlite"))
        try Data("log".utf8).write(to: own.appendingPathComponent("mci.sqlite-wal"))
        try Data(String(repeating: "ab", count: 32).utf8).write(to: own.appendingPathComponent("dev.key"))
        try Data([9, 9, 9]).write(to: blobs.appendingPathComponent("0123.bin"))
        let app = home.appendingPathComponent("Library/Application Support/Hippocampus", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("understanding-feedback"),
                                                withIntermediateDirectories: true)
        try Data("audit".utf8).write(to: app.appendingPathComponent("audit.log"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// Every file of the person's, with its bytes, its permissions and when
    /// it last changed, and every folder with its permissions: the memory's
    /// folder and the app's own, but for Demo Memory's folder inside it. (A
    /// folder's own time changes when Demo Memory's comes and goes in it;
    /// what is in it does not.)
    private func personsFiles(_ home: URL) -> [String: String] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(atPath: support.path) else { return out }
        while let relative = walker.nextObject() as? String {
            guard !relative.hasPrefix("Hippocampus/Demo Memory") else { continue }
            let path = support.appendingPathComponent(relative).path
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let permissions = attributes[.posixPermissions].map { "\($0)" } ?? "?"
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                out[relative] = "folder \(permissions)"
                continue
            }
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: path)))
                .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "-"
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out[relative] = "\(bytes) \(permissions) \(modified)"
        }
        return out
    }

    private func ownEnvironment(_ home: URL) -> [String: String] {
        ProcessSupervisorLaunchPlan.sanitizedEnvironment(
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home.path],
            dbPath: home.appendingPathComponent("Library/Application Support/MCI/mci.sqlite"),
            keyReference: .defaultDatabaseKey
        )
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out")
    }
}

/// The app, as Demo Memory sees it, recording what it was asked.
@MainActor
final class FakeDemoHost: DemoMemoryHost {
    var isPaused = false
    var isQuiet = true
    var isConnectingAITools = false
    var pauseError: Error?
    var confirms = true
    private(set) var calls: [String] = []
    private(set) var reports: [String] = []
    private var change: (@MainActor () -> Void)?

    func pauseRemembering() async throws {
        calls.append("pause")
        if let pauseError { throw pauseError }
        isPaused = true
        isQuiet = true
    }

    func resumeRemembering() {
        calls.append("resume")
        isPaused = false
    }

    func restartReaders(openWindow: Bool) async {
        calls.append(openWindow ? "readers(open)" : "readers(as-is)")
    }

    func watchRemembering(_ change: @escaping @MainActor () -> Void) -> AnyCancellable {
        self.change = change
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated { self?.change = nil }
        }
    }

    /// Something about remembering changed.
    func changed() {
        change?()
    }

    func confirmUse() async -> Bool {
        calls.append("confirm")
        return confirms
    }

    func report(_ message: String) {
        reports.append(message)
    }
}

/// Makes a stand-in week: a store, a screenshot and a calendar in the folder
/// it is given, and nowhere else.
struct FakeDemoMaker: DemoMemoryMaking {
    var error: Error?

    func make(into folder: DemoMemoryFolder, keyHex: String, now: Date, timeZone: TimeZone) async throws
        -> DemoMemoryWeek {
        if let error { throw error }
        try Data("a made-up week, sealed with \(keyHex.prefix(4))".utf8).write(to: folder.database)
        try FileManager.default.createDirectory(at: folder.blobs, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.blobs.appendingPathComponent("4567.bin"))
        try Data("{\"version\":1,\"events\":[]}".utf8).write(to: folder.calendar)
        return DemoMemoryWeek(moments: 120, screenshots: 40)
    }
}
