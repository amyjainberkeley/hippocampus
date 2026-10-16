// SPDX-License-Identifier: Apache-2.0
import Darwin
import XCTest
@testable import HippocampusKit

/// Ask opened: the app asks the capture helper for one fresh read of the
/// window in front, and only while remembering is running.
@MainActor
final class FreshReadRequestTests: XCTestCase {
    private func makeSupervisor(captureEnabled: Bool) -> (ProcessSupervisor, FakeSupervisorTopology) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: keyStore,
            runtimeConfig: FakeRuntimeConfig(captureEnabled: captureEnabled),
            topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(),
            readinessTimeout: 0.1
        )
        return (supervisor, topology)
    }

    func testWhileRememberingTheHelperIsAskedOnce() async throws {
        let (supervisor, topology) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        XCTAssertEqual(supervisor.state, .running)

        XCTAssertTrue(supervisor.requestFreshRead())
        XCTAssertEqual(topology.focusedReadRequests, 1)
    }

    func testNothingIsAskedBeforeStartOrWithRememberingOff() async throws {
        let (idle, idleTopology) = makeSupervisor(captureEnabled: true)
        XCTAssertFalse(idle.requestFreshRead())
        XCTAssertEqual(idleTopology.focusedReadRequests, 0)

        let (off, offTopology) = makeSupervisor(captureEnabled: false)
        offTopology.readinessResults = [.success(())]
        try await off.startAndWaitForReadiness()
        XCTAssertEqual(off.state, .running, "the agent runs; the helper reads nothing")
        XCTAssertFalse(off.requestFreshRead())
        XCTAssertEqual(offTopology.focusedReadRequests, 0)
    }

    func testNothingIsAskedWhilePausedStoppedOrWithoutPermission() async throws {
        let (paused, pausedTopology) = makeSupervisor(captureEnabled: true)
        pausedTopology.readinessResults = [.success(())]
        try await paused.startAndWaitForReadiness()
        try await paused.setPausedAndWait(true)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertFalse(paused.requestFreshRead())
        XCTAssertEqual(pausedTopology.focusedReadRequests, 0)

        let (stopped, stoppedTopology) = makeSupervisor(captureEnabled: true)
        stoppedTopology.readinessResults = [.success(())]
        try await stopped.startAndWaitForReadiness()
        try await stopped.shutdownAndWait()
        XCTAssertFalse(stopped.requestFreshRead())
        XCTAssertEqual(stoppedTopology.focusedReadRequests, 0)

        let (revoked, revokedTopology) = makeSupervisor(captureEnabled: true)
        revokedTopology.readinessResults = [.success(())]
        try await revoked.startAndWaitForReadiness()
        revoked.tccRevokedSurface = .screenRecording
        XCTAssertFalse(revoked.requestFreshRead())
        XCTAssertEqual(revokedTopology.focusedReadRequests, 0)
    }

    // MARK: - The byte on the lease

    func testTheRequestIsOneByteOnTheLease() throws {
        let pipe = Pipe()
        XCTAssertTrue(HelperLeaseCommand.send(HelperLeaseCommand.freshRead, to: pipe.fileHandleForWriting))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try pipe.fileHandleForReading.readToEnd(), Data([0x72]))
    }

    func testAGoneHelperNeitherBlocksNorKillsTheApp() throws {
        // The helper exited: writing to a pipe nobody reads raises SIGPIPE
        // unless the app turned it off.
        let gone = Pipe()
        try gone.fileHandleForReading.close()
        XCTAssertFalse(HelperLeaseCommand.send(HelperLeaseCommand.freshRead, to: gone.fileHandleForWriting))

        // A helper that stopped reading: the main thread must not wait on it.
        let stuck = Pipe()
        let descriptor = stuck.fileHandleForWriting.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let chunk = [UInt8](repeating: 0, count: 4096)
        while chunk.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) > 0 {}
        let started = Date()
        XCTAssertFalse(HelperLeaseCommand.send(HelperLeaseCommand.freshRead, to: stuck.fileHandleForWriting))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testTheByteIsTheOneTheHelperListensFor() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = try String(contentsOf: repository.appendingPathComponent(
            "adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/FreshRead.swift"), encoding: .utf8)
        XCTAssertTrue(helper.contains("public static let byte: UInt8 = 0x72"))
        XCTAssertEqual(HelperLeaseCommand.freshRead, 0x72)
    }
}
