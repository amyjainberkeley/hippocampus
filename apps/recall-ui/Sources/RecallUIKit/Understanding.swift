import Foundation

// What the agent understands about the person's day and about them, as the
// window reads it: `mci-agent overview --json` (Overview), `mci-agent model
// --page --json` (You), `mci-agent sessions --json`, and the `mci_ask` answer.
//
// The shapes are the contract files written for this round
// (`work/contract/overview.md`, `model-page.md`), not the specs' drafts.
// Decoding is tolerant, because the agent may add keys and values without a
// version change: unknown keys are ignored, an unknown enum value takes the
// fallback the contract names, a missing list is empty, and one malformed
// element drops only itself. Times and durations are `_us` integers; a
// sentence that needs one carries `{name}` placeholders the window fills in
// the person's own format (RULINGS I4). Every string a person reads passes
// `ReadableText.guarded`, so no header or U+001E reaches the screen (T14).

// MARK: - Shared shapes

/// A sentence whose clock times and durations are filled in on this Mac, in
/// the person's own format (RULINGS I4). `text(locale:timeZone:)` fills it.
public struct TemplateText: Equatable, Sendable {
    public internal(set) var template: String
    /// Placeholder name to a time, microseconds since the epoch.
    public internal(set) var times: [String: Int64]
    /// Placeholder name to a length of time, in microseconds.
    public internal(set) var durations: [String: Int64]

    public init(template: String, times: [String: Int64] = [:], durations: [String: Int64] = [:]) {
        self.template = template
        self.times = times
        self.durations = durations
    }
}

public extension TemplateText {
    /// The sentence with each `{name}` filled in the person's own format: a
    /// time as a clock time, a length of time as a duration. `{{` and `}}` are
    /// literal braces, and a placeholder with no value stays as written
    /// (contract overview.md section 2).
    func text(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if character == "{" || character == "}", next < template.endIndex, template[next] == character {
                result.append(character)
                index = template.index(after: next)
                continue
            }
            if character == "{", let close = template[next...].firstIndex(of: "}") {
                let name = String(template[next..<close])
                let isName = !name.isEmpty && name.unicodeScalars.allSatisfy {
                    (0x61...0x7A).contains($0.value) || $0 == "_"
                }
                if isName, let us = times[name] {
                    result += Formatters.clockTime(us: us, locale: locale, timeZone: timeZone)
                    index = template.index(after: close)
                    continue
                }
                if isName, let us = durations[name] {
                    result += Formatters.duration(us: us, locale: locale)
                    index = template.index(after: close)
                    continue
                }
            }
            result.append(character)
            index = next
        }
        return result
    }
}

/// Whether the on-device model can write: shared by the overview and the You page.
public struct ModelStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case available, unavailable, unknown
    }

    public let state: State
    /// The reason code, only when `state` is `unavailable`.
    public let reason: String?
    public let checkedUs: Int64?

    public static let unknown = ModelStatus(state: .unknown, reason: nil, checkedUs: nil)

    /// Why the model cannot write, in the words the window has for it.
    public var unavailableReason: ModelUnavailableReason? {
        state == .unavailable ? ModelUnavailableReason(code: reason) : nil
    }
}

/// Why answers or the model's writing are missing. Codes the window has no
/// words for read as `notAvailable` (contract overview.md section 4).
public enum ModelUnavailableReason: Equatable, Sendable {
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    /// Neither Apple Intelligence nor a model server on this Mac can write,
    /// or the model server chosen cannot (`needs_apple_intelligence_or_local_model`,
    /// `local_*`).
    case needsAModel
    case notAvailable

    public init(code: String?) {
        switch code {
        case "apple_intelligence_off": self = .appleIntelligenceOff
        case "device_not_eligible": self = .deviceNotEligible
        case "model_not_ready": self = .modelNotReady
        case "needs_apple_intelligence_or_local_model": self = .needsAModel
        case let code? where code.hasPrefix("local_"): self = .needsAModel
        default: self = .notAvailable
        }
    }
}

/// The kind of work a session was: decides its colour.
public enum WorkKind: String, CaseIterable, Sendable {
    case communication, meetings, code, writing, research, design, ai, planning, media, other
}

