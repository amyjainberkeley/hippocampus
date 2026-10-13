// SPDX-License-Identifier: TBD-private
//
// The reader behind Try it: one read-only `mci-agent mcp-serve` child that
// lists what was saved after a moment in time.
//
// Onboarding reads memory here for the first time; before this it never
// could. It reads through the bundled agent's read-only server, over text
// that has already passed the privacy checks, and only while Try it shows.
//
// Before the first save the agent cannot open memory and exits (10: no key
// yet, 12: no memory yet). The reader treats every exit as "not ready" and
// starts the agent again on a later call, never sooner than 2 s after the
// last start. Rows come back oldest first, so the reader pages until a short
// page and keeps the newest. The agent exits when its input closes, which
// happens when `stop()` runs or onboarding exits. After `stop()` nothing is
// read until `resume()` (Try Again on a stalled Try it).

import Foundation

/// What one read found.
public enum ReadBatch: Equatable, Sendable {
    /// Memory cannot be read yet: the agent exited, is starting again, or
    /// did not answer.
    case notReady
    /// Rows saved after the cursor, oldest first (at most the newest two
    /// pages), and the newest timestamp seen.
    case rows([ReadRow], newestTsUs: UInt64?)
}

public protocol LastReadProbe: Sendable {
    func rows(after tsUs: UInt64) async -> ReadBatch
    /// Close the reader. Reads return `.notReady` until `resume()`.
    func stop() async
    /// Read again after `stop()`; the next read starts the reader.
    func resume() async
}

/// One running reader process.
public protocol ReaderChild: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// The exit status once it has exited.
    var exitStatus: Int32? { get }
    /// Send one JSON-RPC line and wait for the reply with `id`, or nil when
    /// the child exits or `timeout` passes first.
    func call(_ line: Data, id: Int, timeout: Duration) async -> Data?
    func stop()
}

public protocol ReaderLauncher: Sendable {
    /// A started child, or nil when none can be started.
    func launch() -> (any ReaderChild)?
}

public actor AgentLastReadProbe: LastReadProbe {
    /// The agent is never started again sooner than this after a start.
    public static let minimumRespawnInterval: TimeInterval = 2
    /// The exits that mean memory is not there yet (no key, no memory).
    public static let notReadyExitCodes: Set<Int32> = [10, 12]
    public static let pageSize = 50
    /// Bounds one read at a thousand rows.
    public static let maximumPages = 20
    public static let replyTimeout: Duration = .seconds(5)

    private let launcher: any ReaderLauncher
    private let now: @Sendable () -> Date
    private var child: (any ReaderChild)?
    private var lastLaunch: Date?
    private var nextId = 1
    private var stopped = false

    /// Children started so far.
    public private(set) var launchCount = 0
    /// How the last child ended, when one has.
    public private(set) var lastExitStatus: Int32?

    public init(launcher: any ReaderLauncher, now: @escaping @Sendable () -> Date = Date.init) {
        self.launcher = launcher
        self.now = now
    }

    public func rows(after tsUs: UInt64) async -> ReadBatch {
        guard !stopped, let child = runningChild() else { return .notReady }
        var cursor = tsUs
        var newest: UInt64?
        var window: [ReadRow] = []
        for _ in 0..<Self.maximumPages {
            guard let page = await page(from: child, after: cursor) else {
                dropChild(child)
                return newest == nil ? .notReady : .rows(window, newestTsUs: newest)
            }
            guard let last = page.map(\.tsUs).max() else { break }
            window = Array((window + page).suffix(Self.pageSize * 2))
            newest = max(newest ?? 0, last)
            cursor = last
            if page.count < Self.pageSize { break }
        }
        return .rows(window, newestTsUs: newest)
    }

    /// Close the agent's input and stop it. Later reads return `.notReady`
    /// until `resume()`.
    public func stop() {
        stopped = true
        if let child { dropChild(child) }
    }

    /// Read again after `stop()`. The agent starts on the next read, still
    /// no sooner than 2 s after the last start.
    public func resume() {
        stopped = false
    }

    private func runningChild() -> (any ReaderChild)? {
        if let child {
            if child.isRunning { return child }
            dropChild(child)
        }
        if let lastLaunch, now().timeIntervalSince(lastLaunch) < Self.minimumRespawnInterval {
            return nil
        }
        lastLaunch = now()
        launchCount += 1
        guard let fresh = launcher.launch() else { return nil }
        child = fresh
        return fresh
    }

    private func dropChild(_ dropped: any ReaderChild) {
        dropped.stop()
        if let status = dropped.exitStatus { lastExitStatus = status }
        if child === dropped { child = nil }
    }

    private func page(from child: any ReaderChild, after cursor: UInt64) async -> [ReadRow]? {
        let id = nextId
        nextId += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": [
                "name": "mci_events_since",
                "arguments": ["ts_us": NSNumber(value: cursor), "limit": Self.pageSize],
            ] as [String: Any],
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: request),
              let reply = await child.call(line, id: id, timeout: Self.replyTimeout) else { return nil }
        return ReadProof.rows(fromReply: reply)
    }
}

