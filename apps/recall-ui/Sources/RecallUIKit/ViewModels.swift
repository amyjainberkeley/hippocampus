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
    /// A memory shown on its own, opened from outside the list (a link, the
    /// Ask panel). Ask shows it while the field is empty
    /// (critique-recall-engineering finding 5).
    @Published public private(set) var focusedEventId: UInt64?

    private let reader: BrainReader
    /// Persists `{ query, filters }` across quit/restore. Cycle 8.35
    /// audit follow-up. Injectable so tests can pass an in-memory store.
    private let persistence: QueryPersistence
    private var persistCancellable: AnyCancellable?
    private var pendingSearch: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
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
        if let focusedEventId {
            await focusEvent(id: focusedEventId)
        } else {
            await runSearch()
        }
        await reloadObservedApps()
    }

    public var selectedHit: Hit? {
        guard let id = selectedHitId else { return nil }
        return hits.first { $0.id == id }
    }

    /// A memory opened from outside the list is on screen.
    public var isShowingFocusedEvent: Bool { focusedEventId != nil }

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
        focusedEventId = nil
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
        focusedEventId = id
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
        focusedEventId = nil
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
        focusedEventId = nil
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

/// History: moments newest first, a page at a time (spec-recall S3,
/// RULINGS W8, critique-recall-engineering finding 7).
///
/// - Without a day it shows the newest moments, as the window always has.
/// - With a day it browses that day; "Show Earlier" pages on below the
///   oldest row. A day can hold tens of thousands of moments, so one page is
///   never taken for the whole day.
/// - "Show in History" opens a session's own time with its newest moment
///   selected, and "Show Earlier" goes on before it.
/// - The ten-second tick reads again only today, and only when something
///   newer was saved. A past day or a session's time stays as it is.
/// - A delete clears what is shown at once and reads it again.
@MainActor
public final class TimelineViewModel: ObservableObject {
    @Published public private(set) var hits: [Hit] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public var selectedHitId: UInt64?
    @Published public var isDetailFocused: Bool = false
    /// The day shown. Nil shows the newest moments, whatever their day.
    @Published public private(set) var day: MemoryDay?
    /// A session's own time inside `day`, from "Show in History".
    @Published public private(set) var range: ClosedRange<UInt64>?
    /// More moments may lie below the last row: "Show Earlier".
    @Published public private(set) var canLoadEarlier = false
    @Published public private(set) var isLoadingEarlier = false
    /// The last "Show Earlier" failed. The rows already shown stay.
    @Published public private(set) var loadEarlierFailed = false

    public let pageSize: Int
    private let reader: BrainReader
    private let now: @Sendable () -> Date
    /// Moves on with every read that replaces the rows, so an older read
    /// still running can never land over a newer one.
    private var generation = 0
    /// The newest time the next "Show Earlier" page may hold.
    private var earlierUpperBound: UInt64?
    private var deletionObserver: AnyCancellable?

