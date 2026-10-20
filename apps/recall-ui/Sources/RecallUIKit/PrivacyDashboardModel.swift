// PrivacyDashboardModel.swift — pure-value model backing the ⌘7
// Privacy Dashboard (cycle 8.46). Lives in the library target so
// SwiftUI-free unit tests can pin filter compose + confirmation
// matcher byte-exact.
//
// Read-only + protected-set discipline: this file contains ZERO
// mutation entry points. The destructive-action UI stubs in the
// executable target route through this file's `DestructivePrivacyAction`
// enum only to render text — the actual wipe pathway is deferred to
// the follow-up cycle-8.47 PR (mutation FFI + security review).

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
    /// "Forget the Last 24 Hours…": everything since this time yesterday
    /// (SPEC 3.9, 3.11). One verb, Forget, for what a person removes.
    case forgetLast24h
    /// "Delete Everything…": the whole memory. Delete only for wiping it all.
    case deleteEverything

    /// Exact phrase the user must type to enable the "Confirm" button.
    /// Case-sensitive. Chosen so "DELETE EVERYTHING" is meaningfully
    /// harder to fat-finger than "FORGET".
    public var requiredPhrase: String {
        switch self {
        case .forgetLast24h: return "FORGET"
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
            // Plain English on a fresh install: "memory" and "moments" are
            // the product's own words, not "brain"/"captures" (launch copy).
            return isLoading ? "Loading…" : "Nothing saved yet."
        }
        let days = s.daysCovered
        let dayLabel = days == 1 ? "1 day" : "\(days) days"
        return
            "Hippocampus has saved \(s.totalEvents) moments across "
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

// MARK: - The Privacy page (SPEC 3.9)

/// What the Privacy page says is kept: "41,208 moments from 38 days ·
/// Screenshots 1.4 GB · Text and search 610 MB". The sizes show once
/// they are measured, each only when its measurement is whole.
public enum PrivacyKept {
    public static func line(_ summary: SummaryStats?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let summary, summary.totalEvents > 0 else { return nil }
        var parts = [LibraryCopy.Privacy.kept(moments: summary.totalEvents, days: summary.daysCovered, locale: locale)]
        if let storage = summary.storage {
            if storage.managedBlobs.status == .complete || storage.managedBlobs.status == .missing,
               let bytes = storage.managedBlobs.logicalBytes, bytes > 0 {
                parts.append(LibraryCopy.Privacy.screenshots(size(bytes)))
            }
            let text = storage.textMeasurement
            if text.status == .complete, let bytes = text.logicalBytes, bytes > 0 {
                parts.append(LibraryCopy.Privacy.textAndSearch(size(bytes)))
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "1.4 GB", "610 MB", as Finder writes a file's size.
    public static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

/// How much the pictures of windows beside the one in front use (SPEC 6.5),
/// from the content-free file the agent's worker writes beside the capture
/// status: sizes, a count and when, never what is in them.
public struct PicturesUsage: Equatable, Sendable, Decodable {
    /// Bytes the side pictures use now.
    public let sideBytes: UInt64
    /// The most they may use, as Preferences sets it.
    public let budgetBytes: UInt64?
    /// Whether new side pictures are kept. Off with pictures still kept
    /// shows the line too, until they are forgotten or thinned.
    public let enabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case sideBytes = "side_bytes"
        case budgetBytes = "side_budget_bytes"
        /// The agent's word for the switch (`retention_worker.rs`, schema 1).
        case picturesOn = "side_pictures_on"
        case enabled = "side_enabled"
    }

    public init(sideBytes: UInt64, budgetBytes: UInt64?, enabled: Bool?) {
        self.sideBytes = sideBytes
        self.budgetBytes = budgetBytes
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sideBytes = try values.decode(UInt64.self, forKey: .sideBytes)
        budgetBytes = try values.decodeIfPresent(UInt64.self, forKey: .budgetBytes)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .picturesOn)
            ?? values.decodeIfPresent(Bool.self, forKey: .enabled)
    }

    /// The page's line: "Pictures of windows beside the one you're using:
    /// 640 MB of 2 GB." Nil when the feature was never on and nothing is kept.
    public var line: String? {
        guard enabled == true || sideBytes > 0 else { return nil }
        return LibraryCopy.Privacy.sidePictures(PrivacyKept.size(sideBytes), of: budgetBytes.map(PrivacyKept.size))
    }

    public static func decode(_ data: Data) -> PicturesUsage? {
        try? JSONDecoder().decode(PicturesUsage.self, from: data)
    }

    /// `pictures-usage.json` beside the capture status: the development
    /// database's folder when one is set, else Application Support/MCI.
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> PicturesUsage? {
        let url = MemoryFolder.url(environment: environment).appendingPathComponent("pictures-usage.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
        return decode(data)
    }
}

/// The Privacy page's Activity: what was forgotten or exported, and when,
/// from the audit log, which keeps counts and ranges, never content.
public enum PrivacyActivity {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let when: String
        public let what: String
    }

    /// Newest first, forgets and exports only.
    public static func rows(_ entries: [AuditEntry], now: Date, calendar: Calendar,
                            locale: Locale = .autoupdatingCurrent) -> [Row] {
        entries.compactMap { entry in
            guard let what = what(entry) else { return nil }
            return Row(id: entry.id, when: when(entry.timestamp, now: now, calendar: calendar, locale: locale),
                       what: what)
        }
    }

    /// "Forgot the last 10 minutes", "Forgot 3 moments", "Exported everything".
    public static func what(_ entry: AuditEntry) -> String? {
        typealias Words = LibraryCopy.Privacy
        let count = entry.details["count"].flatMap(Int.init)
        switch entry.action {
        case .deleteEvent:
            return Words.forgotMoments(count ?? 1)
        case .deleteEventsInRange:
            if entry.details["range"] == "today" { return Words.forgotToday }
            if let minutes = entry.details["range_minutes"].flatMap(Int.init) {
                return minutes == 60 ? Words.forgotLastHour : Words.forgotLastMinutes(minutes)
            }
            if let hours = entry.details["range_hours"].flatMap(Int.init) {
                return hours == 1 ? Words.forgotLastHour : Words.forgotLastHours(hours)
            }
            return Words.forgotMoments(count ?? 0)
        case .wipeBrain:
            return Words.deletedEverything
        case .exportJson:
            return Words.exportedEverything
        case .appLaunched, .permissionsGranted, .permissionsRevoked, .settingsChange:
            return nil
        }
    }

    /// "Today 3:30 PM", "Yesterday 6:12 PM", "Fri 5:40 PM", "Oct 6 9:12 AM".
    public static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var calendar = calendar
        calendar.locale = locale
        let clock = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let day: String
        switch days {
        case 0: day = LibraryCopy.today
        case 1: day = LibraryCopy.yesterday
        case 2..<7:
            day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated))
        default:
            day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day())
        }
        return "\(day) \(clock)"
    }
}