/// A search made on a page that carried it.
public struct DaySearch: Equatable, Sendable {
    public let query: String
    /// `google`, `github`, …; empty when there was none.
    public let engine: String
    public let tsUs: Int64
    public let eventId: Int64?
    public let url: String?
}

/// What a session's or the right-now card's primary action opens.
public struct Reopen: Equatable, Sendable {
    /// An http or https page, when the moment had one.
    public let url: String?
    public let bundleId: String
    public let appName: String
}

// MARK: - The day overview (`mci-agent overview --json`)

public struct DayOverview: Equatable, Sendable {
    public enum Basis: String, Sendable {
        /// Activity samples exist for the day.
        case measured
        /// Time estimated from saved moments.
        case estimated
    }

    public let version: Int
    /// The local day, `YYYY-MM-DD`.
    public let date: String
    public let isToday: Bool
    /// The agent's clock when it answered: relative times are computed from it.
    public let nowUs: Int64
    public let tzOffsetSecs: Int
    public let dayStartUs: Int64
    /// Exclusive.
    public let dayEndUs: Int64
    public let basis: Basis
    /// The day had more moments than the read limit: its earliest part is
    /// missing, so the space before the first session is not "Nothing saved".
    public let truncated: Bool
    public internal(set) var modelStatus: ModelStatus
    public let now: RightNow
    /// Nil when the day has no sessions.
    public let strip: DayStrip?
    /// The day's sessions, oldest first.
    public let blocks: [DayBlock]
    public let gaps: [DayGap]
    /// The legend, computed from `blocks`.
    public let kinds: [LegendKind]
    public let facts: [DayFact]
    /// Newest first.
    public let searches: [DaySearch]
    /// The day's summary, written by a model; nil without one.
    public internal(set) var account: DayAccount?
    public internal(set) var aiKnows: AIKnows
}

/// The right-now card.
public struct RightNow: Equatable, Sendable {
    public enum State: String, Sendable {
        case inProgress = "in_progress"
        case lastSaved = "last_saved"
        case none
    }

    public let state: State
    /// `inProgress` only: the start of the run of touching sessions ("Now · since {time}").
    public let sinceUs: Int64?
    public let startUs: Int64?
    /// The newest saved moment ("Last saved {time}").
    public let lastSavedUs: Int64?
    /// The session in `blocks`, or nil when it is from before midnight.
    public let blockId: Int64?
    public let title: String?
    public let writtenBy: String?
    public let appName: String?
    public let openEventId: Int64?
    public let reopen: Reopen?

    public static let nothing = RightNow(
        state: .none, sinceUs: nil, startUs: nil, lastSavedUs: nil, blockId: nil,
        title: nil, writtenBy: nil, appName: nil, openEventId: nil, reopen: nil
    )
}

public struct DayStrip: Equatable, Sendable {
    public let startUs: Int64
    public let endUs: Int64
}

/// Time between two sessions with nothing saved.
public struct DayGap: Equatable, Sendable {
    public let startUs: Int64
    public let endUs: Int64
}

/// One session as a person sees it on the day strip.
public struct DayBlock: Equatable, Sendable, Identifiable {
    /// The session's own start. Provisional for a session with no note yet:
    /// keep a selection by time overlap, never by id (RULINGS I2).
    public let id: Int64
    public let provisional: Bool
    public let startUs: Int64
    public let endUs: Int64
    public let inProgress: Bool
    /// Starts less than five minutes after the previous session ends.
    public let touchesPrevious: Bool
    public let title: String
    /// `measured`, or the model that wrote `title`.
    public let writtenBy: String
    public let kind: WorkKind
    public let kindLabel: String
    /// The largest kind holds under half of the session.
    public let mixed: Bool
    public let kinds: [KindShare]
    public let apps: [AppShare]
    public let windows: [BlockWindow]
    /// At most two, ready to fill.
    public let sentences: [DaySentence]
    /// Oldest first.
    public let searches: [DaySearch]
    public let screenshotEventId: Int64?
    /// The newest saved moment: "Show in History" selects it.
    public let openEventId: Int64?
    public let reopen: Reopen?
    /// What a model wrote about the session, for "What Hippocampus noticed".
    public let noticed: Noticed?
}

public struct KindShare: Equatable, Sendable {
    public let kind: WorkKind
    public let kindLabel: String
    public let heldUs: Int64
}

