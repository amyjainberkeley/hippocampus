// FFIBrainReader.swift — `BrainReader` impl backed by the C ABI exposed
// by `adapters/macos/mci-brain-ffi/`.
//
// The reader wraps the opaque `McibrainHandle *` returned by
// `mci_brain_ffi_open` and dispatches the three `BrainReader` methods to
// the corresponding extern fns. JSON returns are decoded via `Codable`
// onto Swift mirrors of the Rust-side `HitJson` / `PrivacyMomentJson`
// structs (see the canonical header for the wire shapes).
//
// # Read-only by construction
//
// `mci_brain_ffi_open` opens the underlying SQLCipher connection with
// `SQLITE_OPEN_READ_ONLY` (see `core/src/store/open.rs::open_readonly`).
// The C ABI does not export any mutating function — there is no
// `put` / `delete` / `mutate_*` extern fn — so the recall-ui structurally
// cannot modify the brain. The CSO load-bearing test
// `tests/readonly_invariant.rs::ffi_open_yields_a_strictly_read_only_brain`
// in `mci-brain-ffi` proves the SQLite-driver-level enforcement.
//
// # Lifecycle
//
// One `FFIBrainReader` instance owns one handle. The reader is class-typed
// (rather than struct) so its `deinit` can call `mci_brain_ffi_close`
// once and exactly once when the last reference drops. Single-close is
// the FFI's contract; the reader enforces it for Swift callers.
//
// # Thread safety
//
// `BrainReader` is `Sendable`; this reader can be shared across `Task`s.
// The Rust side serializes against the inner SqlCipherBrainStore's mutex,
// so concurrent calls are safe; this Swift type is marked `@unchecked
// Sendable` because the `OpaquePointer` storage is not statically
// known-Sendable to the compiler but is semantically immutable for the
// reader's lifetime.

import Foundation
import CMciBrainFFI

/// `BrainReader` impl that calls into the `mci-brain-ffi` C ABI.
public final class FFIBrainReader: BrainReader, @unchecked Sendable {
    /// Opaque pointer returned by `mci_brain_ffi_open`. Becomes `nil`
    /// after `close()`; methods called after close throw
    /// `BrainReaderError.openFailed`.
    private var handle: OpaquePointer?

    /// Open the brain at `path` with the hex-encoded SQLCipher key
    /// `keyHex`. The key MUST be exactly 64 hex characters (32 bytes,
    /// per ADR-0008).
    ///
    /// - Throws: `BrainReaderError.openFailed` with the FFI's last-error
    ///   diagnostic on any failure (missing file, wrong key, malformed
    ///   key hex, etc.).
    public init(path: String, keyHex: String) throws {
        let h: OpaquePointer? = path.withCString { pPath in
            keyHex.withCString { pKey in
                mci_brain_ffi_open(pPath, pKey)
            }
        }
        guard let h else {
            throw BrainReaderError.openFailed(Self.consumeLastError())
        }
        self.handle = h
    }

    /// Explicit close. Safe to call multiple times; subsequent calls are
    /// no-ops. Always called by `deinit`, but tests that want to assert
    /// post-close failure behavior can call it directly.
    public func close() {
        if let h = handle {
            mci_brain_ffi_close(h)
            handle = nil
        }
    }

    deinit {
        // Single-close per the FFI's contract. `close()` is idempotent.
        close()
    }

    // MARK: BrainReader

    public func search(_ opts: SearchOptions) async throws -> [Hit] {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        let payload = QueryPayload(
            text: opts.text,
            limit: opts.limit,
            timeFromUs: opts.timeFromUs,
            timeToUs: opts.timeToUs,
            appFilter: opts.appFilter,
            userAliases: opts.userAliases
        )
        let queryJsonData = try JSONEncoder().encode(payload)
        guard let queryJsonString = String(data: queryJsonData, encoding: .utf8) else {
            throw BrainReaderError.decodeFailed("FFIBrainReader: non-UTF8 query payload")
        }
        let rawJson: UnsafeMutablePointer<CChar>? = queryJsonString.withCString { q in
            mci_brain_ffi_search(h, q)
        }
        guard let rawJson else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        let hits = try Self.decodeHits(rawJson)
        return hits
    }

