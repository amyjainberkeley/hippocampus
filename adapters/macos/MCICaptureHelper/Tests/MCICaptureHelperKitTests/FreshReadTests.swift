import CoreGraphics
import Foundation
import ScreenCaptureKit
import XCTest
@testable import MCICaptureHelperKit

/// Ask opened: one fresh read of the window in front, past the reader's rest
/// (Read now). Synthetic windows only; no screen is captured.
final class FreshReadTests: XCTestCase {
    private let second: UInt64 = 1_000_000

    // MARK: - The request

    func testARequestAsksForOneFrameAndOneReadOfItsWindow() {
        var token = FreshReadToken()
        XCTAssertTrue(token.issue(generation: 7, nowUs: 100 * second))
        XCTAssertTrue(token.isPending(generation: 7, nowUs: 100 * second))
        XCTAssertFalse(token.isPending(generation: 8, nowUs: 100 * second), "only the window Ask opened on")
        XCTAssertTrue(token.takeFrameRequest(generation: 7, nowUs: 100 * second + 200_000))
        XCTAssertFalse(token.takeFrameRequest(generation: 7, nowUs: 100 * second + 400_000), "one stream start")
        XCTAssertFalse(token.consume(generation: 8, nowUs: 101 * second), "another window's frame is not it")
        XCTAssertTrue(token.consume(generation: 7, nowUs: 101 * second))
        XCTAssertFalse(token.consume(generation: 7, nowUs: 101 * second + 1), "once")
        XCTAssertFalse(token.isPending(generation: 7, nowUs: 101 * second + 1))
    }

    func testARequestLapsesWhenItsFrameNeverComes() {
        var token = FreshReadToken()
        XCTAssertTrue(token.issue(generation: 3, nowUs: 10 * second))
        XCTAssertTrue(token.isPending(generation: 3, nowUs: 10 * second + FreshReadToken.lifetimeUs - 1))
        XCTAssertFalse(token.consume(generation: 3, nowUs: 10 * second + FreshReadToken.lifetimeUs))
        XCTAssertFalse(token.takeFrameRequest(generation: 3, nowUs: 10 * second + FreshReadToken.lifetimeUs))
    }

    func testAskToggledQuicklyAsksForOneRead() {
        var token = FreshReadToken()
        XCTAssertTrue(token.issue(generation: 1, nowUs: 50 * second))
        XCTAssertTrue(token.consume(generation: 1, nowUs: 50 * second + 300_000))
        XCTAssertFalse(token.issue(generation: 1, nowUs: 51 * second), "within two seconds of the last request")
        XCTAssertFalse(token.isPending(generation: 1, nowUs: 51 * second))
        XCTAssertTrue(token.issue(generation: 1, nowUs: 52 * second))
        XCTAssertTrue(token.isPending(generation: 1, nowUs: 52 * second))
    }

