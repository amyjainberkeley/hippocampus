import Foundation

/// What the field searches while a page is on screen, Mail-style (SPEC 2.8):
/// "Search: Everything | trailhead-shop", with the page chosen. On a Working
/// On page, Web Pages or Looked Up the shell offers its page; a lens of
/// History offers its kind.
public struct SearchScope: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        /// A Working On item, by its id.
        case item(String)
        case webPages
        case lookedUp
        case lens(LibraryLens)
    }

    public let kind: Kind
    /// The page as the bar names it: "trailhead-shop", "Web Pages".
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    public static func item(_ item: WorkItem) -> SearchScope {
        SearchScope(kind: .item(item.id), name: item.name)
    }

    public static let webPages = SearchScope(kind: .webPages, name: NavigationCopy.webPages)
    public static let lookedUp = SearchScope(kind: .lookedUp, name: NavigationCopy.lookedUp)

    public static func lens(_ lens: LibraryLens) -> SearchScope {
        SearchScope(kind: .lens(lens), name: lens.title)
    }

    /// The matches inside the scope, in their order. An item's are asked of
    /// the `work` read; without one, none can be told apart and none are kept.
    public func keep(_ hits: [Hit], work: (any WorkReader)?) async -> [Hit] {
        switch kind {
        case let .item(id):
            guard let work, !hits.isEmpty,
                  let items = try? await work.items(forMoments: hits.map(\.id)) else { return [] }
            return hits.filter { items[$0.id] == id }
        case .webPages:
            return hits.filter { MomentKinds.isBrowser($0.appBundleId ?? "") && MomentActions.link(of: $0) != nil }
        case .lookedUp:
            return hits.filter { SearchScope.isResultsPage($0.url) }
        case let .lens(lens):
            return hits.filter(lens.includes)
        }
    }

    /// A search engine's page of results: what Looked Up lists.
    public static func isResultsPage(_ value: String?) -> Bool {
        guard let value, let parts = URLComponents(string: value), let host = parts.host?.lowercased(),
              let query = parts.queryItems
        else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        func has(_ name: String) -> Bool { query.contains { $0.name == name && !($0.value ?? "").isEmpty } }
        let path = parts.path.lowercased()
        if bare.hasPrefix("google."), path == "/search" { return has("q") }
        switch bare {
        case "bing.com": return path == "/search" && has("q")
        case "duckduckgo.com": return has("q")
        case "search.yahoo.com": return has("p")
        case "youtube.com", "m.youtube.com": return path == "/results" && has("search_query")
        case "github.com": return path == "/search" && has("q")
        case "kagi.com", "search.brave.com", "ecosia.org": return path == "/search" && has("q")
        default: return false
        }
    }
}

public extension SearchViewModel {
    /// What a search sends: by meaning unless the words are in quotes,
    /// which match exactly, or Exact Words is on (SPEC 2.8). The quotes
    /// themselves are not searched for.
    nonisolated static func request(_ query: String, mode: SearchMode) -> (text: String, mode: SearchMode) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isQuoted(text) else { return (text, mode) }
        let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        let bare = String(text.filter { !quotes.contains($0) })
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (bare.isEmpty ? text : bare, .text)
    }

    /// Words between a pair of quotes, straight or curly.
    nonisolated static func isQuoted(_ text: String) -> Bool {
        let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        var open = false
        var words = false
        for character in text {
            if quotes.contains(character) {
                if open, words { return true }
                open = true
                words = false
            } else if open, !character.isWhitespace {
                words = true
            }
        }
        return false
    }
}
