import Foundation
import ScreenCaptureKit
import XCTest
@testable import MCICaptureHelperKit

final class CaptureRuntimeDiagnosticsTests: XCTestCase {
    func testUserStopEmitsOnlyBoundedDiagnosticsOnce() throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let source = makeStream()
        let error = hostileError(domain: SCStreamErrorDomain, code: -3817)

        let log = try captureStandardError {
            session.stream(source, didStopWithError: error)
            session.stream(source, didStopWithError: error)
        }

        XCTAssertEqual(recorder.snapshot(), [.userStoppedCapture])
        XCTAssertEqual(recorder.snapshot().first?.helperExitStatus, 82)
        XCTAssertEqual(log, "mci-capture-helper: helper_health capture_runtime_failed=userStoppedCapture failure_site=stream_delegate error_domain=SCStreamErrorDomain error_code=-3817\n")
        XCTAssertFalse(log.contains("PRIVATE"))
        XCTAssertLessThan(log.utf8.count, 256)
    }

    func testRetiredDelegateErrorRemainsSilentAndNonterminal() throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let source = makeStream()

        let log = try captureStandardError {
            session.stream(source, didStopWithError: hostileError(
                domain: SCStreamErrorDomain, code: -3805
            ))
            session.stream(source, didStopWithError: hostileError(
                domain: "PRIVATE-domain\nhttps://private.invalid/window", code: -3817
            ))
        }

        XCTAssertEqual(log, "")
        XCTAssertEqual(recorder.snapshot(), [])
        XCTAssertFalse(session.hasRuntimeFailureForTest())
    }

    func testCurrentDelegateFailureIsTerminalAndRejectsRestart() async throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let source = makeStream()
        try install(source, generation: 1, in: session)

        let log = try captureStandardError {
            session.stream(source, didStopWithError: hostileError(domain: SCStreamErrorDomain, code: -3805))
            session.stream(source, didStopWithError: hostileError(domain: NSOSStatusErrorDomain, code: -50))
        }

        XCTAssertEqual(log, "mci-capture-helper: helper_health capture_runtime_failed=streamStoppedUnexpectedly failure_site=stream_delegate error_domain=SCStreamErrorDomain error_code=-3805\n")
        XCTAssertEqual(recorder.snapshot(), [.streamStoppedUnexpectedly])
        XCTAssertEqual(recorder.snapshot().first?.helperExitStatus, 81)
        do {
            try await session.start()
            XCTFail("terminal capture loss must reject restart")
        } catch let failure as CaptureRuntimeFailure {
            XCTAssertEqual(failure, .streamStoppedUnexpectedly)
        }
    }

    func testReplacementRetiresOldDelegateButKeepsCurrentFailureDiagnostics() throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let old = makeStream()
        let replacement = makeStream()
        let epoch = try install(old, generation: 1, in: session)
        XCTAssertTrue(session.registerCandidateStream(replacement, generation: 2, epoch: epoch))
        XCTAssertTrue(session.commitCandidateStream(replacement, generation: 2, epoch: epoch).installed)

        let retiredLog = try captureStandardError {
            session.stream(old, didStopWithError: hostileError(domain: SCStreamErrorDomain, code: -3805))
        }
        XCTAssertEqual(retiredLog, "")
        XCTAssertFalse(session.hasRuntimeFailureForTest())
        XCTAssertEqual(recorder.snapshot(), [])

        let currentLog = try captureStandardError {
            session.stream(replacement, didStopWithError: hostileError(domain: SCStreamErrorDomain, code: -3806))
        }
        XCTAssertEqual(currentLog, "mci-capture-helper: helper_health capture_runtime_failed=streamStoppedUnexpectedly failure_site=stream_delegate error_domain=SCStreamErrorDomain error_code=-3806\n")
        XCTAssertEqual(recorder.snapshot(), [.streamStoppedUnexpectedly])
    }

    func testForeignAndSpoofedDomainsCannotLeakOrImpersonateUserStop() throws {
        for domain in [
            "PRIVATE-domain\nhttps://private.invalid/window",
            "SCStreamErrorDomain\nPRIVATE-forged-log",
            SCStreamErrorDomain + ".PRIVATE-suffix",
            SCStreamErrorDomain + "\nPRIVATE-forged-log",
            String(repeating: "PRIVATE", count: 10000),
        ] {
            let recorder = FailureRecorder()
            let session = makeSession(recorder: recorder)
            let source = makeStream()
            try install(source, generation: 1, in: session)
            let log = try captureStandardError {
                session.stream(source, didStopWithError: hostileError(domain: domain, code: -3817))
            }
            XCTAssertEqual(log, "mci-capture-helper: helper_health capture_runtime_failed=streamStoppedUnexpectedly failure_site=stream_delegate error_domain=other error_code=-3817\n")
            XCTAssertEqual(recorder.snapshot().first?.helperExitStatus, 81)
        }
    }

    func testAllowlistedDomainsAndExtremeNumericCodesStayBounded() throws {
        for (domain, token) in [
            (SCStreamErrorDomain, "SCStreamErrorDomain"),
            (NSOSStatusErrorDomain, "NSOSStatusErrorDomain"),
            (NSPOSIXErrorDomain, "NSPOSIXErrorDomain"),
            (NSCocoaErrorDomain, "NSCocoaErrorDomain"),
        ] {
            for code in [Int.min, Int.max, 0] {
                let recorder = FailureRecorder()
                let session = makeSession(recorder: recorder)
                let source = makeStream()
                try install(source, generation: 1, in: session)
                let log = try captureStandardError {
                    session.stream(source, didStopWithError: hostileError(domain: domain, code: code))
                }
                XCTAssertTrue(log.contains("error_domain=\(token) error_code=\(code)\n"))
                XCTAssertFalse(log.contains("PRIVATE"))
                XCTAssertEqual(log.filter { $0 == "\n" }.count, 1)
                XCTAssertLessThan(log.utf8.count, 256)
                XCTAssertEqual(recorder.snapshot().first?.helperExitStatus, 81)
            }
        }
    }

    func testFailedRebindTeardownKeepsOriginalErrorAndGenericExit() async throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let source = FailingStopStream(error: hostileError(domain: SCStreamErrorDomain, code: -3817))

        let log = try await captureStandardErrorAsync {
            let stopped = await session.stopExpectedStream(source, failureSite: .rebindTeardown)
            XCTAssertFalse(stopped)
        }

        XCTAssertEqual(log, "mci-capture-helper: helper_health capture_runtime_failed=streamStoppedUnexpectedly failure_site=rebind_teardown error_domain=SCStreamErrorDomain error_code=-3817\n")
        XCTAssertEqual(recorder.snapshot(), [.streamStoppedUnexpectedly])
        XCTAssertEqual(recorder.snapshot().first?.helperExitStatus, 81)
        XCTAssertTrue(session.hasRuntimeFailureForTest())
    }

    func testTCCPauseTeardownEmitsItsOwnSiteAndStaysFailClosed() async throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let source = FailingStopStream(error: hostileError(domain: NSOSStatusErrorDomain, code: -50))
        try install(source, generation: 1, in: session)

        let log = try await captureStandardErrorAsync {
            await session.pauseForTCC(surface: .screenRecording)
        }

        XCTAssertEqual(log, "mci-capture-helper: helper_health tcc_revoked=screenRecording\n"
            + "mci-capture-helper: helper_health capture_runtime_failed=streamStoppedUnexpectedly failure_site=tcc_pause_teardown error_domain=NSOSStatusErrorDomain error_code=-50\n")
        XCTAssertTrue(session.isPausedForTCCForTest())
        XCTAssertTrue(session.hasRuntimeFailureForTest())
        XCTAssertEqual(recorder.snapshot().first?.helperExitStatus, 81)
    }

    func testConcurrentCallbacksEmitOnlyOneTerminalDiagnostic() throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let source = StreamIdentity(value: makeStream())
        let error = hostileError(domain: SCStreamErrorDomain, code: -3817)
        let log = try captureStandardError {
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                session.stream(source.value, didStopWithError: error)
            }
        }
        XCTAssertEqual(log, "mci-capture-helper: helper_health capture_runtime_failed=userStoppedCapture failure_site=stream_delegate error_domain=SCStreamErrorDomain error_code=-3817\n")
        XCTAssertEqual(recorder.snapshot(), [.userStoppedCapture])
    }

    func testMissingErrorDoesNotInventFrameworkDetails() throws {
        let recorder = FailureRecorder()
        let session = makeSession(recorder: recorder)
        let log = try captureStandardError {
            session.recordUnexpectedStreamTerminationForTest()
        }
        XCTAssertEqual(log, "mci-capture-helper: helper_health capture_runtime_failed=streamStoppedUnexpectedly failure_site=stream_delegate error_domain=none error_code=none\n")
        XCTAssertEqual(recorder.snapshot(), [.streamStoppedUnexpectedly])
    }

    func testDefaultHandlerWritesHealthLogAndPreservesProcessExitStatuses() throws {
        for (code, exitStatus, failure) in [
            (-3805, Int32(81), "streamStoppedUnexpectedly"),
            (-3817, Int32(82), "userStoppedCapture"),
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [
                "-XCTest", "MCICaptureHelperKitTests.CaptureRuntimeDiagnosticsTests/testDefaultHandlerExitFixture",
                Bundle(for: Self.self).bundleURL.path,
            ]
            // XCTest can dump its environment on launch failure. The fixture
            // needs only this synthetic selector, never the host environment.
            process.environment = ["MCI_CAPTURE_DIAGNOSTICS_TEST_EXIT_CODE": String(code)]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let log = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, exitStatus)
            let expected = "mci-capture-helper: helper_health capture_runtime_failed=\(failure) failure_site=stream_delegate error_domain=SCStreamErrorDomain error_code=\(code)\n"
            // The XCTest harness writes its own suite/case preamble to stderr.
            let helperLog = log.split(separator: "\n").filter {
                !$0.hasPrefix("Test Suite '") && !$0.hasPrefix("Test Case '-[")
            }.joined(separator: "\n") + "\n"
            XCTAssertTrue(helperLog == expected, "default handler stderr must contain only the expected diagnostic")
            XCTAssertFalse(log.contains("PRIVATE"))
        }
    }

    func testDefaultHandlerExitFixture() throws {
        guard let rawCode = ProcessInfo.processInfo.environment["MCI_CAPTURE_DIAGNOSTICS_TEST_EXIT_CODE"],
              let code = Int(rawCode)
        else { return }
        let session = makeSession()
        let source = makeStream()
        try install(source, generation: 1, in: session)
        session.stream(source, didStopWithError: hostileError(domain: SCStreamErrorDomain, code: code))
        XCTFail("the default owner handler must terminate the helper process")
    }

    @discardableResult
    private func install(_ stream: SCStream, generation: UInt64, in session: SCStreamCaptureSession) throws -> UInt64 {
        let epoch = try XCTUnwrap(session.beginCaptureLifecycle())
        XCTAssertTrue(session.registerCandidateStream(stream, generation: generation, epoch: epoch))
        XCTAssertTrue(session.commitCandidateStream(stream, generation: generation, epoch: epoch).installed)
        return epoch
    }

    private func hostileError(domain: String, code: Int) -> NSError {
        NSError(domain: domain, code: code, userInfo: [
            NSLocalizedDescriptionKey: String(repeating: "PRIVATE-description\n", count: 1000),
            NSLocalizedFailureReasonErrorKey: "PRIVATE-reason",
            NSLocalizedRecoverySuggestionErrorKey: "PRIVATE-recovery",
            NSURLErrorKey: URL(string: "https://private.invalid/PRIVATE-url")!,
            NSUnderlyingErrorKey: NSError(domain: "PRIVATE-underlying", code: 99),
            "windowTitle": "PRIVATE-window-title",
            "content": "PRIVATE-screen-content",
        ])
    }

    private func makeStream() -> SCStream {
        // Construction only: no shareable-content lookup or capture is started.
        SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    }

    private func makeSession(recorder: FailureRecorder? = nil) -> SCStreamCaptureSession {
        let pipeline = SCStreamPipeline(
            cascade: SuppressionCascade(
                secureEventInput: SafeProbes(), axSecureSubrole: SafeProbes(),
                denylist: SafeProbes(), blackedRegion: SafeProbes(), knownSafeAppBundles: []
            ),
            encoder: NoopEncoder(), sink: NoopSink()
        )
        if let recorder {
            return SCStreamCaptureSession(
                pipeline: pipeline, denylist: Denylist(entries: []),
                runtimeFailureHandler: { recorder.record($0) }
            )
        }
        return SCStreamCaptureSession(pipeline: pipeline, denylist: Denylist(entries: []))
    }

    private func captureStandardError(_ body: () -> Void) throws -> String {
        let capture = try StandardErrorCapture()
        defer { capture.close() }
        body()
        return try capture.read()
    }

    private func captureStandardErrorAsync(_ body: () async -> Void) async throws -> String {
        let capture = try StandardErrorCapture()
        defer { capture.close() }
        await body()
        return try capture.read()
    }
}

