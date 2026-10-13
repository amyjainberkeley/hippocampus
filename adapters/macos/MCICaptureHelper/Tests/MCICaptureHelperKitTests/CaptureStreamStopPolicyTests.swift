import Foundation
import ScreenCaptureKit
import XCTest
@testable import MCICaptureHelperKit

final class CaptureStreamStopPolicyTests: XCTestCase {
    func testExplicitMacOSStopCannotUseTheAutomaticRetryExit() {
        let error = NSError(domain: SCStreamErrorDomain, code: -3817)
        let failure = CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: true)
        XCTAssertEqual(failure?.helperExitStatus, 82)
    }

    func testRetiredStreamCallbackCannotTerminateItsReplacement() {
        let error = NSError(domain: SCStreamErrorDomain, code: -3805)
        XCTAssertNil(CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: false))
    }

    func testExplicitUserStopWinsWhenWindowReplacementRacesItsCallback() {
        XCTAssertEqual(CaptureRuntimeFailure.forStreamStop(
            NSError(domain: SCStreamErrorDomain, code: -3817), sourceIsLive: false
        )?.helperExitStatus, 82)
    }

    func testCurrentStreamLossStillRequiresOwnerVisibleFailure() {
        let error = NSError(domain: SCStreamErrorDomain, code: -3805)
        XCTAssertEqual(
            CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: true)?.helperExitStatus,
            81
        )
    }

    func testForeignErrorDomainCannotImpersonateExplicitMacOSStop() {
        let error = NSError(domain: "SyntheticTransportError", code: -3817)
        XCTAssertEqual(
            CaptureRuntimeFailure.forStreamStop(error, sourceIsLive: true)?.helperExitStatus,
            81
        )
    }

    // MARK: - What runs before the process ends

    override func setUp() {
        super.setUp()
        HelperExit.resetForTesting()
    }

    override func tearDown() {
        HelperExit.resetForTesting()
        super.tearDown()
    }

    func testTheBeforeExitHookRunsBeforeTheFailureHandler() {
        let events = StopEventLog()
        HelperExit.registerBeforeExit { events.append("before exit") }
        let session = StopFixtures.makeSession { failure in
            events.append("handler \(failure.helperExitStatus)")
        }
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let userStopped = NSError(domain: SCStreamErrorDomain, code: -3817)

        session.stream(stream, didStopWithError: userStopped)
        session.stream(stream, didStopWithError: userStopped)

        XCTAssertEqual(events.snapshot(), ["before exit", "handler 82"],
                       "the OCR worker must be stopped before the handler ends the process, once")
    }

    func testTheBeforeExitHookRunsOnceAndEveryCallerWaitsForIt() {
        let events = StopEventLog()
        HelperExit.registerBeforeExit {
            Thread.sleep(forTimeInterval: 0.05)
            events.append("stopped")
        }
        let early = StopEventLog()
        // Each display's stream and the focused stream report Stop Sharing on
        // their own queues, so several threads arrive at once.
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            HelperExit.runBeforeExit()
            if events.snapshot().isEmpty { early.append("returned before the work finished") }
        }
        XCTAssertEqual(events.snapshot(), ["stopped"])
        XCTAssertEqual(early.snapshot(), [])
    }

    func testWorkThatReachesTheExitPathAgainDoesNotDeadlock() {
        let events = StopEventLog()
        HelperExit.registerBeforeExit {
            HelperExit.runBeforeExit()
            events.append("stopped")
        }
        HelperExit.runBeforeExit()
        XCTAssertEqual(events.snapshot(), ["stopped"])
    }

    /// The real default path, in a child process: the registered work runs,
    /// then Stop Sharing ends with `_exit(82)`, which skips exit handlers, and
    /// any other failure keeps `exit`.
    func testStopSharingStopsTheWorkerThenEndsWith82WithoutExitHandlers() throws {
        for (failure, status, exitHandlersRun) in [
            ("userStoppedCapture", Int32(82), false),
            ("streamStoppedUnexpectedly", Int32(81), true),
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [
                "-XCTest", "MCICaptureHelperKitTests.CaptureStreamStopPolicyTests/testTerminationFixture",
                Bundle(for: Self.self).bundleURL.path,
            ]
            // The fixture needs only this synthetic selector, never the host environment.
            process.environment = [StopFixtures.terminationEnvironmentKey: failure]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let log = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()

            XCTAssertEqual(process.terminationReason, .exit, failure)
            XCTAssertEqual(process.terminationStatus, status, failure)
            let hook = try XCTUnwrap(log.range(of: StopFixtures.hookMarker), "\(failure): the work did not run")
            if exitHandlersRun {
                let handlers = try XCTUnwrap(log.range(of: StopFixtures.exitHandlerMarker), failure)
                XCTAssertLessThan(hook.lowerBound, handlers.lowerBound, failure)
            } else {
                XCTAssertNil(log.range(of: StopFixtures.exitHandlerMarker),
                             "Stop Sharing must end without running exit handlers")
            }
        }
    }

    func testTerminationFixture() throws {
        guard let raw = ProcessInfo.processInfo.environment[StopFixtures.terminationEnvironmentKey] else { return }
        let failure: CaptureRuntimeFailure = raw == "userStoppedCapture" ? .userStoppedCapture : .streamStoppedUnexpectedly
        HelperExit.registerBeforeExit {
            FileHandle.standardError.write(Data(StopFixtures.hookMarker.utf8))
        }
        atexit {
            FileHandle.standardError.write(Data(StopFixtures.exitHandlerMarker.utf8))
        }
        SCStreamCaptureSession.terminateHelper(for: failure)
    }
}

