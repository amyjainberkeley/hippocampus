// SPDX-License-Identifier: Apache-2.0
//
// ChildProcessSpawner.swift — the window's process, started with posix_spawn
// so it can be given the private pipe (SPEC 2.6.4): file descriptor 3 for
// the window to write to the app, 4 for the app to write to the window, and
// `MCI_WINDOW_CHANNEL=3,4` in its environment. Foundation's Process closes
// every descriptor above 2 in the child, so it can't carry them.
//
// Every other descriptor is closed in the child (POSIX_SPAWN_CLOEXEC_DEFAULT),
// its signal mask is empty and its signals are at their defaults, as a fresh
// process's are. The app's own ends of the pipes are close-on-exec, so no
// other child the app starts ever inherits them.

import Darwin
import Foundation

/// A window process the app started, with the app's ends of its pipe.
public final class SpawnedWindowProcess: @unchecked Sendable {
    public let processIdentifier: pid_t
    /// What the window writes (its descriptor 3), for the app to read.
    public let fromWindow: FileHandle
    /// What the app writes, for the window to read (its descriptor 4).
    public let toWindow: FileHandle

    private let lock = NSLock()
    private var exited = false
    private var exitStatus: Int32?
    private var handlers: [@Sendable (Int32) -> Void] = []
    private var source: DispatchSourceProcess?

    init(processIdentifier: pid_t, fromWindow: FileHandle, toWindow: FileHandle) {
        self.processIdentifier = processIdentifier
        self.fromWindow = fromWindow
        self.toWindow = toWindow
        let source = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit,
                                                      queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.reap() }
        self.source = source
        source.resume()
        // It may have ended before the source was armed.
        reapIfEnded()
    }

    /// Whether the process still runs. A process that ended is reaped, so
    /// none is left behind as a zombie.
    public var isRunning: Bool {
        reapIfEnded()
        return lock.withLock { !exited }
    }

    /// How it ended: its exit status, or 128 + the signal that ended it.
    public var terminationStatus: Int32? { lock.withLock { exitStatus } }

    /// Called once, when the process has ended (or at once if it has).
    public func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        let status: Int32? = lock.withLock {
            if exited { return exitStatus ?? 0 }
            handlers.append(handler)
            return nil
        }
        if let status { handler(status) }
    }

    /// SIGTERM, as Foundation's `terminate()` sends.
    public func terminate() {
        guard isRunning else { return }
        _ = Darwin.kill(processIdentifier, SIGTERM)
    }

    /// SIGKILL, for a process that would not end.
    public func kill() {
        guard isRunning else { return }
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }

    private func reapIfEnded() {
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier {
            finish(status)
        } else if result < 0, errno == ECHILD {
            finish(0)
        }
    }

    private func reap() {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result < 0 && errno == EINTR
        finish(result == processIdentifier ? status : 0)
    }

    private func finish(_ raw: Int32) {
        let code: Int32 = (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
        let ready: [@Sendable (Int32) -> Void] = lock.withLock {
            guard !exited else { return [] }
            exited = true
            exitStatus = code
            let ready = handlers
            handlers = []
            return ready
        }
        source?.cancel()
        for handler in ready { handler(code) }
    }
}

public enum ChildProcessSpawnerError: Error, Equatable {
    case pipe(Int32)
    case spawn(Int32)
}

/// Starts the window's process with the private pipe on descriptors 3 and 4.
public enum ChildProcessSpawner {
    /// The window writes here; the app reads.
    public static let windowWritesDescriptor: Int32 = 3
    /// The app writes here; the window reads.
    public static let windowReadsDescriptor: Int32 = 4
    public static let channelEnvironmentKey = "MCI_WINDOW_CHANNEL"

    /// Starts `executable` with `environment` (plus the channel's variable)
    /// and the two pipes. Standard input is /dev/null; standard output and
    /// error are the app's own, as Foundation's Process gives them.
    public static func spawnWindow(executable: URL, arguments: [String] = [],
                                   environment: [String: String]) throws -> SpawnedWindowProcess {
        var toApp: [Int32] = [-1, -1]
        var toWindow: [Int32] = [-1, -1]
        guard pipe(&toApp) == 0 else { throw ChildProcessSpawnerError.pipe(errno) }
        guard pipe(&toWindow) == 0 else {
            let error = errno
            close(toApp[0]); close(toApp[1])
            throw ChildProcessSpawnerError.pipe(error)
        }
        // Every end is close-on-exec in the app. The child's two are moved
        // high first, so a dup2 onto 3 or 4 is never a dup2 onto itself
        // (which would keep close-on-exec set in the child).
        let childWrites = highDescriptor(toApp[1])
        let childReads = highDescriptor(toWindow[0])
        for descriptor in [toApp[0], toWindow[1], childWrites, childReads] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        defer {
            close(childWrites)
            close(childReads)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, childWrites, windowWritesDescriptor)
        posix_spawn_file_actions_adddup2(&actions, childReads, windowReadsDescriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
                                                     | POSIX_SPAWN_SETSIGDEF))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)

        var childEnvironment = environment
        childEnvironment[channelEnvironmentKey] = "\(windowWritesDescriptor),\(windowReadsDescriptor)"
        let path = executable.path
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard result == 0 else {
            close(toApp[0])
            close(toWindow[1])
            throw ChildProcessSpawnerError.spawn(result)
        }
        // Never SIGPIPE: a window that is gone is a refusal, not a crash.
        _ = fcntl(toWindow[1], F_SETNOSIGPIPE, 1)
        return SpawnedWindowProcess(
            processIdentifier: pid,
            fromWindow: FileHandle(fileDescriptor: toApp[0], closeOnDealloc: true),
            toWindow: FileHandle(fileDescriptor: toWindow[1], closeOnDealloc: true)
        )
    }

    /// `descriptor`, moved to 10 or above; the original is closed.
    private static func highDescriptor(_ descriptor: Int32) -> Int32 {
        let high = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
        guard high >= 0 else { return descriptor }
        close(descriptor)
        return high
    }
}
