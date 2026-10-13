import Foundation

/// How to start a read-only `mci-agent mcp-serve` child: the bundled binary
/// and a sanitized environment carrying only the brain path and the
/// Keychain reference.
public struct MemorySessionLaunch: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public enum MemorySessionError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case exited
    case toolFailed(String)
    case malformedReply
}

/// A warm memory session: one `mci-agent mcp-serve` child kept running, so
/// the embedder and (with `--assist`) the on-device model stay loaded.
/// Requests are JSON-RPC lines matched by id; the child is restarted on the
/// next call after it exits or times out.
public actor MemorySession {
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextId = 1
    private var generation = 0

    public init() {}

    /// Call a tool and return the JSON of its `result` payload (the
    /// understanding tools' `result.result`, or the whole result for recall).
    public func call(
        _ tool: String,
        arguments: Data,
        launch: MemorySessionLaunch,
        timeout: Duration
    ) async throws -> Data {
        try ensureRunning(launch)
        let id = nextId
        nextId += 1
        guard let argumentsObject = try? JSONSerialization.jsonObject(with: arguments),
              var line = try? JSONSerialization.data(withJSONObject: [
                  "jsonrpc": "2.0", "id": id, "method": "tools/call",
                  "params": ["name": tool, "arguments": argumentsObject],
              ])
        else { throw MemorySessionError.malformedReply }
        line.append(0x0A)
        let currentGeneration = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input?.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: MemorySessionError.exited)
                stop()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id: id, generation: currentGeneration)
            }
        }
    }

    /// Whether a child is running now.
    public var isRunning: Bool { process?.isRunning == true }

    /// Stop the child. Pending calls fail.
    public func stop() {
        process?.terminate()
        process = nil
        input = nil
        generation += 1
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: MemorySessionError.exited)
        }
    }

    private func expire(id: Int, generation expected: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: MemorySessionError.timedOut)
        // A child that stops answering is replaced; one slow answer is not.
        if expected == generation, pending.isEmpty { stop() }
    }

    private func ensureRunning(_ launch: MemorySessionLaunch) throws {
        if let process, process.isRunning { return }
        stop()
        guard FileManager.default.isExecutableFile(atPath: launch.executable.path) else {
            throw MemorySessionError.unavailable
        }
        let child = Process()
        child.executableURL = launch.executable
        child.arguments = launch.arguments
        child.environment = launch.environment
        child.qualityOfService = .userInitiated
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            throw MemorySessionError.unavailable
        }
        process = child
        input = stdin.fileHandleForWriting
        let myGeneration = generation
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            // Replies are framed on 0x0A only: `bytes.lines` also splits on
            // U+2028 and U+0085, which arrive unescaped inside replies and
            // would cut one in two (RULINGS S11).
            var framer = ReplyFramer()
            do {
                for try await byte in reader.bytes {
                    if let frame = framer.append(byte) {
                        await self?.deliver(frame: frame, generation: myGeneration)
                    }
                }
            } catch {}
            await self?.exited(generation: myGeneration)
        }
    }

    private func exited(generation expected: Int) {
        guard expected == generation else { return }
        stop()
    }

    private func deliver(frame: Data, generation expected: Int) {
        guard expected == generation,
              let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let id = object["id"] as? Int,
              let continuation = pending.removeValue(forKey: id)
        else { return }
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: MemorySessionError.toolFailed(error["message"] as? String ?? "failed"))
            return
        }
        guard let result = object["result"] as? [String: Any] else {
            continuation.resume(throwing: MemorySessionError.malformedReply)
            return
        }
        let payload = result["result"] ?? result
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            continuation.resume(throwing: MemorySessionError.malformedReply)
            return
        }
        continuation.resume(returning: data)
    }
}

/// Cuts the child's output into replies at each 0x0A byte, and nowhere else.
struct ReplyFramer {
    private var buffer = Data()

    /// The finished reply when `byte` ends one.
    mutating func append(_ byte: UInt8) -> Data? {
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        defer { buffer.removeAll(keepingCapacity: true) }
        return buffer
    }
}
