// QueryPersistenceTests.swift — round-trip + corruption + empty-state
// tests for the cycle 8.35 audit follow-up (recall-UI query persistence).
//
// Uses an in-memory `KeyValueStore` fake so the test suite never touches
// the process `UserDefaults.standard`.

import XCTest
@testable import RecallUIKit

/// In-memory `KeyValueStore` fake — every method is trivially deterministic
/// so we can assert what got written and simulate corruption.
private final class InMemoryStore: KeyValueStore, @unchecked Sendable {
    var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        storage[key]
    }
    func set(_ data: Data?, forKey key: String) {
        if let data { storage[key] = data } else { storage.removeValue(forKey: key) }
    }
    func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}

final class QueryPersistenceTests: XCTestCase {
    private func makePersistence() -> (QueryPersistence, InMemoryStore) {
        let store = InMemoryStore()
        return (QueryPersistence(store: store, key: "test.recall.query"), store)
    }

    // MARK: - Round trip

    func testSaveThenLoadRoundTripsIdentically() {
        let (p, _) = makePersistence()
        var filters = FilterState()
        filters.toggleApp("com.apple.Safari")
        filters.toggleApp("com.microsoft.VSCode")
        filters.setDateRange(.last7Days)
        filters.toggleHasUrl()

        let original = PersistedQueryState(query: "swift concurrency", filters: filters)
        p.save(original)

        let loaded = p.load()
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded?.query, "swift concurrency")
        XCTAssertEqual(loaded?.filters.appBundleIds, ["com.apple.Safari", "com.microsoft.VSCode"])
        XCTAssertEqual(loaded?.filters.dateRange, .last7Days)
        XCTAssertTrue(loaded?.filters.hasUrl ?? false)
    }

    func testCustomDateRangeRoundTrips() {
        let (p, _) = makePersistence()
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_500_000)
        var filters = FilterState()
        filters.setDateRange(.custom(from: from, to: to))
        p.save(PersistedQueryState(query: "q", filters: filters))
        XCTAssertEqual(p.load()?.filters.dateRange, .custom(from: from, to: to))
    }

    // MARK: - Empty / clear

    func testEmptyStateDoesNotPersist() {
        let (p, store) = makePersistence()
        // Pre-populate with a value so we can assert it's cleared.
        p.save(PersistedQueryState(query: "old", filters: FilterState()))
        XCTAssertFalse(store.storage.isEmpty)

        p.save(PersistedQueryState(query: "", filters: FilterState()))
        XCTAssertTrue(store.storage.isEmpty, "empty state must clear the key, not overwrite it")
        XCTAssertNil(p.load())
    }

    func testLoadOnEmptyStoreReturnsNil() {
        let (p, _) = makePersistence()
        XCTAssertNil(p.load())
    }

    func testClearRemovesPersistedState() {
        let (p, store) = makePersistence()
        p.save(PersistedQueryState(query: "hello", filters: FilterState()))
        XCTAssertFalse(store.storage.isEmpty)
        p.clear()
        XCTAssertTrue(store.storage.isEmpty)
        XCTAssertNil(p.load())
    }

    // MARK: - Corruption

    func testCorruptedBlobFallsBackToNilWithoutCrash() {
        let store = InMemoryStore()
        let key = "test.recall.query"
        store.storage[key] = Data("not valid json {{{".utf8)
        let p = QueryPersistence(store: store, key: key)
        XCTAssertNil(p.load(), "corrupted blob must degrade to nil, not crash")
    }

    func testUnknownSchemaVersionReturnsNil() {
        // Manually construct a JSON blob with a future schema version
        // to prove the loader rejects it rather than partially trusting it.
        let store = InMemoryStore()
        let key = "test.recall.query"
        let future = #"{"schemaVersion":9999,"query":"q","filters":{"appBundleIds":[],"dateRange":{"kind":"none"},"hasUrl":false}}"#
        store.storage[key] = Data(future.utf8)
        let p = QueryPersistence(store: store, key: key)
        XCTAssertNil(p.load())
    }

    // MARK: - SearchViewModel wiring (restore on init)

    @MainActor
    func testSearchViewModelRestoresPersistedStateOnInit() async {
        let store = InMemoryStore()
        let key = "test.recall.query"
        let p = QueryPersistence(store: store, key: key)
        var filters = FilterState()
        filters.toggleApp("com.apple.Safari")
        filters.setDateRange(.today)
        p.save(PersistedQueryState(query: "restored query", filters: filters))

        let vm = SearchViewModel(
            reader: StubBrainReader(),
            persistence: QueryPersistence(store: store, key: key)
        )
        XCTAssertEqual(vm.query, "restored query")
        XCTAssertEqual(vm.filters.appBundleIds, ["com.apple.Safari"])
        XCTAssertEqual(vm.filters.dateRange, .today)
    }

    @MainActor
    func testSearchViewModelClearAlsoClearsPersistence() async {
        let store = InMemoryStore()
        let key = "test.recall.query"
        let p = QueryPersistence(store: store, key: key)
        p.save(PersistedQueryState(
            query: "will be cleared",
            filters: FilterState()
        ))
        let vm = SearchViewModel(
            reader: StubBrainReader(),
            persistence: QueryPersistence(store: store, key: key)
        )
        XCTAssertEqual(vm.query, "will be cleared")
        vm.clear()
        XCTAssertTrue(vm.query.isEmpty)
        XCTAssertNil(QueryPersistence(store: store, key: key).load())
    }
}