    func testAForcedReadStartsTheWindowsIntervalAgain() {
        var pacing = FocusedReadPacing()
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 0, textCatchUp: false))
        pacing.noteRead(generation: 1, nowUs: 2 * second)
        XCTAssertFalse(pacing.admit(generation: 1, nowUs: 4 * second, textCatchUp: false), "three seconds from the forced read")
        XCTAssertTrue(pacing.admit(generation: 1, nowUs: 5 * second, textCatchUp: false))
        pacing.noteRead(generation: 2, nowUs: 6 * second)
        XCTAssertFalse(pacing.isNewWindow(generation: 2), "a window read by request counts as read")
    }

    // MARK: - The lease the app writes on

    func testTheLeaseHandsOnEveryByteAndEndsAtEOF() async throws {
        let pipe = Pipe()
        let received = ByteRecorder()
        let reader = Task {
            try await ParentLifetimeLease.waitForEOF(on: pipe.fileHandleForReading) { received.append($0) }
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data([FreshReadRequest.byte, 0x00, FreshReadRequest.byte]))
        try pipe.fileHandleForWriting.close()
        try await reader.value
        XCTAssertEqual(received.bytes, [0x72, 0x00, 0x72])
        XCTAssertEqual(FreshReadRequest.byte, UInt8(ascii: "r"))
    }

    func testMainRoutesTheRequestToTheCaptureSessionOnly() throws {
        let main = try String(contentsOf: Self.packageRoot.appendingPathComponent("Sources/MCICaptureHelper/main.swift"),
                              encoding: .utf8)
        XCTAssertTrue(main.contains("let freshReadSession = captureRuntime?.session"),
                      "without --capture there is no session, so nothing is read")
        XCTAssertTrue(main.contains("if byte == FreshReadRequest.byte { freshReadSession?.requestFreshRead() }"))
        XCTAssertTrue(main.contains("ParentLifetimeLease.waitForEOF(onByte: leaseCommands)"))
    }

    // MARK: - The session

    func testAskOpeningOnABoundWindowReadsItPastItsIntervalAndTheReadersRest() throws {
        let (session, store) = makeSession()
        store.storeSync(FocusedWindow(bundleId: "com.apple.TextEdit", windowId: 41))
        let generation = store.currentSync().generation
        XCTAssertNotNil(session.beginCaptureLifecycle())

        XCTAssertTrue(session.admitFocusedReadForTest(generation: generation, nowUs: 100 * second), "first frame")
        XCTAssertFalse(session.admitFocusedReadForTest(generation: generation, nowUs: 101 * second), "inside the interval")

        CaptureReadBudget.shared.recordRead(tookUs: 30 * second) // the reader now rests for a while
        defer { CaptureReadBudget.shared.recordRead(tookUs: 0) }
        XCTAssertFalse(session.admitFocusedReadForTest(generation: generation, nowUs: 110 * second), "the reader rests")

        try captureStandardError { session.requestFreshRead() }
        XCTAssertTrue(session.freshReadPendingForTest(generation: generation))
        XCTAssertTrue(session.takeFreshFrameRequestForTest(generation: generation), "its stream starts again")
        XCTAssertFalse(session.takeFreshFrameRequestForTest(generation: generation))
        XCTAssertTrue(session.admitFocusedReadForTest(generation: generation, nowUs: 110 * second), "read now")
        XCTAssertFalse(session.admitFocusedReadForTest(generation: generation, nowUs: 110 * second + 1), "once")
    }

    func testTheRequestNamesTheWindowInFrontAndLapsesIfFocusMoves() throws {
        let (session, store) = makeSession()
        store.storeSync(FocusedWindow(bundleId: "com.apple.TextEdit", windowId: 41))
        let asked = store.currentSync().generation
        XCTAssertNotNil(session.beginCaptureLifecycle())
        try captureStandardError { session.requestFreshRead() }
        store.storeSync(FocusedWindow(bundleId: "com.apple.mail", windowId: 42))
        let moved = store.currentSync().generation
        XCTAssertNotEqual(asked, moved)
        XCTAssertFalse(session.freshReadPendingForTest(generation: moved))
        XCTAssertFalse(session.takeFreshFrameRequestForTest(generation: moved))
    }

    func testNothingIsAskedForAnExcludedOrNeverReadWindow() throws {
        for bundle in ["com.1password.1password", "com.bitwarden.desktop", "ai.hippocampus", "com.example.private"] {
            let (session, store) = makeSession(userExcluded: ["com.example.private"])
            store.storeSync(FocusedWindow(bundleId: bundle, windowId: 9))
            XCTAssertNotNil(session.beginCaptureLifecycle())
            let log = try captureStandardError { session.requestFreshRead() }
            XCTAssertFalse(session.freshReadPendingForTest(generation: store.currentSync().generation), bundle)
            XCTAssertEqual(log, "", bundle)
        }
    }

    func testNothingIsAskedWhileCaptureIsNotRunning() async throws {
        // Never started.
        let (idle, idleStore) = makeSession()
        idleStore.storeSync(FocusedWindow(bundleId: "com.apple.TextEdit", windowId: 5))
        idle.requestFreshRead()
        XCTAssertFalse(idle.freshReadPendingForTest(generation: idleStore.currentSync().generation))

        // Paused because Screen Recording was taken away.
        let (paused, pausedStore) = makeSession()
        pausedStore.storeSync(FocusedWindow(bundleId: "com.apple.TextEdit", windowId: 5))
        XCTAssertNotNil(paused.beginCaptureLifecycle())
        _ = try await captureStandardErrorAsync { await paused.pauseForTCC(surface: .screenRecording) }
        paused.requestFreshRead()
        XCTAssertFalse(paused.freshReadPendingForTest(generation: pausedStore.currentSync().generation))

        // Stopped.
        let (stopped, stoppedStore) = makeSession()
        stoppedStore.storeSync(FocusedWindow(bundleId: "com.apple.TextEdit", windowId: 5))
        XCTAssertNotNil(stopped.beginCaptureLifecycle())
        try await stopped.stop()
        stopped.requestFreshRead()
        XCTAssertFalse(stopped.freshReadPendingForTest(generation: stoppedStore.currentSync().generation))

        // No focused window at all.
        let (empty, emptyStore) = makeSession()
        XCTAssertNotNil(empty.beginCaptureLifecycle())
        empty.requestFreshRead()
        XCTAssertFalse(empty.freshReadPendingForTest(generation: emptyStore.currentSync().generation))
    }

    func testTheRequestLeavesOneContentFreeLine() throws {
        let (session, store) = makeSession()
        store.storeSync(FocusedWindow(bundleId: "com.apple.TextEdit", windowId: 41))
        XCTAssertNotNil(session.beginCaptureLifecycle())
        let first = try captureStandardError { session.requestFreshRead() }
        let again = try captureStandardError { session.requestFreshRead() }
        XCTAssertEqual(first, "mci-capture-helper: helper_health: fresh_read_requested\n")
        XCTAssertEqual(again, "", "a second request within two seconds adds nothing")
    }

    // MARK: - Fixtures

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeSession(userExcluded: [String] = []) -> (SCStreamCaptureSession, FocusedWindowStore) {
        let store = FocusedWindowStore()
        let pipeline = SCStreamPipeline(
            cascade: SuppressionCascade(
                secureEventInput: QuietProbes(), axSecureSubrole: QuietProbes(),
                denylist: QuietProbes(), blackedRegion: QuietProbes(), knownSafeAppBundles: []
            ),
            encoder: DiscardingEncoder(), sink: DiscardingSink()
        )
        let session = SCStreamCaptureSession(
            pipeline: pipeline,
            denylist: Denylist(entries: userExcluded.map { DenylistEntry(kind: .appBundle, pattern: $0) }),
            focusedWindowStore: store
        )
        return (session, store)
    }

    @discardableResult
    private func captureStandardError(_ body: () -> Void) throws -> String {
        let capture = try StderrToFile()
        defer { capture.close() }
        body()
        return try capture.read()
    }

    private func captureStandardErrorAsync(_ body: () async -> Void) async throws -> String {
        let capture = try StderrToFile()
        defer { capture.close() }
        await body()
        return try capture.read()
    }
}

