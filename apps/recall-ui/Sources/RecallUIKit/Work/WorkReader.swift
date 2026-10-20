import Foundation

/// Reads what the person is working on: the agent's `work` read in the app
/// (SPEC 3.12.2), fixtures in previews, renders and tests. Today, the shell,
/// Working On, Web Pages and History's "Part of" all read through one.
public protocol WorkReader: Sendable {
    /// Working On's items and Web Pages' pages over the last `days` days.
    func work(days: Int) async throws -> WorkSnapshot
    /// One item, with a page of its moments older than `before`
    /// (microseconds since the epoch), or nil when it has none left.
    func item(id: String, before: UInt64?) async throws -> WorkItem?
    /// The item each of `moments` is part of, by moment id.
    func items(forMoments moments: [UInt64]) async throws -> [UInt64: String]
}

/// A work read from fixtures; empty by default, as on a first day. The
/// synthetic preview and the off-screen renders use it, so they never start
/// the agent or read the person's memory.
public struct PreviewWorkReader: WorkReader {
    public let snapshot: WorkSnapshot

    public init(snapshot: WorkSnapshot = .empty) {
        self.snapshot = snapshot
    }

    public func work(days: Int) async throws -> WorkSnapshot { snapshot }

    public func item(id: String, before: UInt64?) async throws -> WorkItem? {
        snapshot.items.first { $0.id == id }
    }

    public func items(forMoments moments: [UInt64]) async throws -> [UInt64: String] {
        snapshot.momentItems.filter { moments.contains($0.key) }
    }

    /// Sam's week (`WorkFixtures`): what the synthetic preview and the
    /// renders read.
    public static func sample(now: Date, calendar: Calendar) -> PreviewWorkReader {
        PreviewWorkReader(snapshot: WorkFixtures.snapshot(now: now, calendar: calendar))
    }
}

/// A work read that fails, as the agent does when it can't answer: what
/// renders and tests use for "Couldn't load this. Nothing is lost."
public struct UnavailableWorkReader: WorkReader {
    public init() {}

    public func work(days: Int) async throws -> WorkSnapshot { throw UnderstandingError.unavailable }
    public func item(id: String, before: UInt64?) async throws -> WorkItem? { throw UnderstandingError.unavailable }
    public func items(forMoments moments: [UInt64]) async throws -> [UInt64: String] {
        throw UnderstandingError.unavailable
    }
}
