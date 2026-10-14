// SPDX-License-Identifier: Apache-2.0
//
// CaptureOrphanSweep.swift — ends capture processes that no running
// Hippocampus owns (spec-shell S6.4, critique-shell-engineering 1 and 2).
//
// A capture helper left behind by a crash, a Force Quit or `kill -9` of the
// app can keep its screen streams open, and so the recording indicator lit.
// Nothing else looks for one. The sweep runs at launch, after Pause, after
// Stop Sharing and at Quit.
//
// Rules:
// - Only this user's processes, and only from inside a `.app` bundle: a
//   development build's helper may be run by hand.
// - Real paths on both sides. The helper matches its exact path; an OCR
//   worker matches anything under `Contents/Resources/HippocampusOCR/`.
// - `mci-agent` is never touched, except an orphaned writer
//   (`--drain-stdin` with parent 1), which holds the memory's writer lock
//   while it drains: wait for it to exit, then SIGTERM. Never SIGKILL a
//   writer, and never touch `mcp-serve`: AI tools run it.
// - Quit ends every match, including a child of ours that survived the
//   stop. The other sweeps leave our live children, and the processes they
//   started, alone.
// - Off the main thread, and the process is checked again just before each
//   signal in case its pid was reused.

import Darwin
import Foundation
import os

/// What the supervisor uses, so its tests can watch the sweep without
/// signalling real processes.
public protocol CaptureOrphanSweeping: Sendable {
    func run(
        _ moment: CaptureOrphanSweep.Moment,
        liveChildren: (@Sendable () async -> Set<pid_t>)?
    ) async -> CaptureOrphanSweep.Outcome
}

public struct CaptureOrphanSweep: CaptureOrphanSweeping {
    public enum Moment: String, Sendable {
        case launch
        case paused
        case stopped
        case quit
    }

    public struct Outcome: Sendable, Equatable {
        /// Processes the sweep signalled.
        public var ended = 0
        /// Of those, the ones still alive when it gave up.
        public var remaining = 0
    }

    /// The real paths the sweep looks for, inside one `.app` bundle.
    package struct Targets: Sendable, Equatable {
        package let helper: String
        /// Ends in "/", so a sibling folder with a longer name never matches.
        package let ocrDirectory: String
        package let agent: String

        /// Nil outside a `.app` bundle.
        package init?(bundleURL: URL) {
            guard bundleURL.pathExtension == "app",
                  let bundle = CaptureOrphanSweep.realPath(bundleURL.path)
            else { return nil }
            helper = bundle + "/Contents/MacOS/MCICaptureHelper"
            ocrDirectory = bundle + "/Contents/Resources/HippocampusOCR/"
            agent = bundle + "/Contents/MacOS/mci-agent"
        }
    }

    /// One process as the sweep sees it.
    package struct RunningProcess: Sendable, Equatable {
        package let pid: pid_t
        package let parent: pid_t
        package let uid: uid_t
        /// The executable's real path.
        package let path: String
        /// Read only for `mci-agent`; empty otherwise.
        package let arguments: [String]

        package init(pid: pid_t, parent: pid_t, uid: uid_t, path: String, arguments: [String] = []) {
            self.pid = pid
            self.parent = parent
            self.uid = uid
            self.path = path
            self.arguments = arguments
        }
    }

    package enum Kind: Sendable, Equatable {
        /// A capture helper or OCR worker: SIGTERM, then SIGKILL.
        case capture
        /// An orphaned writer agent: wait, then SIGTERM only.
        case writer
    }

    package struct Match: Sendable, Equatable {
        package let pid: pid_t
        package let kind: Kind
    }

    private let targets: Targets
    private let writerGrace: Duration
    private let logger = Logger(subsystem: "ai.hippocampus", category: "sweep")

    /// Nil when Hippocampus is not running from a `.app` bundle.
    public init?(bundleURL: URL, writerGrace: Duration = .seconds(10)) {
        guard let targets = Targets(bundleURL: bundleURL) else { return nil }
        self.targets = targets
        self.writerGrace = writerGrace
    }

    // MARK: Which processes