    public func recentEvents(limit: Int) async throws -> [Hit] {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        let clamped = UInt32(max(0, min(limit, Int(UInt32.max))))
        guard let rawJson = mci_brain_ffi_recent_events(h, clamped) else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        return try Self.decodeHits(rawJson)
    }

    public func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        let clamped = UInt32(max(0, min(limit, Int(UInt32.max))))
        guard let rawJson = mci_brain_ffi_recent_privacy_moments(h, clamped) else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        return try Self.decodePrivacyMoments(rawJson)
    }

    public func listObservedApps(
        limit: Int,
        timeFromUs: UInt64?
    ) async throws -> [ObservedApp] {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        let payload = ObservedAppsQueryPayload(limit: limit, timeFromUs: timeFromUs)
        let queryJsonData = try JSONEncoder().encode(payload)
        guard let queryJsonString = String(data: queryJsonData, encoding: .utf8) else {
            throw BrainReaderError.decodeFailed("FFIBrainReader: non-UTF8 query payload")
        }
        let rawJson: UnsafeMutablePointer<CChar>? = queryJsonString.withCString { q in
            mci_brain_ffi_list_observed_apps(h, q)
        }
        guard let rawJson else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        return try Self.decodeObservedApps(rawJson)
    }

    /// Cycle-8.37 PR-3: resolve a batch of linked event ids into full
    /// `Hit` rows for the related-hits flyout in `DetailPaneView`. The
    /// FFI caps the request at 32 ids; we mirror that cap on the Swift
    /// side so the encoded JSON never violates the contract. Returns
    /// `[]` when the input is empty (no FFI round trip).
    public func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        guard !ids.isEmpty else { return [] }
        // Mirror the FFI's EVENTS_BY_IDS_CAP so the wire payload is bounded.
        let capped = Array(ids.prefix(32))
        let payload = EventsByIdsPayload(ids: capped)
        let queryJsonData = try JSONEncoder().encode(payload)
        guard let queryJsonString = String(data: queryJsonData, encoding: .utf8) else {
            throw BrainReaderError.decodeFailed("FFIBrainReader: non-UTF8 ids payload")
        }
        let rawJson: UnsafeMutablePointer<CChar>? = queryJsonString.withCString { q in
            mci_brain_ffi_events_by_ids(h, q)
        }
        guard let rawJson else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        return try Self.decodeHits(rawJson)
    }

    public func listEpisodes(limit: Int) async throws -> [Episode] {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        let clamped = UInt32(max(0, min(limit, Int(UInt32.max))))
        guard let rawJson = mci_brain_ffi_list_episodes(h, clamped) else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        return try Self.decodeEpisodes(rawJson)
    }

    // MARK: BrainReader — Daily Brief surface

    public func briefForDate(_ dateLocal: String) async throws -> Brief? {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        let rawJson: UnsafeMutablePointer<CChar>? = dateLocal.withCString { p in
            mci_brain_ffi_brief_for_date(h, p)
        }
        guard let rawJson else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        return try Self.decodeOptionalBrief(rawJson)
    }

    public func latestBrief() async throws -> Brief? {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        guard let rawJson = mci_brain_ffi_latest_brief(h) else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        return try Self.decodeOptionalBrief(rawJson)
    }

    public func briefDates(limit: Int) async throws -> [String] {
        guard let h = handle else {
            throw BrainReaderError.openFailed("FFIBrainReader: handle already closed")
        }
        let clamped = UInt32(max(0, min(limit, Int(UInt32.max))))
        guard let rawJson = mci_brain_ffi_brief_dates(h, clamped) else {
            throw BrainReaderError.queryFailed(Self.consumeLastError())
        }
        defer { mci_brain_ffi_string_free(rawJson) }
        let s = String(cString: rawJson)
        guard let data = s.data(using: .utf8) else {
            throw BrainReaderError.decodeFailed("non-UTF8 JSON from FFI (brief_dates)")
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw BrainReaderError.decodeFailed("FFIBrainReader.briefDates: \(error)")
        }
    }

    // MARK: helpers

    /// Read the FFI's thread-local last-error slot and convert it to a
    /// Swift `String`. The pointer is owned by the FFI (do NOT
    /// `string_free` it); we copy on read because the slot is
    /// overwritten by the next FFI call on this thread.
    private static func consumeLastError() -> String {
        guard let p = mci_brain_ffi_last_error_message() else {
            return "FFIBrainReader: unknown error"
        }
        return String(cString: p)
    }

    private static func decodeHits(_ raw: UnsafeMutablePointer<CChar>) throws -> [Hit] {
        let s = String(cString: raw)
        guard let data = s.data(using: .utf8) else {
            throw BrainReaderError.decodeFailed("non-UTF8 JSON from FFI")
        }
        do {
            let wire = try JSONDecoder().decode([HitWire].self, from: data)
            return wire.map { $0.toHit() }
        } catch {
            throw BrainReaderError.decodeFailed("FFIBrainReader: \(error)")
        }
    }

    private static func decodePrivacyMoments(
        _ raw: UnsafeMutablePointer<CChar>
    ) throws -> [PrivacyMoment] {
        let s = String(cString: raw)
        guard let data = s.data(using: .utf8) else {
            throw BrainReaderError.decodeFailed("non-UTF8 JSON from FFI")
        }
        do {
            let wire = try JSONDecoder().decode([PrivacyMomentWire].self, from: data)
            return wire.map { $0.toPrivacyMoment() }
        } catch {
            throw BrainReaderError.decodeFailed("FFIBrainReader: \(error)")
        }
    }

    private static func decodeObservedApps(
        _ raw: UnsafeMutablePointer<CChar>
    ) throws -> [ObservedApp] {
        let s = String(cString: raw)
        guard let data = s.data(using: .utf8) else {
            throw BrainReaderError.decodeFailed("non-UTF8 JSON from FFI")
        }
        do {
            let wire = try JSONDecoder().decode([ObservedAppWire].self, from: data)
            return wire.map { $0.toObservedApp() }
        } catch {
            throw BrainReaderError.decodeFailed("FFIBrainReader: \(error)")
        }
    }

    private static func decodeEpisodes(
        _ raw: UnsafeMutablePointer<CChar>
    ) throws -> [Episode] {
        let s = String(cString: raw)
        guard let data = s.data(using: .utf8) else {
            throw BrainReaderError.decodeFailed("non-UTF8 JSON from FFI")
        }
        do {
            let wire = try JSONDecoder().decode([EpisodeWire].self, from: data)
            return wire.map { $0.toEpisode() }
        } catch {
            throw BrainReaderError.decodeFailed("FFIBrainReader: \(error)")
        }
    }

    /// Decode either a `BriefWire` JSON object or the literal JSON `null`.
    /// The Rust FFI returns `null` for "no brief on this date" / "store
    /// has no briefs" — Swift's `Optional<BriefWire>` decoder reads that
    /// directly.
    private static func decodeOptionalBrief(
        _ raw: UnsafeMutablePointer<CChar>
    ) throws -> Brief? {
        let s = String(cString: raw)
        guard let data = s.data(using: .utf8) else {
            throw BrainReaderError.decodeFailed("non-UTF8 JSON from FFI (brief)")
        }
        do {
            let wire = try JSONDecoder().decode(BriefWire?.self, from: data)
            return wire?.toBrief()
        } catch {
            throw BrainReaderError.decodeFailed("FFIBrainReader.brief: \(error)")
        }
    }
}

