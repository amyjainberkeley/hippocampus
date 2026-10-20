import Foundation

/// The `work` read (`mci-agent work --json`, SPEC 3.12.2): what Working On
/// and Web Pages show, made from window titles. Ids, never names, travel in
/// links.
public struct WorkSnapshot: Equatable, Sendable {
    /// When the agent made it, in microseconds since the epoch.
    public var generatedUs: UInt64?
    /// Working On's items, most time in the last 7 days of use first.
    public var items: [WorkItem]
    /// Web Pages' pages, newest first.
    public var pages: [WorkPage]
    /// For a read of some moments: the item each is part of, by moment id.
    public var momentItems: [UInt64: String]

    public init(generatedUs: UInt64? = nil, items: [WorkItem] = [], pages: [WorkPage] = [],
                momentItems: [UInt64: String] = [:]) {
        self.generatedUs = generatedUs
        self.items = items
        self.pages = pages
        self.momentItems = momentItems
    }

    /// Nothing worked on yet.
    public static let empty = WorkSnapshot()
}

extension WorkSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case generatedUs = "generated_us"
        case items, pages
        case momentItems = "moment_items"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let lookups = try values.decodeIfPresent([String: String].self, forKey: .momentItems) ?? [:]
        self.init(
            generatedUs: try values.decodeIfPresent(UInt64.self, forKey: .generatedUs),
            items: try values.decodeIfPresent([WorkItem].self, forKey: .items) ?? [],
            pages: try values.decodeIfPresent([WorkPage].self, forKey: .pages) ?? [],
            momentItems: Dictionary(lookups.compactMap { key, item in UInt64(key).map { ($0, item) } },
                                    uniquingKeysWith: { first, _ in first })
        )
    }
}

/// One code project, document, design or spreadsheet Working On lists.
public struct WorkItem: Equatable, Sendable, Identifiable {
    /// What kind of thing an item is. Pages and searches are never items.
    public enum Kind: String, Sendable, CaseIterable {
        case code, document, design, spreadsheet
    }

    /// A keyed hash of its kind and name: stable on this Mac, meaningless on
    /// any other.
    public let id: String
    public let kind: Kind
    /// Its name, as its windows' titles write it.
    public let name: String
    /// The bundle ids of the apps it was worked on in, most time first.
    public let apps: [String]
    /// The sites it was worked on at, most time first: a document on the
    /// web ("docs.google.com"). Empty for one in its own app.
    public let hosts: [String]
    public let lastUs: UInt64
    /// Minutes in front in the last 7 days of use.
    public let weekMinutes: Int
    /// Days of the last 7 days of use it was worked on.
    public let daysThisWeek: Int
    /// Whether the sidebar lists it.
    public let inSidebar: Bool
    /// Whether it has the sidebar's time (30 minutes within the last 14
    /// days of use), whatever its name: a name that looks personal joins
    /// the sidebar when the person shows it.
    public let recent: Bool
    /// Why the sidebar doesn't, when it's the name's own: `"personal"`.
    public let hiddenReason: String?
    /// For code, the files its editors named, newest first.
    public let files: [WorkFile]
    /// Pages, searches and AI chats open around the same time.
    public let alongside: [WorkAlongside]
    /// For code, the folder it seems to be in, with `~` for home.
    public let folderGuess: String?
    /// Its moment ids, newest first.
    public let moments: [UInt64]
    /// The moment whose kept screenshot is its thumbnail in the sidebar, on
    /// hover and in Show All: its newest moment with a screenshot
    /// (SPEC-DELTA 2). Nil shows the kind's symbol.
    public let thumbnailMoment: UInt64?
    /// Minutes in front over everything read: what Show All says for an
    /// item from before this week.
    public let totalMinutes: Int
    /// Conversations open around the same time, by name only (SPEC-DELTA 4).
    public let conversations: [WorkConversation]
    /// With one item's read: its sessions, newest first, for the meetings
    /// that overlapped them.
    public let sessions: [WorkSession]

    public init(
        id: String, kind: Kind, name: String, apps: [String] = [], hosts: [String] = [], lastUs: UInt64,
        weekMinutes: Int = 0, daysThisWeek: Int = 0, inSidebar: Bool = true, recent: Bool? = nil,
        hiddenReason: String? = nil,
        files: [WorkFile] = [], alongside: [WorkAlongside] = [], folderGuess: String? = nil,
        moments: [UInt64] = [], thumbnailMoment: UInt64? = nil, totalMinutes: Int? = nil,
        conversations: [WorkConversation] = [], sessions: [WorkSession] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.apps = apps
        self.hosts = hosts
        self.lastUs = lastUs
        self.weekMinutes = weekMinutes
        self.daysThisWeek = daysThisWeek
        self.inSidebar = inSidebar
        self.recent = recent ?? inSidebar
        self.hiddenReason = hiddenReason
        self.files = files
        self.alongside = alongside
        self.folderGuess = folderGuess
        self.moments = moments
        self.thumbnailMoment = thumbnailMoment
        self.totalMinutes = totalMinutes ?? weekMinutes
        self.conversations = conversations
        self.sessions = sessions
    }

    /// Whether a name that looks personal keeps it out of the sidebar.
    public var looksPersonal: Bool { hiddenReason == "personal" }

    /// Whether the sidebar lists it, with the person's choices: never one
    /// they hid; a name that looks personal once they showed it, while it
    /// has the sidebar's time.
    public func inSidebar(hidden: Set<String>, shown: Set<String> = []) -> Bool {
        guard !hidden.contains(id) else { return false }
        return inSidebar || (looksPersonal && recent && shown.contains(id))
    }