    public init(
        reader: BrainReader,
        pageSize: Int = 100,
        day: MemoryDay? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        deletions: MemoryDeletionSignal = .shared
    ) {
        _day = Published(initialValue: day)
        self.reader = reader
        self.pageSize = max(1, pageSize)
        self.now = now
        deletionObserver = deletions.center
            .publisher(for: MemoryDeletionSignal.notification, object: deletions)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.memoryWasDeleted() }
            }
    }

    public var selectedHit: Hit? {
        guard let id = selectedHitId else { return nil }
        return hits.first { $0.id == id }
    }

    /// Read what is shown again from its first page.
    public func reload() async {
        await load(selecting: nil)
    }

    /// Show `day` from its newest moment. Nil shows the newest moments,
    /// whatever their day.
    public func show(day: MemoryDay?) async {
        if day != self.day || range != nil {
            self.day = day
            range = nil
            clearRows()
        }
        await load(selecting: nil)
    }

    /// "Show in History": the session's own time inside `day`, with
    /// `eventId` (its newest moment) selected. "Show Earlier" goes on before
    /// the session. A range outside the day shows the whole day.
    public func show(day: MemoryDay, around range: ClosedRange<UInt64>, selecting eventId: UInt64? = nil) async {
        self.day = day
        let lower = max(range.lowerBound, day.startUs)
        let upper = min(range.upperBound, day.endUs)
        self.range = lower <= upper ? lower...upper : nil
        clearRows()
        await load(selecting: eventId)
    }

    /// Leave a session's time for its whole day, keeping the selection.
    public func showWholeDay() async {
        guard range != nil else { return }
        range = nil
        await load(selecting: selectedHitId)
    }

    /// "Show Earlier": the next page below the last row, added under it.
    public func loadEarlier() async {
        guard canLoadEarlier, !isLoading, !isLoadingEarlier, let upper = earlierUpperBound else { return }
        let request = generation
        isLoadingEarlier = true
        loadEarlierFailed = false
        defer { if request == generation { isLoadingEarlier = false } }
        do {
            let page = try await page(from: day?.startUs, to: upper, excluding: Set(hits.map(\.id)),
                                      extra: hits.filter { $0.tsUs == upper }.count)
            guard request == generation, !Task.isCancelled else { return }
            hits += page.rows
            canLoadEarlier = page.more
            earlierUpperBound = page.rows.last?.tsUs ?? upper
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            loadEarlierFailed = true
        }
    }

    /// The ten-second tick. Only today's History, or the newest moments, is
    /// read again, and only when a newer moment was saved; the newer moments
    /// go on top and the pages below stay. A past day and a session's own
    /// time stay as they are (critique-recall-engineering finding 7).
    public func refresh() async {
        guard !isLoading, !isLoadingEarlier else { return }
        if let day {
            let nowUs = UInt64(max(0, now().timeIntervalSince1970 * 1_000_000))
            guard range == nil, day.contains(nowUs) else { return }
        }
        let request = generation
        let newest: Hit?
        do {
            newest = try await reader.recentEvents(limit: 1).first
        } catch {
            return
        }
        guard request == generation, !Task.isCancelled, let newest else { return }
        if let day, !day.contains(newest.tsUs) { return }
        if let top = hits.first {
            let isNewer = newest.tsUs > top.tsUs
                || (newest.tsUs == top.tsUs && !hits.contains { $0.id == newest.id })
            guard isNewer else { return }
        }
        guard let day, let top = hits.first else {
            await load(selecting: nil)
            return
        }
        do {
            let page = try await page(from: top.tsUs, to: day.endUs, excluding: Set(hits.map(\.id)),
                                      extra: hits.prefix { $0.tsUs == top.tsUs }.count)
            guard request == generation, !Task.isCancelled else { return }
            if page.more {
                // More than a page arrived: the rows below would no longer
                // follow on from it, so History starts again from the top.
                await load(selecting: nil)
            } else {
                hits = page.rows + hits
            }
        } catch {
            return
        }
    }

    private func load(selecting eventId: UInt64?) async {
        generation += 1
        let request = generation
        let day = self.day
        let range = self.range
        isLoading = true
        isLoadingEarlier = false
        loadEarlierFailed = false
        errorMessage = nil
        defer { if request == generation { isLoading = false } }
        do {
            let rows: [Hit]
            let more: Bool
            let next: UInt64?
            if let day {
                let lower = range?.lowerBound ?? day.startUs
                let upper = range?.upperBound ?? day.endUs
                let page = try await page(from: lower, to: upper, excluding: [])
                rows = page.rows
                // Below a session's time lies the rest of its day.
                more = page.more || lower > day.startUs
                next = rows.last?.tsUs ?? (lower > day.startUs ? lower - 1 : nil)
            } else {
                rows = try await reader.recentEvents(limit: pageSize)
                more = rows.count >= pageSize
                next = rows.last?.tsUs
            }
            guard request == generation, !Task.isCancelled else { return }
            hits = rows
            canLoadEarlier = more && next != nil
            earlierUpperBound = next
            if let eventId, rows.contains(where: { $0.id == eventId }) {
                selectedHitId = eventId
            } else if let selected = selectedHitId, !rows.contains(where: { $0.id == selected }) {
                selectedHitId = nil
                isDetailFocused = false
            }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            hits = []
            canLoadEarlier = false
            earlierUpperBound = nil
            errorMessage = "\(error)"
        }
    }

    /// Up to a page of moments between `lower` and `upper`, newest first, and
    /// whether more lie below them. `extra` asks for as many more as are shown
    /// already at an edge's time: they come back and are dropped, so a moment
    /// sharing its time with a row shown is never skipped.
    private func page(
        from lower: UInt64?,
        to upper: UInt64,
        excluding shown: Set<UInt64>,
        extra: Int = 0
    ) async throws -> (rows: [Hit], more: Bool) {
        let found = try await reader.search(SearchOptions(
            text: "", limit: pageSize + 1 + extra, timeFromUs: lower, timeToUs: upper,
            mode: .text, browse: true
        ))
        var seen = shown
        let fresh = found.filter { hit in
            hit.tsUs <= upper && hit.tsUs >= (lower ?? 0) && seen.insert(hit.id).inserted
        }
        return (Array(fresh.prefix(pageSize)), fresh.count > pageSize)
    }

    private func clearRows() {
        generation += 1
        hits = []
        canLoadEarlier = false
        earlierUpperBound = nil
        isLoadingEarlier = false
        loadEarlierFailed = false
        errorMessage = nil
        selectedHitId = nil
        isDetailFocused = false
    }

    /// Moments were deleted: nothing shown may be one of them, so the rows go
    /// at once and are read again. A selection still there stays.
    private func memoryWasDeleted() {
        generation += 1
        hits = []
        canLoadEarlier = false
        earlierUpperBound = nil
        isLoadingEarlier = false
        loadEarlierFailed = false
        Task { [weak self] in await self?.load(selecting: nil) }
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
