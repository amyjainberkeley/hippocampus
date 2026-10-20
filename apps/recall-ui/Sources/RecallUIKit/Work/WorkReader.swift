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
}
