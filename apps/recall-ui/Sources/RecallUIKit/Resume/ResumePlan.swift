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

        public var id: String { [kind, title, url ?? path ?? app ?? ""].joined(separator: "\u{1F}") }

        public init(kind: String, title: String, app: String? = nil, url: String? = nil, path: String? = nil,
                    checked: Bool = true, note: String? = nil) {
            self.kind = kind
            self.title = title
            self.app = app
            self.url = url
            self.path = path
            self.checked = checked
            self.note = note
        }

        private enum CodingKeys: String, CodingKey {
            case kind, title, app, url, path, checked, note
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
                note: try values.decodeIfPresent(String.self, forKey: .note)
            )
        }
    }

    /// What was open in the item's last session, in the sheet's order.
    public let items: [Target]

    public init(items: [Target]) {
        self.items = items
    }

    /// Nothing to open again.
    public static let empty = ResumePlan(items: [])

    /// What the sheet can open: everything without a note saying why not.
    public var openable: [Target] { items.filter { $0.note == nil } }
}

/// Reads a Resume plan: the agent's `resume-plan` in the app, fixtures in
/// previews and tests.
public protocol ResumePlanning: Sendable {
    func plan(item: String) async throws -> ResumePlan
}

/// No plans: nothing to open again. What the window uses until Resume reads
/// the agent's, and what previews and renders use.
public struct NoResumePlans: ResumePlanning {
    public init() {}

    public func plan(item: String) async throws -> ResumePlan { .empty }
}
