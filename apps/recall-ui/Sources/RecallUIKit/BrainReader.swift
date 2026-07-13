// BrainReader.swift — protocol abstracting the brain read surface.
//
// The recall-ui never opens the brain directly; it always goes through
// a `BrainReader`. Two impls exist:
//
//   - `StubBrainReader` (this file) — canned data for headless tests and
//     the v1 demo. No FFI, no SQLCipher, no disk I/O.
//   - `FFIBrainReader` (separate file) — calls the C ABI in
//     `adapters/macos/mci-brain-ffi/` via `MciBrainFFI.swift`. Compiled
//     in P3.9a but does not yet link a non-empty static lib; P3.9b
//     finishes the binding.
//
// Read-only by construction: the protocol has no `put`/`delete`/`mutate`
// surface (ADR-0016 §4.3 + ADR-0017 §5 invariants). Adding one is an
// AGENT_PROTOCOL §5 protected-set change.

import Foundation

/// One hit row the UI renders in the search list or the timeline.
public struct Hit: Sendable, Equatable, Identifiable, Codable {
    public var id: UInt64 { eventId }
    public let eventId: UInt64
    /// Microseconds since UNIX epoch (matches `events.ts_us`).
    public let tsUs: UInt64
    public let appBundleId: String?
    public let windowTitle: String?
    public let url: String?
    /// Truncated OCR snippet (caps at ~280 chars at the FFI boundary).
    public let ocrTextSnippet: String
    /// Where the row came from: "lexical" / "hybrid" / "timeline".
    /// P3.9a: timeline = "timeline"; search results from the stub use
    /// "lexical"; P3.9b adds "hybrid" when HybridRetriever lights up.
    public let source: String
    /// Fused score [0,1] for search; `nil` for plain timeline rows.
    public let score: Float?

    /// Canonical names of the resolver-allowlist entities
    /// (person / org / location / email / phone / url — never a
    /// redacted-token label) this event mentions. Powers the entity-chip
    /// strip on `HitRow` and the detail-pane entity list (cycle 8.35 PR-2).
    ///
    /// Empty when the store has no graph data or the event mentions
    /// nothing in the allowlist. Mirrors the `entities` field on the FFI's
    /// `HitJson` and on the MCP `mci_recall` wire
    /// (`apps/agent/src/mcp/server.rs:302`) — capped at 16 names per hit
    /// (`ENTITY_LIMIT` in `mci-brain-ffi`).
    public let entities: [String]

    /// Cross-app "dot-connect" event ids reachable from this hit's episode
    /// via a `shared_identity` `episode_edge`. Powers the "Related (N)"
    /// flyout in `DetailPaneView` (cycle 8.35 PR-3).
    ///
    /// Empty when the hit's episode has no cross-app link, or when the
    /// store has no `episode_edges` data. Post-cascade only. Mirrors the
    /// `linked_event_ids` field on the FFI's `HitJson` and on the MCP
    /// `mci_recall` wire (`apps/agent/src/mcp/server.rs:303`) — capped
    /// at 16 ids per hit (`LINK_LIMIT` in `mci-brain-ffi`).
    public let linkedEventIds: [UInt64]

    /// Absolute filesystem path to the encrypted keyframe blob captured
    /// alongside this event, or `nil` for events without a keyframe
    /// (Messages / Mail / PageContent-only ingest; legacy events captured
    /// before the P3.6.5 blob writer landed). Mirrors the FFI's
    /// `HitJson.thumbnail_path` (cycle 8.35 PR-4).
    ///
    /// The path is opened by the `HitThumbnail` view in `HitRow`, which
    /// applies a light blur + slight desaturation for defense-in-depth
    /// against over-shoulder viewing. A missing file (stale hex,
    /// user-deleted blob dir) falls back to the placeholder icon —
    /// never a crash.
    ///
    /// **Privacy invariant.** A keyframe blob exists on disk ONLY for
    /// events that cleared cascade-twice (ADR-0016 §4.8). The brain-store
    /// `put_event` wall (`cascade_reason != 0` → rejected) means no
    /// `.suppress`-decided event carries this field. Surfacing the path
    /// here cannot leak a redacted keyframe.
    public let thumbnailPath: String?

