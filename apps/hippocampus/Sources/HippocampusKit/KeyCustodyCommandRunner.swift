// SPDX-License-Identifier: TBD-private
import Foundation
import Darwin

public enum ChildProcessEnvironment {
    public static let forbiddenInheritedNames = [
        "MCI_DB_KEY_HEX",
        "MCI_DB_KEY_FILE",
        "MCI_DEVELOPMENT_FILE_KEY",
        "HIPPOCAMPUS_ENABLE_V2P1",
    ]

    public static func scrubbingReusableKeys(
        from baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment
        for name in forbiddenInheritedNames {
            environment.removeValue(forKey: name)
        }
        return environment
    }

    public static func makeProcess(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Process {
        let process = Process()
        process.environment = scrubbingReusableKeys(from: baseEnvironment)
        return process
    }
}

struct KeyCustodyCommandResult: Sendable, Equatable {
    let terminationStatus: Int32
    let diagnostic: String
}

enum KeyCustodyCommandRunner {
    static let diagnosticLimit = 4_096
    static let terminationGraceSeconds: TimeInterval = 0.25

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> KeyCustodyCommandResult {
        let child = KeyCustodyChildControl()

        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
                let process = ChildProcessEnvironment.makeProcess(baseEnvironment: environment)
                process.executableURL = executableURL
                process.arguments = arguments

                let stderr = Pipe()
                let diagnostic = BoundedDiagnostic(limit: diagnosticLimit)
                let drain = DispatchWorkItem {
                    do {
                        while let data = try stderr.fileHandleForReading.read(upToCount: 65_536),
                              !data.isEmpty
                        {
                            diagnostic.append(data)
                        }
                    } catch {
                        // The process status remains authoritative; diagnostics are best effort.
                    }
                }
                DispatchQueue.global(qos: .utility).async(execute: drain)

                process.standardOutput = try FileHandle(
                    forWritingTo: URL(fileURLWithPath: "/dev/null")
                )
                process.standardError = stderr
                child.install(process)

                do {
                    try child.checkCancellation()
                    try process.run()
                    child.didLaunch(process)
                } catch {
                    try? stderr.fileHandleForWriting.close()
                    try? stderr.fileHandleForReading.close()
                    drain.wait()
                    child.clear(process)
                    if child.wasCancelled { throw CancellationError() }
                    throw error
                }

                try? stderr.fileHandleForWriting.close()
                process.waitUntilExit()
                drain.wait()
                child.clear(process)

                if child.wasCancelled {
                    throw CancellationError()
                }

                return KeyCustodyCommandResult(
                    terminationStatus: process.terminationStatus,
                    diagnostic: diagnostic.string
                )
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            child.cancel()
        }
    }
}

private final class BoundedDiagnostic: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ incoming: Data) {
        lock.withLock {
            guard data.count < limit else { return }
            data.append(incoming.prefix(limit - data.count))
        }
    }

    var string: String {
        lock.withLock {
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private final class KeyCustodyChildControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var terminationScheduledPID: pid_t?

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ process: Process) {
        lock.withLock {
            self.process = process
            terminationScheduledPID = nil
        }
    }

    func checkCancellation() throws {
        if wasCancelled { throw CancellationError() }
    }

    func didLaunch(_ process: Process) {
        let shouldTerminate = lock.withLock {
            cancelled && self.process === process
        }
        if shouldTerminate { scheduleTermination(for: process) }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process {
                self.process = nil
                terminationScheduledPID = nil
            }
        }
    }

    func cancel() {
        let process = lock.withLock {
            cancelled = true
            return self.process
        }
        if let process { scheduleTermination(for: process) }
    }

    private func scheduleTermination(for process: Process) {
        let pid: pid_t? = lock.withLock {
            guard self.process === process,
                  process.isRunning,
                  terminationScheduledPID != process.processIdentifier
            else { return nil }
            terminationScheduledPID = process.processIdentifier
            return process.processIdentifier
        }
        guard let pid else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + KeyCustodyCommandRunner.terminationGraceSeconds
        ) { [weak self, weak process] in
            guard let self, let process else { return }
            let shouldKill = self.lock.withLock {
                self.cancelled
                    && self.process === process
                    && self.terminationScheduledPID == pid
                    && process.isRunning
            }
            if shouldKill { kill(pid, SIGKILL) }
        }
    }
}