final class ParentGoneDeadlineTests: XCTestCase {
    func testTheProductionDeadlineIsTenSecondsAndEndsWith85() {
        XCTAssertEqual(ParentGoneDeadline.seconds, 10)
        XCTAssertEqual(ParentGoneDeadline.exitStatus, 85)
    }

    func testNothingHappensWhileTheParentLives() {
        let events = StopEventLog()
        let parentGone = StopFlag()
        let deadline = ParentGoneDeadline(
            seconds: 0.01, pollInterval: 0.01,
            parentIsGone: { parentGone.value },
            beforeExit: { events.append("before exit") },
            exitProcess: { events.append("exit \($0)") }
        )
        deadline.arm()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(events.snapshot(), [], "a live parent bounds the drain itself")
        parentGone.set() // lets the watcher thread finish
    }

    func testOnceTheParentIsGoneTheWorkerStopsFirstThenTheProcessEndsWith85() {
        let events = StopEventLog()
        let parentGone = StopFlag()
        let deadline = ParentGoneDeadline(
            seconds: 0.2, pollInterval: 0.005,
            parentIsGone: { parentGone.value },
            beforeExit: { events.append("before exit") },
            exitProcess: { events.append("exit \($0)") }
        )
        deadline.arm()
        deadline.arm()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(events.snapshot(), [])

        let goneAt = Date()
        parentGone.set()
        XCTAssertTrue(events.wait(timeout: 10) { $0.contains("exit 85") })
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(events.snapshot(), ["before exit", "exit 85"], "arming twice starts one watcher")
        let times = events.times()
        XCTAssertGreaterThanOrEqual(times[0].timeIntervalSince(goneAt), 0)
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.2,
                                    "the worker stops first, then the drain gets its full time")
    }
}

private enum StopFixtures {
    static let terminationEnvironmentKey = "MCI_CAPTURE_STOP_TEST_FAILURE"
    static let hookMarker = "before-exit work ran\n"
    static let exitHandlerMarker = "exit handlers ran\n"

    private struct NoSEI: SecureEventInputProbe {
        func isSecureEventInputEnabled() -> Bool { false }
    }
    private struct AXNonSecure: AXSecureSubroleProbe {
        func focusedHasSecureSubrole() -> Bool? { false }
    }
    private struct NoApps: DenylistProbe {
        func appIsDenied(bundleId _: String) -> Bool { false }
        func urlIsDenied(_: String) -> Bool { false }
        func windowTitleIsDenied(_: String) -> Bool { false }
    }
    private struct NoBlack: BlackedRegionProbe {
        func hasBlackedRegion() -> Bool { false }
    }
    private struct NoopEncoder: FrameEncoder {
        func encodeAllowedFrame(input _: EncoderInput?, seq _: UInt64, context _: WorkflowContext) async throws {}
    }
    private struct NoopSink: FrameSink {
        func write(_: Data) async throws {}
    }

