#if DEBUG
import Foundation

/// Debug-only fixtures for drawing Overview and You in every state, off
/// screen (`RecallPreviewRenderer`). Everything comes from the contract
/// samples (persona Sam, Monday 2026-10-12, 14:37:05 in UTC−7), changed only
/// as each state needs. No agent, no file and no memory is read.
public struct OverviewPreviewUnderstanding: UnderstandingReader {
    public enum State: String, CaseIterable, Sendable {
        /// Today, a day of work, and an AI tool that starts with it.
        case today
        /// Today, nothing saved yet.
        case todayEmpty
        /// Another day, with work.
        case pastDay
        /// Another day, nothing saved.
        case pastDayEmpty
        /// Apple Intelligence is off: titles from windows, nothing noticed,
        /// no summary, and the You page's footer line.
        case modelOff
        /// No AI tool starts its sessions with what Hippocampus knows.
        case noAITool
        /// The day and the page cannot be read.
        case unavailable
        /// You, nothing learned yet (the model is on).
        case nothingLearned
        /// You, nothing learned, and Apple Intelligence is off.
        case nothingLearnedModelOff
    }

    public let state: State

    public init(_ state: State) {
        self.state = state
    }

    public func overview(_ day: UnderstandingDay) async throws -> DayOverview {
        switch state {
        case .unavailable:
            throw UnderstandingError.unavailable
        case .todayEmpty, .nothingLearned, .nothingLearnedModelOff:
            return try Self.edited(PreviewUnderstandingFixtures.overview) { json in
                Self.empty(&json)
            }
        case .pastDayEmpty:
            return try Self.edited(PreviewUnderstandingFixtures.overview) { json in
                Self.empty(&json)
                Self.past(&json)
            }
        case .pastDay:
            return try Self.edited(PreviewUnderstandingFixtures.overview) { json in
                Self.past(&json)
            }
        case .modelOff:
            return try Self.edited(PreviewUnderstandingFixtures.overview) { json in
                json["model_status"] = Self.modelOffStatus
                json["account"] = NSNull()
                // With the model off nothing new is written: every title is
                // the longest window's, and nothing is noticed.
                if var blocks = json["blocks"] as? [[String: Any]] {
                    for index in blocks.indices {
                        let windows = blocks[index]["windows"] as? [[String: Any]] ?? []
                        let title = (windows.first?["title"] as? String) ?? (windows.first?["name"] as? String) ?? "Untitled"
                        blocks[index]["title"] = title
                        blocks[index]["written_by"] = "measured"
                        blocks[index]["noticed"] = NSNull()
                    }
                    json["blocks"] = blocks
                }
            }
        case .noAITool:
            return try Self.edited(PreviewUnderstandingFixtures.overview) { json in
                if var knows = json["ai_knows"] as? [String: Any] {
                    knows["hook_installed"] = false
                    json["ai_knows"] = knows
                }
            }
        case .today:
            return try Self.decode(DayOverview.self, PreviewUnderstandingFixtures.overview)
        }
    }

    public func modelPage() async throws -> ModelPage {
        switch state {
        case .unavailable:
            throw UnderstandingError.unavailable
        case .nothingLearned, .todayEmpty, .pastDayEmpty:
            return try Self.edited(PreviewUnderstandingFixtures.modelPage, as: ModelPage.self) { json in
                json["shared"] = []
                json["kept_back"] = []
                json["not_seen_lately"] = []
                json["recent_work"] = []
            }
        case .nothingLearnedModelOff:
            return try Self.edited(PreviewUnderstandingFixtures.modelPage, as: ModelPage.self) { json in
                json["shared"] = []
                json["kept_back"] = []
                json["not_seen_lately"] = []
                json["recent_work"] = []
                json["model_status"] = Self.modelOffStatus
            }
        case .modelOff:
            return try Self.edited(PreviewUnderstandingFixtures.modelPage, as: ModelPage.self) { json in
                json["model_status"] = Self.modelOffStatus
            }
        case .today, .pastDay, .noAITool:
            return try Self.decode(ModelPage.self, PreviewUnderstandingFixtures.modelPage)
        }
    }

    public func ask(_ question: String, app: String?, title: String?, now: String?) async throws -> AskAnswer {
        try Self.decode(AskAnswer.self, PreviewUnderstandingFixtures.answer)
    }

    public func invalidate() async {}
    public func shutdown() async {}

    private static var modelOffStatus: [String: Any] {
        ["state": "unavailable", "reason": "apple_intelligence_off", "checked_us": 1_791_839_440_000_000]
    }