public struct AppShare: Equatable, Sendable {
    public let bundleId: String
    public let name: String
    public let heldUs: Int64
}

public struct BlockWindow: Equatable, Sendable {
    public let bundleId: String
    public let name: String
    public let title: String?
    public let host: String?
    public let heldUs: Int64
    public let eventId: Int64?
}

/// A sentence about a session: `switched_between` or `reworded_search`.
/// Any other id is shown as written.
public struct DaySentence: Equatable, Sendable {
    public let id: String
    public let text: TemplateText
}

public struct Noticed: Equatable, Sendable {
    public let text: String
    public let writtenBy: String
}

/// One entry of the legend.
public struct LegendKind: Equatable, Sendable {
    public let kind: WorkKind
    public let kindLabel: String
    public let durationUs: Int64
}

/// One fact about the day, with what clicking it does.
public struct DayFact: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case active, longest, returned, searched, other
    }

    public let kind: Kind
    public let text: TemplateText
    public let action: FactAction?
}

public struct FactAction: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case selectBlocks = "select_blocks"
        case showSearches = "show_searches"
        case none
    }

    public let kind: Kind
    /// For `selectBlocks`: the sessions to select, oldest first.
    public let blockIds: [Int64]
}

/// The day's summary, behind "Summary" (RULINGS I11).
public struct DayAccount: Equatable, Sendable {
    public let headline: String
    public let narrative: String
    /// The model that wrote it, for "Written on this Mac by {writer}".
    public let writtenBy: String
    public let generatedUs: Int64?
}

/// What a connected AI is given right now without asking, line for line.
public struct AIKnows: Equatable, Sendable {
    /// "Recent work", newest first, each with `{start}` and `{end}`.
    public let recentWork: [TemplateText]
    /// "About the user", in the order sent.
    public internal(set) var aboutYou: [AboutYouLine]
    /// A session hook is installed for at least one AI tool; without one
    /// nothing is sent at session start, so the window offers "Connect".
    public let hookInstalled: Bool

    public static let nothing = AIKnows(recentWork: [], aboutYou: [], hookInstalled: false)
}

public struct AboutYouLine: Equatable, Sendable, Identifiable {
    /// The item's id on the You page.
    public let id: Int64
    public let text: String
}

// MARK: - The You page (`mci-agent model --page --json`)

public struct ModelPage: Equatable, Sendable {
    public let version: Int
    public let nowUs: Int64
    public internal(set) var modelStatus: ModelStatus
    /// "Recent work", exactly as a new session of a connected AI gets it.
    public let recentWork: [TemplateText]
    /// "What your AI can be told about you".
    public internal(set) var shared: [ModelItem]
    /// "Not sent unless your AI looks it up".
    public internal(set) var keptBack: [ModelItem]
    /// "Not seen lately": neither sent nor served.
    public internal(set) var notSeenLately: [ModelItem]
}

/// One thing Hippocampus understands about the person, in the exact words an AI is given.
public struct ModelItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case project, goal, habit, preference, skill, relationship, struggle, other
    }

    public enum Group: String, Sendable {
        case workingOn = "working_on"
        case howYouWork = "how_you_work"
        case skills, people, struggles
        /// A group the window has no title for: shown last, untitled.
        case other
    }

    public enum Basis: String, Sendable {
        /// "You confirmed this"
        case confirmed
        /// "Seen on {n} days"
        case seenOnDays = "seen_on_days"
        /// "Seen once"
        case seenOnce = "seen_once"
    }

    /// The id a verdict file names.
    public let id: Int64
    public let text: String
    public let kind: Kind
    public let group: Group
    public internal(set) var basis: Basis
    public let daysSeen: Int
    public let reasoning: String
    public let updatedUs: Int64
    /// One dated row per session the item rests on, newest first.
    public let evidenceSessions: [EvidenceSession]
}

public struct EvidenceSession: Equatable, Sendable {
    public let startUs: Int64
    public let endUs: Int64
    public let openEventId: Int64?
    public let appName: String
    public let windowTitle: String?
}

// MARK: - Noted sessions (`mci-agent sessions --json`)

public struct SessionsDay: Equatable, Sendable {
    public let date: String
    /// Oldest first.
    public let sessions: [NotedSession]
}

