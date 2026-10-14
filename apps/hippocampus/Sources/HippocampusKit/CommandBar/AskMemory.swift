// SPDX-License-Identifier: Apache-2.0
//
// AskMemory.swift — how Ask reaches memory: two warm `mci-agent mcp-serve`
// children. `reads` searches and checks the window in front; `assistant`
// (`--assist`) answers and suggests, one request at a time. Both stop after
// ten minutes without a call (RULINGS S9).

import Foundation

public enum AskSession: Sendable, Equatable {
    case reads
    case assistant
}

/// Calls a memory tool and returns its result's JSON. A protocol so the
/// panel's behaviour is tested without a child process.
@MainActor
public protocol AskMemory: AnyObject {
    func call(_ session: AskSession, _ tool: String, arguments: Data, timeout: Duration) async throws -> Data
    func stop() async
}

@MainActor
public final class WarmMemorySessions: AskMemory {
    public static let idleStop: Duration = .seconds(600)

    let reads = MemorySession()
    let assistant = MemorySession()
    private let launch: @MainActor (_ assist: Bool) -> MemorySessionLaunch?
    private let idleAfter: Duration
    private var calls = 0
    private var running = 0
    private var idleTask: Task<Void, Never>?

    public init(
        launch: @escaping @MainActor (_ assist: Bool) -> MemorySessionLaunch?,
        idleAfter: Duration = WarmMemorySessions.idleStop
    ) {
        self.launch = launch
        self.idleAfter = idleAfter
    }

    public func call(_ session: AskSession, _ tool: String, arguments: Data, timeout: Duration) async throws -> Data {
        guard let launch = launch(session == .assistant) else { throw MemorySessionError.unavailable }
        calls += 1
        running += 1
        idleTask?.cancel()
        defer {
            running -= 1
            stopWhenIdle()
        }
        let target = session == .reads ? reads : assistant
        return try await target.call(tool, arguments: arguments, launch: launch, timeout: timeout)
    }

    /// Stop both children together and wait until they have exited (on
    /// quit): about one second at most, even mid-answer (spec-shell S6.2).
    public func stop() async {
        idleTask?.cancel()
        let reads = reads
        let assistant = assistant
        async let readsStopped: Void = reads.stopAndWait()
        async let assistantStopped: Void = assistant.stopAndWait()
        _ = await (readsStopped, assistantStopped)
    }

    private func stopWhenIdle() {
        guard running == 0 else { return }
        let mark = calls
        let delay = idleAfter
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.running == 0, self.calls == mark else { return }
            await self.reads.stop()
            await self.assistant.stop()
        }
    }
}