/// The environment the reader child gets: the memory path and the key
/// reference onboarding inherited from the app, as they were, and nothing
/// else of onboarding's environment. Never a raw key.
public enum ReaderEnvironment {
    static let keychainNames = [
        "MCI_DB_KEYCHAIN_SERVICE", "MCI_DB_KEYCHAIN_ACCOUNT", "MCI_DB_KEYCHAIN_STORAGE_MODEL",
    ]

    /// Nil when the app did not pass a memory path and one complete key
    /// reference: then there is nothing safe to read with.
    public static func make(inherited: [String: String]) -> [String: String]? {
        guard let dbPath = inherited["MCI_DB_PATH"], !dbPath.isEmpty else { return nil }
        var environment: [String: String] = ["MCI_DB_PATH": dbPath]
        if inherited["MCI_DEVELOPMENT_FILE_KEY"] == "1",
           let keyFile = inherited["MCI_DB_KEY_FILE"], !keyFile.isEmpty {
            environment["MCI_DEVELOPMENT_FILE_KEY"] = "1"
            environment["MCI_DB_KEY_FILE"] = keyFile
        } else if keychainNames.allSatisfy({ inherited[$0]?.isEmpty == false }) {
            for name in keychainNames { environment[name] = inherited[name] }
        } else {
            return nil
        }
        for name in ["HOME", "TMPDIR"] {
            if let value = inherited[name] { environment[name] = value }
        }
        environment["PATH"] = inherited["PATH"] ?? "/usr/bin:/bin"
        // Listing rows needs no meaning search; skip loading the embedder.
        environment["MCI_EMBEDDER_DISABLED"] = "1"
        return environment
    }
}

/// Starts the bundled `mci-agent mcp-serve` beside this executable.
public struct AgentReaderLauncher: ReaderLauncher {
    private let executable: URL?
    private let environment: [String: String]?

    public init(
        executable: URL? = AgentReaderLauncher.bundledAgent(),
        environment: [String: String]? = ReaderEnvironment.make(inherited: ProcessInfo.processInfo.environment)
    ) {
        self.executable = executable
        self.environment = environment
    }

    /// `Contents/MacOS/mci-agent`, beside the app's own binary, as
    /// `LocalKeyGenerator` finds it.
    public static func bundledAgent(near executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let url = executable?.deletingLastPathComponent().appendingPathComponent("mci-agent"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    public func launch() -> (any ReaderChild)? {
        guard let executable, let environment else { return nil }
        return ProcessReaderChild(executable: executable, arguments: ["mcp-serve"], environment: environment)
    }
}

/// A reader child over pipes: one JSON object per line each way.
public final class ProcessReaderChild: ReaderChild, @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var finished = false

    public init?(executable: URL, arguments: [String], environment: [String: String]) {
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        input = stdin.fileHandleForWriting
        // A write after the child exits must fail, not end onboarding.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] _ in self?.finish() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            // One reply per line, cut at the newline byte alone. A reply can
            // hold U+2028, U+2029 or U+0085 inside a string (the agent's JSON
            // writer leaves them as they are), and a text line reader breaks
            // there, so the reply would never parse and every read would
            // time out.
            var line = Data()
            do {
                for try await byte in reader.bytes {
                    if byte == 0x0A {
                        self?.deliver(line)
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(byte)
                    }
                }
            } catch {}
            self?.finish()
        }
    }

    public var isRunning: Bool { process.isRunning }

    public var exitStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    public func call(_ line: Data, id: Int, timeout: Duration) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let accepted = lock.withLock { () -> Bool in
                guard !finished else { return false }
                pending[id] = continuation
                return true
            }
            guard accepted else {
                continuation.resume(returning: nil)
                return
            }
            do {
                try input.write(contentsOf: line + Data([0x0A]))
            } catch {
                take(id)?.resume(returning: nil)
                return
            }
            Task.detached { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.take(id)?.resume(returning: nil)
            }
        }
    }

    public func stop() {
        try? input.close()
        if process.isRunning { process.terminate() }
        finish()
    }

    private func take(_ id: Int) -> CheckedContinuation<Data?, Never>? {
        lock.withLock { pending.removeValue(forKey: id) }
    }

    private func deliver(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue else { return }
        take(id)?.resume(returning: line)
    }

    private func finish() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Data?, Never>] in
            finished = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for continuation in waiting {
            continuation.resume(returning: nil)
        }
    }
}
