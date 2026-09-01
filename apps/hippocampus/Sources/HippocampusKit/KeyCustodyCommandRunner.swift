// SPDX-License-Identifier: TBD-private
import Foundation

struct KeyCustodyCommandResult: Sendable, Equatable {
    let terminationStatus: Int32
    let diagnostic: String
}

enum KeyCustodyCommandRunner {
    static let diagnosticLimit = 4_096

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> KeyCustodyCommandResult {
        let child = KeyCustodyChildControl()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.environment = environment

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

                do {
                    try process.run()
                } catch {
                    try? stderr.fileHandleForWriting.close()
                    try? stderr.fileHandleForReading.close()
                    drain.wait()
                    throw error
                }

                child.install(process)
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

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ process: Process) {
        let shouldTerminate = lock.withLock {
            self.process = process
            return cancelled
        }
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process {
                self.process = nil
            }
        }
    }

    func cancel() {
        let process = lock.withLock {
            cancelled = true
            return self.process
        }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}
