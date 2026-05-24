// ViewModels.swift — @MainActor observable view models the SwiftUI
// scenes bind to. Kept in the testable library target so unit tests
// can exercise state transitions without spinning a SwiftUI scene.

import Foundation

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public var query: String = ""
    @Published public private(set) var hits: [Hit] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public var selectedHitId: UInt64?
    @Published public var isDetailFocused: Bool = false
    @Published public var filters: FilterState = FilterState()
    /// Top-N observed apps in the current window. The filter pills row
    /// reads this to render dynamic per-app pills + the overflow menu.
    @Published public private(set) var observedApps: [ObservedApp] = []

    private let reader: BrainReader

    public init(reader: BrainReader) {
        self.reader = reader
    }

    /// Refresh the per-app pill source. Cheap aggregate query — call on
    /// first appearance of the search tab and whenever the date-range
    /// changes (so the pills reflect the same window the search uses).
    public func reloadObservedApps() async {
        let from = filters.timeWindowUs().fromUs
        do {
            observedApps = try await reader.listObservedApps(limit: 50, timeFromUs: from)
        } catch {
            observedApps = []
        }
    }

    public var selectedHit: Hit? {
        guard let id = selectedHitId else { return nil }
        return hits.first { $0.id == id }
    }

    public func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || filters.anyActive else {
            hits = []
            errorMessage = nil
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let window = filters.timeWindowUs()
            let results: [Hit]
            if q.isEmpty {
                // Filter-only path. FTS5 rejects empty / `*` queries
                // (core/brain `fts5_search_empty_query_rejected`), so we
                // pull a recent-events pool and apply window + app + URL
                // filters client-side. Pool of 500 is plenty for the
                // dogfood window (Last 7 days at active capture rates).
                results = try await applyClientFilters(
                    to: reader.recentEvents(limit: 500),
                    window: window
                )
            } else {
                let opts = SearchOptions(
                    text: q,
                    limit: 50,
                    appFilter: filters.appFilter,
                    timeFromUs: window.fromUs,
                    timeToUs: window.toUs
                )
                results = try await applyClientFilters(
                    to: reader.search(opts),
                    window: window
                )
            }
            hits = results
        } catch {
            hits = []
            errorMessage = "\(error)"
        }
    }

    /// Apply window + app + URL filters that the FFI does not enforce
    /// on its own. Centralized so the filter-only path and the
    /// text+filter path stay in sync.
    private func applyClientFilters(
        to results: [Hit],
        window: (fromUs: UInt64?, toUs: UInt64?)
    ) -> [Hit] {
        var out = results
        if let from = window.fromUs {
            out = out.filter { $0.tsUs >= from }
        }
        if let to = window.toUs {
            out = out.filter { $0.tsUs <= to }
        }
        if filters.requiresClientSideAppFilter || filters.appFilter != nil {
            out = out.filter { filters.matchesApp($0.appBundleId) }
        }
        if filters.hasUrl {
            out = out.filter { $0.url != nil && !$0.url!.isEmpty }
        }
        return Array(out.prefix(50))
    }

    public func clear() {
        query = ""
        hits = []
        errorMessage = nil
        filters = FilterState()
    }

    public func moveSelectionUp() {
        guard !hits.isEmpty else { return }
        guard let current = selectedHitId,
              let idx = hits.firstIndex(where: { $0.id == current }), idx > 0
        else {
            selectedHitId = hits.first?.id
            return
        }
        selectedHitId = hits[idx - 1].id
    }

    public func moveSelectionDown() {
        guard !hits.isEmpty else { return }
        guard let current = selectedHitId,
              let idx = hits.firstIndex(where: { $0.id == current }), idx < hits.count - 1
        else {
            selectedHitId = hits.first?.id
            return
        }
        selectedHitId = hits[idx + 1].id
    }

    public func focusDetail() {
        if selectedHitId != nil { isDetailFocused = true }
    }

    public func dismissDetail() {
        isDetailFocused = false
    }
}

@MainActor
public final class TimelineViewModel: ObservableObject {
    @Published public private(set) var hits: [Hit] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public var selectedHitId: UInt64?
    @Published public var isDetailFocused: Bool = false

    private let reader: BrainReader
    private let pageSize: Int

    public init(reader: BrainReader, pageSize: Int = 100) {
        self.reader = reader
        self.pageSize = pageSize
    }

    public var selectedHit: Hit? {
        guard let id = selectedHitId else { return nil }
        return hits.first { $0.id == id }
    }

    public func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            hits = try await reader.recentEvents(limit: pageSize)
        } catch {
            hits = []
            errorMessage = "\(error)"
        }
    }

    public func moveSelectionUp() {
        guard !hits.isEmpty else { return }
        guard let current = selectedHitId,
              let idx = hits.firstIndex(where: { $0.id == current }), idx > 0
        else {
            selectedHitId = hits.first?.id
            return
        }
        selectedHitId = hits[idx - 1].id
    }

    public func moveSelectionDown() {
        guard !hits.isEmpty else { return }
        guard let current = selectedHitId,
              let idx = hits.firstIndex(where: { $0.id == current }), idx < hits.count - 1
        else {
            selectedHitId = hits.first?.id
            return
        }
        selectedHitId = hits[idx + 1].id
    }

    public func focusDetail() {
        if selectedHitId != nil { isDetailFocused = true }
    }

    public func dismissDetail() {
        isDetailFocused = false
    }
}

@MainActor
public final class EpisodesViewModel: ObservableObject {
    @Published public private(set) var episodes: [Episode] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public var selectedEpisodeId: UInt64?

    private let reader: BrainReader
    private let pageSize: Int

    public init(reader: BrainReader, pageSize: Int = 200) {
        self.reader = reader
        self.pageSize = pageSize
    }

    public var selectedEpisode: Episode? {
        guard let id = selectedEpisodeId else { return nil }
        return episodes.first { $0.id == id }
    }

    public func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            episodes = try await reader.listEpisodes(limit: pageSize)
        } catch {
            episodes = []
            errorMessage = "\(error)"
        }
    }
}

@MainActor
public final class PrivacyMomentsViewModel: ObservableObject {
    @Published public private(set) var moments: [PrivacyMoment] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?

    private let reader: BrainReader
    private let pageSize: Int

    public init(reader: BrainReader, pageSize: Int = 100) {
        self.reader = reader
        self.pageSize = pageSize
    }

    public func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            moments = try await reader.recentPrivacyMoments(limit: pageSize)
        } catch {
            moments = []
            errorMessage = "\(error)"
        }
    }
}