    /// Whether Show All keeps it under "Not shown in the sidebar": hidden by
    /// the person, or a name that looks personal they haven't shown.
    public func isKeptOut(hidden: Set<String>, shown: Set<String> = []) -> Bool {
        hidden.contains(id) || (looksPersonal && !shown.contains(id))
    }
}

extension WorkItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, name, apps, hosts, files, alongside, moments, conversations, sessions
        case lastUs = "last_us"
        case weekMinutes = "week_minutes"
        case daysThisWeek = "days_this_week"
        case inSidebar = "in_sidebar"
        case recent
        case hiddenReason = "hidden_reason"
        case folderGuess = "folder_guess"
        case thumbnailMoment = "thumbnail_moment"
        case totalMinutes = "total_minutes"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        guard let known = Kind(rawValue: kind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                                                   debugDescription: "Not a kind Working On lists")
        }
        self.init(
            id: try values.decode(String.self, forKey: .id),
            kind: known,
            name: try values.decode(String.self, forKey: .name),
            apps: try values.decodeIfPresent([String].self, forKey: .apps) ?? [],
            hosts: try values.decodeIfPresent([String].self, forKey: .hosts) ?? [],
            lastUs: try values.decode(UInt64.self, forKey: .lastUs),
            weekMinutes: try values.decodeIfPresent(Int.self, forKey: .weekMinutes) ?? 0,
            daysThisWeek: try values.decodeIfPresent(Int.self, forKey: .daysThisWeek) ?? 0,
            inSidebar: try values.decodeIfPresent(Bool.self, forKey: .inSidebar) ?? true,
            recent: try values.decodeIfPresent(Bool.self, forKey: .recent),
            hiddenReason: try values.decodeIfPresent(String.self, forKey: .hiddenReason),
            files: try values.decodeIfPresent([WorkFile].self, forKey: .files) ?? [],
            alongside: try values.decodeIfPresent([WorkAlongside].self, forKey: .alongside) ?? [],
            folderGuess: try values.decodeIfPresent(String.self, forKey: .folderGuess),
            moments: try values.decodeIfPresent([UInt64].self, forKey: .moments) ?? [],
            thumbnailMoment: try values.decodeIfPresent(UInt64.self, forKey: .thumbnailMoment),
            totalMinutes: try values.decodeIfPresent(Int.self, forKey: .totalMinutes),
            conversations: try values.decodeIfPresent([WorkConversation].self, forKey: .conversations) ?? [],
            sessions: try values.decodeIfPresent([WorkSession].self, forKey: .sessions) ?? []
        )
    }
}

/// A conversation with people open around the same time as an item: its
/// name, never what was said.
public struct WorkConversation: Decodable, Equatable, Sendable {
    /// "#launch", "Jordan Lee", an email's subject.
    public let name: String
    public let app: String
    /// Its newest moment.
    public let moment: UInt64
    public let lastUs: UInt64

    public init(name: String, app: String, moment: UInt64, lastUs: UInt64) {
        self.name = name
        self.app = app
        self.moment = moment
        self.lastUs = lastUs
    }

    private enum CodingKeys: String, CodingKey {
        case name, app, moment
        case lastUs = "last_us"
    }
}

/// One of an item's sessions: its own time.
public struct WorkSession: Decodable, Equatable, Sendable {
    public let startUs: UInt64
    public let endUs: UInt64

    public init(startUs: UInt64, endUs: UInt64) {
        self.startUs = startUs
        self.endUs = endUs
    }

    private enum CodingKeys: String, CodingKey {
        case startUs = "start_us"
        case endUs = "end_us"
    }
}

/// A file a code project's editors named.
public struct WorkFile: Decodable, Equatable, Sendable {
    public let name: String
    public let lastUs: UInt64
    /// Its newest moment.
    public let moment: UInt64

    public init(name: String, lastUs: UInt64, moment: UInt64) {
        self.name = name
        self.lastUs = lastUs
        self.moment = moment
    }

    private enum CodingKeys: String, CodingKey {
        case name, moment
        case lastUs = "last_us"
    }
}

/// A page, search or AI chat open around the same time as an item.
public struct WorkAlongside: Decodable, Equatable, Sendable {
    /// `"page"`, `"search"` or `"ai_chat"`.
    public let kind: String
    public let title: String
    public let host: String?
    public let app: String
    /// Its newest moment.
    public let moment: UInt64
    public let lastUs: UInt64

    public init(kind: String, title: String, host: String? = nil, app: String, moment: UInt64, lastUs: UInt64) {
        self.kind = kind
        self.title = title
        self.host = host
        self.app = app
        self.moment = moment
        self.lastUs = lastUs
    }

    private enum CodingKeys: String, CodingKey {
        case kind, title, host, app, moment
        case lastUs = "last_us"
    }
}

/// A page Web Pages lists: one row per address, across days.
public struct WorkPage: Decodable, Equatable, Sendable {
    public let title: String
    public let host: String?
    /// The address's path, without its query and fragment.
    public let path: String?
    public let app: String
    /// On how many days it was read.
    public let days: Int
    public let lastUs: UInt64
    /// Its moment ids, newest first.
    public let moments: [UInt64]

    public init(title: String, host: String? = nil, path: String? = nil, app: String, days: Int = 1,
                lastUs: UInt64, moments: [UInt64]) {
        self.title = title
        self.host = host
        self.path = path
        self.app = app
        self.days = days
        self.lastUs = lastUs
        self.moments = moments
    }

    /// The page's address without its query and fragment, when known:
    /// "devnotes.example/rounding".
    public var address: String? {
        host.map { host in host + ((path ?? "/") == "/" ? "" : path ?? "") }
    }

    private enum CodingKeys: String, CodingKey {
        case title, host, path, app, days, moments
        case lastUs = "last_us"
    }
}