private final class ByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt8] = []
    func append(_ byte: UInt8) { lock.withLock { stored.append(byte) } }
    var bytes: [UInt8] { lock.withLock { stored } }
}

private struct QuietProbes: SecureEventInputProbe, AXSecureSubroleProbe, DenylistProbe, BlackedRegionProbe {
    func isSecureEventInputEnabled() -> Bool { false }
    func focusedHasSecureSubrole() -> Bool? { false }
    func appIsDenied(bundleId: String) -> Bool { false }
    func urlIsDenied(_ url: String) -> Bool { false }
    func windowTitleIsDenied(_ title: String) -> Bool { false }
    func hasBlackedRegion() -> Bool { false }
}

private struct DiscardingEncoder: FrameEncoder {
    func encodeAllowedFrame(input: EncoderInput?, seq: UInt64, context: WorkflowContext) async throws {}
}

private struct DiscardingSink: FrameSink {
    func write(_ data: Data) async throws {}
}

/// Standard error into a private file for the length of one check. These
/// cases run serially within their process.
private final class StderrToFile {
    private let url: URL
    private let file: FileHandle
    private let saved: Int32

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let original = dup(STDERR_FILENO)
        guard original >= 0, dup2(descriptor, STDERR_FILENO) >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            if original >= 0 { Darwin.close(original) }
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: url)
            throw POSIXError(code)
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        saved = original
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
