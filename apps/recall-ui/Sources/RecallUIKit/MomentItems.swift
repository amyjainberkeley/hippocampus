import Foundation

/// "Part of trailhead-shop ›" under a moment's header (SPEC 3.4): the Working
/// On item each moment on a page belongs to. Asked of the `work` read once
/// per page of moments (`work --json --moments <ids>`) and kept, with the
/// items' names from one read of Working On.
@MainActor
public final class MomentItems: ObservableObject {
    /// The item each moment asked about is part of, by moment id.
    @Published public private(set) var items: [UInt64: WorkItem] = [:]

    private let reader: (any WorkReader)?
    private var asked: Set<UInt64> = []
    private var named: [String: WorkItem] = [:]
    private var namesRead = false

    /// How far back the names are read: as long as moments are kept by default.
    static let days = 90

    public init(reader: (any WorkReader)?) {
        self.reader = reader
    }

    /// Ask about the moments not asked about yet. A failed read leaves them
    /// without a "Part of" line; the next page asks again.
    public func load(_ moments: [UInt64]) async {
        guard let reader else { return }
        let new = moments.filter { !asked.contains($0) }
        guard !new.isEmpty else { return }
        asked.formUnion(new)
        guard let found = try? await reader.items(forMoments: new) else {
            asked.subtract(new)
            return
        }
        if !namesRead || found.values.contains(where: { named[$0] == nil }) {
            if let snapshot = try? await reader.work(days: Self.days) {
                namesRead = true
                for item in snapshot.items { named[item.id] = item }
            }
        }
        var resolved = items
        for (moment, id) in found {
            if let item = named[id] {
                resolved[moment] = item
            } else if let item = try? await reader.item(id: id, before: nil) {
                named[id] = item
                resolved[moment] = item
            }
        }
        if resolved != items { items = resolved }
    }

    /// Forget what was asked: after a delete, items are made again.
    public func clear() {
        asked = []
        named = [:]
        namesRead = false
        items = [:]
    }

    /// The item to name under `hit`'s header: only when it goes by another
    /// name than the caption already says.
    public func partOf(_ hit: Hit) -> WorkItem? {
        Self.partOf(items[hit.id], caption: MomentRowText.headline(hit))
    }

    public static func partOf(_ item: WorkItem?, caption: String) -> WorkItem? {
        guard let item, !item.name.isEmpty else { return nil }
        return caption.localizedCaseInsensitiveContains(item.name) ? nil : item
    }
}
