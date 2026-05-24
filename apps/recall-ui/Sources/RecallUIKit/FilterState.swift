// FilterState.swift — the recall-UI search filter model.
//
// Replaces the original hardcoded-pill model with two structured filter
// dimensions + a single boolean pill:
//
//   - `appBundleIds: Set<String>` — dynamic per-app filter (gap #1 in
//     the Director-Brain recall-UI audit). Populated from the
//     `listObservedApps` reader endpoint.
//   - `dateRange: DateRangePreset` — discrete preset {none, today,
//     yesterday, last7Days, custom(from, to)}.
//   - `hasUrl: Bool` — single toggle preserved from v1.
//
// The state encodes itself into `SearchOptions.timeFromUs / timeToUs /
// appFilter` for FFI consumption. When more than one app is selected
// the reader can only filter on one at the wire level — the SearchView-
// Model post-filters the remainder client-side.

import Foundation

/// Preset date-range buckets shown as filter pills. The `custom` case
/// carries an explicit `ClosedRange<Date>`; the calendar popover writes
/// it. `none` means "no date filter" (the implicit default).
public enum DateRangePreset: Equatable, Sendable, Hashable {
    case none
    case today
    case yesterday
    case last7Days
    case custom(from: Date, to: Date)

    /// Short label for pill display.
    public var label: String {
        switch self {
        case .none: return "All time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7Days: return "Last 7 days"
        case .custom: return "Custom…"
        }
    }

    /// `true` when this preset narrows the search at all.
    public var isActive: Bool {
        if case .none = self { return false }
        return true
    }

    /// The four discrete presets shown as a pill row (always rendered,
    /// `.custom` is opened from the trailing "Custom…" pill).
    public static var presetPills: [DateRangePreset] {
        [.today, .yesterday, .last7Days]
    }
}

/// The single boolean pill kept from v1 — `Has URL` narrows to events
/// captured with an active browser tab URL.
public enum FilterPill: String, CaseIterable, Sendable, Equatable, Hashable, Identifiable {
    case hasUrl

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hasUrl: return "Has URL"
        }
    }
}

/// The recall-UI search filter model. Equatable so the SearchView's
/// `.onChange` only re-fires when something actually changes.
public struct FilterState: Equatable, Sendable {
    /// App bundle ids the user has narrowed to. Empty ⇒ no app filter.
    public var appBundleIds: Set<String> = []
    /// Time-window preset. `.none` ⇒ no time filter.
    public var dateRange: DateRangePreset = .none
    /// `Has URL` toggle.
    public var hasUrl: Bool = false

    public init() {}

    /// `true` when any filter dimension would narrow the result set.
    public var anyActive: Bool {
        !appBundleIds.isEmpty || dateRange.isActive || hasUrl
    }

    /// Toggle one app bundle id in the set.
    public mutating func toggleApp(_ bundleId: String) {
        if appBundleIds.contains(bundleId) {
            appBundleIds.remove(bundleId)
        } else {
            appBundleIds.insert(bundleId)
        }
    }

    /// Toggle the `hasUrl` pill.
    public mutating func toggleHasUrl() {
        hasUrl.toggle()
    }

    /// Replace the date-range preset (or clear it if `preset == .none`).
    public mutating func setDateRange(_ preset: DateRangePreset) {
        dateRange = preset
    }

    /// Resolve `dateRange` to a `[fromUs, toUs?]` time window. Returns
    /// `nil` when no time filter applies. `toUs` is `nil` for open-ended
    /// windows ("today" runs from start-of-day to now-ish; the FFI
    /// treats `toUs == nil` as "no upper bound").
    public func timeWindowUs(now: Date = Date()) -> (fromUs: UInt64?, toUs: UInt64?) {
        switch dateRange {
        case .none:
            return (nil, nil)
        case .today:
            let start = Calendar.current.startOfDay(for: now)
            return (start.usSinceEpoch, nil)
        case .yesterday:
            let startToday = Calendar.current.startOfDay(for: now)
            let startYesterday = Calendar.current.date(
                byAdding: .day, value: -1, to: startToday
            ) ?? startToday
            return (startYesterday.usSinceEpoch, startToday.usSinceEpoch)
        case .last7Days:
            let start = Calendar.current.date(
                byAdding: .day, value: -7, to: now
            ) ?? now
            return (start.usSinceEpoch, nil)
        case .custom(let from, let to):
            // Inclusive lower bound; exclusive upper bound (so that
            // selecting "Mar 1 to Mar 1" picks up only that day).
            let upper = Calendar.current.date(
                byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)
            ) ?? to
            return (
                Calendar.current.startOfDay(for: from).usSinceEpoch,
                upper.usSinceEpoch
            )
        }
    }

    /// Lower bound projection — preserved for callers that only consume
    /// the start of the window.
    public func timeFromUs(now: Date = Date()) -> UInt64? {
        timeWindowUs(now: now).fromUs
    }

    /// The single `app_bundle_id` the FFI can filter on, if any. When
    /// the user selected exactly one app, pass it through to the wire
    /// for an index hit. With two or more, leave `nil` and rely on
    /// client-side post-filter in the view model.
    public var appFilter: String? {
        appBundleIds.count == 1 ? appBundleIds.first : nil
    }

    /// `true` when the FFI's single `app_filter` cannot fully express
    /// `appBundleIds` (i.e. ≥ 2 apps selected) and the view model must
    /// post-filter results in Swift.
    public var requiresClientSideAppFilter: Bool {
        appBundleIds.count >= 2
    }

    /// Quick predicate for callers comparing a Hit's app to the
    /// app filter selection. `true` when no selection or the app is in
    /// the set.
    public func matchesApp(_ bundleId: String?) -> Bool {
        if appBundleIds.isEmpty { return true }
        guard let id = bundleId else { return false }
        return appBundleIds.contains(id)
    }
}

private extension Date {
    /// Microseconds-since-epoch projection clamped to non-negative.
    var usSinceEpoch: UInt64 {
        let t = timeIntervalSince1970
        if t <= 0 { return 0 }
        return UInt64(t * 1_000_000)
    }
}