/// A stored session note. Measured notes' `surface` and `beneath` are
/// telemetry and are never shown (RULINGS W4); the overview's blocks carry
/// what the window shows. The `time` text, keys and activity words are not
/// decoded at all, so they cannot reach the screen.
public struct NotedSession: Equatable, Sendable, Identifiable {
    public var id: Int64 { startUs }
    public let startUs: Int64
    public let endUs: Int64
    public let title: String
    public let surface: String
    public let beneath: String
    public let writtenBy: String
    public let kind: WorkKind
    public let kindLabel: String
    /// Nil when the stored note could not be read.
    public let segments: [SessionSegment]?
    public let searches: [SessionSearch]?
}

public struct SessionSegment: Equatable, Sendable {
    public let startUs: Int64
    public let endUs: Int64
    /// The bundle id (`unknown` when the moment had none).
    public let app: String
    public let name: String
    public let title: String?
    public let host: String?
    public let events: [Int64]
}

/// `[ts_us, engine, query]` on the wire.
public struct SessionSearch: Equatable, Sendable {
    public let tsUs: Int64
    public let engine: String
    public let query: String
}

// MARK: - Answers (`mci_ask`)

public struct AskAnswer: Equatable, Sendable {
    /// Nil when the model could not answer.
    public let answer: String?
    /// Why there is no answer: a reason code, or a sentence.
    public let unavailable: String?
    public let sources: [AskSource]

    public var unavailableReason: ModelUnavailableReason? {
        unavailable.map { ModelUnavailableReason(code: $0) }
    }
}

public struct AskSource: Equatable, Sendable, Identifiable {
    public var id: Int { n }
    public let n: Int
    public let eventId: Int64
    public let tsUs: Int64
    public let app: String
    public let title: String?
    public let url: String?
    public let text: String
}

// MARK: - Tolerant decoding

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Consumes one element of any shape, so a malformed element can be skipped.
private struct Skipped: Decodable {
    init(from decoder: Decoder) throws {}
}

private extension KeyedDecodingContainer where Key == AnyKey {
    /// A required value: its absence or wrong type fails the enclosing object.
    func need<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        try decode(T.self, forKey: AnyKey(key))
    }

    /// An optional value: missing, null or of the wrong type reads as nil.
    func maybe<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: AnyKey(key))) ?? nil
    }

    /// One of an enum's values: missing or unknown reads as `fallback`, the
    /// value the contract names, so a new value never fails a reply.
    func choice<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        maybe(key, as: String.self).flatMap(T.init(rawValue:)) ?? fallback
    }

    /// Text a person may read: missing reads as `fallback`; guarded (RULINGS T14).
    func text(_ key: String, default fallback: String = "") -> String {
        maybe(key, as: String.self).map(ReadableText.guarded) ?? fallback
    }

    /// Optional text a person may read, guarded.
    func optionalText(_ key: String) -> String? {
        maybe(key, as: String.self).map(ReadableText.guarded)
    }

    /// A list: missing or null is empty, and an element that does not decode is skipped.
    func list<T: Decodable>(_ key: String, of type: T.Type = T.self) -> [T] {
        guard (try? decodeNil(forKey: AnyKey(key))) == false,
              var elements = try? nestedUnkeyedContainer(forKey: AnyKey(key))
        else { return [] }
        var result: [T] = []
        while !elements.isAtEnd {
            if let element = try? elements.decode(T.self) {
                result.append(element)
            } else if (try? elements.decode(Skipped.self)) == nil {
                break
            }
        }
        return result
    }

    /// A list that is nil when the agent could not read it, as `sessions --json` says.
    func optionalList<T: Decodable>(_ key: String, of type: T.Type = T.self) -> [T]? {
        guard contains(AnyKey(key)), (try? decodeNil(forKey: AnyKey(key))) == false else { return nil }
        return list(key, of: T.self)
    }

    func times(_ key: String) -> [String: Int64] {
        guard let object = try? nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key)) else { return [:] }
        var result: [String: Int64] = [:]
        for name in object.allKeys {
            if let value = try? object.decode(Int64.self, forKey: name) {
                result[name.stringValue] = value
            }
        }
        return result
    }
}

