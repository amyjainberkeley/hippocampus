import Foundation

/// What Resume would open again for one Working On item, from what was open
/// in its last session (`mci-agent resume-plan`, SPEC-DELTA 3): web pages in
/// the browser they were read in, documents through their links or their
/// app, the code folder in its editor, and the other apps in use.
///
/// Resume sends nothing anywhere. The sheet lists exactly what will open,
/// and nothing opens until the person clicks; then the window only asks
/// macOS to open each one.
public struct ResumePlan: Decodable, Equatable, Sendable {
    /// One thing Resume could open again.
    public struct Target: Decodable, Equatable, Sendable, Identifiable {
        /// `"page"`, `"document"`, `"folder"` or `"app"`.
        public let kind: String
        /// What the sheet calls it.
        public let title: String
        /// The bundle id of the app that opens it.
        public let app: String?
        /// A page's or a linked document's address, without query or fragment.
        public let url: String?
        /// A local document's or a folder's path, with `~` for home.
        public let path: String?
        /// Whether its checkbox starts ticked.
        public let checked: Bool
        /// Why it can't be opened again, when it can't.
        public let note: String?
        /// What the agent says about it, as a code the window words:
        /// `missing`, `no_address` (it can't open), `single_note`,
        /// `app_only`, `no_folder` (only its app opens).
        public let reason: String?

        /// Unique in a plan: a folder opens once in its editor and once in
        /// a terminal, so the app is part of it.
        public var id: String { [kind, title, url ?? path ?? "", app ?? ""].joined(separator: "\u{1F}") }

        public init(kind: String, title: String, app: String? = nil, url: String? = nil, path: String? = nil,
                    checked: Bool = true, note: String? = nil, reason: String? = nil) {
            self.kind = kind
            self.title = title
            self.app = app
            self.url = url
            self.path = path
            self.checked = checked
            self.note = note
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case kind, title, app, url, path, checked, note, reason
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                kind: try values.decode(String.self, forKey: .kind),
                title: try values.decode(String.self, forKey: .title),
                app: try values.decodeIfPresent(String.self, forKey: .app),
                url: try values.decodeIfPresent(String.self, forKey: .url),
                path: try values.decodeIfPresent(String.self, forKey: .path),
                checked: try values.decodeIfPresent(Bool.self, forKey: .checked) ?? true,
                note: try values.decodeIfPresent(String.self, forKey: .note),
                reason: try values.decodeIfPresent(String.self, forKey: .reason)
            )
        }

        /// Whether it can be opened at all: it names something to open and
        /// nothing says it can't.
        public var canOpen: Bool {
            note == nil && !Self.blockingReasons.contains(reason ?? "")
                && (url != nil || path != nil || app != nil)
        }

        /// Reasons that mean there is nothing to open.
        public static let blockingReasons: Set<String> = ["missing", "no_address"]

        /// Opens in a browser as a tab: a page, or a document's link.
        public var isTab: Bool { url != nil }
    }

    /// The item a plan is for.
    public struct Item: Decodable, Equatable, Sendable {
        public let name: String
        public let kind: String

        public init(name: String, kind: String) {
            self.name = name
            self.kind = kind
        }
    }

    /// The session a plan comes from: its own time.
    public struct Session: Decodable, Equatable, Sendable {
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

    /// What was open in the item's last session, in the sheet's order.
    public let items: [Target]
    /// The item, when the agent knew it.
    public let item: Item?
    /// The session the plan comes from.
    public let session: Session?

    public init(items: [Target], item: Item? = nil, session: Session? = nil) {
        self.items = items
        self.item = item
        self.session = session
    }

    private enum CodingKeys: String, CodingKey {
        case items, item, session
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try values.decodeIfPresent([Target].self, forKey: .items) ?? [],
            item: try values.decodeIfPresent(Item.self, forKey: .item),
            session: try values.decodeIfPresent(Session.self, forKey: .session)
        )
    }

    /// Nothing to open again.
    public static let empty = ResumePlan(items: [])

    /// What the sheet can open: everything without a note saying why not.
    public var openable: [Target] { items.filter(\.canOpen) }
}

/// Reads a Resume plan: the agent's `resume-plan` in the app, fixtures in
/// previews and tests.
public protocol ResumePlanning: Sendable {
    func plan(item: String) async throws -> ResumePlan
}

/// No plans: nothing to open again. What previews use when they have no
/// fixture, and what a window opened without Hippocampus has.
public struct NoResumePlans: ResumePlanning {
    public init() {}

    public func plan(item: String) async throws -> ResumePlan { .empty }
}

/// Plans from fixtures, by item id: previews, renders and tests.
public struct PreviewResumePlans: ResumePlanning {
    public let plans: [String: ResumePlan]

    public init(plans: [String: ResumePlan]) {
        self.plans = plans
    }

    public func plan(item: String) async throws -> ResumePlan {
        plans[item] ?? .empty
    }
}
