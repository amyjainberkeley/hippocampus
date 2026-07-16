// GlobalRecallPopupViewModel.swift — pure logic for the Spotlight-
// like recall popup (CEO-directed flagship feature).
//
// Kept in RecallUIKit so `RecallUIKitTests` can exercise the debounce
// and results wiring without linking the SwiftUI executable — same
// pattern as `ActionPanelCore` (PR #74) and `BriefViewModel` (§brief
// viewer spec).
//
// # Query pipeline
//
// - `query` is `@Published`; the view binds to it via `$query`.
// - The debounce timer fires 100ms after the last keystroke and
//   dispatches `perform()`. If a new keystroke arrives inside the
//   window, the pending fire is cancelled.
// - `perform()` swallows FFI errors — the popup renders "No results"
//   rather than an error banner, matching Spotlight's UX. The error
//   is exposed via `lastError` for tests + a future diagnostic
//   surface.
// - Results are capped at `resultLimit` (default 8, matching the
//   audit-doc spec) so the popup stays keyboard-navigable.
// - The `slowThresholdMs` field is exposed so the view can render a
//   "recall UI opening…" hint when a query is taking too long.
//
// # Ephemeral state (unlike SearchViewModel)
//
// Per the CEO's design constraint, the popup does NOT persist query
// state across dismiss/re-open — a fresh open starts empty. That
// intentionally differs from the recall UI's `QueryPersistence`
// (PR #50). `reset()` clears everything.

import Combine
import Foundation

/// A hit selected from the popup's result list — either the user
/// tapped it or hit Enter. The view layer maps this to either an
/// external deep-link open or an internal DetailPane focus.
public enum PopupHitAction: Sendable, Equatable {
    /// Open the hit's source URL (browser tab, file path).
    case openExternal(URL)
    /// Focus the DetailPane in the recall UI for `eventId`.
    case openInRecallUI(eventId: UInt64)
}

@MainActor
public final class GlobalRecallPopupViewModel: ObservableObject {
    @Published public var query: String = ""
    @Published public private(set) var results: [Hit] = []
    @Published public private(set) var isSearching: Bool = false
    @Published public private(set) var selectedIndex: Int = 0
    @Published public private(set) var lastError: String?

    /// Number of rows to render. Matches the audit-doc's "max 8"
    /// spec — larger lists start to lose the Spotlight-like scanning
    /// feel and encourage typing a better query.
    public let resultLimit: Int
    /// Milliseconds after the last keystroke before dispatching the
    /// FFI search. 100ms matches Raycast (peer study §3.4). Exposed
    /// so tests can drive it directly.
    public let debounceMs: Int

    private let reader: BrainReader
    private var debounceCancellable: AnyCancellable?
    // The in-flight search task is only ever cancelled, never awaited through
    // this property, so its Success type is immaterial to usage — but it must
    // match the task actually assigned (a Result-returning search) for Swift 6.
    private var inFlightTask: Task<Result<[Hit], any Error>, Never>?

    public init(
        reader: BrainReader,
        resultLimit: Int = 8,
        debounceMs: Int = 100
    ) {
        self.reader = reader
        self.resultLimit = resultLimit
        self.debounceMs = debounceMs

        // Debounce the query -> perform dispatch. Cancelling the
        // subscription in `deinit` isn't required (Combine cleans
        // up automatically), but we hold the AnyCancellable so it
        // isn't dropped on the floor immediately.
        self.debounceCancellable =
            $query
            .debounce(
                for: .milliseconds(debounceMs),
                scheduler: DispatchQueue.main
            )
            .removeDuplicates()
            .sink { [weak self] q in
                guard let self else { return }
                Task { @MainActor in await self.perform(query: q) }
            }
    }

    /// Reset the popup back to first-open state. Called by the view
    /// layer on Esc / hotkey-toggle / after invoking a result.
    public func reset() {
        inFlightTask?.cancel()
        inFlightTask = nil
        query = ""
        results = []
        selectedIndex = 0
        isSearching = false
        lastError = nil
    }

    /// Directly trigger a search bypassing the debounce. Tests call
    /// this instead of waiting on the timer.
    public func perform(query rawQuery: String) async {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cancel any prior in-flight search so we don't race two
        // FFI round trips against each other.
        inFlightTask?.cancel()

        guard !q.isEmpty else {
            results = []
            isSearching = false
            selectedIndex = 0
            lastError = nil
            return
        }

        isSearching = true
        lastError = nil
        let task = Task { [reader, resultLimit] () -> Result<[Hit], Error> in
            do {
                let hits = try await reader.search(
                    SearchOptions(text: q, limit: resultLimit)
                )
                return .success(hits)
            } catch {
                return .failure(error)
            }
        }
        inFlightTask = task
        let outcome = await task.value
        // The task could have been superseded while we were awaiting.
        // Only publish if this is still the current in-flight search.
        guard !Task.isCancelled else { return }
        isSearching = false
        switch outcome {
        case .success(let hits):
            results = hits
            selectedIndex = 0
        case .failure(let err):
            results = []
            lastError = "\(err)"
            selectedIndex = 0
        }
    }

    public func selectNext() {
        guard !results.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, results.count - 1)
    }

    public func selectPrev() {
        guard !results.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    /// Compute the action for the currently-selected hit. `nil` when
    /// there's nothing to invoke (empty results). The `preferExternal`
    /// flag matches the Cmd-Enter modifier: when true, prefer the
    /// source URL if one exists; when false (plain Enter), open in
    /// the recall UI DetailPane.
    public func invokeAction(preferExternal: Bool) -> PopupHitAction? {
        guard results.indices.contains(selectedIndex) else { return nil }
        let hit = results[selectedIndex]
        if preferExternal, let raw = hit.url, let url = URL(string: raw) {
            return .openExternal(url)
        }
        return .openInRecallUI(eventId: hit.eventId)
    }
}