    /// Convenience: file URL for the thumbnail, or `nil` when no path
    /// was populated. Purely a derivation from `thumbnailPath` — no I/O.
    public var thumbnailURL: URL? {
        guard let p = thumbnailPath, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    public init(
        eventId: UInt64,
        tsUs: UInt64,
        appBundleId: String?,
        windowTitle: String?,
        url: String?,
        ocrTextSnippet: String,
        source: String,
        score: Float?,
        entities: [String] = [],
        linkedEventIds: [UInt64] = [],
        thumbnailPath: String? = nil
    ) {
        self.eventId = eventId
        self.tsUs = tsUs
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.url = url
        self.ocrTextSnippet = ocrTextSnippet
        self.source = source
        self.score = score
        self.entities = entities
        self.linkedEventIds = linkedEventIds
        self.thumbnailPath = thumbnailPath
    }
}

/// One daily brief — mirrors the Rust `BriefRow` shape backing the
/// `briefs` table (migration 0002). Surfaced to the Brief tab in the
/// Recall UI per `docs/design/brief-viewer-spec.md`.
public struct Brief: Sendable, Equatable, Identifiable, Codable {
    public var id: UInt64 { rowId }
    /// Stable `briefs.id` rowid.
    public let rowId: UInt64
    /// ISO 8601 local date "YYYY-MM-DD".
    public let dateLocal: String
    /// Generation timestamp in microseconds since UNIX epoch.
    public let generatedTsUs: UInt64
    /// Author model identifier (e.g. `"qwen3-1.7b-fp16"`).
    public let modelId: String
    /// Author model version string.
    public let modelVersion: String
    /// Header title.
    public let title: String
    /// Markdown body.
    public let body: String
    /// Word count for the header.
    public let wordCount: UInt32
    /// Number of events the author saw when composing.
    public let sourceEventCount: UInt32

    public init(
        rowId: UInt64,
        dateLocal: String,
        generatedTsUs: UInt64,
        modelId: String,
        modelVersion: String,
        title: String,
        body: String,
        wordCount: UInt32,
        sourceEventCount: UInt32
    ) {
        self.rowId = rowId
        self.dateLocal = dateLocal
        self.generatedTsUs = generatedTsUs
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.title = title
        self.body = body
        self.wordCount = wordCount
        self.sourceEventCount = sourceEventCount
    }
}

/// One privacy-moment card row. Carries ONLY {ts, appBundleId, reasonCode}
/// — never OCR text, never keyframe, never windowTitle/url
/// (ADR-0017 §5.1).
public struct PrivacyMoment: Sendable, Equatable, Identifiable, Codable {
    public var id: String { "\(tsUs)-\(appBundleId ?? "nil")-\(reasonCode)" }
    public let tsUs: UInt64
    public let appBundleId: String?
    public let reasonCode: UInt8

    public init(tsUs: UInt64, appBundleId: String?, reasonCode: UInt8) {
        self.tsUs = tsUs
        self.appBundleId = appBundleId
        self.reasonCode = reasonCode
    }
}

/// Search query options.
public struct SearchOptions: Sendable, Equatable {
    public let text: String
    public let limit: Int
    public let appFilter: String?
    public let timeFromUs: UInt64?
    public let timeToUs: UInt64?
    /// Cycle 8.42 — user-defined entity aliases (`UserDictionary`). Keys
    /// are canonical names, values are the alias list. The recall pipeline
    /// OR-expands the FTS5 query at the FFI boundary so a search for one
    /// spelling also matches events that mention any of the other
    /// spellings. Empty (or nil) = no expansion, byte-identical to the
    /// baseline recall path.
    public let userAliases: [String: [String]]?

    public init(
        text: String,
        limit: Int = 50,
        appFilter: String? = nil,
        timeFromUs: UInt64? = nil,
        timeToUs: UInt64? = nil,
        userAliases: [String: [String]]? = nil
    ) {
        self.text = text
        self.limit = limit
        self.appFilter = appFilter
        self.timeFromUs = timeFromUs
        self.timeToUs = timeToUs
        self.userAliases = userAliases
    }
}

/// One row of the dynamic per-app filter pop-up — a bundle id observed
/// in the brain together with how many events it has produced (within
/// the requested time window). Surface for the recall-UI per-app filter
/// pills (Director-Brain audit, dogfood-v1 gap #1).
public struct ObservedApp: Sendable, Equatable, Identifiable, Codable {
    public var id: String { appBundleId }
    public let appBundleId: String
    public let count: UInt64

