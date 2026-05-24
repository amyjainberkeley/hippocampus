// BriefViewModel.swift — @MainActor observable view model for the Brief
// tab in the Recall UI (`docs/design/brief-viewer-spec.md`).
//
// The view model owns one explicit `BriefScene` enum that the SwiftUI
// scene switches over. The five scenes map 1-1 to the five viewer
// states in the spec table:
//
//   1. .modelMissing             — model not downloaded
//   2. .awaitingFirstFullDay     — model present, no full day captured
//   3. .loading                  — querying the brain
//   4. .brief(_)                 — full brief screen
//   5. .missingForDate(_)        — selected date has no brief
//   6. .error(_)                 — reader returned an error (spec table row 6)
//
// The "generating in flight" state in the spec is reachable through
// `.loading` here — the Recall UI is a READ-ONLY consumer of the brain,
// so it cannot observe the author's in-flight progress directly. When a
// future cycle adds a publish/subscribe channel for author state, this
// VM gains a `.generating(progress:)` case that the scene renders with
// `ShimmerLoadingView`.

import Foundation

/// What the Brief scene should render. Exhaustive: every transition
/// goes through `loadFor` / `pickPrevious` / `pickNext` and lands on
/// exactly one of these.
public enum BriefScene: Equatable {
    /// Daily-brief author model is not installed — deep-link the user
    /// to the Hippocampus.app's ModelDownloadView.
    case modelMissing
    /// Model is present but no brief has been generated yet (no full
    /// day captured). `captureHoursSoFar` surfaces a "first brief
    /// generates after your first full day" copy with progress.
    case awaitingFirstFullDay(captureHoursSoFar: Double?)
    /// FFI fetch is in flight — render shimmer.
    case loading
    /// A brief is loaded. The view renders header + body + footer
    /// actions.
    case brief(Brief)
    /// The selected date has no brief on file. `dateLocal` is the
    /// ISO date the user navigated to.
    case missingForDate(dateLocal: String)
    /// The reader returned an error. `message` is the FFI diagnostic
    /// passed straight through.
    case error(message: String)
}

@MainActor
public final class BriefViewModel: ObservableObject {
    /// What the scene should render. Derived; written only by VM methods.
    @Published public private(set) var scene: BriefScene = .loading

    /// ISO `YYYY-MM-DD` the date selector is pointed at. `nil` until the
    /// VM has loaded the latest brief / picked a default.
    @Published public private(set) var selectedDate: String?

    /// All known brief dates, most-recent first. Drives the `<` / `>`
    /// arrows + the date label. Empty until the first reload.
    @Published public private(set) var knownDates: [String] = []

    /// Whether the user has the brief-author model on disk. The view
    /// supplies this at init time (the model presence check belongs to
    /// Hippocampus.app, not the recall UI). If `false`, the VM short-
    /// circuits to `.modelMissing` regardless of brain state.
    public let isModelPresent: Bool

    /// Whether the user has accumulated at least one full day of capture.
    /// The view supplies this at init time. If `false` AND no brief is
    /// found, the VM renders `.awaitingFirstFullDay`. If a brief IS
    /// found, the VM renders the brief regardless — a synthetic test
    /// brief should always show.
    public let hasFullDayCapture: Bool

    /// Hours of capture so far (best-effort, optional). Surfaces in the
    /// `.awaitingFirstFullDay` copy.
    public let captureHoursSoFar: Double?

    private let reader: BrainReader

    public init(
        reader: BrainReader,
        isModelPresent: Bool = true,
        hasFullDayCapture: Bool = true,
        captureHoursSoFar: Double? = nil
    ) {
        self.reader = reader
        self.isModelPresent = isModelPresent
        self.hasFullDayCapture = hasFullDayCapture
        self.captureHoursSoFar = captureHoursSoFar
    }

    /// Re-query the brain, picking the latest brief (or whatever the
    /// caller asked for via `forceDate`) and updating `knownDates`.
    ///
    /// Called once on tab appearance, again after a Regenerate, and any
    /// time the deep-link router lands the user on this tab.
    public func reload(forceDate: String? = nil) async {
        if !isModelPresent {
            scene = .modelMissing
            return
        }

        scene = .loading
        do {
            let dates = try await reader.briefDates(limit: 365)
            knownDates = dates

            if let target = forceDate {
                try await loadForThrowing(target)
                return
            }

            if let latest = try await reader.latestBrief() {
                selectedDate = latest.dateLocal
                scene = .brief(latest)
                return
            }

            // No briefs at all. Decide between "first full day pending"
            // vs "missing brief".
            if hasFullDayCapture {
                // The user has captured a full day but no brief exists
                // yet — either generation is pending or capture is off
                // for this date. Surface the date-specific empty state.
                let today = Self.todayISO()
                selectedDate = today
                scene = .missingForDate(dateLocal: today)
            } else {
                scene = .awaitingFirstFullDay(captureHoursSoFar: captureHoursSoFar)
            }
        } catch {
            scene = .error(message: "\(error)")
        }
    }

    /// Load a brief for one explicit ISO date.
    public func loadFor(_ dateLocal: String) async {
        do {
            try await loadForThrowing(dateLocal)
        } catch {
            scene = .error(message: "\(error)")
        }
    }

    private func loadForThrowing(_ dateLocal: String) async throws {
        selectedDate = dateLocal
        scene = .loading
        if let brief = try await reader.briefForDate(dateLocal) {
            scene = .brief(brief)
        } else {
            scene = .missingForDate(dateLocal: dateLocal)
        }
    }

    /// Step to the previous (older) brief in `knownDates`. No-op when
    /// the current date is the oldest known one.
    public func pickPrevious() async {
        guard let current = selectedDate,
              let idx = knownDates.firstIndex(of: current),
              idx + 1 < knownDates.count
        else { return }
        let next = knownDates[idx + 1]
        await loadFor(next)
    }

    /// Step to the next (newer) brief in `knownDates`. No-op when the
    /// current date is the newest known one.
    public func pickNext() async {
        guard let current = selectedDate,
              let idx = knownDates.firstIndex(of: current),
              idx > 0
        else { return }
        let next = knownDates[idx - 1]
        await loadFor(next)
    }

    /// Whether `pickPrevious` would do anything.
    public var canPickPrevious: Bool {
        guard let current = selectedDate,
              let idx = knownDates.firstIndex(of: current)
        else { return false }
        return idx + 1 < knownDates.count
    }

    /// Whether `pickNext` would do anything.
    public var canPickNext: Bool {
        guard let current = selectedDate,
              let idx = knownDates.firstIndex(of: current)
        else { return false }
        return idx > 0
    }

    /// Today's date as `YYYY-MM-DD` in the user's local timezone.
    /// Public so tests can compare against the same formatter.
    public static func todayISO(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }
}