// ---------------------------------------------------------------------------
// Wire mirrors — `Codable` shapes that match the Rust-side `HitJson` /
// `PrivacyMomentJson` exactly (snake_case keys). Kept private to this
// module so the public `BrainReader` surface (`Hit` / `PrivacyMoment`)
// stays camelCase.
// ---------------------------------------------------------------------------

private struct HitWire: Decodable {
    let event_id: UInt64
    let ts_us: UInt64
    let app_bundle_id: String?
    let window_title: String?
    let url: String?
    let ocr_text_snippet: String
    let source: String
    let score: Float?
    /// Cycle-8.35 PR-1: additive entity chip surface. `serde(default)` on
    /// the Rust side means older FFI builds (or hand-rolled test payloads)
    /// that omit this key still decode — we mirror that here by defaulting
    /// to an empty array on the Swift side too. See `docs/research/
    /// 2026-07-12-recall-ui-audit.md` §3.1.
    let entities: [String]?
    /// Cycle-8.35 PR-1: additive cross-app dot-connect ids. Same
    /// `serde(default)` compatibility contract as `entities` above.
    let linked_event_ids: [UInt64]?
    /// Cycle-8.35 PR-4: additive on-disk keyframe path. `serde(default)`
    /// on the Rust side + `Optional` on this decoder means older FFI
    /// builds (or hand-rolled test payloads) that omit the key still
    /// decode; the field simply reads as `nil` on the Swift side and
    /// the `HitRow` renders the placeholder-icon thumbnail. Wire key
    /// is snake_case (`thumbnail_path`), locked by
    /// `hit_json_wire_uses_snake_case_keys_for_new_fields` in
    /// `adapters/macos/mci-brain-ffi/tests/hit_entities_wire.rs`.
    let thumbnail_path: String?

