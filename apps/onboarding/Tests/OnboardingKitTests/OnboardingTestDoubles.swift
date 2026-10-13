import Foundation
@testable import OnboardingKit

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// A value main-actor closures can share and the test can change.
@MainActor
final class MainBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Records `tccutil` resets instead of running them: a real reset would
/// change System Settings on this Mac.
final class RecordingResetter: TCCResetting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    var resets: [[String]] { lock.withLock { calls } }
    func reset(_ arguments: [String]) { lock.withLock { calls.append(arguments) } }
}

/// Counts requests instead of starting `--tcc-request`.
final class RecordingRequester: ScreenRecordingRequester, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    func request() { lock.withLock { count += 1 } }
}

/// Answers for a fresh process without starting one. The answer is the one
/// set when a check starts, as a real child reads the permission once; the
/// test can hold the next check open to see what waits for it.
final class StubProbe: ScreenRecordingProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var reply: Bool?
    private var count = 0
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?

    init(_ answer: Bool?) { reply = answer }

    var answer: Bool? {
        get { lock.withLock { reply } }
        set { lock.withLock { reply = newValue } }
    }

    var calls: Int { lock.withLock { count } }

    /// Make the next check wait until `release()`.
    func holdNextCheck() { lock.withLock { holdNext = true } }

    var isHeld: Bool { lock.withLock { gate != nil } }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func isGranted() async -> Bool? {
        let (answerAtStart, hold) = lock.withLock { () -> (Bool?, Bool) in
            count += 1
            defer { holdNext = false }
            return (reply, holdNext)
        }
        if hold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { gate = continuation }
            }
        }
        return answerAtStart
    }
}

/// A Screen Recording permission whose in-process answer the test sets,
/// with every side effect recorded instead of performed. Nothing is written
/// to defaults: a suite would leave a file in `~/Library/Preferences`.
@MainActor
final class ScreenRecordingFixture {
    var inProcess: Bool
    let probe: StubProbe
    let requester = RecordingRequester()
    let resetter = RecordingResetter()
    let attempts: InMemoryScreenRecordingAttempts
    var panesOpened: [String] = []
    private(set) var permission: RealScreenRecordingPermission!

    init(inProcess: Bool, freshProcessSays: Bool?, attempted: Bool = false) {
        self.inProcess = inProcess
        self.probe = StubProbe(freshProcessSays)
        self.attempts = InMemoryScreenRecordingAttempts(attempted: attempted)
        permission = RealScreenRecordingPermission(
            preflight: { [unowned self] in self.inProcess },
            probe: probe,
            requester: requester,
            resetter: resetter,
            attempts: attempts,
            openPane: { [unowned self] pane in self.panesOpened.append(pane) }
        )
    }
}

/// A permission whose async check can be held open by the test, to see
/// what a row shows while a refresh is still running.
@MainActor
final class HeldPermission: TCCPermission, @unchecked Sendable {
    let kind: TCCPermissionKind
    private(set) var status: TCCStatus
    /// What the next async check finds.
    var grantedOnNextAsyncCheck = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private(set) var asyncChecks = 0

    init(kind: TCCPermissionKind, status: TCCStatus = .notRequested) {
        self.kind = kind
        self.status = status
    }

    /// Make the next async check wait until `release()`.
    func holdNextAsyncCheck() { holdNext = true }

    func release() {
        gate?.resume()
        gate = nil
    }

    var isHeld: Bool { gate != nil }

    func checkCurrent() -> TCCStatus { status }

    func checkCurrentAsync(outOfProcess: Bool) async -> TCCStatus {
        asyncChecks += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        if grantedOnNextAsyncCheck { status = .granted }
        return status
    }

    func requestOrOpenSettings() {}
    func resetAndRetry() async -> Bool { false }
    func openPrivacySettings() {}
}

/// Consent that fails to save, as a full disk would.
struct DiskFull: Error {}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("onboarding-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The repository root, for tests that read source files.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OnboardingKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // apps/onboarding
    .deletingLastPathComponent()  // apps
    .deletingLastPathComponent()  // repository

let onboardingPackageRoot = repositoryRoot.appendingPathComponent("apps/onboarding")