private func fields(_ decoder: Decoder) throws -> KeyedDecodingContainer<AnyKey> {
    try decoder.container(keyedBy: AnyKey.self)
}

extension TemplateText: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(template: ReadableText.guarded(try f.need("template")),
                  times: f.times("times"), durations: f.times("durations"))
    }
}

extension ModelStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(state: f.choice("state", default: State.unknown), reason: f.maybe("reason"), checkedUs: f.maybe("checked_us"))
    }
}

extension DaySearch: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(query: ReadableText.guarded(try f.need("query")), engine: f.maybe("engine") ?? "",
                  tsUs: try f.need("ts_us"), eventId: f.maybe("event_id"), url: f.maybe("url"))
    }
}

extension Reopen: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        let bundleId: String = try f.need("bundle_id")
        self.init(url: f.maybe("url"), bundleId: bundleId, appName: f.text("app_name"))
    }
}

extension DayOverview: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(
            version: f.maybe("version") ?? 1,
            date: try f.need("date"),
            isToday: f.maybe("is_today") ?? false,
            nowUs: f.maybe("now_us") ?? 0,
            tzOffsetSecs: f.maybe("tz_offset_secs") ?? 0,
            dayStartUs: try f.need("day_start_us"),
            dayEndUs: try f.need("day_end_us"),
            basis: f.choice("basis", default: Basis.estimated),
            truncated: f.maybe("truncated") ?? false,
            modelStatus: f.maybe("model_status") ?? .unknown,
            now: f.maybe("now") ?? .nothing,
            strip: f.maybe("strip"),
            blocks: f.list("blocks"),
            gaps: f.list("gaps"),
            kinds: f.list("kinds"),
            facts: f.list("facts"),
            searches: f.list("searches"),
            account: f.maybe("account"),
            aiKnows: f.maybe("ai_knows") ?? .nothing
        )
    }
}

extension RightNow: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        let state = f.choice("state", default: State.none)
        guard state != .none else {
            self = .nothing
            return
        }
        self.init(
            state: state, sinceUs: f.maybe("since_us"), startUs: f.maybe("start_us"),
            lastSavedUs: f.maybe("last_saved_us"), blockId: f.maybe("block_id"),
            title: f.optionalText("title"), writtenBy: f.maybe("written_by"),
            appName: f.optionalText("app_name"), openEventId: f.maybe("open_event_id"),
            reopen: f.maybe("reopen")
        )
    }
}

extension DayStrip: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(startUs: try f.need("start_us"), endUs: try f.need("end_us"))
    }
}

extension DayGap: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(startUs: try f.need("start_us"), endUs: try f.need("end_us"))
    }
}

extension DayBlock: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(
            id: try f.need("id"),
            provisional: f.maybe("provisional") ?? false,
            startUs: try f.need("start_us"),
            endUs: try f.need("end_us"),
            inProgress: f.maybe("in_progress") ?? false,
            touchesPrevious: f.maybe("touches_previous") ?? false,
            title: f.text("title"),
            writtenBy: f.maybe("written_by") ?? "measured",
            kind: f.choice("kind", default: WorkKind.other),
            kindLabel: f.text("kind_label"),
            mixed: f.maybe("mixed") ?? false,
            kinds: f.list("kinds"),
            apps: f.list("apps"),
            windows: f.list("windows"),
            sentences: f.list("sentences"),
            searches: f.list("searches"),
            screenshotEventId: f.maybe("screenshot_event_id"),
            openEventId: f.maybe("open_event_id"),
            reopen: f.maybe("reopen"),
            noticed: f.maybe("noticed")
        )
    }
}

extension KindShare: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(kind: f.choice("kind", default: WorkKind.other), kindLabel: f.text("kind_label"), heldUs: f.maybe("held_us") ?? 0)
    }
}

extension AppShare: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(bundleId: try f.need("bundle_id"), name: f.text("name"), heldUs: f.maybe("held_us") ?? 0)
    }
}

extension BlockWindow: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(bundleId: try f.need("bundle_id"), name: f.text("name"), title: f.optionalText("title"),
                  host: f.maybe("host"), heldUs: f.maybe("held_us") ?? 0, eventId: f.maybe("event_id"))
    }
}

