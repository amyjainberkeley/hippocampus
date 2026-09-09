// ViewModels.swift — @MainActor observable view models the SwiftUI
// scenes bind to. Kept in the testable library target so unit tests
// can exercise state transitions without spinning a SwiftUI scene.

import Combine
import Foundation

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public var query: String = "" {
        didSet { if query != oldValue { searchInputChanged() } }
    }
    @Published public var mode: SearchMode = .text {
        didSet { if mode != oldValue { searchInputChanged() } }
    }
    @Published public private(set) var hits: [Hit] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public var selectedHitId: UInt64?
    @Published public var isDetailFocused: Bool = false
    @Published public var filters: FilterState = FilterState() {
        didSet { if filters != oldValue { searchInputChanged() } }
    }
    /// Top-N observed apps in the current window. The filter pills row
    /// reads this to render dynamic per-app pills + the overflow menu.
    @Published public private(set) var observedApps: [ObservedApp] = []

    private let reader: BrainReader
    /// Persists `{ query, filters }` across quit/restore. Cycle 8.35
    /// audit follow-up. Injectable so tests can pass an in-memory store.
    private let persistence: QueryPersistence
    private var persistCancellable: AnyCancellable?
    private var pendingSearch: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var focusedEventID: UInt64?
    /// Cycle 8.42 — snapshot of the user dictionary. Reloaded before every
    /// search so edits in the Settings tab take effect on the next query
    /// without a restart. Injectable for tests.
    private let userDictionaryLoader: @Sendable () -> UserDictionary

    public init(
        reader: BrainReader,
        persistence: QueryPersistence = QueryPersistence(),
        userDictionaryLoader: @escaping @Sendable () -> UserDictionary = {
            (try? loadUserDictionary()) ?? .empty
        }
    ) {
        self.reader = reader
        self.persistence = persistence
        self.userDictionaryLoader = userDictionaryLoader
        // Rehydrate synchronously so the view's first render already
        // reflects the user's last session. Falls through to defaults
        // on nil / corrupted blob (see QueryPersistence.load).
        if let restored = persistence.load() {
            self.query = restored.query
            self.filters = restored.filters
        }
        // Debounce writes so a fast typist doesn't hammer UserDefaults.
        // 250 ms matches the audit spec; the trailing edge fires so the
        // final keystroke is always captured.
        self.persistCancellable = Publishers.CombineLatest($query, $filters)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [persistence] q, f in
                persistence.save(PersistedQueryState(query: q, filters: f))
            }
    }

    /// Refresh the per-app pill source. Cheap aggregate query — call on
    /// first appearance of the search tab and whenever the date-range
    /// changes (so the pills reflect the same window the search uses).
    public func reloadObservedApps() async {
        let requestedFilters = filters
        let from = requestedFilters.timeWindowUs().fromUs
        do {
            let apps = try await reader.listObservedApps(limit: 50, timeFromUs: from)
            guard requestedFilters == filters, !Task.isCancelled else { return }
            observedApps = apps
        } catch {
            guard requestedFilters == filters, !Task.isCancelled else { return }
            observedApps = []
        }
    }

    /// Re-run every read represented by the current search surface.
    public func refresh() async {
        guard !Task.isCancelled else { return }
        if let focusedEventID {
            await focusEvent(id: focusedEventID)
        } else {
            await runSearch()
        }
        await reloadObservedApps()
    }

    public var selectedHit: Hit? {
        guard let id = selectedHitId else { return nil }
        return hits.first { $0.id == id }
    }

    /// Filter capability independent of selected mode.
    public var hasUnsupportedRelatedFilters: Bool {
        filters.appBundleIds.count > 1 || filters.hasUrl
    }

    public var filterLimitationMessage: String? {
        guard mode == .related,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              filters.anyActive else { return nil }
        if hasUnsupportedRelatedFilters {
            return "Related search does not support multiple-app or URL filters. Choose Text to apply these filters."
        }
        return "Related search filters a limited candidate set and may omit matching memories. Use Text to filter before the result limit."
    }

    public func runSearch() async {
        let generation = beginSearchRequest()
        focusedEventID = nil
        let requestedFilters = filters
        let requestedMode = mode
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            selectedHitId = nil
            isDetailFocused = false
            errorMessage = nil
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        defer { if generation == searchGeneration { isSearching = false } }
        if !q.isEmpty && requestedMode == .related && hasUnsupportedRelatedFilters {
            hits = []
            selectedHitId = nil
            isDetailFocused = false
            return
        }
        do {
            let window = requestedFilters.timeWindowUs()
            // Calendar windows are half-open; the legacy FFI remains inclusive.
            if let upper = window.toUs, upper == 0 || (window.fromUs ?? 0) >= upper {
                hits = []
                selectedHitId = nil
                isDetailFocused = false
                return
            }
            let dict = q.isEmpty ? UserDictionary.empty : userDictionaryLoader()
            let opts = SearchOptions(
                text: q,
                limit: 50,
                appFilter: requestedFilters.appFilter,
                timeFromUs: window.fromUs,
                timeToUs: window.toUs.map { $0 - 1 },
                userAliases: dict.entries.isEmpty ? nil : dict.toAliasMap(),
                mode: requestedMode,
                browse: false,
                appFilters: requestedFilters.appBundleIds.sorted(),
                hasUrl: requestedFilters.hasUrl
            )
            let results = try await applyClientFilters(
                to: reader.search(opts),
                filters: requestedFilters,
                window: window
            )
            guard generation == searchGeneration, !Task.isCancelled else { return }
            hits = results
            if let selectedHitId, !results.contains(where: { $0.id == selectedHitId }) {
                self.selectedHitId = nil
                isDetailFocused = false
            }
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            hits = []
            errorMessage = "\(error)"
        }
    }

    /// Load one canonical event selected outside the main workspace (for
    /// example from the global Recall popup) and reveal its detail directly.
    public func focusEvent(id: UInt64) async {
        guard id > 0 else { return }
        let generation = beginSearchRequest()
        focusedEventID = id
        isSearching = true
        errorMessage = nil
        defer { if generation == searchGeneration { isSearching = false } }
        do {
            let focused = try await reader.fetchEventsByIds([id])
            guard generation == searchGeneration, !Task.isCancelled else { return }
            hits = Array(focused.prefix(1))
            selectedHitId = hits.first?.eventId
            isDetailFocused = selectedHitId != nil
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            hits = []
            selectedHitId = nil
            isDetailFocused = false
            errorMessage = "\(error)"
        }
    }

    /// Defensive validation for alternate readers. Browse and Text apply these
    /// predicates in SQL before LIMIT; this is not a candidate-pool search.
    private func applyClientFilters(
        to results: [Hit],
        filters: FilterState,
        window: (fromUs: UInt64?, toUs: UInt64?)
    ) -> [Hit] {
        var out = results
        if let from = window.fromUs {
            out = out.filter { $0.tsUs >= from }
        }
        if let to = window.toUs {
            out = out.filter { $0.tsUs < to }
        }
        if !filters.appBundleIds.isEmpty {
            out = out.filter { filters.matchesApp($0.appBundleId) }
        }
        if filters.hasUrl {
            out = out.filter { $0.url != nil && !$0.url!.isEmpty }
        }
        return Array(out.prefix(50))
    }

    public func clear() {
        query = ""
        filters = FilterState()
        _ = beginSearchRequest()
        focusedEventID = nil
        hits = []
        errorMessage = nil
        selectedHitId = nil
        isDetailFocused = false
        isSearching = false
        // Eagerly wipe persistence too — the debounced sink would
        // eventually erase it (empty state ⇒ delete key) but the user
        // clicked "×" so make it immediate.
        persistence.clear()
    }

    private func beginSearchRequest() -> UInt64 {
        pendingSearch?.cancel()
        pendingSearch = nil
        searchGeneration &+= 1
        return searchGeneration
    }

    private func searchInputChanged() {
        _ = beginSearchRequest()
        focusedEventID = nil
        hits = []
        selectedHitId = nil
        isDetailFocused = false
        errorMessage = nil
        isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isSearching else { return }
        pendingSearch = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pendingSearch = nil
            await self.refresh()
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
