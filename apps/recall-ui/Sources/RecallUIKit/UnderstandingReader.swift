import Foundation

/// What the three places read about the day and about the person, and where
/// answers come from. The agent computes all of it; the window runs it.
public protocol UnderstandingReader: Sendable {
    /// The overview of one local day.
    func overview(_ day: UnderstandingDay) async throws -> DayOverview
    /// What Hippocampus understands about the person: the You page.
    func modelPage() async throws -> ModelPage
    /// An answer from memory. Never cached.
    func ask(_ question: String, app: String?, title: String?, now: String?) async throws -> AskAnswer
    /// Forget every cached read.
    func invalidate() async
    /// Stop everything this reader started (on quit).
    func shutdown() async
}

/// Errors a reader throws besides `CancellationError`. A cancelled read is
/// never reported as either of these.
public enum UnderstandingError: Error, Equatable, Sendable {
    /// Hippocampus could not be asked: no agent, it would not start, it
    /// failed, or it took too long.
    case unavailable
    /// It answered with something that is not the expected shape.
    case malformed
}

/// One local day, as the agent is asked about it: the date, and the time
/// zone's offset at noon of that day (contract overview.md section 1).
public struct UnderstandingDay: Hashable, Sendable {
    public let dateLocal: String
    public let tzOffsetSeconds: Int

    public init(dateLocal: String, tzOffsetSeconds: Int) {
        self.dateLocal = dateLocal
        self.tzOffsetSeconds = tzOffsetSeconds
    }

    public init(date: Date, calendar: Calendar = .current) {
        dateLocal = MemoryDay(date: date, calendar: calendar).dateLocal
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        tzOffsetSeconds = calendar.timeZone.secondsFromGMT(for: noon)
    }
}

