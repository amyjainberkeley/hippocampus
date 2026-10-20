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
    /// The bundle ids of the apps it was worked on in.
    public let apps: [String]
    public let lastUs: UInt64
    /// Minutes in front in the last 7 days of use.
    public let weekMinutes: Int
    /// Days of the last 7 days of use it was worked on.
    public let daysThisWeek: Int
    /// Whether the sidebar lists it.
    public let inSidebar: Bool
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

    public init(
        id: String, kind: Kind, name: String, apps: [String] = [], lastUs: UInt64,
        weekMinutes: Int = 0, daysThisWeek: Int = 0, inSidebar: Bool = true, hiddenReason: String? = nil,
        files: [WorkFile] = [], alongside: [WorkAlongside] = [], folderGuess: String? = nil,
        moments: [UInt64] = [], thumbnailMoment: UInt64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.apps = apps
        self.lastUs = lastUs
        self.weekMinutes = weekMinutes
        self.daysThisWeek = daysThisWeek
        self.inSidebar = inSidebar
        self.hiddenReason = hiddenReason
        self.files = files
        self.alongside = alongside
        self.folderGuess = folderGuess
        self.moments = moments
        self.thumbnailMoment = thumbnailMoment
    }
}

extension WorkItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, name, apps, files, alongside, moments
        case lastUs = "last_us"
        case weekMinutes = "week_minutes"
        case daysThisWeek = "days_this_week"
        case inSidebar = "in_sidebar"
        case hiddenReason = "hidden_reason"
        case folderGuess = "folder_guess"
        case thumbnailMoment = "thumbnail_moment"
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
            lastUs: try values.decode(UInt64.self, forKey: .lastUs),
            weekMinutes: try values.decodeIfPresent(Int.self, forKey: .weekMinutes) ?? 0,
            daysThisWeek: try values.decodeIfPresent(Int.self, forKey: .daysThisWeek) ?? 0,
            inSidebar: try values.decodeIfPresent(Bool.self, forKey: .inSidebar) ?? true,
            hiddenReason: try values.decodeIfPresent(String.self, forKey: .hiddenReason),
            files: try values.decodeIfPresent([WorkFile].self, forKey: .files) ?? [],
            alongside: try values.decodeIfPresent([WorkAlongside].self, forKey: .alongside) ?? [],
            folderGuess: try values.decodeIfPresent(String.self, forKey: .folderGuess),
            moments: try values.decodeIfPresent([UInt64].self, forKey: .moments) ?? [],
            thumbnailMoment: try values.decodeIfPresent(UInt64.self, forKey: .thumbnailMoment)
        )
    }
}

/// A file a code project's editors named.
public struct WorkFile: Decodable, Equatable, Sendable {
    public let name: String
    public let lastUs: UInt64
    /// Its newest moment.
    public let moment: UInt64

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

    private enum CodingKeys: String, CodingKey {
        case title, host, path, app, days, moments
        case lastUs = "last_us"
    }
}
