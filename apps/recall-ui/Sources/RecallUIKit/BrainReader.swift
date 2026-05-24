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

    public init(
        eventId: UInt64,
        tsUs: UInt64,
        appBundleId: String?,
        windowTitle: String?,
        url: String?,
        ocrTextSnippet: String,
        source: String,
        score: Float?
    ) {
        self.eventId = eventId
        self.tsUs = tsUs
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.url = url
        self.ocrTextSnippet = ocrTextSnippet
        self.source = source
        self.score = score
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

    public init(
        text: String,
        limit: Int = 50,
        appFilter: String? = nil,
        timeFromUs: UInt64? = nil,
        timeToUs: UInt64? = nil
    ) {
        self.text = text
        self.limit = limit
        self.appFilter = appFilter
        self.timeFromUs = timeFromUs
        self.timeToUs = timeToUs
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
}

/// In-memory stub reader. Returns deterministic canned data so the
/// SwiftUI scenes have something to render in v1 and the unit tests
/// can assert against known rows. **Never** runs in a release build —
/// the executable target's launch path wires `FFIBrainReader` once
/// P3.9b lands.
public struct StubBrainReader: BrainReader {
    /// Canned demo corpus. Stable order so tests can assert on it.
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
            score: 0.91
        ),
        Hit(
            eventId: 102,
            tsUs: 1_736_000_120_000_000,
            appBundleId: "com.microsoft.VSCode",
            windowTitle: "lib.rs — mci",
            url: nil,
            ocrTextSnippet: "pub trait Chunker: Send + Sync { fn chunk(&self ...",
            source: "lexical",
            score: 0.74
        ),
        Hit(
            eventId: 103,
            tsUs: 1_736_000_240_000_000,
            appBundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "#general — MCI",
            url: nil,
            ocrTextSnippet: "shipping P3.9 today — recall UI v1",
            source: "lexical",
            score: 0.62
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
}
