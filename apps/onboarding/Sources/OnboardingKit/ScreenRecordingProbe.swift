// SPDX-License-Identifier: TBD-private
//
// Screen Recording, asked of a fresh process. On some macOS versions a
// process keeps the "no" it read before the person turned Screen Recording
// on, so onboarding asks a new copy of itself:
//
//   onboarding --tcc-probe screen-recording     exits 0 when allowed, 1 when not
//   onboarding --tcc-request screen-recording   asks macOS, then exits
//
// The request runs in its own process so that whatever macOS does to the
// process that asked (it may end it once the person allows the
// permission) never touches the window the person is using. Both commands
// are answered by the entry point before any window exists.

import Foundation

/// The two commands the onboarding binary answers before it shows a window.
public enum TCCProbeCommand {
    public static let probeFlag = "--tcc-probe"
    public static let requestFlag = "--tcc-request"
    public static let screenRecording = "screen-recording"
    /// A probe flag with anything other than a known permission after it.
    public static let usageExitCode: Int32 = 64

    /// The exit status for a probe or request command line, or nil when the
    /// arguments are not one and the app should start. `arguments[0]` is
    /// the program path.
    public static func exitCode(
        arguments: [String],
        preflight: () -> Bool,
        request: () -> Bool
    ) -> Int32? {
        let command = Array(arguments.dropFirst())
        guard let flag = command.first, flag == probeFlag || flag == requestFlag else {
            return nil
        }
        guard command.count == 2, command[1] == screenRecording else { return usageExitCode }
        let granted = flag == probeFlag ? preflight() : request()
        return granted ? 0 : 1
    }
}

/// Whether Screen Recording is allowed, according to a fresh process. `nil`
/// when that is unknown: no binary to ask, a timeout, a signal, or any exit
/// status other than 0 or 1.
public protocol ScreenRecordingProbe: Sendable {
    func isGranted() async -> Bool?
}

/// Asks macOS for Screen Recording from a separate process.
public protocol ScreenRecordingRequester: Sendable {
    func request()
}

public struct ChildScreenRecordingProbe: ScreenRecordingProbe {
    public static let defaultArguments = [TCCProbeCommand.probeFlag, TCCProbeCommand.screenRecording]
    public static let defaultTimeout: Duration = .seconds(3)

    private let executable: URL?
    private let arguments: [String]
    private let timeout: Duration

    public init(
        executable: URL?,
        arguments: [String] = ChildScreenRecordingProbe.defaultArguments,
        timeout: Duration = ChildScreenRecordingProbe.defaultTimeout
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    public func isGranted() async -> Bool? {
        guard let executable else { return nil }
        switch await ChildProcessRun.run(executable: executable, arguments: arguments, timeout: timeout) {
        case .exited(0): return true
        case .exited(1): return false
        case .exited, .signaled, .timedOut, .failedToStart: return nil
        }
    }
}

/// Starts `onboarding --tcc-request screen-recording` and does not wait for
/// it. A child still running after two minutes is stopped.
public final class ChildScreenRecordingRequester: ScreenRecordingRequester, @unchecked Sendable {
    public static let defaultArguments = [TCCProbeCommand.requestFlag, TCCProbeCommand.screenRecording]
    static let longestRun: TimeInterval = 120

    private let executable: URL?
    private let arguments: [String]
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    public init(executable: URL?, arguments: [String] = ChildScreenRecordingRequester.defaultArguments) {
        self.executable = executable
        self.arguments = arguments
    }

    public func request() {
        guard let executable else { return }
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let key = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] _ in self?.forget(key) }
        lock.withLock { running[key] = process }
        do {
            try process.run()
        } catch {
            forget(key)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.longestRun) { [weak self] in
            self?.stopIfRunning(key)
        }
    }

    private func forget(_ key: ObjectIdentifier) {
        _ = lock.withLock { running.removeValue(forKey: key) }
    }

    private func stopIfRunning(_ key: ObjectIdentifier) {
        guard let process = lock.withLock({ running[key] }), process.isRunning else { return }
        process.terminate()
    }
}

/// The onboarding binary itself, for the probe commands. Inside the app
/// `Bundle.main.executableURL` names the app's own binary, so it is not used.
public enum OnboardingExecutable {
    public static let name = "onboarding"

    public static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        guard let first = arguments.first, !first.isEmpty else { return nil }
        let url = first.hasPrefix("/")
            ? URL(fileURLWithPath: first)
            : URL(fileURLWithPath: currentDirectory).appendingPathComponent(first)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.lastPathComponent == name,
              FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
        return resolved
    }
}

/// How a short-lived child ended.
enum ChildProcessOutcome: Equatable, Sendable {
    case exited(Int32)
    case signaled
    case timedOut
    case failedToStart
}

enum ChildProcessRun {
    /// Run a child to completion, or stop it at `timeout`.
    static func run(executable: URL, arguments: [String], timeout: Duration) async -> ChildProcessOutcome {
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let box = ProcessBox(process)
        return await withCheckedContinuation { continuation in
            let outcome = OutcomeOnce(continuation)
            process.terminationHandler = { finished in
                outcome.resume(finished.terminationReason == .uncaughtSignal
                    ? .signaled : .exited(finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                outcome.resume(.failedToStart)
                return
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if outcome.resume(.timedOut) { box.process.terminate() }
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Resumes its continuation once; later calls report false and do nothing.
private final class OutcomeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChildProcessOutcome, Never>?

    init(_ continuation: CheckedContinuation<ChildProcessOutcome, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ outcome: ChildProcessOutcome) -> Bool {
        let waiting: CheckedContinuation<ChildProcessOutcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: outcome)
        return waiting != nil
    }
}
