import Foundation
import RecallUIKit

private final class MemoryStore: KeyValueStore, @unchecked Sendable {
    var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func set(_ data: Data?, forKey key: String) {
        storage[key] = data
    }

    func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}

@main
struct RecallStateBehavior {
    static func main() {
        precondition(MCI.Workspace.evidenceFilmstripHeight(availableHeight: 599) == 136)
        precondition(MCI.Workspace.evidenceFilmstripHeight(availableHeight: 600) == 200)

        let key = "test.recall.query"
        let store = MemoryStore()
        let persisted = QueryPersistence(store: store, key: key)
        persisted.save(PersistedQueryState(query: "private query", filters: FilterState()))
        precondition(persisted.load()?.query == "private query")

        let ephemeral = QueryPersistence(
            environment: ["MCI_EPHEMERAL_UI_STATE": "1"],
            store: store,
            key: key
        )
        precondition(ephemeral.load() == nil)
        ephemeral.save(PersistedQueryState(query: "replacement", filters: FilterState()))
        precondition(persisted.load()?.query == "private query")
    }
}
