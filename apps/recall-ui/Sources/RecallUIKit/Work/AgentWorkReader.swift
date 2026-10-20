import Foundation

/// The searches Looked Up lists (`mci-agent searches --json`): read from page
/// addresses, newest first.
public struct SearchRecord: Decodable, Equatable, Sendable, Identifiable {
    /// The query as typed.
    public let query: String
    /// The engine's short name: `google`, `youtube`, `github`, …
    public let engine: String
    public let tsUs: UInt64
    /// The browser's name ("Chrome"), as the agent names it.
    public let app: String?
    /// The results page's address.
    public let url: String?
    /// The results page's moment.
    public let eventId: UInt64

    public var id: UInt64 { eventId }

    public init(query: String, engine: String, tsUs: UInt64, app: String?, url: String?, eventId: UInt64) {
        self.query = query
        self.engine = engine
        self.tsUs = tsUs
        self.app = app
        self.url = url
        self.eventId = eventId
    }

    private enum CodingKeys: String, CodingKey {
        case query, engine, app, url
        case tsUs = "ts_us"
        case eventId = "event_id"
    }
}

/// Reads the searches Looked Up lists: the agent in the app, fixtures in
/// previews, renders and tests.
public protocol SearchesReading: Sendable {
    /// Searches in the last `hours`, newest first, at most `limit`.
    func searches(hours: Int, limit: Int) async throws -> [SearchRecord]
}

/// Searches from fixtures; none by default, as on a Mac whose browsers
/// haven't told Hippocampus an address yet.
public struct PreviewSearchesReader: SearchesReading {
    public let records: [SearchRecord]

    public init(records: [SearchRecord] = []) {
        self.records = records
    }

    public func searches(hours: Int, limit: Int) async throws -> [SearchRecord] {
        Array(records.sorted { $0.tsUs > $1.tsUs }.prefix(max(0, limit)))
    }
}

/// The window's own reads from the bundled agent (SPEC 3.12.2, 3.6,
/// SPEC-DELTA 3): `work`, `searches` and `resume-plan`, through the same
/// resolver and runner as every other read of the window's.
///
/// Reads are kept in memory only, for two minutes (the worker's cycle) and
/// never across a delete (`MemoryDeletionSignal`); the same read asked for
/// twice at once runs one child. A Resume plan is read fresh each time the
/// sheet opens. Nothing here writes anything or sends anything anywhere.
public actor AgentWorkReader: WorkReader, SearchesReading, ResumePlanning {
    public typealias Runner = @Sendable (ContextHandoffCommand, TimeInterval) async throws -> String

    /// The reader the app's window uses.
    public static let shared = AgentWorkReader()
    public static let lifetime: TimeInterval = 120
    public static let commandTimeout: TimeInterval = 20

    private let environment: [String: String]
    private let recallExecutableURL: URL?
    private let isExecutable: @Sendable (URL) -> Bool
    private let run: Runner
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let deletions: MemoryDeletionSignal

    private struct Entry {
        let data: Data
        let storedAt: Date
        let deletion: UInt64
    }

    private var cache: [[String]: Entry] = [:]
    private var flights: [[String]: Task<Data, Error>] = [:]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recallExecutableURL: URL? = Bundle.main.executableURL,
        isExecutable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        run: @escaping Runner = { try await ContextHandoffExporter.run(command: $0, timeoutSeconds: $1) },
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .autoupdatingCurrent,
        deletions: MemoryDeletionSignal = .shared
    ) {
        self.environment = environment
        self.recallExecutableURL = recallExecutableURL
        self.isExecutable = isExecutable
        self.run = run
        self.now = now
        self.timeZone = timeZone
        self.deletions = deletions
    }

    // MARK: Arguments

    /// The arguments every read ends with: JSON, this Mac's time zone, and
    /// the memory's path when one is set.
    func shared(_ arguments: [String]) -> [String] {
        var all = arguments + ["--json", "--tz-offset-secs", String(timeZone.secondsFromGMT(for: now()))]
        if let path = environment["MCI_DB_PATH"], !path.isEmpty {
            all += ["--db-path", path]
        }
        return all
    }

    static func workArguments(days: Int) -> [String] {
        ["work", "--days", String(max(1, days))]
    }

    static func itemArguments(id: String, before: UInt64?) -> [String] {
        ["work", "--item", id] + (before.map { ["--before", String($0)] } ?? [])
    }

    static func momentArguments(_ moments: [UInt64]) -> [String] {
        ["work", "--moments", moments.sorted().map(String.init).joined(separator: ",")]
    }

    static func searchesArguments(hours: Int, limit: Int) -> [String] {
        ["searches", "--hours", String(min(max(1, hours), 744)), "--limit", String(min(max(1, limit), 500))]
    }

    // MARK: WorkReader

    public func work(days: Int) async throws -> WorkSnapshot {
        try decode(WorkSnapshot.self, from: try await read(Self.workArguments(days: days), cached: true))
    }

    public func item(id: String, before: UInt64?) async throws -> WorkItem? {
        guard RecallLaunchRequest.isWorkItemId(id) else { return nil }
        let snapshot = try decode(WorkSnapshot.self,
                                  from: try await read(Self.itemArguments(id: id, before: before), cached: true))
        return snapshot.items.first { $0.id == id }
    }

    public func items(forMoments moments: [UInt64]) async throws -> [UInt64: String] {
        guard !moments.isEmpty else { return [:] }
        let snapshot = try decode(WorkSnapshot.self,
                                  from: try await read(Self.momentArguments(moments), cached: true))
        return snapshot.momentItems
    }

    // MARK: SearchesReading

    public func searches(hours: Int, limit: Int) async throws -> [SearchRecord] {
        struct Answer: Decodable {
            let searches: [SearchRecord]
        }
        return try decode(Answer.self,
                          from: try await read(Self.searchesArguments(hours: hours, limit: limit), cached: true))
            .searches
    }

    // MARK: ResumePlanning

    public func plan(item: String) async throws -> ResumePlan {
        guard RecallLaunchRequest.isWorkItemId(item) else { return .empty }
        return try decode(ResumePlan.self, from: try await read(["resume-plan", "--item", item], cached: false))
    }

    /// Forget every read kept.
    public func invalidate() {
        cache.removeAll()
    }

    // MARK: Reading

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UnderstandingError.malformed
        }
    }

    private func read(_ arguments: [String], cached: Bool) async throws -> Data {
        try Task.checkCancellation()
        let full = shared(arguments)
        let deletion = deletions.generation
        if cached, let entry = cache[full], entry.deletion == deletion,
           (0..<Self.lifetime).contains(now().timeIntervalSince(entry.storedAt)) {
            return entry.data
        }
        if let flight = flights[full] {
            return try await flight.value
        }
        let command: ContextHandoffCommand
        do {
            command = ContextHandoffCommand(
                executableURL: try ContextHandoffCommand.agentURL(environment: environment,
                                                                  recallExecutableURL: recallExecutableURL,
                                                                  isExecutable: isExecutable),
                arguments: full)
        } catch {
            throw UnderstandingError.unavailable
        }
        let run = run
        let flight = Task<Data, Error> {
            do {
                return Data(try await run(command, Self.commandTimeout).utf8)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UnderstandingError.unavailable
            }
        }
        flights[full] = flight
        defer { flights[full] = nil }
        let data = try await flight.value
        // A delete while it ran: the answer may name what was forgotten.
        if cached, deletions.generation == deletion {
            cache[full] = Entry(data: data, storedAt: now(), deletion: deletion)
        }
        return data
    }
}
