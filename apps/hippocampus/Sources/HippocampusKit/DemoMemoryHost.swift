// SPDX-License-Identifier: Apache-2.0
//
// DemoMemoryHost.swift — what Demo Memory asks of the app (SPEC-DELTA 6), and
// the app's answer through the supervisor's own controls.

import AppKit
import Combine
import Foundation

/// What Demo Memory asks of the app: to pause and resume remembering, to
/// say whether anything reads the screen or is about to, and to start Ask's
/// memory sessions and the window again on the memory in use now.
@MainActor
public protocol DemoMemoryHost: AnyObject {
    /// A pause is kept: the person's, or the one Demo Memory made.
    var isPaused: Bool { get }
    /// When the pause kept now ends on its own (For 1 Hour, Until
    /// Tomorrow); nil for one that waits for the person, or none.
    var pausedUntil: Date? { get }
    /// Nothing reads the screen or is about to: no capture helper or agent
    /// runs or is starting, no turn-on is under way, and no stop failed.
    var isQuiet: Bool { get }
    /// Connect AI Tools… is writing the AI tools' settings now. They always
    /// name the person's own memory, never Demo Memory.
    var isConnectingAITools: Bool { get }
    /// Pause remembering until Leave Demo Memory, even over a pause of the
    /// person's that would end on its own, and return once nothing reads
    /// the screen. Throws when it couldn't.
    func pauseRemembering() async throws
    /// Put back the person's own timed pause, ending at `end`.
    func pauseRemembering(until end: Date)
    /// Take back the pause Demo Memory made.
    func resumeRemembering()
    /// End Ask's memory sessions and the window, then open the window on
    /// Today again, if one was open or `openWindow`: each starts again on the
    /// memory in use now.
    func restartReaders(openWindow: Bool) async
    /// Calls `change` after anything about remembering changes.
    func watchRemembering(_ change: @escaping @MainActor () -> Void) -> AnyCancellable
    /// Asks the person before Demo Memory starts.
    func confirmUse() async -> Bool
    /// Tells the person why Demo Memory didn't start.
    func report(_ message: String)
}

public extension DemoMemoryHost {
    /// A host whose pauses never end on their own: there is no timed pause
    /// to set aside, so none is ever put back.
    var pausedUntil: Date? { nil }
    func pauseRemembering(until end: Date) {}
}

public enum DemoMemoryHostError: Error, Equatable {
    case couldNotPause
}

/// The app's answer, through the supervisor's own controls: a kept pause,
/// which owns no processes, and the window opened the way every other way
/// of opening it does. Ask's memory sessions and the window are this app's
/// own children; Demo Memory ends them so each starts again on the memory
/// in use. The capture helper and the agent that remembers are never ended
/// here: the pause stops them, as Pause in the menu does.
@MainActor
public final class SupervisorDemoMemoryHost: DemoMemoryHost {
    private let supervisor: ProcessSupervisor
    private let locator: BundleBinaryLocator
    private let connectingAITools: @MainActor () -> Bool
    private let pauseWait: Duration

    public init(
        supervisor: ProcessSupervisor,
        locator: BundleBinaryLocator = BundleBinaryLocator(),
        isConnectingAITools: @escaping @MainActor () -> Bool = { false },
        pauseWait: Duration = .seconds(15)
    ) {
        self.supervisor = supervisor
        self.locator = locator
        self.connectingAITools = isConnectingAITools
        self.pauseWait = pauseWait
    }

    public var isPaused: Bool { supervisor.pausedSince != nil }

    public var pausedUntil: Date? { supervisor.pausedUntil }

    public var isQuiet: Bool {
        guard !supervisor.turningOn, !supervisor.stopFailed else { return false }
        switch supervisor.state {
        case .paused, .idle, .stopped: return true
        case .starting, .running, .crashed: return false
        }
    }

    public var isConnectingAITools: Bool { connectingAITools() }

    public func pauseRemembering() async throws {
        // Until the person resumes, which Leave Demo Memory stands in for: a
        // timed pause's end would turn remembering on mid-take, and reopen
        // the window on the person's own memory. Leave puts it back.
        supervisor.pause(until: nil)
        let deadline = ContinuousClock.now.advanced(by: pauseWait)
        while !isQuiet {
            guard !supervisor.stopFailed, ContinuousClock.now < deadline else {
                throw DemoMemoryHostError.couldNotPause
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    public func pauseRemembering(until end: Date) {
        supervisor.pause(until: end)
    }

    public func resumeRemembering() {
        supervisor.setPaused(false)
    }

    public func restartReaders(openWindow: Bool) async {
        let me = getpid()
        let agent = locator.agentPath().map { CaptureOrphanSweep.realPath($0.path) ?? $0.path }
        let window = locator.recallUIPath().map { CaptureOrphanSweep.realPath($0.path) ?? $0.path }
        let children = CaptureOrphanSweep.listProcesses(agentPath: agent ?? "").filter { $0.parent == me }
        // Ask's sessions (`mci-agent mcp-serve`): Ask starts new ones with
        // its next question. The agent that remembers is never one of them.
        for child in children where child.path == agent && child.arguments.first == "mcp-serve" {
            kill(child.pid, SIGTERM)
        }
        let windows = children.filter { $0.path == window }.map(\.pid)
        for pid in windows where NSRunningApplication(processIdentifier: pid)?.terminate() != true {
            kill(pid, SIGTERM)
        }
        await Self.waitForExit(windows, upTo: .seconds(3))
        for pid in windows where CaptureOrphanSweep.isAlive(pid) {
            kill(pid, SIGTERM)
        }
        await Self.waitForExit(windows, upTo: .seconds(1))
        if openWindow || !windows.isEmpty {
            supervisor.openRecallUI(initialTab: ProcessSupervisor.windowTab)
        }
    }

    public func watchRemembering(_ change: @escaping @MainActor () -> Void) -> AnyCancellable {
        supervisor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { change() } }
    }

    public func confirmUse() async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = DemoCopy.confirmTitle
        alert.informativeText = DemoCopy.confirmMessage
        alert.addButton(withTitle: DemoCopy.confirmButton)
        alert.addButton(withTitle: DemoCopy.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func report(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = DemoCopy.couldntUseTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func waitForExit(_ pids: [pid_t], upTo limit: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while pids.contains(where: CaptureOrphanSweep.isAlive), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