extension DaySentence: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(id: f.maybe("id") ?? "", text: try TemplateText(from: decoder))
    }
}

extension Noticed: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(text: ReadableText.guarded(try f.need("text")), writtenBy: f.maybe("written_by") ?? "")
    }
}

extension LegendKind: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(kind: f.choice("kind", default: WorkKind.other), kindLabel: f.text("kind_label"), durationUs: f.maybe("duration_us") ?? 0)
    }
}

extension DayFact: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(kind: f.choice("id", default: Kind.other), text: try TemplateText(from: decoder), action: f.maybe("action"))
    }
}

extension FactAction: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(kind: f.choice("type", default: Kind.none), blockIds: f.list("block_ids"))
    }
}

extension DayAccount: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(headline: f.text("headline"), narrative: f.text("narrative"),
                  writtenBy: f.maybe("written_by") ?? "", generatedUs: f.maybe("generated_us"))
    }
}

extension AIKnows: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(recentWork: f.list("recent_work"), aboutYou: f.list("about_you"),
                  hookInstalled: f.maybe("hook_installed") ?? false)
    }
}

extension AboutYouLine: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(id: try f.need("id"), text: ReadableText.guarded(try f.need("text")))
    }
}

extension ModelPage: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(
            version: f.maybe("version") ?? 1,
            // Required: an agent without the page answers `model --page` with
            // its old `{"propositions": …}` list and exit 0. That must read as
            // malformed, never as a page where nothing has been learned.
            nowUs: try f.need("now_us"),
            modelStatus: f.maybe("model_status") ?? .unknown,
            recentWork: f.list("recent_work"),
            shared: f.list("shared"),
            keptBack: f.list("kept_back"),
            notSeenLately: f.list("not_seen_lately")
        )
    }
}

extension ModelItem: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(
            id: try f.need("id"),
            text: ReadableText.guarded(try f.need("text")),
            kind: f.choice("kind", default: Kind.other),
            group: f.choice("group", default: Group.other),
            basis: f.choice("basis", default: Basis.seenOnce),
            daysSeen: f.maybe("days_seen") ?? 0,
            reasoning: f.text("reasoning"),
            updatedUs: f.maybe("updated_us") ?? 0,
            evidenceSessions: f.list("evidence_sessions")
        )
    }
}

extension EvidenceSession: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(startUs: try f.need("start_us"), endUs: try f.need("end_us"),
                  openEventId: f.maybe("open_event_id"), appName: f.text("app_name"),
                  windowTitle: f.optionalText("window_title"))
    }
}

extension SessionsDay: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(date: f.maybe("date") ?? "", sessions: f.list("sessions"))
    }
}

extension NotedSession: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(
            startUs: try f.need("start_us"),
            endUs: try f.need("end_us"),
            title: f.text("title"),
            surface: f.text("surface"),
            beneath: f.text("beneath"),
            writtenBy: f.maybe("written_by") ?? "measured",
            kind: f.choice("kind", default: WorkKind.other),
            kindLabel: f.text("kind_label"),
            segments: f.optionalList("segments"),
            searches: f.optionalList("searches")
        )
    }
}

extension SessionSegment: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(startUs: try f.need("start_us"), endUs: try f.need("end_us"),
                  app: f.maybe("app") ?? "unknown", name: f.text("name"),
                  title: f.optionalText("title"), host: f.maybe("host"), events: f.list("events"))
    }
}

extension SessionSearch: Decodable {
    public init(from decoder: Decoder) throws {
        var tuple = try decoder.unkeyedContainer()
        let tsUs = try tuple.decode(Int64.self)
        let engine = try tuple.decode(String.self)
        let query = try tuple.decode(String.self)
        self.init(tsUs: tsUs, engine: engine, query: ReadableText.guarded(query))
    }
}

extension AskAnswer: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(answer: f.optionalText("answer"), unavailable: f.maybe("unavailable"), sources: f.list("sources"))
    }
}

extension AskSource: Decodable {
    public init(from decoder: Decoder) throws {
        let f = try fields(decoder)
        self.init(n: try f.need("n"), eventId: try f.need("event_id"), tsUs: f.maybe("ts_us") ?? 0,
                  app: f.text("app"), title: f.optionalText("title"), url: f.maybe("url"),
                  text: f.text("text"))
    }
}
