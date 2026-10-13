import Foundation

/// Answers from memory in the window (RULINGS W2): one warm
/// `mci-agent mcp-serve --assist` child calling `mci_ask`, so the embedder and
/// the on-device model stay loaded between questions. The question travels on
/// the child's standard input, never on a command line. The child stops a
/// minute after its last answer, and with the window.
public actor AnswerSession {
    /// The model's ready line can take 20 s and its answer 60 s
    /// (`understanding/mind.rs`, `query.rs`), on top of loading the embedder
    /// and searching (critique-recall-engineering finding 2).
    public static let answerTimeout: Duration = .seconds(100)
    /// The warm child stops this long after it was last used.
    public static let idleStop: Duration = .seconds(60)

    private let session: MemorySession
    private let launch: @Sendable () throws -> MemorySessionLaunch
    private let timeout: Duration
    private let idleAfter: Duration
    private var idleStopTask: Task<Void, Never>?
    private var asking = 0

    public init(
        session: MemorySession = MemorySession(),
        timeout: Duration = AnswerSession.answerTimeout,
        idleAfter: Duration = AnswerSession.idleStop,
        launch: @escaping @Sendable () throws -> MemorySessionLaunch
    ) {
        self.session = session
        self.timeout = timeout
        self.idleAfter = idleAfter
        self.launch = launch
    }

    /// Ask `question`, with the window the person came from when known.
    /// Cancelling the calling task stops the request. Throws
    /// `UnderstandingError` or `CancellationError`, never anything else.
    public func ask(_ question: String, app: String? = nil, title: String? = nil, now: String? = nil) async throws -> AskAnswer {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UnderstandingError.malformed }
        var arguments: [String: Any] = ["question": trimmed]
        for (key, value) in [("app", app), ("title", title), ("now", now)] {
            if let value, !value.isEmpty { arguments[key] = value }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: arguments) else {
            throw UnderstandingError.malformed
        }
        let launch: MemorySessionLaunch
        do {
            launch = try self.launch()
        } catch {
            throw UnderstandingError.unavailable
        }
        idleStopTask?.cancel()
        idleStopTask = nil
        asking += 1
        defer {
            asking -= 1
            if asking == 0 { scheduleIdleStop() }
        }
        do {
            let data: Data
            do {
                data = try await session.call("mci_ask", arguments: body, launch: launch, timeout: timeout)
            } catch MemorySessionError.exited where !Task.isCancelled {
                // A question cancelled just before this one stopped the child
                // this one was sent to: ask once more, on a fresh child.
                data = try await session.call("mci_ask", arguments: body, launch: launch, timeout: timeout)
            }
            do {
                return try JSONDecoder().decode(AskAnswer.self, from: data)
            } catch {
                throw UnderstandingError.malformed
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? UnderstandingError { throw error }
            if case MemorySessionError.malformedReply = error { throw UnderstandingError.malformed }
            throw UnderstandingError.unavailable
        }
    }

    /// Stop the warm child now (on quit, or when answers are not wanted).
    public func stop() async {
        idleStopTask?.cancel()
        idleStopTask = nil
        await session.stop()
    }

    /// Whether the warm child is running.
    public var isRunning: Bool {
        get async { await session.isRunning }
    }

    private func scheduleIdleStop() {
        idleStopTask?.cancel()
        let after = idleAfter
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(for: after)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() async {
        guard asking == 0 else { return }
        idleStopTask = nil
        await session.stop()
    }
}
