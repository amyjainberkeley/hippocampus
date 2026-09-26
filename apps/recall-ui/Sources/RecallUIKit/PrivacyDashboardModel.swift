// PrivacyDashboardModel.swift — pure-value model backing the ⌘7
// Privacy Dashboard (cycle 8.46). Lives in the library target so
// SwiftUI-free unit tests can pin filter compose + confirmation
// matcher byte-exact.
//
// Read-only + protected-set discipline: this file contains ZERO
// mutation entry points. The destructive-action UI stubs in the
// executable target route through this file's `DestructivePrivacyAction`
// enum only to render text — the actual wipe pathway is deferred to
// the follow-up cycle-8.47 PR (mutation FFI + CSO sign-off).

import Foundation

/// Local filter state for the Privacy Dashboard. Applied to loaded
/// `[Hit]` (client-side) and composed to a JSON dict when the user
/// exports their data.
public struct PrivacyDashboardFilter: Equatable, Sendable {
    /// Bundle-id filter. `nil` or empty = all apps.
    public var appBundleId: String?
    /// Time cutoff (hours before "now"). `nil` or `0` = all time.
    public var sinceHours: Int?

    public static let empty =
        PrivacyDashboardFilter(appBundleId: nil, sinceHours: nil)

    public init(appBundleId: String?, sinceHours: Int?) {
        self.appBundleId = appBundleId
        self.sinceHours = sinceHours
    }

    /// Apply the filter to a preloaded list. Deterministic (uses the
    /// injected `now`); pure — no I/O, no global state.
    public func apply(to hits: [Hit], now: Date = Date()) -> [Hit] {
        var out = hits
        if let app = appBundleId, !app.isEmpty {
            out = out.filter { $0.appBundleId == app }
        }
        if let hours = sinceHours, hours > 0 {
            let cutoff = UInt64(
                (now.timeIntervalSince1970 - Double(hours) * 3600.0)
                    * 1_000_000.0
            )
            out = out.filter { $0.tsUs >= cutoff }
        }
        return out
    }

    /// JSON payload the dashboard emits alongside the exported events
    /// so the user's downloaded artifact records what filter they were
    /// viewing. Keys mirror the `SearchOptions` wire so a future
    /// server-side pushdown can consume the same shape.
    public func composeJSON(now: Date = Date()) -> [String: String] {
        var d: [String: String] = [:]
        if let app = appBundleId, !app.isEmpty {
            d["app_bundle_id"] = app
        }
        if let hours = sinceHours, hours > 0 {
            let cutoff = UInt64(
                (now.timeIntervalSince1970 - Double(hours) * 3600.0)
                    * 1_000_000.0
            )
            d["time_from_us"] = String(cutoff)
        }
        return d
    }
}

/// Which destructive action the dashboard's confirmation sheet is
/// asking about. Locks the typed-word gate every destructive UI in the
/// dashboard MUST pass before firing its (currently stubbed) delete
/// pathway. Test surface for `PrivacyDashboardTests`.
public enum DestructivePrivacyAction: String, Sendable {
    case deleteLast24h
    case deleteEverything

    /// Exact phrase the user must type to enable the "Confirm" button.
    /// Case-sensitive. Chosen so "DELETE EVERYTHING" is meaningfully
    /// harder to fat-finger than "DELETE".
    public var requiredPhrase: String {
        switch self {
        case .deleteLast24h: return "DELETE"
        case .deleteEverything: return "DELETE EVERYTHING"
        }
    }

    /// Pure predicate. Case-sensitive; leading/trailing whitespace is
    /// trimmed so a stray space doesn't lock the user out.
    public func matches(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespaces) == requiredPhrase
    }
}

/// Pure presentation of counts, logical bytes, and measurement completeness.
public enum PrivacyDashboardSummary {
    public static func line(
        summary: SummaryStats?,
        isLoading: Bool = false
    ) -> String {
        guard let s = summary else {
            // Cycle 8.54 copy audit — "No brain data yet" was jargon;
            // the new copy reads as normal English on a fresh install.
            return isLoading ? "Loading…" : "No captures yet."
        }
        let days = s.daysCovered
        let dayLabel = days == 1 ? "1 day" : "\(days) days"
        return
            "Hippocampus has captured \(s.totalEvents) events across "
            + "\(dayLabel)."
    }

    public static func storageTotal(summary: SummaryStats?) -> String {
        guard let storage = summary?.storage else {
            return "Storage breakdown unavailable."
        }
        guard let bytes = storage.reportedTotalBytes else {
            return "Storage total unavailable; measurement incomplete."
        }
        if storage.complete {
            return "Reported local storage: \(formatBytes(bytes))"
        }
        return "Partial storage measurement: \(formatBytes(bytes)) reported; total incomplete."
    }

    public static func storageValue(_ measurement: StorageMeasurement) -> String {
        let value = measurement.logicalBytes.map(formatBytes) ?? "Unavailable"
        switch measurement.status {
        case .complete: return value
        case .missing: return "\(value) (absent)"
        case .unreadable: return "\(value) (unreadable)"
        case .symlink: return "\(value) (symlink skipped)"
        case .unsupported: return "\(value) (unsupported file type or path)"
        case .partial: return "\(value) (partial; entries skipped)"
        case .limitReached: return "\(value) (partial; scan limit reached)"
        case .overflow: return "Unavailable (size overflow)"
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        guard let signed = Int64(exactly: bytes) else {
            return "\(bytes.formatted()) bytes"
        }
        return ByteCountFormatter.string(fromByteCount: signed, countStyle: .file)
    }
}