    static func makeSession(
        runtimeFailureHandler: @escaping @Sendable (CaptureRuntimeFailure) -> Void
    ) -> SCStreamCaptureSession {
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(), axSecureSubrole: AXNonSecure(),
            denylist: NoApps(), blackedRegion: NoBlack(), knownSafeAppBundles: []
        )
        return SCStreamCaptureSession(
            pipeline: SCStreamPipeline(cascade: cascade, encoder: NoopEncoder(), sink: NoopSink()),
            denylist: Denylist(entries: []),
            runtimeFailureHandler: runtimeFailureHandler
        )
    }
}

private final class StopEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(name: String, at: Date)] = []

    func append(_ event: String) {
        lock.withLock { events.append((event, Date())) }
    }

    func snapshot() -> [String] {
        lock.withLock { events.map(\.name) }
    }

    func times() -> [Date] {
        lock.withLock { events.map(\.at) }
    }

    func wait(timeout: TimeInterval, until done: ([String]) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done(snapshot()) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return done(snapshot())
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var value: Bool { lock.withLock { raised } }

    func set() {
        lock.withLock { raised = true }
    }
}

final class FocusRebindPolicyTests: XCTestCase {
    func testAClosedWindowIsNotAFailure() {
        let closed = NSError(domain: SCStreamErrorDomain, code: -3815)
        XCTAssertTrue(ClosedWindowBudget.isClosedWindow(closed))
        var budget = ClosedWindowBudget()
        XCTAssertTrue(budget.absorb(nowUs: 1_000_000))
    }

    func testOtherStopsAreNotMistakenForAClosedWindow() {
        for code in [-3805, -3811, -3817, -3821] {
            XCTAssertFalse(ClosedWindowBudget.isClosedWindow(NSError(domain: SCStreamErrorDomain, code: code)))
        }
        XCTAssertFalse(ClosedWindowBudget.isClosedWindow(NSError(domain: "SyntheticTransportError", code: -3815)))
    }

    func testClosedWindowStopsBackToBackAreStillAFailure() {
        var budget = ClosedWindowBudget()
        let absorbed = (0..<ClosedWindowBudget.limit).map { budget.absorb(nowUs: 1_000_000 + UInt64($0) * 300_000) }
        XCTAssertEqual(absorbed, Array(repeating: true, count: ClosedWindowBudget.limit - 1) + [false])
    }

    func testWindowsClosedMinutesApartNeverUseUpTheBudget() {
        var budget = ClosedWindowBudget()
        for close in 0..<50 {
            XCTAssertTrue(budget.absorb(nowUs: UInt64(close) * 60_000_000))
        }
    }

    func testStoppingAStreamThatAlreadyEndedIsNotAFailure() {
        XCTAssertTrue(ClosedWindowBudget.isAlreadyStopped(NSError(domain: SCStreamErrorDomain, code: -3808)))
        XCTAssertFalse(ClosedWindowBudget.isAlreadyStopped(NSError(domain: SCStreamErrorDomain, code: -3816)))
        XCTAssertFalse(ClosedWindowBudget.isAlreadyStopped(NSError(domain: "SyntheticTransportError", code: -3808)))
    }

    func testAWindowThatCannotBeBoundIsRetriedEveryTwoSecondsNotFiveTimesASecond() {
        var pacing = RebindRetryPacing()
        XCTAssertTrue(pacing.admit(generation: 7, nowUs: 0))
        pacing.record(generation: 7, installed: false, nowUs: 0)
        let polls = stride(from: UInt64(200_000), through: 10_000_000, by: 200_000)
        var attempts = 0
        for now in polls where pacing.admit(generation: 7, nowUs: now) {
            attempts += 1
            pacing.record(generation: 7, installed: false, nowUs: now)
        }
        XCTAssertEqual(attempts, 5)
    }

    func testANewFocusedWindowIsTriedAtOnce() {
        var pacing = RebindRetryPacing()
        pacing.record(generation: 7, installed: false, nowUs: 1_000_000)
        XCTAssertFalse(pacing.admit(generation: 7, nowUs: 1_200_000))
        XCTAssertTrue(pacing.admit(generation: 8, nowUs: 1_200_000))
    }

    func testABoundWindowClearsTheWait() {
        var pacing = RebindRetryPacing()
        pacing.record(generation: 7, installed: false, nowUs: 1_000_000)
        pacing.record(generation: 7, installed: true, nowUs: 1_100_000)
        XCTAssertTrue(pacing.admit(generation: 7, nowUs: 1_200_000))
    }
}