    func toHit() -> Hit {
        Hit(
            eventId: event_id,
            tsUs: ts_us,
            appBundleId: app_bundle_id,
            windowTitle: window_title,
            url: url,
            ocrTextSnippet: ocr_text_snippet,
            source: source,
            score: score,
            entities: entities ?? [],
            linkedEventIds: linked_event_ids ?? [],
            thumbnailPath: thumbnail_path
        )
    }
}

private struct PrivacyMomentWire: Decodable {
    let ts_us: UInt64
    let app_bundle_id: String?
    let reason_code: UInt8

    func toPrivacyMoment() -> PrivacyMoment {
        PrivacyMoment(tsUs: ts_us, appBundleId: app_bundle_id, reasonCode: reason_code)
    }
}

/// Wire shape of `BriefJson` from `mci-brain-ffi` (snake_case fields,
/// matches the Rust serde derive). Mirror is private so the public
/// `Brief` surface stays camelCase.
private struct BriefWire: Decodable {
    let id: UInt64
    let date_local: String
    let generated_ts_us: UInt64
    let model_id: String
    let model_version: String
    let title: String
    let body: String
    let word_count: UInt32
    let source_event_count: UInt32

    func toBrief() -> Brief {
        Brief(
            rowId: id,
            dateLocal: date_local,
            generatedTsUs: generated_ts_us,
            modelId: model_id,
            modelVersion: model_version,
            title: title,
            body: body,
            wordCount: word_count,
            sourceEventCount: source_event_count
        )
    }
}

private struct QueryPayload: Encodable {
    let text: String
    let limit: Int
    let timeFromUs: UInt64?
    let timeToUs: UInt64?
    let appFilter: String?
    /// Cycle 8.42 — user-defined alias map. `nil` (default) is encoded as
    /// missing key so the FFI's `#[serde(default)]` yields an empty map,
    /// preserving pre-8.42 behavior.
    let userAliases: [String: [String]]?

    enum CodingKeys: String, CodingKey {
        case text
        case limit
        case timeFromUs = "time_from_us"
        case timeToUs = "time_to_us"
        case appFilter = "app_filter"
        case userAliases = "user_aliases"
    }
}

/// Cycle-8.37 PR-3: input payload for `mci_brain_ffi_events_by_ids`.
/// Serializes to `{"ids":[<u64>,...]}` — the exact wire the Rust
/// `EventsByIdsQueryJson` decodes. `ids` is snake_case-safe by virtue of
/// being a single word.
private struct EventsByIdsPayload: Encodable {
    let ids: [UInt64]
}

private struct ObservedAppsQueryPayload: Encodable {
    let limit: Int
    let timeFromUs: UInt64?

    enum CodingKeys: String, CodingKey {
        case limit
        case timeFromUs = "time_from_us"
    }
}

private struct ObservedAppWire: Decodable {
    let app_bundle_id: String
    let count: UInt64

    func toObservedApp() -> ObservedApp {
        ObservedApp(appBundleId: app_bundle_id, count: count)
    }
}

private struct EpisodeWire: Decodable {
    let id: UInt64
    let app_bundle_id: String?
    let ts_start_us: UInt64
    let ts_end_us: UInt64
    let event_count: UInt64

    func toEpisode() -> Episode {
        Episode(
            episodeId: id,
            appBundleId: app_bundle_id,
            tsStartUs: ts_start_us,
            tsEndUs: ts_end_us,
            eventCount: event_count
        )
    }
}
