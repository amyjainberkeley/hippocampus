// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import HippocampusKit

/// The sweep that ends capture processes no running Hippocampus owns
/// (spec-shell S6.4, critique-shell-engineering 2).
final class CaptureOrphanSweepTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Which processes

    func testAHelperMatchesOnlyAtItsExactPathInThisBundle() throws {
        let targets = try makeTargets()
        let other = targets.helper.replacingOccurrences(of: "Hippocampus.app", with: "Other.app")
        let processes = [
            process(10, path: targets.helper),
            process(11, path: other),
            process(12, path: targets.helper + "-old"),
            process(13, path: "/usr/local/bin/MCICaptureHelper"),
        ]
        XCTAssertEqual(matches(processes, targets), [CaptureOrphanSweep.Match(pid: 10, kind: .capture)])
    }

    func testAnOCRWorkerMatchesAnythingUnderItsFolderAndNothingBesideIt() throws {
        let targets = try makeTargets()
        let folder = String(targets.ocrDirectory.dropLast())
        let processes = [
            process(20, path: targets.ocrDirectory + "hippocampus-ocr"),
            process(21, path: targets.ocrDirectory + "_internal/python3"),
            process(22, path: folder + "-old/hippocampus-ocr"),
            process(23, path: folder),
        ]
        XCTAssertEqual(matches(processes, targets).map(\.pid), [20, 21])
    }

    func testNeverMatchesMCPServeAndOnlyAnOrphanedWriterAgent() throws {
        let targets = try makeTargets()
        let processes = [
            // AI tools run these, often with a parent that has gone.
            process(30, parent: 1, path: targets.agent, arguments: ["mcp-serve"]),
            process(31, parent: 1, path: targets.agent, arguments: ["mcp-serve", "--assist"]),
            process(32, parent: 900, path: targets.agent, arguments: ["mcp-serve"]),
            // A writer whose app is alive belongs to that app.
            process(33, parent: 900, path: targets.agent, arguments: ["--drain-stdin", "--strict"]),
            process(34, parent: 1, path: targets.agent, arguments: ["ensure-key", "--db-path", "/x"]),
            // Left behind: it drains, then the sweep waits and asks it to stop.
            process(35, parent: 1, path: targets.agent, arguments: ["--drain-stdin", "--strict", "--db-path", "/x"]),
        ]
        XCTAssertEqual(matches(processes, targets), [CaptureOrphanSweep.Match(pid: 35, kind: .writer)])
    }

    func testSkipsThisProcessOtherUsersAndLaunchd() throws {
        let targets = try makeTargets()
        let processes = [
            process(getpid(), path: targets.helper),
            process(40, path: targets.helper, uid: getuid() + 1),
            process(1, path: targets.helper),
            process(41, path: targets.helper),
        ]
        XCTAssertEqual(matches(processes, targets).map(\.pid), [41])
    }

    func testOutsideQuitOurLiveChildrenAndWhatTheyStartedAreLeftAlone() throws {
        let targets = try makeTargets()
        let processes = [
            process(50, parent: getpid(), path: targets.helper),
            process(51, parent: 50, path: targets.ocrDirectory + "hippocampus-ocr"),
            process(52, parent: 1, path: targets.helper),
            process(53, parent: 52, path: targets.ocrDirectory + "hippocampus-ocr"),
        ]
        XCTAssertEqual(matches(processes, targets, liveChildren: [50]).map(\.pid), [52, 53])
        XCTAssertEqual(
            matches(processes, targets, liveChildren: nil).map(\.pid), [50, 51, 52, 53],
            "Quit ends every match, including a child of ours that survived the stop"
        )
    }

    func testDoesNothingOutsideAnAppBundle() throws {
        let build = root.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        XCTAssertNil(CaptureOrphanSweep(bundleURL: build))
        XCTAssertNil(CaptureOrphanSweep.Targets(bundleURL: build))
    }

    func testTargetsUseRealPaths() throws {
        let targets = try makeTargets()
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: root.appendingPathComponent("Hippocampus.app")
        )
        XCTAssertEqual(CaptureOrphanSweep.Targets(bundleURL: alias), targets)
        let real = try XCTUnwrap(CaptureOrphanSweep.realPath(root.path))
        XCTAssertEqual(targets.helper, real + "/Hippocampus.app/Contents/MacOS/MCICaptureHelper")
    }

    // MARK: Ending them, with real processes

    func testEndsALeftoverHelperAndLeavesAnotherBundleAndMCPServeRunning() async throws {
        let bundle = root.appendingPathComponent("Hippocampus.app")
        let helper = try copy("/bin/sleep", to: bundle.appendingPathComponent("Contents/MacOS/MCICaptureHelper"))
        let worker = try copy(
            "/bin/sleep", to: bundle.appendingPathComponent("Contents/OCR/HippocampusOCR/hippocampus-ocr")
        )
        let otherHelper = try copy(
            "/bin/sleep", to: root.appendingPathComponent("Other.app/Contents/MacOS/MCICaptureHelper")
        )
        let agent = try copy("/bin/cat", to: bundle.appendingPathComponent("Contents/MacOS/mci-agent"))

        let leftover = try start(helper, ["30"])
        let leftoverWorker = try start(worker, ["30"])
        let elsewhere = try start(otherHelper, ["30"])
        let input = Pipe()
        let server = try start(agent, ["-", "mcp-serve"], input: input)
        defer {
            for process in [leftover, leftoverWorker, elsewhere, server] where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        let arguments = CaptureOrphanSweep.arguments(of: server.processIdentifier)
        XCTAssertEqual(arguments, ["-", "mcp-serve"])

        let sweep = try XCTUnwrap(CaptureOrphanSweep(bundleURL: bundle))
        let outcome = await sweep.run(.launch, liveChildren: { [] })

        XCTAssertEqual(outcome, CaptureOrphanSweep.Outcome(ended: 2, remaining: 0))
        leftover.waitUntilExit()
        leftoverWorker.waitUntilExit()
        XCTAssertEqual(leftover.terminationReason, .uncaughtSignal)
        XCTAssertTrue(elsewhere.isRunning, "another copy's helper is not this bundle's")
        XCTAssertTrue(server.isRunning, "mcp-serve is never touched")
    }

    func testLeavesALiveChildRunningOutsideQuit() async throws {
        let bundle = root.appendingPathComponent("Hippocampus.app")
        let helper = try copy("/bin/sleep", to: bundle.appendingPathComponent("Contents/MacOS/MCICaptureHelper"))
        let child = try start(helper, ["30"])
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let pid = child.processIdentifier

        let sweep = try XCTUnwrap(CaptureOrphanSweep(bundleURL: bundle))
        let outcome = await sweep.run(.paused, liveChildren: { [pid] })

        XCTAssertEqual(outcome, CaptureOrphanSweep.Outcome())
        XCTAssertTrue(child.isRunning)
    }

    // MARK: The supervisor's sweeps

    @MainActor
    func testPauseAndStopSharingSweepAndLeaveLiveChildrenWhileQuitEndsEveryMatch() async throws {
        let sweeper = RecordingOrphanSweeper()
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: keyStore,
            runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(),
            readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) },
            orphanSweeper: sweeper
        )
        try await supervisor.startAndWaitForReadiness()
        XCTAssertEqual(sweeper.runs, [], "running: nothing to sweep")

        try await supervisor.setPausedAndWait(true)
        try await waitUntil { sweeper.runs.count == 1 }
        try await supervisor.setPausedAndWait(false)
        topology.fireUnexpectedExit(forLaunchAt: 1, label: "helper", status: 82)
        try await waitUntil { sweeper.runs.count == 2 }
        XCTAssertEqual(sweeper.runs, [
            .init(moment: .paused, leavesLiveChildren: true),
            .init(moment: .stopped, leavesLiveChildren: true),
        ])

        try await supervisor.shutdownAndWait()
        await supervisor.sweepOrphans(.quit)
        XCTAssertEqual(sweeper.runs.last, .init(moment: .quit, leavesLiveChildren: false))
        XCTAssertEqual(sweeper.runs.count, 3, "the stop at Quit leaves the sweep to Quit")
    }

    // MARK: Helpers

    private func makeTargets() throws -> CaptureOrphanSweep.Targets {
        let bundle = root.appendingPathComponent("Hippocampus.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return try XCTUnwrap(CaptureOrphanSweep.Targets(bundleURL: bundle))
    }

    private func process(
        _ pid: pid_t, parent: pid_t = 1, path: String, uid: uid_t = getuid(), arguments: [String] = []
    ) -> CaptureOrphanSweep.RunningProcess {
        CaptureOrphanSweep.RunningProcess(pid: pid, parent: parent, uid: uid, path: path, arguments: arguments)
    }

    private func matches(
        _ processes: [CaptureOrphanSweep.RunningProcess],
        _ targets: CaptureOrphanSweep.Targets,
        liveChildren: Set<pid_t>? = []
    ) -> [CaptureOrphanSweep.Match] {
        CaptureOrphanSweep.matches(in: processes, targets: targets, liveChildren: liveChildren)
    }

    private func copy(_ source: String, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: destination)
        return destination
    }

    private func start(_ executable: URL, _ arguments: [String], input: Pipe? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

private final class RecordingOrphanSweeper: CaptureOrphanSweeping, @unchecked Sendable {
    struct Run: Equatable {
        let moment: CaptureOrphanSweep.Moment
        let leavesLiveChildren: Bool
    }

    private let lock = NSLock()
    private var recorded: [Run] = []

    var runs: [Run] { lock.withLock { recorded } }

    func run(
        _ moment: CaptureOrphanSweep.Moment,
        liveChildren: (@Sendable () async -> Set<pid_t>)?
    ) async -> CaptureOrphanSweep.Outcome {
        lock.withLock { recorded.append(Run(moment: moment, leavesLiveChildren: liveChildren != nil)) }
        return CaptureOrphanSweep.Outcome()
    }
}