    /// A day with nothing saved, as the agent writes one.
    private static func empty(_ json: inout [String: Any]) {
        json["blocks"] = []
        json["gaps"] = []
        json["kinds"] = []
        json["facts"] = []
        json["searches"] = []
        json["strip"] = NSNull()
        json["account"] = NSNull()
        json["basis"] = "estimated"
        json["now"] = ["state": "none"]
        if var knows = json["ai_knows"] as? [String: Any] {
            knows["recent_work"] = []
            json["ai_knows"] = knows
        }
    }

    /// The same day, read as another day: no Right now card.
    private static func past(_ json: inout [String: Any]) {
        json["is_today"] = false
        json["now"] = ["state": "none"]
        if var blocks = json["blocks"] as? [[String: Any]] {
            for index in blocks.indices { blocks[index]["in_progress"] = false }
            json["blocks"] = blocks
        }
    }

    private static func edited(
        _ sample: String,
        _ edit: (inout [String: Any]) -> Void
    ) throws -> DayOverview {
        try edited(sample, as: DayOverview.self, edit)
    }

    private static func edited<T: Decodable>(
        _ sample: String,
        as type: T.Type,
        _ edit: (inout [String: Any]) -> Void
    ) throws -> T {
        guard var json = try JSONSerialization.jsonObject(with: Data(sample.utf8)) as? [String: Any] else {
            throw UnderstandingError.malformed
        }
        edit(&json)
        let data = try JSONSerialization.data(withJSONObject: json)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw UnderstandingError.malformed
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw UnderstandingError.malformed
        }
    }
}

/// Debug-only moments behind the samples' sessions, for drawing Overview: one
/// moment per window the overview names, each with a stored screenshot path
/// under `/preview/keyframes/`, which only the preview's thumbnail provider
/// answers. Searches by time return the moments inside the range.
public struct OverviewPreviewBrainReader: BrainReader {
    /// What a preview screenshot shows: the window's app and title.
    public struct Window: Equatable, Sendable {
        public let app: String
        public let title: String
        public let kind: WorkKind
    }

    public let moments: [Hit]
    /// Screenshot path to the window it shows.
    public let windows: [String: Window]

    public init() {
        let overview = (try? JSONDecoder().decode(DayOverview.self, from: Data(PreviewUnderstandingFixtures.overview.utf8)))
        var hits: [Hit] = []
        var windows: [String: Window] = [:]
        for block in overview?.blocks ?? [] {
            var ids: [(Int64, BlockWindow?)] = block.windows.compactMap { window in window.eventId.map { ($0, window) } }
            if let shot = block.screenshotEventId, !ids.contains(where: { $0.0 == shot }) {
                ids.insert((shot, block.windows.first), at: 0)
            }
            if let open = block.openEventId, !ids.contains(where: { $0.0 == open }) {
                ids.append((open, block.windows.first))
            }
            for (offset, entry) in ids.enumerated() {
                guard let id = UInt64(exactly: entry.0) else { continue }
                let window = entry.1
                let span = max(1, block.endUs - block.startUs)
                let ts = block.startUs + span * Int64(offset + 1) / Int64(ids.count + 1)
                let path = "/preview/keyframes/\(id).bin"
                let title = window?.title ?? block.title
                windows[path] = Window(app: window?.name ?? "", title: title, kind: block.kind)
                hits.append(Hit(eventId: id, tsUs: UInt64(ts), appBundleId: window?.bundleId, windowTitle: title,
                                url: window?.host.map { "https://\($0)/" }, ocrTextSnippet: title,
                                source: "timeline", score: nil, thumbnailPath: path, sourceKind: "screen_ocr"))
            }
        }
        moments = hits.sorted { $0.tsUs < $1.tsUs }
        self.windows = windows
    }

    public func search(_ opts: SearchOptions) async throws -> [Hit] {
        guard opts.browse else { return [] }
        return Array(moments.filter { hit in
            (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
        }.reversed().prefix(opts.limit))
    }

    public func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        moments.filter { ids.contains($0.eventId) }
    }

    public func recentEvents(limit: Int) async throws -> [Hit] { Array(moments.reversed().prefix(limit)) }
    public func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    public func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    public func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    public func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    public func latestBrief() async throws -> Brief? { nil }
    public func briefDates(limit: Int) async throws -> [String] { [] }
    public func summaryStats() async throws -> SummaryStats { throw BrainReaderError.queryFailed("preview") }
}
#endif
