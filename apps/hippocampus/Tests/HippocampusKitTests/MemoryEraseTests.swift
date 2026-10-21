// SPDX-License-Identifier: Apache-2.0
//
// Storage-security review S3: Delete Everything from the window is a
// crypto-shred the app carries out. Remembering stops as for a forget, the
// bundled agent erases the memory and its key while nothing remembers, and
// remembering starts again if it was on. Nothing here runs a real agent.

import XCTest
@testable import HippocampusKit

@MainActor
final class MemoryEraseTests: XCTestCase {
    private final class RecordingEraser: MemoryErasing {
        weak var supervisor: ProcessSupervisor?
        var result = true
        private(set) var calls: [(database: URL, environment: [String: String])] = []
        private(set) var rememberingWhileErasing: Bool?

        func erase(agentURL: URL, databaseURL: URL, environment: [String: String]) async -> Bool {
            calls.append((databaseURL, environment))
            rememberingWhileErasing = supervisor?.state == .running
            XCTAssertEqual(agentURL.lastPathComponent, "mci-agent")
            return result
        }
    }

    private let custody = CountingCustody()

    /// Counts `ensure-key` runs; never runs one.
    private final class CountingCustody: KeyCustodyPreparing {
        private(set) var prepared = 0
        func prepare(agentURL: URL, databaseURL: URL, keyReference: KeychainKeyReference) async throws {
            prepared += 1
        }
    }

    private func supervisor() -> ProcessSupervisor {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        return ProcessSupervisor(
            locator: locator, keyStore: keyStore, runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: FakeSupervisorTopology(), keyCustodyPreparer: custody, readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }, pauses: UserPauseController()
        )
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDeleteEverythingErasesWhileNothingRemembersThenRemembersAgain() async throws {
        let supervisor = supervisor()
        let eraser = RecordingEraser()
        eraser.supervisor = supervisor
        supervisor.memoryEraser = eraser
        try await supervisor.startAndWaitForReadiness()
        XCTAssertEqual(supervisor.state, .running)
        let preparedBefore = custody.prepared

        let erased = await supervisor.handleWindowRequest(WindowChannelRequest(id: "e1", op: .erase))
        XCTAssertTrue(erased)
        XCTAssertEqual(eraser.calls.count, 1)
        XCTAssertEqual(eraser.rememberingWhileErasing, false, "the agent is stopped: the writer lease is free")
        XCTAssertNil(eraser.calls.first?.environment["MCI_DB_KEY_HEX"], "no key travels")
        XCTAssertNotNil(eraser.calls.first?.environment["MCI_DB_KEYCHAIN_SERVICE"])
        await eventually { supervisor.state == .running }
        XCTAssertGreaterThanOrEqual(custody.prepared - preparedBefore, 2,
                       "a new key is made right after the erase, and checked again when remembering restarts")
        XCTAssertEqual(supervisor.state, .running, "it was on, so it comes back, with a new key")
        XCTAssertFalse(supervisor.holdingForForget)
        try await supervisor.shutdownAndWait()
    }

    func testAFailedEraseStillRemembersAgainAndSaysSo() async throws {
        let supervisor = supervisor()
        let eraser = RecordingEraser()
        eraser.result = false
        supervisor.memoryEraser = eraser
        try await supervisor.startAndWaitForReadiness()
        let erased = await supervisor.handleWindowRequest(WindowChannelRequest(id: "e2", op: .erase))
        XCTAssertFalse(erased)
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    /// An erase that waits until the test lets it finish.
    private final class GatedEraser: MemoryErasing {
        private(set) var started = false
        private var finished = false
        private var gate: CheckedContinuation<Void, Never>?

        func erase(agentURL: URL, databaseURL: URL, environment: [String: String]) async -> Bool {
            started = true
            if !finished { await withCheckedContinuation { gate = $0 } }
            return true
        }

        func finish() {
            finished = true
            gate?.resume()
            gate = nil
        }
    }

    /// The erase is the app's own pass: the window that asked may close or
    /// send a release, and the erase may outlast a forget's 30 seconds, yet
    /// nothing remembers until the erase and the new key are done.
    func testAWindowThatClosesMidEraseNeverStartsRememberingUnderIt() async throws {
        let supervisor = supervisor()
        let eraser = GatedEraser()
        supervisor.memoryEraser = eraser
        try await supervisor.startAndWaitForReadiness()
        XCTAssertEqual(supervisor.state, .running)
        let erasing = Task { @MainActor in
            await supervisor.handleWindowRequest(WindowChannelRequest(id: "e3", op: .erase))
        }
        await eventually { eraser.started }
        XCTAssertTrue(eraser.started)
        XCTAssertEqual(supervisor.forgetHold.holder, .app)

        _ = await supervisor.handleWindowRequest(WindowChannelRequest(id: "r3", op: .release))
        await supervisor.forgetHold.windowEnded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(supervisor.forgetHold.isHolding, "the erase still holds")
        XCTAssertTrue(supervisor.holdingForForget)
        XCTAssertNotEqual(supervisor.state, .running, "nothing remembers while the memory is erased")

        eraser.finish()
        let erased = await erasing.value
        XCTAssertTrue(erased)
        await eventually { supervisor.state == .running }
        XCTAssertEqual(supervisor.state, .running, "it was on, so it comes back once the erase is done")
        XCTAssertFalse(supervisor.forgetHold.isHolding)
        try await supervisor.shutdownAndWait()
    }

    func testTheWindowMayAskForAnEraseOnlyOutsideAHold() {
        let row = StatusRow(title: "x", detail: nil, action: .pause)
        let erase = WindowChannelRequest(id: "r", op: .erase)
        XCTAssertTrue(WindowChannelPolicy.allows(erase, row: row, holding: false))
        XCTAssertFalse(WindowChannelPolicy.allows(erase, row: row, holding: true))
        XCTAssertEqual(WindowChannelRequest.parse(Data(#"{"v":1,"id":"r9","op":"erase"}"#.utf8))?.op, .erase)
    }
}
