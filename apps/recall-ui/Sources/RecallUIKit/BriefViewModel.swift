// BriefViewModel.swift — @MainActor observable view model for the Brief
// tab in the Recall UI (`docs/design/brief-viewer-spec.md`).
//
// The view model owns one explicit `BriefScene` enum that the SwiftUI
// scene switches over. Its scenes cover the viewer states in the spec
// plus an explicit unknown-coverage state:
//
//   1. .captureCoverageUnknown   — no trustworthy coverage signal
//   2. .awaitingFirstFullDay     — measured coverage is insufficient
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

/// Source-backed full-day coverage used only to choose the no-brief scene.
public enum CaptureCoverage: Sendable, Equatable {
    /// Recall has no trustworthy supervisor or persisted coverage signal.
    case unknown
    /// A real measurement exists and is below one full day. Hours may be
    /// omitted when the provider exposes only the threshold result.
    case insufficient(captureHoursSoFar: Double?)
    /// A real measurement confirms at least one full day.
    case fullDay
}

/// What the Brief scene should render. Exhaustive: every transition
/// goes through `loadFor` / `pickPrevious` / `pickNext` and lands on
/// exactly one of these.
public enum BriefScene: Equatable {
    /// No brief exists and Recall has no coverage measurement with which to
    /// explain that absence.
    case captureCoverageUnknown
    /// No brief exists and measured coverage is below one full day.
    /// `captureHoursSoFar` optionally surfaces progress.
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

    /// Coverage evidence used only after a no-brief result. Existing briefs
    /// render regardless of coverage so source-backed content always wins.
    public let captureCoverage: CaptureCoverage

    private let reader: BrainReader

    /// Compatibility for callers with a real Bool coverage measurement.
    public convenience init(
        reader: BrainReader,
        hasFullDayCapture: Bool,
        captureHoursSoFar: Double? = nil
    ) {
        self.init(
            reader: reader,
            captureCoverage: hasFullDayCapture
                ? .fullDay
                : .insufficient(captureHoursSoFar: captureHoursSoFar)
        )
    }

    public init(
        reader: BrainReader,
        captureCoverage: CaptureCoverage = .unknown
    ) {
        self.reader = reader
        self.captureCoverage = captureCoverage
    }

    /// Re-query the brain, picking the latest brief (or whatever the
    /// caller asked for via `forceDate`) and updating `knownDates`.
    ///
    /// Called once on tab appearance, when refreshing a saved brief, and any time
    /// the deep-link router lands the user on this tab.
    public func reload(forceDate: String? = nil) async {
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

            // No briefs at all. Explain only what the supplied coverage
            // evidence can establish.
            switch captureCoverage {
            case .unknown:
                scene = .captureCoverageUnknown
            case .insufficient(let captureHoursSoFar):
                scene = .awaitingFirstFullDay(captureHoursSoFar: captureHoursSoFar)
            case .fullDay:
                let today = Self.todayISO()
                selectedDate = today
                scene = .missingForDate(dateLocal: today)
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