    public init(appBundleId: String, count: UInt64) {
        self.appBundleId = appBundleId
        self.count = count
    }
}

/// One row in the Episodes tab — a contiguous run of events in the same
/// app, produced by `core/brain::episode_segmenter` (ADR-0010).
public struct Episode: Sendable, Equatable, Identifiable, Codable {
    public var id: UInt64 { episodeId }
    public let episodeId: UInt64
    public let appBundleId: String?
    /// Microseconds since UNIX epoch (matches `episodes.ts_start`).
    public let tsStartUs: UInt64
    /// Microseconds since UNIX epoch (matches `episodes.ts_end`).
    public let tsEndUs: UInt64
    public let eventCount: UInt64

    public init(
        episodeId: UInt64,
        appBundleId: String?,
        tsStartUs: UInt64,
        tsEndUs: UInt64,
        eventCount: UInt64
    ) {
        self.episodeId = episodeId
        self.appBundleId = appBundleId
        self.tsStartUs = tsStartUs
        self.tsEndUs = tsEndUs
        self.eventCount = eventCount
    }

    /// Convenience: episode duration in seconds (>= 0).
    public var durationSeconds: Double {
        let span = tsEndUs >= tsStartUs ? tsEndUs - tsStartUs : 0
        return Double(span) / 1_000_000.0
    }
}

/// Errors the reader may surface to view models.
public enum BrainReaderError: Error, Equatable {
    case openFailed(String)
    case queryFailed(String)
    case decodeFailed(String)
}

/// Content-free result of a Privacy Dashboard destructive action.
/// Mirrors the FFI's `DeleteResultJson`.
public struct DeleteResult: Sendable, Equatable, Codable {
    /// Rows removed from the `events` table (CASCADE children not counted).
    public let eventsDeleted: UInt64
    /// Whether the post-delete VACUUM succeeded. `false` here still means
    /// the DELETE landed — disk-space reclamation may be pending.
    public let vacuumOk: Bool

    public init(eventsDeleted: UInt64, vacuumOk: Bool) {
        self.eventsDeleted = eventsDeleted
        self.vacuumOk = vacuumOk
    }
}

/// Cycle 8.47 (PR #76 follow-up) — the *mutation* surface for the
/// Privacy Dashboard's destructive actions. Kept SEPARATE from
/// `BrainReader` so:
///
///   1. The read protocol stays read-only-by-type (a consumer that only
///      needs reads takes `BrainReader`, not this).
///   2. `StubBrainReader` (canned) can implement reads without pretending
///      to support delete — headless tests that need delete supply their
///      own mock `PrivacyMutator`.
///   3. The FFI-only, gated escape hatch is easy to grep for and audit.
///
/// Every method here is user-gated by the SwiftUI confirmation flow in
/// `PrivacyDashboard.swift`: typed-word "DELETE" (or "DELETE EVERYTHING")
/// before any of these fire. The wipe path requires a two-step token
/// dance (`prepareWipe` → `wipeBrain(token:)`) with a 60s expiry.
public protocol PrivacyMutator: Sendable {
    /// Delete one event by id.
    func deleteEvent(id: UInt64) async throws -> DeleteResult

    /// Delete every event with `ts_us` in `[startTsUs, endTsUs]`.
    func deleteEventsInRange(
        startTsUs: UInt64,
        endTsUs: UInt64
    ) async throws -> DeleteResult

    /// Issue a wipe-confirmation token. Valid for 60 seconds; a second
    /// `prepareWipe` invalidates the previous token.
    func prepareWipe() async throws -> String