/// Reads the agent's CLI through the same resolver and runner as
/// `ContextHandoffExporter`, and answers through a warm `AnswerSession`.
///
/// Reads are cached in memory only, keyed by their arguments: today's
/// overview for 120 s (the worker's cycle), another day's for 600 s, the You
/// page for 120 s. Concurrent reads of the same arguments share one child.
/// A delete (`MemoryDeletionSignal`) or `invalidate()` drops every cached
/// read at once. Verdicts given but not yet applied are laid over every read
/// (`VerdictInbox`).
public actor AgentUnderstandingReader: UnderstandingReader {
    public typealias Runner = @Sendable (ContextHandoffCommand, TimeInterval) async throws -> String

    public static let commandTimeout: TimeInterval = 20
    public static let todayLifetime: TimeInterval = 120
    public static let otherDayLifetime: TimeInterval = 600
    public static let modelPageLifetime: TimeInterval = 120

    private let environment: [String: String]
    private let recallExecutableURL: URL?
    private let isExecutable: @Sendable (URL) -> Bool
    private let run: Runner
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let deletions: MemoryDeletionSignal
    private let verdicts: VerdictInbox?
    private let answers: AnswerSession

    private struct Entry {
        let value: any Sendable
        let storedAt: Date
        let lifetime: TimeInterval
        let deletion: UInt64
    }

    private struct Flight {
        let arguments: [String]
        let deletion: UInt64
        let generation: Int
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<any Sendable, any Error>] = [:]
    }

    private var cache: [[String]: Entry] = [:]
    private var flights: [UUID: Flight] = [:]
    private var currentFlight: [[String]: UUID] = [:]
    private var generation = 0

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recallExecutableURL: URL? = Bundle.main.executableURL,
        isExecutable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        run: @escaping Runner = { try await ContextHandoffExporter.run(command: $0, timeoutSeconds: $1) },
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        deletions: MemoryDeletionSignal = .shared,
        verdicts: VerdictInbox? = .shared,
        answers: AnswerSession? = nil
    ) {
        self.environment = environment
        self.recallExecutableURL = recallExecutableURL
        self.isExecutable = isExecutable
        self.run = run
        self.now = now
        self.calendar = calendar
        self.deletions = deletions
        self.verdicts = verdicts
        self.answers = answers ?? AnswerSession { [environment, recallExecutableURL, isExecutable] in
            try Self.answerLaunch(environment: environment, recallExecutableURL: recallExecutableURL,
                                  isExecutable: isExecutable)
        }
    }

    /// How the warm answer child starts: the bundled agent, `mcp-serve
    /// --assist`, the window's own child environment. No question is here.
    public static func answerLaunch(
        environment: [String: String],
        recallExecutableURL: URL?,
        isExecutable: (URL) -> Bool
    ) throws -> MemorySessionLaunch {
        let agent = try ContextHandoffCommand.agentURL(environment: environment,
                                                       recallExecutableURL: recallExecutableURL,
                                                       isExecutable: isExecutable)
        return MemorySessionLaunch(executable: agent,
                                   arguments: ["mcp-serve", "--assist"] + databaseArguments(environment),
                                   environment: ContextHandoffExporter.childEnvironment(from: environment))
    }

    /// `overview --json --date … --tz-offset-secs …`, and the memory's path when one is set.
    static func overviewArguments(_ day: UnderstandingDay, environment: [String: String]) -> [String] {
        ["overview", "--json", "--date", day.dateLocal, "--tz-offset-secs", String(day.tzOffsetSeconds)]
            + databaseArguments(environment)
    }

    /// `model --page --json --tz-offset-secs …`, and the memory's path when one is set.
    static func modelPageArguments(tzOffsetSeconds: Int, environment: [String: String]) -> [String] {
        ["model", "--page", "--json", "--tz-offset-secs", String(tzOffsetSeconds)]
            + databaseArguments(environment)
    }

    private static func databaseArguments(_ environment: [String: String]) -> [String] {
        guard let path = environment["MCI_DB_PATH"], !path.isEmpty else { return [] }
        return ["--db-path", path]
    }

    // MARK: UnderstandingReader

    public func overview(_ day: UnderstandingDay) async throws -> DayOverview {
        let overview: DayOverview = try await read(Self.overviewArguments(day, environment: environment)) {
            $0.isToday ? Self.todayLifetime : Self.otherDayLifetime
        }
        return verdicts.map { overview.overlaying($0.pending()) } ?? overview
    }

    public func modelPage() async throws -> ModelPage {
        let offset = calendar.timeZone.secondsFromGMT(for: now())
        let page: ModelPage = try await read(Self.modelPageArguments(tzOffsetSeconds: offset, environment: environment)) { _ in
            Self.modelPageLifetime
        }
        return verdicts.map { page.overlaying($0.pending()) } ?? page
    }

    public func ask(_ question: String, app: String?, title: String?, now: String?) async throws -> AskAnswer {
        try await answers.ask(question, app: app, title: title, now: now)
    }

    public func invalidate() {
        cache.removeAll()
        currentFlight.removeAll()
        generation += 1
    }

    public func shutdown() async {
        invalidate()
        for flight in flights.values {
            flight.task?.cancel()
        }
        await answers.stop()
    }

    // MARK: Reads

    private func read<Value: Decodable & Sendable>(
        _ arguments: [String],
        lifetime: @escaping @Sendable (Value) -> TimeInterval
    ) async throws -> Value {
        try Task.checkCancellation()
        let deletion = deletions.generation
        if let entry = cache[arguments], entry.deletion == deletion,
           (0..<entry.lifetime).contains(now().timeIntervalSince(entry.storedAt)),
           let value = entry.value as? Value {
            return value
        }
        let command: ContextHandoffCommand
        do {
            command = ContextHandoffCommand(
                executableURL: try ContextHandoffCommand.agentURL(environment: environment,
                                                                  recallExecutableURL: recallExecutableURL,
                                                                  isExecutable: isExecutable),
                arguments: arguments)
        } catch {
            throw UnderstandingError.unavailable
        }
        let waiter = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any Sendable, any Error>) in
                join(arguments, waiter: waiter, continuation: continuation, deletion: deletion) { [run] id in
                    Task.detached(priority: .userInitiated) { [weak self] in
                        let outcome: Result<(value: any Sendable, lifetime: TimeInterval), any Error>
                        do {
                            let output = try await run(command, Self.commandTimeout)
                            let value: Value
                            do {
                                value = try JSONDecoder().decode(Value.self, from: Data(output.utf8))
                            } catch {
                                throw UnderstandingError.malformed
                            }
                            outcome = .success((value, lifetime(value)))
                        } catch {
                            outcome = .failure(error)
                        }
                        await self?.land(id, outcome)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.leave(waiter) }
        }
        guard let value = result as? Value else { throw UnderstandingError.malformed }
        return value
    }

    /// Wait on the read already running for `arguments`, or start one.
    private func join(
        _ arguments: [String],
        waiter: UUID,
        continuation: CheckedContinuation<any Sendable, any Error>,
        deletion: UInt64,
        start: (UUID) -> Task<Void, Never>
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let id = currentFlight[arguments], var flight = flights[id],
           flight.deletion == deletion, flight.generation == generation {
            flight.waiters[waiter] = continuation
            flights[id] = flight
            return
        }
        let id = UUID()
        var flight = Flight(arguments: arguments, deletion: deletion, generation: generation)
        flight.waiters[waiter] = continuation
        flights[id] = flight
        currentFlight[arguments] = id
        flights[id]?.task = start(id)
    }

    /// A read finished: keep it if nothing was deleted or invalidated since
    /// it started, and hand it to everyone waiting on it.
    private func land(_ id: UUID, _ outcome: Result<(value: any Sendable, lifetime: TimeInterval), any Error>) {
        guard let flight = flights.removeValue(forKey: id) else { return }
        if currentFlight[flight.arguments] == id {
            currentFlight[flight.arguments] = nil
        }
        if case let .success(read) = outcome,
           flight.deletion == deletions.generation, flight.generation == generation {
            cache[flight.arguments] = Entry(value: read.value, storedAt: now(),
                                            lifetime: read.lifetime, deletion: flight.deletion)
        }
        for continuation in flight.waiters.values {
            switch outcome {
            case let .success(read):
                continuation.resume(returning: read.value)
            case let .failure(error):
                continuation.resume(throwing: Self.understandingError(error))
            }
        }
    }

    /// A waiter was cancelled: it gets `CancellationError` now, and a read
    /// nobody waits on any more is stopped, with its child.
    private func leave(_ waiter: UUID) {
        guard let id = flights.first(where: { $0.value.waiters[waiter] != nil })?.key,
              var flight = flights[id],
              let continuation = flight.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            flights[id] = nil
            if currentFlight[flight.arguments] == id {
                currentFlight[flight.arguments] = nil
            }
        } else {
            flights[id] = flight
        }
    }

    private static func understandingError(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? UnderstandingError { return error }
        return UnderstandingError.unavailable
    }
}