    /// The processes the sweep ends. Never this process, never another
    /// user's, never an `mci-agent` but an orphaned writer. With
    /// `liveChildren` (every sweep but Quit's), never one of them or a
    /// process one of them started.
    package static func matches(
        in processes: [RunningProcess],
        targets: Targets,
        uid: uid_t = getuid(),
        selfPID: pid_t = getpid(),
        liveChildren: Set<pid_t>?
    ) -> [Match] {
        processes.compactMap { process in
            guard process.pid > 1, process.pid != selfPID, process.uid == uid else { return nil }
            if let liveChildren,
               liveChildren.contains(process.pid) || liveChildren.contains(process.parent) {
                return nil
            }
            if process.path == targets.helper || process.path.hasPrefix(targets.ocrDirectory) {
                return Match(pid: process.pid, kind: .capture)
            }
            if process.path == targets.agent, process.parent == 1,
               process.arguments.contains("--drain-stdin"),
               !process.arguments.contains("mcp-serve") {
                return Match(pid: process.pid, kind: .writer)
            }
            return nil
        }
    }

    // MARK: Ending them

    public func run(
        _ moment: Moment,
        liveChildren: (@Sendable () async -> Set<pid_t>)?
    ) async -> Outcome {
        let found = await currentMatches(liveChildren: liveChildren)
        guard !found.isEmpty else { return Outcome() }
        var outcome = Outcome()

        // Capture first, so an orphaned writer's input closes and it can
        // finish draining.
        let capture = found.filter { $0.kind == .capture }.map(\.pid)
        var signalled = await send(capture, SIGTERM, kind: .capture, liveChildren: liveChildren)
        outcome.ended += signalled.count
        await waitForExit(signalled, upTo: .milliseconds(500))
        let stubborn = await send(signalled.filter(Self.isAlive), SIGKILL, kind: .capture, liveChildren: liveChildren)
        await waitForExit(stubborn, upTo: .milliseconds(500))
        outcome.remaining += signalled.filter(Self.isAlive).count

        let writers = found.filter { $0.kind == .writer }.map(\.pid)
        if !writers.isEmpty {
            await waitForExit(writers, upTo: moment == .quit ? .seconds(1) : writerGrace)
            signalled = await send(writers.filter(Self.isAlive), SIGTERM, kind: .writer, liveChildren: liveChildren)
            outcome.ended += signalled.count
            await waitForExit(signalled, upTo: .seconds(5))
            outcome.remaining += signalled.filter(Self.isAlive).count
        }

        logger.info("sweep: \(moment.rawValue, privacy: .public) ended \(outcome.ended), \(outcome.remaining) still running")
        return outcome
    }

    private func currentMatches(liveChildren: (@Sendable () async -> Set<pid_t>)?) async -> [Match] {
        let children = await liveChildren?()
        return Self.matches(
            in: Self.listProcesses(agentPath: targets.agent), targets: targets, liveChildren: children
        )
    }

    /// Sends `signal` to each pid that is still the same kind of match, read
    /// again now. Returns the pids it signalled.
    private func send(
        _ pids: [pid_t], _ signal: Int32, kind: Kind,
        liveChildren: (@Sendable () async -> Set<pid_t>)?
    ) async -> [pid_t] {
        guard !pids.isEmpty else { return [] }
        let children = await liveChildren?()
        var signalled: [pid_t] = []
        for pid in pids {
            guard let now = Self.read(pid, agentPath: targets.agent),
                  Self.matches(in: [now], targets: targets, liveChildren: children)
                    == [Match(pid: pid, kind: kind)]
            else { continue }
            if kill(pid, signal) == 0 { signalled.append(pid) }
        }
        return signalled
    }

    private func waitForExit(_ pids: [pid_t], upTo limit: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while pids.contains(where: Self.isAlive), clock.now < deadline {
            if (try? await Task.sleep(for: .milliseconds(50))) == nil { return }
        }
    }

    // MARK: The process table

    /// This user's processes, with real paths, and arguments for the agent.
    static func listProcesses(agentPath: String) -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        let uid = getuid()
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 1, let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            return read(pid, info: info, agentPath: agentPath)
        }
    }

    static func read(_ pid: pid_t, agentPath: String) -> RunningProcess? {
        guard let info = bsdInfo(pid) else { return nil }
        return read(pid, info: info, agentPath: agentPath)
    }

    private static func read(_ pid: pid_t, info: proc_bsdinfo, agentPath: String) -> RunningProcess? {
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let raw = String(cString: buffer)
        let path = realPath(raw) ?? raw
        return RunningProcess(
            pid: pid, parent: pid_t(info.pbi_ppid), uid: info.pbi_uid, path: path,
            arguments: path == agentPath ? arguments(of: pid) : []
        )
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Gone, or a zombie waiting to be reaped.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard let info = bsdInfo(pid) else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    /// The process's arguments after its executable path (KERN_PROCARGS2).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // the executable path
        while index < size, buffer[index] == 0 { index += 1 }  // its padding
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return Array(arguments.dropFirst())  // argv[0]
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