    /// Wipe every user-content row. Requires the token returned by the
    /// most-recent `prepareWipe`.
    func wipeBrain(token: String) async throws -> DeleteResult
}

/// The full read surface the recall-ui consumes. No mutating methods.
public protocol BrainReader: Sendable {
    func search(_ opts: SearchOptions) async throws -> [Hit]
    func recentEvents(limit: Int) async throws -> [Hit]
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment]
    /// Observed apps within the optional time window, sorted by count DESC.
    /// Nil-app rows are excluded.
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp]
    /// Most-recent episodes (sorted by start DESC) from the segmenter.
    func listEpisodes(limit: Int) async throws -> [Episode]

    /// Resolve a batch of event ids into full [`Hit`] rows. Powers the
    /// related-hits flyout in `DetailPaneView` (cycle 8.37 PR-3): given a
    /// hit's `linkedEventIds`, the flyout renders app · time · snippet
    /// for each cross-app sibling — this is the visible dot-connect
    /// surface ("your Safari tab about X is connected to your Slack
    /// message about Y and your VSCode buffer about Z").
    ///
    /// Order in the result follows input order for the ids that resolve;
    /// ids that no longer exist in the store are silently dropped (a
    /// linked-event id can refer to an event later suppressed by the
    /// cascade). Input is capped at 32 ids at the FFI boundary — excess
    /// is truncated silently.
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit]

    // Daily Brief read surface — backs the Brief tab
    // (`docs/design/brief-viewer-spec.md`).

    /// Fetch the brief for one ISO local date (`YYYY-MM-DD`). `nil` when
    /// the store has no brief for that date.
    func briefForDate(_ dateLocal: String) async throws -> Brief?
    /// Fetch the most-recently-generated brief, or `nil` when the store
    /// has no briefs at all.
    func latestBrief() async throws -> Brief?
    /// List up to `limit` brief dates (`YYYY-MM-DD`) most-recent first.
    /// Powers the date selector's `<` / `>` arrows.
    func briefDates(limit: Int) async throws -> [String]

    /// Content-free aggregate — event count, oldest/newest ts,
    /// on-disk byte size. Powers the Privacy Dashboard's top summary
    /// card ("MCI has captured X events across Y days, using Z MB of
    /// encrypted storage"). No row content is exposed.
    func summaryStats() async throws -> SummaryStats
}

/// Content-free brain aggregate — mirrors the FFI's `SummaryStatsJson`.
/// The Privacy Dashboard top card renders `"MCI has captured
/// {totalEvents} events across {daysCovered} days, using
/// {formattedDiskBytes} of encrypted storage."`
public struct SummaryStats: Sendable, Equatable, Codable {
    /// Total rows in `events`. `0` on an empty store.
    public let totalEvents: UInt64
    /// Smallest `events.ts_us`. `nil` on an empty store.
    public let oldestTsUs: UInt64?
    /// Largest `events.ts_us`. `nil` on an empty store.
    public let newestTsUs: UInt64?
    /// On-disk byte count of the SQLCipher brain file.
    public let diskBytes: UInt64

    public init(
        totalEvents: UInt64,
        oldestTsUs: UInt64?,
        newestTsUs: UInt64?,
        diskBytes: UInt64
    ) {
        self.totalEvents = totalEvents
        self.oldestTsUs = oldestTsUs
        self.newestTsUs = newestTsUs
        self.diskBytes = diskBytes
    }

    /// Days spanned by the capture window (`ceil((newest - oldest) /
    /// 86_400_000_000)`), or `0` when the store is empty / all events
    /// share one day.
    public var daysCovered: UInt64 {
        guard let oldest = oldestTsUs, let newest = newestTsUs, newest >= oldest
        else { return 0 }
        let deltaUs = newest - oldest
        let dayUs: UInt64 = 86_400_000_000
        // ceil-divide so a partial day counts as one.
        let d = (deltaUs + dayUs - 1) / dayUs
        // Empty (delta == 0) still means the user has data for "1 day"
        // if totalEvents > 0 — but the caller renders that; here we just
        // report the spanned-day count and let the view decide.
        return max(d, totalEvents > 0 ? 1 : 0)
    }
}