// Use a file so a regression that prints an unbounded error cannot fill a pipe
// and deadlock the test. These XCTest cases run serially within their process.
private final class StandardErrorCapture {
    private let url: URL
    private let file: FileHandle
    private let saved: Int32

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        saved = dup(STDERR_FILENO)
        guard saved >= 0, dup2(file.fileDescriptor, STDERR_FILENO) >= 0 else {
            throw POSIXError(.EBADF)
        }
    }

    func read() throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func close() {
        dup2(saved, STDERR_FILENO)
        Darwin.close(saved)
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }
}

private final class FailingStopStream: SCStream {
    private let failure: NSError

    init(error: NSError) {
        failure = error
        super.init(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    }

    override func stopCapture(completionHandler: ((Error?) -> Void)? = nil) {
        completionHandler?(failure)
    }
}

// Concurrent callbacks use the stream only as an identity; they do not call
// its framework methods or mutate it. Session state is protected by its lock.
private struct StreamIdentity: @unchecked Sendable {
    let value: SCStream
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [CaptureRuntimeFailure] = []

    func record(_ failure: CaptureRuntimeFailure) {
        lock.withLock { failures.append(failure) }
    }

    func snapshot() -> [CaptureRuntimeFailure] {
        lock.withLock { failures }
    }
}

private struct SafeProbes: SecureEventInputProbe, AXSecureSubroleProbe, DenylistProbe, BlackedRegionProbe {
    func isSecureEventInputEnabled() -> Bool { false }
    func focusedHasSecureSubrole() -> Bool? { false }
    func appIsDenied(bundleId: String) -> Bool { false }
    func urlIsDenied(_ url: String) -> Bool { false }
    func windowTitleIsDenied(_ title: String) -> Bool { false }
    func hasBlackedRegion() -> Bool { false }
}

private struct NoopEncoder: FrameEncoder {
    func encodeAllowedFrame(input: EncoderInput?, seq: UInt64, context: WorkflowContext) async throws {}
}

private struct NoopSink: FrameSink {
    func write(_ data: Data) async throws {}
}
