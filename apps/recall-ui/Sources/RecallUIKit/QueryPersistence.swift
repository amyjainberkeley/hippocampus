// QueryPersistence.swift — persist the recall-UI search query + filter
// state across app quit + restore. Cycle 8.35 recall-UI audit follow-up
// (`docs/research/2026-07-12-recall-ui-audit.md`).
//
// # Scope
//
// The user types a query, tweaks filter pills, then quits the helper
// (or the helper crashes / is restarted). On next launch the visible
// state is empty, forcing them to re-type context. This module snapshots
// `{ query, FilterState }` to `UserDefaults` and rehydrates it on VM
// init. A "×" clear affordance already exists on `SearchView`; that same
// path (`SearchViewModel.clear()`) also wipes the persisted state, so
// the user can reset by clicking clear.
//
// # Privacy rationale — READ THIS BEFORE MOVING STORAGE
//
// The QUERY is user-typed text and the FILTER selections are app-bundle
// ids + date presets. Neither contains brain content (OCR text, page
// content, browser URL, screenshot pixels) — the brain itself stays in
// SQLCipher (adapters/macos/mci-brain-ffi/) and is NEVER touched by
// this module. Persisting a user's own query to plain `UserDefaults` is
// no more privileged than persisting their Safari address-bar history:
// it is their own text and any "leak" is their own words.
//
// If a future change extends persistence to include HITS, SNIPPETS, or
// any reader-returned content, that IS brain content and MUST NOT live
// in UserDefaults — it belongs in the SQLCipher store on the reader
// side. Track A privacy invariant, CSO veto gate.
//
// # Storage schema
//
// UserDefaults key: `com.hippocampus.recall.lastQuery`
// Value:            JSON blob (Data) of `PersistedQueryState`
//
// A JSON envelope with a `schemaVersion` field is used so a future
// schema evolution can be handled without corrupting the app. Decode
// failures fall back to an empty state — corrupted UserDefaults must
// never crash the app.

import Foundation

/// The persisted envelope. `schemaVersion` gates evolution; decode
/// failures are swallowed by the loader.
public struct PersistedQueryState: Codable, Equatable, Sendable {
    /// Bump when the layout breaks compatibility. v1 is the initial
    /// shape shipped in cycle 8.35 audit follow-up.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var query: String
    public var filters: FilterState

    public init(
        schemaVersion: Int = PersistedQueryState.currentSchemaVersion,
        query: String,
        filters: FilterState
    ) {
        self.schemaVersion = schemaVersion
        self.query = query
        self.filters = filters
    }

    /// `true` when the state is worth persisting. Empty query + default
    /// filters ⇒ we delete the key entirely so the next launch loads
    /// clean without a stale JSON blob sitting on disk.
    public var isEmpty: Bool {
        query.isEmpty && !filters.anyActive
    }
}

/// Minimal key-value store the persistence layer talks to. Abstracted
/// so tests can inject an in-memory fake without polluting the process
/// `UserDefaults.standard`.
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore, @unchecked Sendable {
    public func set(_ data: Data?, forKey key: String) {
        if let data {
            self.set(data as Any, forKey: key)
        } else {
            self.removeObject(forKey: key)
        }
    }
}

/// Save / load / clear the persisted query state. Stateless around the
/// injected `KeyValueStore` so it's cheap to construct.
public struct QueryPersistence: Sendable {
    /// UserDefaults key — kept stable across releases; changing this
    /// silently wipes every existing user's persisted state.
    public static let defaultKey = "com.hippocampus.recall.lastQuery"

    private let store: KeyValueStore
    private let key: String

    public init(
        store: KeyValueStore = UserDefaults.standard,
        key: String = QueryPersistence.defaultKey
    ) {
        self.store = store
        self.key = key
    }

    /// Save the state. Empty state (empty query + default filters)
    /// clears the key so the next `load` returns nil.
    public func save(_ state: PersistedQueryState) {
        guard !state.isEmpty else {
            store.removeObject(forKey: key)
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            store.set(data, forKey: key)
        } catch {
            // Persistence is best-effort — never fatal.
        }
    }

    /// Load the state. Returns `nil` when nothing is stored OR the
    /// stored blob is corrupted / from an unknown schema version.
    public func load() -> PersistedQueryState? {
        guard let data = store.data(forKey: key) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(PersistedQueryState.self, from: data)
            // Reject unknown schema versions — the user gets a clean
            // slate rather than a partially-populated UI.
            guard decoded.schemaVersion == PersistedQueryState.currentSchemaVersion else {
                return nil
            }
            return decoded
        } catch {
            return nil
        }
    }

    /// Explicit clear — the "×" button on SearchView routes here via
    /// `SearchViewModel.clear()`.
    public func clear() {
        store.removeObject(forKey: key)
    }
}