/// In-memory stub reader. Returns deterministic canned data so the
/// SwiftUI scenes have something to render in v1 and the unit tests
/// can assert against known rows. **Never** runs in a release build —
/// the executable target's launch path wires `FFIBrainReader` once
/// P3.9b lands.
public struct StubBrainReader: BrainReader {
    /// Canned demo corpus. Stable order so tests can assert on it.
    ///
    /// The three rows are wired so the cross-hit link topology is
    /// realistic — hit 101 ↔ hit 102 (both mention "MCI"), hit 102 ↔ hit
    /// 103 (both mention "MCI"). This matches the "same topic showed up
    /// across Safari + VSCode + Slack over the past 3 days" WOW example
    /// in `docs/research/2026-07-12-recall-ui-audit.md` §7.
    public static let demoHits: [Hit] = [
        Hit(
            eventId: 101,
            tsUs: 1_736_000_000_000_000,
            appBundleId: "com.apple.Safari",
            windowTitle: "Apple — Privacy",
            url: "https://apple.com/privacy/",
            ocrTextSnippet:
                "Privacy is a fundamental human right. Your data is yours.",
            source: "lexical",
            score: 0.91,
            entities: ["Apple", "privacy"],
            linkedEventIds: [102]
        ),
        Hit(
            eventId: 102,
            tsUs: 1_736_000_120_000_000,
            appBundleId: "com.microsoft.VSCode",
            windowTitle: "lib.rs — mci",
            url: nil,
            ocrTextSnippet: "pub trait Chunker: Send + Sync { fn chunk(&self ...",
            source: "lexical",
            score: 0.74,
            entities: ["MCI", "Chunker"],
            linkedEventIds: [101, 103]
        ),
        Hit(
            eventId: 103,
            tsUs: 1_736_000_240_000_000,
            appBundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "#general — MCI",
            url: nil,
            ocrTextSnippet: "shipping P3.9 today — recall UI v1",
            source: "lexical",
            score: 0.62,
            entities: ["MCI", "recall-ui"],
            linkedEventIds: [102]
        ),
    ]

    /// Canned episodes. Two Safari segments around a single VSCode block.
    public static let demoEpisodes: [Episode] = [
        Episode(
            episodeId: 3,
            appBundleId: "com.tinyspeck.slackmacgap",
            tsStartUs: 1_736_000_240_000_000,
            tsEndUs: 1_736_000_290_000_000,
            eventCount: 1
        ),
        Episode(
            episodeId: 2,
            appBundleId: "com.microsoft.VSCode",
            tsStartUs: 1_736_000_120_000_000,
            tsEndUs: 1_736_000_180_000_000,
            eventCount: 1
        ),
        Episode(
            episodeId: 1,
            appBundleId: "com.apple.Safari",
            tsStartUs: 1_736_000_000_000_000,
            tsEndUs: 1_736_000_060_000_000,
            eventCount: 1
        ),
    ]

    /// Canned daily briefs for headless tests / the v1 demo. Stable
    /// shape so view-model tests can assert on it. Dates are in ISO
    /// form so they sort lexically.
    public static let demoBriefs: [Brief] = [
        Brief(
            rowId: 1,
            dateLocal: "2026-05-21",
            generatedTsUs: 1_716_343_380_000_000,
            modelId: "qwen3-1.7b-fp16",
            modelVersion: "demo",
            title: "Thursday, May 21, 2026",
            body: """
            ## Highlights

            Spent most of the day shipping the brief viewer UI scaffold.

            ## Deep work

            ~3 uninterrupted hours in VSCode on the SwiftUI Brief tab.

            ## Context switches

            Safari → VSCode → Terminal → Slack, ~14 switches.

            ## Notable URLs

            - apple.com/privacy/
            - github.com/amyjainberkeley/hippocampus/pull/175

            ## Unfinished threads

            Two open Safari tabs at end of day.
            """,
            wordCount: 56,
            sourceEventCount: 198
        ),
        Brief(
            rowId: 2,
            dateLocal: "2026-05-22",
            generatedTsUs: 1_716_429_780_000_000,
            modelId: "qwen3-1.7b-fp16",
            modelVersion: "demo",
            title: "Friday, May 22, 2026",
            body: """
            ## Highlights

            Closed the Qwen3 conversion env fix and unblocked the brief
            author pipeline.

            ## Deep work

            ~4 hours in VSCode and Terminal on `scripts/convert_brief_model.py`.

            ## Context switches

            Steady work; ~7 switches across the day.

            ## Notable URLs

            - github.com/QwenLM/Qwen3
            - github.com/amyjainberkeley/hippocampus/pull/173

            ## Unfinished threads

            One Safari tab pinned for the model card.
            """,
            wordCount: 70,
            sourceEventCount: 142
        ),
    ]

