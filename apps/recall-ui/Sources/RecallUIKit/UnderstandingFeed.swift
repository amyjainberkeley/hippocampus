import Combine
import Foundation

/// What one place shows from an `UnderstandingReader`, and how it stays true.
///
/// - A new key (another day) starts empty and loads.
/// - The same key keeps the last good read on screen while a newer one is
///   read, and keeps it when that read fails (critique-recall-engineering
///   finding 9).
/// - A cancelled read changes nothing: it is never shown as unavailable.
/// - A delete (`MemoryDeletionSignal`) clears what is shown at once, because
///   it may have been made from the deleted moments, and reads it again.
@MainActor
public final class UnderstandingFeed<Key: Hashable & Sendable, Value: Sendable>: ObservableObject {
    public enum Phase: Equatable, Sendable {
        /// Nothing asked for yet.
        case idle
        /// Reading, with nothing to show yet.
        case loading
        /// `value` is the last good read.
        case ready
        /// The read failed and there is nothing to show.
        case unavailable
    }

    @Published public private(set) var key: Key?
    @Published public private(set) var value: Value?
    @Published public private(set) var phase: Phase = .idle
    /// A newer read is running while `value` stays on screen.
    @Published public private(set) var isRefreshing = false

    private let fetch: @Sendable (Key) async throws -> Value
    private var generation = 0
    private var deletionObserver: AnyCancellable?

    public init(
        deletions: MemoryDeletionSignal = .shared,
        fetch: @escaping @Sendable (Key) async throws -> Value
    ) {
        self.fetch = fetch
        deletionObserver = deletions.center
            .publisher(for: MemoryDeletionSignal.notification, object: deletions)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.memoryWasDeleted() }
            }
    }

    /// Show `key`, reading it.
    public func load(_ key: Key) async {
        if key != self.key {
            self.key = key
            value = nil
            phase = .loading
        } else if value == nil {
            phase = .loading
        }
        isRefreshing = value != nil
        generation += 1
        let request = generation
        do {
            let fresh = try await fetch(key)
            guard request == generation else { return }
            value = fresh
            phase = .ready
            isRefreshing = false
        } catch {
            guard request == generation else { return }
            isRefreshing = false
            if error is CancellationError || Task.isCancelled { return }
            if value == nil { phase = .unavailable }
        }
    }

    /// Read the key on screen again, keeping it on screen meanwhile.
    public func refresh() async {
        guard let key else { return }
        await load(key)
    }

    private func memoryWasDeleted() {
        generation += 1
        value = nil
        isRefreshing = false
        guard let key else {
            phase = .idle
            return
        }
        phase = .loading
        Task { [weak self] in await self?.load(key) }
    }
}