    /// Canned privacy moments. Reason codes span the ADR-0017 §5.2 table.
    public static let demoPrivacyMoments: [PrivacyMoment] = [
        PrivacyMoment(
            tsUs: 1_736_000_060_000_000,
            appBundleId: "com.1password.app",
            reasonCode: 4
        ),
        PrivacyMoment(
            tsUs: 1_736_000_180_000_000,
            appBundleId: "com.apple.Terminal",
            reasonCode: 3
        ),
        PrivacyMoment(
            tsUs: 1_736_000_300_000_000,
            appBundleId: nil,
            reasonCode: 7
        ),
    ]

    public init() {}

    public func search(_ opts: SearchOptions) async throws -> [Hit] {
        let needle = opts.text.lowercased()
        let isWildcard = opts.text == "*"
        guard !opts.text.isEmpty else { return [] }
        var matches = Self.demoHits
        if !isWildcard {
            matches = matches.filter { h in
                h.ocrTextSnippet.lowercased().contains(needle)
                    || (h.windowTitle?.lowercased().contains(needle) ?? false)
                    || (h.url?.lowercased().contains(needle) ?? false)
            }
        }
        if let app = opts.appFilter {
            matches = matches.filter { $0.appBundleId == app }
        }
        if let from = opts.timeFromUs {
            matches = matches.filter { $0.tsUs >= from }
        }
        if let to = opts.timeToUs {
            matches = matches.filter { $0.tsUs <= to }
        }
        return Array(matches.prefix(opts.limit))
    }

    public func recentEvents(limit: Int) async throws -> [Hit] {
        Array(
            Self.demoHits
                .sorted { $0.tsUs > $1.tsUs }
                .prefix(max(0, limit))
        )
    }

    public func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] {
        Array(
            Self.demoPrivacyMoments
                .sorted { $0.tsUs > $1.tsUs }
                .prefix(max(0, limit))
        )
    }

    public func listObservedApps(
        limit: Int,
        timeFromUs: UInt64?
    ) async throws -> [ObservedApp] {
        var counts: [String: UInt64] = [:]
        for hit in Self.demoHits {
            if let from = timeFromUs, hit.tsUs < from { continue }
            guard let app = hit.appBundleId else { continue }
            counts[app, default: 0] += 1
        }
        let rows =
            counts
            .map { ObservedApp(appBundleId: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.appBundleId < $1.appBundleId
            }
        return Array(rows.prefix(max(0, limit)))
    }

    public func listEpisodes(limit: Int) async throws -> [Episode] {
        Array(
            Self.demoEpisodes
                .sorted { $0.tsStartUs > $1.tsStartUs }
                .prefix(max(0, limit))
        )
    }

    public func briefForDate(_ dateLocal: String) async throws -> Brief? {
        Self.demoBriefs.first { $0.dateLocal == dateLocal }
    }

    public func latestBrief() async throws -> Brief? {
        Self.demoBriefs.max { $0.generatedTsUs < $1.generatedTsUs }
    }

    public func briefDates(limit: Int) async throws -> [String] {
        Array(
            Self.demoBriefs
                .sorted { $0.dateLocal > $1.dateLocal }
                .prefix(max(0, limit))
                .map(\.dateLocal)
        )
    }

    /// Silent truncation at 32 mirrors the FFI's `EVENTS_BY_IDS_CAP`.
    /// Ids that don't match any demo hit are dropped so the stub matches
    /// the FFI's "linked event may have been suppressed" semantics.
    public func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        let byId = Dictionary(uniqueKeysWithValues: Self.demoHits.map { ($0.eventId, $0) })
        return ids.prefix(32).compactMap { byId[$0] }
    }

    /// Aggregate the canned corpus for the dashboard preview. Realistic
    /// enough for the summary card snapshot test; not a live disk read.
    public func summaryStats() async throws -> SummaryStats {
        let ts = Self.demoHits.map(\.tsUs)
        return SummaryStats(
            totalEvents: UInt64(Self.demoHits.count),
            oldestTsUs: ts.min(),
            newestTsUs: ts.max(),
            diskBytes: 12_582_912  // ~12 MB — matches a plausible ~3-day capture.
        )
    }
}
