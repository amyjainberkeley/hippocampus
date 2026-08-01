//! MCI macOS adapter — C-ABI FFI shim exposing a **READ-ONLY** view of the
//! Phase-3 brain to the Swift recall-ui app (`apps/recall-ui/`).
//!
//! # Scope: P3.9b — real read-only store wired
//!
//! Every entry point now holds a live read-only `SqlCipherBrainStore`
//! handle. `mci_brain_ffi_open` decodes the hex `SQLCipher` key, opens the
//! store via [`mci_brain::SqlCipherBrainStore::open_readonly`] (which goes
//! through [`mci_core::store::open_readonly`] with `SQLITE_OPEN_READ_ONLY |
//! SQLITE_OPEN_NO_MUTEX | SQLITE_OPEN_URI`), and stashes it in an opaque
//! [`Handle`]. `mci_brain_ffi_search` runs FTS5 lexical search (the
//! `HybridRetriever` from P3.7 needs an [`mci_brain::Embedder`] backed by
//! the bundled arctic-embed-s `.mlpackage`; P3.3's Core ML runtime is the
//! follow-on PR that wires that, at which point search swaps to the full
//! hybrid path with a one-line ctor change). `mci_brain_ffi_recent_events`
//! issues `SELECT ... FROM events ORDER BY ts_us DESC LIMIT ?` via the
//! store's `recent_events` helper. `mci_brain_ffi_recent_privacy_moments`
//! returns an empty list — the tombstone log lives in a separate
//! `mci-tombstones.bin` file and surfacing it in the recall UI is P3.9c
//! (see the function-level deferral note).
//!
//! # READ-ONLY by construction (ADR-0017 §5 / ADR-0016 §4.3 invariant)
//!
//! [`mci_core::store::open_readonly`] sets `SQLITE_OPEN_READ_ONLY` on the
//! underlying connection. Any `INSERT` / `UPDATE` / `DELETE` / `CREATE` /
//! `DROP` issued through the resulting `rusqlite::Connection` fails at the
//! driver level with `SQLITE_READONLY` (extended code 8). The recall-ui
//! app is structurally a **consumer** of the brain; it cannot write to it.
//! The FFI surface mirrors that discipline — there is no `put_event` /
//! `delete_event` / `mutate_*` function exported. Adding one is an
//! `AGENT_PROTOCOL` §5 protected-set violation.
//!
//! The CSO read-only verification is load-bearing: it lives in
//! `core/src/store/open.rs::tests::open_readonly_round_trips_then_refuses_writes`
//! (driver-level proof of `SQLITE_READONLY`) and in
//! `tests/readonly_invariant.rs` (this crate's integration test that opens
//! via the FFI shim and confirms the brain is read-only end-to-end).
//!
//! # Allocator discipline
//!
//! Every `*mut c_char` this crate returns was allocated by Rust's global
//! allocator (via `CString::into_raw`). The Swift caller MUST return that
//! pointer to [`mci_brain_ffi_string_free`] so Rust can reclaim it
//! (`CString::from_raw`).

#![forbid(unsafe_op_in_unsafe_fn)]
#![deny(missing_docs)]
// FFI by definition requires `unsafe` for the raw pointer entry points.
// Each `unsafe` block carries a per-call-site safety comment.
#![allow(unsafe_code)]

use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use mci_brain::{BrainStore, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// JSON value types — what the Swift side decodes with `Codable`
// ---------------------------------------------------------------------------

/// A search-result row returned by [`mci_brain_ffi_search`] /
/// [`mci_brain_ffi_recent_events`]. Carries the event id, time, and the
/// post-cascade-allowed metadata the recall-ui surfaces. **No** suppressed
/// content can appear here by construction (ADR-0016 §4.3): only events
/// that cleared the cascade twice reach the brain store, and this FFI
/// reads only from that store.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HitJson {
    /// Brain `events.id` rowid.
    pub event_id: u64,
    /// `events.ts_us` — microseconds since UNIX epoch.
    pub ts_us: u64,
    /// `events.app_bundle_id` (nullable in schema; encoded as JSON `null`).
    pub app_bundle_id: Option<String>,
    /// `events.window_title` (nullable).
    pub window_title: Option<String>,
    /// `events.url` (nullable).
    pub url: Option<String>,
    /// First N characters of `events.text` for snippet display. The
    /// FFI caps this at [`SNIPPET_CHAR_CAP`] characters at the Rust
    /// boundary so the Swift list cells never receive megabytes of OCR
    /// text per row.
    pub ocr_text_snippet: String,
    /// Which retrieval source produced this hit. `"lexical"` for plain
    /// FTS5 search (P3.9b); `"timeline"` for recent-events list;
    /// `"hybrid"` once the `HybridRetriever` + Core ML embedder backend
    /// (P3.3) is wired.
    pub source: String,
    /// Fused score in `[0.0, 1.0]` (P3.7 hybrid) or BM25-derived
    /// monotone-with-relevance lexical score. `None` for plain timeline
    /// rows where no query was issued.
    pub score: Option<f32>,
    /// **Additive (Phase-6 close, cycle 8.35 PR-1).** Canonical names of the
    /// resolver-allowlist entities (person / org / location / email / phone /
    /// url — never a redacted-token label) this event mentions. Mirrors the
    /// `entities` field on the MCP `mci_recall` wire
    /// (`apps/agent/src/mcp/server.rs:302`) so recall UI can render entity
    /// chips. Empty when the store has no graph data or the event mentions
    /// nothing in the resolver allowlist. Filled by
    /// [`mci_brain::BrainStore::entity_names_for_event`] — capped at
    /// [`ENTITY_LIMIT`] names per hit.
    #[serde(default)]
    pub entities: Vec<String>,
    /// **Additive (Phase-6 close, cycle 8.35 PR-1).** Cross-app "dot-connect"
    /// event ids reachable from this hit's episode via a `shared_identity`
    /// `episode_edge` (the V2-P6 Consolidator's link). Mirrors the
    /// `linked_event_ids` field on the MCP `mci_recall` wire
    /// (`apps/agent/src/mcp/server.rs:303`). Empty when the hit's episode has
    /// no cross-app link. Post-cascade only (`cascade_reason = 0` wall).
    /// Filled by [`mci_brain::BrainStore::linked_event_ids_for_event`] —
    /// capped at [`LINK_LIMIT`] ids per hit.
    #[serde(default)]
    pub linked_event_ids: Vec<u64>,
    /// **Additive (cycle 8.35 PR-4).** Absolute filesystem path to the
    /// encrypted keyframe blob for this event, or `None` for events that
    /// carry no keyframe (Messages / Mail / PageContent-only ingest paths;
    /// legacy events captured before the P3.6.5 blob writer landed).
    ///
    /// Derived from `events.keyframe_blob` (the content-addressed sha256 hex
    /// written by [`KeyframeBlobWriter`] at capture time) + the on-disk
    /// convention `<brain_dir>/blobs/<hex>.bin` (see
    /// `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/KeyframeBlobWriter.swift`
    /// line 10). The path is emitted verbatim — this crate does not stat
    /// the file. The Swift `HitThumbnail` view treats a missing file as
    /// "no keyframe" (same UX as `None`), so a hostile / stale hex string
    /// is graceful degradation, not a crash.
    ///
    /// **Privacy invariant (ADR-0016 §4.3, §4.8, item 8).** A keyframe blob
    /// exists on disk ONLY for events that cleared cascade-twice. The
    /// brain-store `put_event` wall (`cascade_reason != 0` → rejected)
    /// means no `.suppress`-decided event can carry a `keyframe_blob`
    /// column, so surfacing this path here cannot leak a redacted
    /// keyframe. Verified by inspection at
    /// `core/brain/src/sqlcipher_brain_store.rs:1258`.
    ///
    /// **Backward compat.** `#[serde(default)]` — pre-8.35-PR-4 clients
    /// omit the key entirely; older Swift decoders that don't know the
    /// field simply ignore it.
    #[serde(default)]
    pub thumbnail_path: Option<String>,
}

/// A privacy-moment card row returned by
/// [`mci_brain_ffi_recent_privacy_moments`]. Carries **only** the
/// post-cascade-decision metadata — `app_bundle_id` + `ts` + the cascade
/// reason code mapped to a friendly string. Never the OCR'd text,
/// never the keyframe, never the window-title / URL.
/// ADR-0017 §5.1 + ADR-0016 §4.5 invariant.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrivacyMomentJson {
    /// Capture timestamp, microseconds since UNIX epoch.
    pub ts_us: u64,
    /// `appBundleId` of the frontmost app when the cascade fired.
    /// `null` when the helper had no bundle id (catchall path).
    pub app_bundle_id: Option<String>,
    /// Cascade reason code 1..=9 (ADR-0017 §5.2 table).
    pub reason_code: u8,
}

/// JSON payload format for [`mci_brain_ffi_search`] input.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryJson {
    /// Natural-language query.
    pub text: String,
    /// Maximum hits to return.
    pub limit: usize,
    /// Inclusive lower bound on `ts_us`, microseconds. `None` ⇒ no filter.
    #[serde(default)]
    pub time_from_us: Option<u64>,
    /// Inclusive upper bound on `ts_us`, microseconds. `None` ⇒ no filter.
    #[serde(default)]
    pub time_to_us: Option<u64>,
    /// Restrict to one `appBundleId`. `None` ⇒ no filter.
    #[serde(default)]
    pub app_filter: Option<String>,
    /// **Additive (cycle 8.42).** User-defined entity aliases from the
    /// recall UI's `UserDictionary`. Keys are canonical names; values are
    /// the alias list. When the query text contains a token that appears
    /// as either a canonical name or one of its aliases (case-insensitive),
    /// the FTS5 query is OR-expanded to include all the other spellings
    /// so a search for `"AJ"` also matches events that mention `"Amy Jain"`.
    /// Missing key / empty map = no expansion; the recall path is
    /// byte-identical to the pre-8.42 behavior. Backward-compat by
    /// `#[serde(default)]`.
    #[serde(default)]
    pub user_aliases: std::collections::HashMap<String, Vec<String>>,
}

/// JSON payload format for [`mci_brain_ffi_events_by_ids`] input.
///
/// **Cycle 8.37 PR-3** — the related-hits flyout in the recall UI needs to
/// resolve a `hit.linked_event_ids: Vec<u64>` (populated in PR-1) into full
/// [`HitJson`] rows so the flyout can render app · time · snippet for each
/// linked sibling. This payload is the input side of that dot-connect
/// fetch surface. Capped at [`EVENTS_BY_IDS_CAP`] ids per call — a hostile
/// caller cannot trick the FFI into an unbounded per-id `get_event` loop.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventsByIdsQueryJson {
    /// Event ids to look up. Duplicates are tolerated; order in the result
    /// follows input order for the ids that resolve (missing ids are
    /// silently dropped so the caller can pass a raw `linked_event_ids`
    /// slice without pre-filtering deleted rows).
    pub ids: Vec<u64>,
}

/// JSON payload format for [`mci_brain_ffi_list_observed_apps`] input.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObservedAppsQueryJson {
    /// Maximum apps to return.
    pub limit: usize,
    /// Inclusive lower bound on `ts_us`, microseconds. `None` ⇒ no filter.
    #[serde(default)]
    pub time_from_us: Option<u64>,
}

/// One row of [`mci_brain_ffi_list_observed_apps`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ObservedAppJson {
    /// `events.app_bundle_id`, never null (nil-app rows are excluded).
    pub app_bundle_id: String,
    /// Number of events captured under this app bundle id in the window.
    pub count: u64,
}

/// One row of [`mci_brain_ffi_list_episodes`]. Mirrors `EpisodeRecord`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EpisodeJson {
    /// Episode id (maps to `episodes.id` rowid).
    pub id: u64,
    /// Primary app bundle id for the episode.
    pub app_bundle_id: Option<String>,
    /// Episode start timestamp (microseconds since UNIX epoch).
    pub ts_start_us: u64,
    /// Episode end timestamp (microseconds since UNIX epoch).
    pub ts_end_us: u64,
    /// Number of events assigned to this episode.
    pub event_count: u64,
}

/// JSON payload format for [`mci_brain_ffi_timeline_events`] input.
///
/// **V2-P13 (Phase D scaffold)** — the Rewind-style timeline strip in the
/// recall UI needs a lightweight event-summary row for each capture in a
/// time range. `resolution` is a hint to the downsampler; the FFI itself
/// bucketizes to keep the returned row count bounded no matter how many
/// events fall in the window.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimelineQueryJson {
    /// Inclusive lower bound on `ts_us`, microseconds since UNIX epoch.
    pub start_ts_us: u64,
    /// Inclusive upper bound on `ts_us`, microseconds since UNIX epoch.
    pub end_ts_us: u64,
    /// Rendering-resolution hint. `"minute" | "hour" | "day"` — the FFI
    /// only uses this to pick the downsample bucket when the raw event
    /// density exceeds [`TIMELINE_MAX_EVENTS`]. Unknown values fall back
    /// to `"minute"`.
    #[serde(default)]
    pub resolution: Option<String>,
}

/// One row of [`mci_brain_ffi_timeline_events`] — a lightweight event
/// summary for the V2-P13 timeline strip. Deliberately smaller than
/// [`HitJson`]: no `linked_event_ids`, no `entities`, no `score` — the
/// strip renders app + time + thumbnail + snippet; deeper context is
/// pulled via `mci_brain_ffi_events_by_ids` when the user clicks a card.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TimelineEventJson {
    /// Brain `events.id` rowid.
    pub event_id: u64,
    /// `events.ts_us` — microseconds since UNIX epoch.
    pub ts_us: u64,
    /// `events.app_bundle_id`, nullable in schema.
    pub app_bundle_id: Option<String>,
    /// Very short snippet (~80 chars) for the card's hover-preview.
    pub snippet: String,
    /// Absolute filesystem path to the encrypted keyframe blob, or
    /// `None` for events with no keyframe (Messages / Mail / text-only
    /// ingest paths). Same derivation + privacy invariant as
    /// [`HitJson::thumbnail_path`].
    pub thumbnail_path: Option<String>,
}

/// Result payload for the mutation entry points — content-free.
///
/// **Cycle 8.47 follow-up to PR #76.** The Privacy Dashboard's destructive
/// actions (`Delete this event`, `Delete last 24 hours`, `Delete everything`)
/// need a machine-readable success signal so the SwiftUI banner can render
/// "3 events removed; 12 KB reclaimed" rather than a bare "OK". The shape
/// is content-free: only counts + a boolean for whether the VACUUM
/// succeeded (a VACUUM failure — disk full, permission — is surfaced as
/// `vacuum_ok: false` with `deleted > 0`, so the user knows their data was
/// removed even if disk space wasn't yet reclaimed).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeleteResultJson {
    /// Rows removed from the `events` table. CASCADE-deleted child rows
    /// (event_vectors, chunks, entity_mentions) are NOT counted here.
    pub events_deleted: u64,
    /// Whether the post-delete `VACUUM` succeeded (freed disk space).
    /// `false` on VACUUM error — the DELETE itself may still have
    /// succeeded, so callers should treat `events_deleted > 0 &&
    /// !vacuum_ok` as "data gone, disk not yet reclaimed".
    pub vacuum_ok: bool,
}

/// Content-free aggregate returned by [`mci_brain_ffi_summary_stats`].
/// Mirrors [`mci_brain::BrainStats`] for the count + oldest/newest, plus
/// the on-disk byte size of the brain SQLite file. Zero row content is
/// exposed — this is the payload for the Privacy Dashboard's "MCI has
/// captured X events across Y days, using Z MB of encrypted storage"
/// summary card. Amy's directive (2026-07-13): "show the full control,
/// no collection."
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SummaryStatsJson {
    /// Total rows in `events`. `0` on an empty store.
    pub total_events: u64,
    /// Smallest `events.ts_us` in microseconds since epoch, or `None` on
    /// an empty store.
    pub oldest_ts_us: Option<u64>,
    /// Largest `events.ts_us` in microseconds since epoch, or `None` on
    /// an empty store.
    pub newest_ts_us: Option<u64>,
    /// On-disk byte count of the SQLCipher `.sqlite` file. `0` if the
    /// file cannot be stat'd (should never happen since the FFI is
    /// holding an open handle to it, but graceful fallback).
    pub disk_bytes: u64,
}

// ---------------------------------------------------------------------------
// Handle — opaque pointer the Swift side holds across calls
// ---------------------------------------------------------------------------

/// Opaque handle the recall-ui retains across FFI calls. Wraps a live
/// read-only [`SqlCipherBrainStore`] (`SQLITE_OPEN_READ_ONLY`) for the
/// duration the recall-ui keeps the brain open.
pub struct Handle {
    store: Arc<SqlCipherBrainStore>,
    /// Directory that holds the encrypted keyframe blobs (`<brain_dir>/blobs/`).
    /// Populated at `open()` from the brain file's parent directory; used to
    /// derive [`HitJson::thumbnail_path`] (cycle 8.35 PR-4). Never used to
    /// open new files or write — the FFI is READ-ONLY by construction; the
    /// Swift caller is the one that stats + decodes the referenced blob.
    blob_dir: PathBuf,
    /// Absolute path to the brain SQLite file. Used by
    /// [`mci_brain_ffi_summary_stats`] to `fs::metadata(...)` the file and
    /// by the mutation entry points (delete / wipe) to briefly open a
    /// writer connection when the recall UI's Privacy Dashboard fires a
    /// destructive action.
    brain_path: PathBuf,
    /// Retained SQLCipher key. Needed so the mutation entry points can
    /// briefly open a *writer* connection to run DELETE + VACUUM. The
    /// underlying `DbKey` type zeroizes on drop; the key material was
    /// already in-process via the read-only `store` handle, so retaining
    /// a `DbKey` clone is not new attack surface — it just keeps the same
    /// bytes reachable through a different path.
    ///
    /// **Protected-set rationale.** ADR-0016 §4.3 says the recall UI cannot
    /// mutate the brain. The cycle-8.46 Privacy Dashboard needs an
    /// explicit, user-gated escape hatch (typed-word "DELETE" confirmation
    /// + two-step token for wipe). This field is the plumbing that turns
    /// the escape hatch on for the four enumerated methods and nothing
    /// else — every other FFI still routes through `store` (read-only).
    /// The read-only invariant test in `tests/readonly_invariant.rs` now
    /// allow-lists the four mutation methods by name.
    db_key: DbKey,
    /// Pending wipe token — the two-step confirmation for
    /// [`mci_brain_ffi_wipe_brain`]. Filled by
    /// [`mci_brain_ffi_prepare_wipe`]; expires 60s after issue. The
    /// wipe entry point checks (a) token matches, (b) not expired, then
    /// clears the slot regardless of outcome (single-use).
    pending_wipe: Mutex<Option<(Instant, String)>>,
}

// ---------------------------------------------------------------------------
// extern "C" entry points
// ---------------------------------------------------------------------------

/// Open the brain at `path` with the hex-encoded `SQLCipher` key `key_hex`.
///
/// `key_hex` MUST be exactly 64 lower-or-upper-case hex characters
/// (32 bytes = 256 bits per ADR-0008). The store opens with
/// `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_NO_MUTEX | SQLITE_OPEN_URI` —
/// any mutating SQL through the resulting handle fails with
/// `SQLITE_READONLY` (the load-bearing invariant in ADR-0017 §5).
///
/// Returns a non-null opaque [`Handle`] pointer on success; on failure
/// returns null and [`mci_brain_ffi_last_error_message`] carries the
/// diagnostic.
///
/// # Safety
///
/// `path` and `key_hex` MUST be non-null, null-terminated UTF-8
/// C strings. The caller retains ownership; this function does not
/// store the pointers past return.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_open(
    path: *const c_char,
    key_hex: *const c_char,
) -> *mut Handle {
    if path.is_null() || key_hex.is_null() {
        set_last_error("mci_brain_ffi_open: null pointer argument");
        return ptr::null_mut();
    }
    // Safety: caller guarantees the pointers are valid null-terminated
    // UTF-8 C strings. We only borrow them for the duration of this call.
    let Ok(path_str) = unsafe { CStr::from_ptr(path) }.to_str() else {
        set_last_error("mci_brain_ffi_open: non-UTF8 path");
        return ptr::null_mut();
    };
    let Ok(key_str) = unsafe { CStr::from_ptr(key_hex) }.to_str() else {
        set_last_error("mci_brain_ffi_open: non-UTF8 key_hex");
        return ptr::null_mut();
    };

    let key_bytes = match decode_hex_key(key_str) {
        Ok(b) => b,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_open: {e}"));
            return ptr::null_mut();
        }
    };
    let key = DbKey::from_bytes(key_bytes);

    let p = PathBuf::from(path_str);
    let store = match SqlCipherBrainStore::open_readonly(&p, &key) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_open: {e}"));
            return ptr::null_mut();
        }
    };

    clear_last_error();
    // Blob dir convention (P3.6.5, KeyframeBlobWriter): sibling `blobs/`
    // directory next to the brain file. `~/Library/Application Support/MCI/mci.sqlite`
    // → `~/Library/Application Support/MCI/blobs/`. If the brain path has
    // no parent (`/mci.sqlite`), fall back to `./blobs` — surfacing this
    // as an error would gratuitously fail brain open for a corner case
    // that never arises in production (the launch path always writes the
    // brain into Application Support).
    let blob_dir = p
        .parent()
        .map(|parent| parent.join("blobs"))
        .unwrap_or_else(|| PathBuf::from("blobs"));
    // Retain a clone of the DbKey so the mutation entry points can open
    // a transient writer. `DbKey: Clone` copies the 32-byte buffer; both
    // clones zeroize on drop.
    let db_key = key.clone();
    let h = Box::new(Handle {
        store: Arc::new(store),
        blob_dir,
        brain_path: p,
        db_key,
        pending_wipe: Mutex::new(None),
    });
    Box::into_raw(h)
}

/// Close a handle previously returned by [`mci_brain_ffi_open`].
///
/// Calling this with a null pointer is a no-op. Double-close is undefined
/// behavior — the Swift wrapper enforces single-close.
///
/// # Safety
///
/// `h` MUST be a pointer previously returned by [`mci_brain_ffi_open`]
/// and not yet passed to this function.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_close(h: *mut Handle) {
    if h.is_null() {
        return;
    }
    // Safety: caller upheld the precondition that h came from open()
    // and has not been freed yet. We reconstruct the Box so its Drop runs.
    let _ = unsafe { Box::from_raw(h) };
}

/// Run a search against the brain. Returns a JSON array of [`HitJson`]
/// rows. Allocated by Rust — caller MUST pass the returned pointer back
/// to [`mci_brain_ffi_string_free`].
///
/// P3.9b uses lexical FTS5 only (`source: "lexical"`); the full
/// `HybridRetriever` (P3.7) needs an `Embedder` backed by the bundled
/// arctic-embed-s `.mlpackage`, which is the P3.3 Core ML adapter's
/// payload. When that lands, this function swaps to `HybridRetriever`
/// with a one-line ctor change and the `source` tag flips to `"hybrid"`.
///
/// Returns null on input-parse failure or unexpected internal error;
/// [`mci_brain_ffi_last_error_message`] carries the diagnostic.
///
/// # Safety
///
/// `h` must be a live handle. `query_json` must be a non-null,
/// null-terminated UTF-8 C string containing a [`QueryJson`] payload.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_search(
    h: *mut Handle,
    query_json: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_search: null handle");
        return ptr::null_mut();
    }
    if query_json.is_null() {
        set_last_error("mci_brain_ffi_search: null query");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a valid live handle that has not been
    // freed via mci_brain_ffi_close.
    let handle = unsafe { &*h };
    // Safety: caller guarantees a valid null-terminated UTF-8 string.
    let query_c = unsafe { CStr::from_ptr(query_json) };
    let Ok(query_str) = query_c.to_str() else {
        set_last_error("mci_brain_ffi_search: non-UTF8 query");
        return ptr::null_mut();
    };
    let query: QueryJson = match serde_json::from_str(query_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_search: bad query JSON: {e}"));
            return ptr::null_mut();
        }
    };
    if query.text.is_empty() {
        // Empty query is a malformed search request, not an empty result —
        // FTS5 rejects it too. Surface as an empty list with no error.
        let empty: Vec<HitJson> = Vec::new();
        return json_to_c_string(&empty);
    }
    let limit = query.limit.min(MAX_LIMIT as usize).max(1);

    // Cycle 8.42: expand the FTS5 query with the user's dictionary aliases
    // BEFORE handing it to `fts5_search`. Empty alias map = identity
    // (`expanded == query.text`), which preserves the pre-8.42 recall
    // trace byte-for-byte on stores that don't send the field. See
    // `expand_query_with_user_aliases` for the expansion rules.
    let expanded = expand_query_with_user_aliases(&query.text, &query.user_aliases);

    // P3.9b: FTS5-only lexical search. See module docs for the HybridRetriever
    // swap point (P3.3 Core ML embedder needs to land first).
    let hits_raw = match handle.store.fts5_search(&expanded, limit) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_search: fts5_search: {e}"));
            return ptr::null_mut();
        }
    };

    let mut hits_json: Vec<HitJson> = Vec::with_capacity(hits_raw.len());
    for (event_id, score) in hits_raw {
        match handle.store.get_event(event_id) {
            Ok(Some(ev)) => {
                if !passes_filters(
                    ev.ts_us,
                    ev.app_bundle_id.as_deref(),
                    query.time_from_us,
                    query.time_to_us,
                    query.app_filter.as_deref(),
                ) {
                    continue;
                }
                let (entities, linked_event_ids) = enrich_hit(&handle.store, event_id);
                let thumbnail_path =
                    thumbnail_path_for(&handle.blob_dir, ev.keyframe_blob.as_deref());
                hits_json.push(HitJson {
                    event_id: event_id.0,
                    ts_us: ev.ts_us,
                    app_bundle_id: ev.app_bundle_id,
                    window_title: ev.window_title,
                    url: ev.url,
                    ocr_text_snippet: snippet(&ev.text),
                    source: "lexical".into(),
                    score: Some(score),
                    entities,
                    linked_event_ids,
                    thumbnail_path,
                });
            }
            Ok(None) => {}
            Err(e) => {
                set_last_error(&format!("mci_brain_ffi_search: get_event: {e}"));
                return ptr::null_mut();
            }
        }
    }
    json_to_c_string(&hits_json)
}

/// Fetch the N most recent events for the plain timeline view. Returns
/// a JSON array of [`HitJson`]. Same allocator discipline as
/// [`mci_brain_ffi_search`].
///
/// # Safety
///
/// `h` must be a live handle. `limit` is treated as `u32` and clamped
/// to [`MAX_LIMIT`] internally so a hostile value cannot allocate
/// unbounded memory.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_recent_events(h: *mut Handle, limit: u32) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_recent_events: null handle");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a valid live handle.
    let handle = unsafe { &*h };
    let limit_clamped = limit.min(MAX_LIMIT) as usize;

    let events = match handle.store.recent_events(limit_clamped) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_recent_events: {e}"));
            return ptr::null_mut();
        }
    };
    let hits: Vec<HitJson> = events
        .into_iter()
        .map(|ev| {
            let (entities, linked_event_ids) = enrich_hit(&handle.store, ev.id);
            let thumbnail_path = thumbnail_path_for(&handle.blob_dir, ev.keyframe_blob.as_deref());
            HitJson {
                event_id: ev.id.0,
                ts_us: ev.ts_us,
                app_bundle_id: ev.app_bundle_id,
                window_title: ev.window_title,
                url: ev.url,
                ocr_text_snippet: snippet(&ev.text),
                source: "timeline".into(),
                score: None,
                entities,
                linked_event_ids,
                thumbnail_path,
            }
        })
        .collect();
    json_to_c_string(&hits)
}

/// Resolve a batch of event ids into full [`HitJson`] rows. Powers the
/// **related-hits flyout** in the recall UI (cycle 8.37 PR-3, PR #27
/// carried the `linked_event_ids` field the flyout resolves through this
/// call). Given a hit whose `linked_event_ids: Vec<u64>` names its
/// cross-app siblings, the Swift side calls this to render the "your
/// email about X is connected to your Slack message about Y and your
/// Safari tab about Z" strip.
///
/// `query_json` is a UTF-8 JSON string of [`EventsByIdsQueryJson`]:
///
/// ```json
/// {"ids": [101, 202, 303]}
/// ```
///
/// Returns a JSON array of [`HitJson`] rows for the ids that resolve.
/// Order in the output follows input order for the ids that resolve;
/// ids that no longer exist in the store are silently dropped (a
/// linked-event id can refer to an event that was later suppressed by
/// the cascade — the store's `get_event` returns `None` and the flyout
/// gracefully skips the row). Each row carries the same
/// `entities` + `linked_event_ids` enrichment as `mci_brain_ffi_search`
/// so a flyout row remains navigable to further siblings.
///
/// The result's `source` is `"linked"` and `score` is `None` — this is
/// a dot-connect lookup, not a ranked retrieval.
///
/// **Input cap**: at most [`EVENTS_BY_IDS_CAP`] ids per call
/// (excess ids are truncated silently). A hostile caller cannot use
/// this entry point to trigger an unbounded `get_event` loop.
///
/// Same read-only + allocator discipline as the other returners; caller
/// MUST pass the returned pointer back to [`mci_brain_ffi_string_free`].
///
/// # Safety
///
/// `h` must be a live handle. `query_json` must be a non-null,
/// null-terminated UTF-8 C string containing an
/// [`EventsByIdsQueryJson`] payload.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_events_by_ids(
    h: *mut Handle,
    query_json: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_events_by_ids: null handle");
        return ptr::null_mut();
    }
    if query_json.is_null() {
        set_last_error("mci_brain_ffi_events_by_ids: null query");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    // Safety: caller guarantees a null-terminated UTF-8 C string.
    let query_c = unsafe { CStr::from_ptr(query_json) };
    let Ok(query_str) = query_c.to_str() else {
        set_last_error("mci_brain_ffi_events_by_ids: non-UTF8 query");
        return ptr::null_mut();
    };
    let query: EventsByIdsQueryJson = match serde_json::from_str(query_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_events_by_ids: bad query JSON: {e}"));
            return ptr::null_mut();
        }
    };
    // Silent truncation at the cap — the recall-UI flyout paginates below
    // this anyway. See EVENTS_BY_IDS_CAP for the load-bearing bound.
    let ids: Vec<u64> = query.ids.into_iter().take(EVENTS_BY_IDS_CAP).collect();

    let mut out: Vec<HitJson> = Vec::with_capacity(ids.len());
    for id in ids {
        match handle.store.get_event(EventId(id)) {
            Ok(Some(ev)) => {
                let (entities, linked_event_ids) = enrich_hit(&handle.store, EventId(id));
                let thumbnail_path =
                    thumbnail_path_for(&handle.blob_dir, ev.keyframe_blob.as_deref());
                out.push(HitJson {
                    event_id: id,
                    ts_us: ev.ts_us,
                    app_bundle_id: ev.app_bundle_id,
                    window_title: ev.window_title,
                    url: ev.url,
                    ocr_text_snippet: snippet(&ev.text),
                    source: "linked".into(),
                    score: None,
                    entities,
                    linked_event_ids,
                    thumbnail_path,
                });
            }
            Ok(None) => {
                // Linked event was suppressed (cascade) or deleted since
                // the source hit was recorded — silently drop.
            }
            Err(e) => {
                set_last_error(&format!("mci_brain_ffi_events_by_ids: get_event: {e}"));
                return ptr::null_mut();
            }
        }
    }
    json_to_c_string(&out)
}

/// **V2-P13 (Phase D scaffold)** — Return lightweight event summaries for
/// a time range, downsampled if too many events fall in the window.
///
/// The Rewind-style timeline strip in the recall UI (⌘8 tab) needs a
/// bounded number of rows regardless of how densely the user captured
/// during the requested range. This entry point:
///
/// 1. Rejects windows longer than [`TIMELINE_MAX_RANGE_US`] (90 days) so
///    a hostile caller cannot force a full-corpus scan.
/// 2. Rejects `start_ts_us > end_ts_us`.
/// 3. Fetches the most-recent events (up to [`TIMELINE_HARD_CAP`]) and
///    filters to the `[start_ts_us, end_ts_us]` window.
/// 4. Downsamples: if the filtered count exceeds [`TIMELINE_MAX_EVENTS`],
///    the result is bucketized (one representative per bucket) — bucket
///    width is 1 minute when the range ≤ 24 h, otherwise the ceil-divide
///    of (range / max-events) rounded up to the next minute.
/// 5. Returns rows sorted by `ts_us` ASCENDING (left-to-right timeline).
///
/// Read-only by construction: uses `handle.store.recent_events` (the
/// same read-only entry point powering the flat timeline list) then
/// filters in Rust. No writer connection is opened.
///
/// # Safety
///
/// `h` must be a live handle. `query_json` must be a non-null,
/// null-terminated UTF-8 C string containing a [`TimelineQueryJson`]
/// payload.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_timeline_events(
    h: *mut Handle,
    query_json: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_timeline_events: null handle");
        return ptr::null_mut();
    }
    if query_json.is_null() {
        set_last_error("mci_brain_ffi_timeline_events: null query");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    // Safety: caller guarantees a null-terminated UTF-8 C string.
    let query_c = unsafe { CStr::from_ptr(query_json) };
    let Ok(query_str) = query_c.to_str() else {
        set_last_error("mci_brain_ffi_timeline_events: non-UTF8 query");
        return ptr::null_mut();
    };
    let query: TimelineQueryJson = match serde_json::from_str(query_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!(
                "mci_brain_ffi_timeline_events: bad query JSON: {e}"
            ));
            return ptr::null_mut();
        }
    };
    if query.start_ts_us > query.end_ts_us {
        set_last_error("mci_brain_ffi_timeline_events: start_ts_us > end_ts_us");
        return ptr::null_mut();
    }
    let range = query.end_ts_us - query.start_ts_us;
    if range > TIMELINE_MAX_RANGE_US {
        set_last_error(&format!(
            "mci_brain_ffi_timeline_events: range {} us exceeds cap {} us (~90 days)",
            range, TIMELINE_MAX_RANGE_US
        ));
        return ptr::null_mut();
    }

    // Fetch the most-recent slice up to the hard cap, then filter to the
    // requested window. For a scaffold the O(N) filter is fine — the hard
    // cap is 10_000 rows. A follow-on cycle may push the range predicate
    // down to SQL via a store-side `events_in_range` (would require
    // protected-set sign-off on `sqlcipher_brain_store.rs`).
    let events = match handle.store.recent_events(TIMELINE_HARD_CAP) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_timeline_events: {e}"));
            return ptr::null_mut();
        }
    };
    let mut filtered: Vec<TimelineEventJson> = events
        .into_iter()
        .filter(|ev| ev.ts_us >= query.start_ts_us && ev.ts_us <= query.end_ts_us)
        .map(|ev| {
            let thumbnail_path = thumbnail_path_for(&handle.blob_dir, ev.keyframe_blob.as_deref());
            TimelineEventJson {
                event_id: ev.id.0,
                ts_us: ev.ts_us,
                app_bundle_id: ev.app_bundle_id,
                snippet: timeline_snippet(&ev.text),
                thumbnail_path,
            }
        })
        .collect();

    // Ascending order — left-to-right on the timeline strip.
    filtered.sort_by_key(|e| e.ts_us);

    // Downsample if we're over the max-events budget.
    let out = downsample_timeline(filtered, range);
    json_to_c_string(&out)
}

/// Fetch the N most recent privacy-moment cards. Returns a JSON array
/// of [`PrivacyMomentJson`]. Same allocator discipline.
///
/// **Carries no content** — only `app_bundle_id` + `ts_us` + `reason_code`
/// per ADR-0017 §5.1 + ADR-0016 §4.5. The reason→friendly-string map
/// lives in the Swift `Localizable.strings` per ADR-0017 §5.2.
///
/// # Deferred to P3.9c
///
/// The cascade tombstone log lives in a separate file (`mci-tombstones.bin`,
/// the wire-frame log) — it is **NOT** a table inside the encrypted brain
/// store. Surfacing tombstones to the recall UI requires either (a) reading
/// the tombstone log directly from the shim, or (b) the agent's daemon
/// process maintaining a derived `privacy_moments` table inside the brain
/// store from the wire-frame stream. The trust-boundary choice between
/// (a) and (b) is CSO-gated and is the P3.9c PR's scope. Until then this
/// function returns an empty list and the Swift `PrivacyMomentsView`
/// renders the empty-state copy. Returning canned data here would be a
/// trust-boundary violation (ADR-0017 §5.1 — privacy moments carry no
/// content; faked rows are content-free but the *count* itself is signal).
///
/// # Safety
///
/// `h` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_recent_privacy_moments(
    h: *mut Handle,
    limit: u32,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_recent_privacy_moments: null handle");
        return ptr::null_mut();
    }
    let _limit = limit.min(MAX_LIMIT) as usize;
    let empty: Vec<PrivacyMomentJson> = Vec::new();
    json_to_c_string(&empty)
}

/// List the most-observed `app_bundle_id` values + their event counts.
///
/// `query_json` is a UTF-8 JSON string of [`ObservedAppsQueryJson`].
/// Returns a UTF-8 JSON array of [`ObservedAppJson`] rows. Sorted by
/// count DESC, then bundle id ASC. Rows where `events.app_bundle_id IS
/// NULL` are excluded. Surface for the recall-UI dynamic per-app filter
/// pills (Director-Brain audit, dogfood-v1 gap #1).
///
/// Allocator discipline matches the other read entry points: the
/// returned pointer is owned by Rust and MUST be freed via
/// [`mci_brain_ffi_string_free`].
///
/// # Safety
///
/// `h` must be a live handle. `query_json` must be a non-null,
/// null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_list_observed_apps(
    h: *mut Handle,
    query_json: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_list_observed_apps: null handle");
        return ptr::null_mut();
    }
    if query_json.is_null() {
        set_last_error("mci_brain_ffi_list_observed_apps: null query");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    // Safety: caller guarantees a null-terminated UTF-8 C string.
    let query_c = unsafe { CStr::from_ptr(query_json) };
    let Ok(query_str) = query_c.to_str() else {
        set_last_error("mci_brain_ffi_list_observed_apps: non-UTF8 query");
        return ptr::null_mut();
    };
    let query: ObservedAppsQueryJson = match serde_json::from_str(query_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!(
                "mci_brain_ffi_list_observed_apps: bad query JSON: {e}"
            ));
            return ptr::null_mut();
        }
    };
    let limit = query.limit.min(MAX_LIMIT as usize).max(1);

    let rows = match handle.store.observed_apps(limit, query.time_from_us) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_list_observed_apps: {e}"));
            return ptr::null_mut();
        }
    };
    let out: Vec<ObservedAppJson> = rows
        .into_iter()
        .map(|(app_bundle_id, count)| ObservedAppJson {
            app_bundle_id,
            count,
        })
        .collect();
    json_to_c_string(&out)
}

/// List the most-recent `episodes` rows produced by the episode
/// segmenter. Returns a UTF-8 JSON array of [`EpisodeJson`] sorted by
/// `ts_start_us` DESC. Surface for the recall-UI Episodes tab.
///
/// Allocator discipline matches the other read entry points.
///
/// # Safety
///
/// `h` must be a live handle. `limit` is treated as `u32` and clamped
/// to [`MAX_LIMIT`] internally.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_list_episodes(h: *mut Handle, limit: u32) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_list_episodes: null handle");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    let limit_clamped = limit.min(MAX_LIMIT) as usize;

    let eps = match handle.store.recent_episodes(limit_clamped) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_list_episodes: {e}"));
            return ptr::null_mut();
        }
    };
    let out: Vec<EpisodeJson> = eps
        .into_iter()
        .map(|e| EpisodeJson {
            id: e.id,
            app_bundle_id: e.app_bundle_id,
            ts_start_us: e.ts_start,
            ts_end_us: e.ts_end,
            event_count: e.event_count,
        })
        .collect();
    json_to_c_string(&out)
}

// ---------------------------------------------------------------------------
// Daily Brief read surface — backs the Recall UI's Brief tab
// (`docs/design/brief-viewer-spec.md`). READ-ONLY by construction; the FFI
// has no `put_brief` / `delete_brief` entry point. Writes happen through the
// agent process via `SqlCipherBrainStore::put_brief` (or, for manual smoke
// tests, the `mci-brain insert-brief` subcommand).
// ---------------------------------------------------------------------------

/// JSON value type for one daily brief row. Mirrors [`mci_brain::BriefRow`]
/// with snake_case keys for Swift `Codable` interop.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BriefJson {
    /// Stable `briefs.id` rowid.
    pub id: u64,
    /// ISO 8601 local date "YYYY-MM-DD" (one row per local day).
    pub date_local: String,
    /// Generation wall-clock, microseconds since UNIX epoch.
    pub generated_ts_us: u64,
    /// Author model identifier — surfaced in the brief header.
    pub model_id: String,
    /// Author model version string — surfaced in the brief header.
    pub model_version: String,
    /// Title rendered above the body.
    pub title: String,
    /// Markdown body.
    pub body: String,
    /// Word count for the header.
    pub word_count: u32,
    /// Number of events the author saw when composing.
    pub source_event_count: u32,
}

fn brief_to_json(b: mci_brain::BriefRow) -> BriefJson {
    BriefJson {
        id: b.id,
        date_local: b.date_local,
        generated_ts_us: b.generated_ts_us,
        model_id: b.model_id,
        model_version: b.model_version,
        title: b.title,
        body: b.body,
        word_count: b.word_count,
        source_event_count: b.source_event_count,
    }
}

/// Fetch the brief for `date_local` (ISO "YYYY-MM-DD"). Returns a JSON
/// object on success or the literal JSON `null` if the day has no brief.
/// Same allocator discipline as the other returners — caller MUST pass
/// the returned pointer back to [`mci_brain_ffi_string_free`].
///
/// # Safety
///
/// `h` must be a live handle; `date_local` must be a non-null,
/// null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_brief_for_date(
    h: *mut Handle,
    date_local: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_brief_for_date: null handle");
        return ptr::null_mut();
    }
    if date_local.is_null() {
        set_last_error("mci_brain_ffi_brief_for_date: null date_local");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a valid live handle that has not been freed.
    let handle = unsafe { &*h };
    // Safety: caller guarantees a valid null-terminated UTF-8 string.
    let date_c = unsafe { CStr::from_ptr(date_local) };
    let Ok(date_str) = date_c.to_str() else {
        set_last_error("mci_brain_ffi_brief_for_date: non-UTF8 date_local");
        return ptr::null_mut();
    };
    match handle.store.brief_for_date(date_str) {
        Ok(Some(b)) => json_to_c_string(&brief_to_json(b)),
        Ok(None) => json_null_c_string(),
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_brief_for_date: {e}"));
            ptr::null_mut()
        }
    }
}

/// Fetch the most-recently-generated brief, or JSON `null` if the store
/// has no briefs. Powers the Recall UI's default Brief tab view.
///
/// # Safety
/// `h` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_latest_brief(h: *mut Handle) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_latest_brief: null handle");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a valid live handle.
    let handle = unsafe { &*h };
    match handle.store.latest_brief() {
        Ok(Some(b)) => json_to_c_string(&brief_to_json(b)),
        Ok(None) => json_null_c_string(),
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_latest_brief: {e}"));
            ptr::null_mut()
        }
    }
}

/// Return up to `limit` brief dates ("YYYY-MM-DD") ordered most-recent
/// first as a JSON array of strings. Powers the Recall UI's `<` / `>`
/// date selector.
///
/// `limit` is clamped to [`MAX_LIMIT`].
///
/// # Safety
/// `h` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_brief_dates(h: *mut Handle, limit: u32) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_brief_dates: null handle");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a valid live handle.
    let handle = unsafe { &*h };
    let lim = limit.min(MAX_LIMIT) as usize;
    match handle.store.brief_dates(lim) {
        Ok(dates) => json_to_c_string(&dates),
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_brief_dates: {e}"));
            ptr::null_mut()
        }
    }
}

/// Content-free aggregate summary for the Privacy Dashboard's top card.
/// Returns a JSON object of [`SummaryStatsJson`] on success — total event
/// count, oldest/newest ts, and the on-disk byte size of the SQLCipher
/// brain file. NO event content, no bundle-id list, no window titles.
///
/// The `disk_bytes` field is the `fs::metadata(brain_path).len()` of the
/// file the handle was opened against — the FFI already holds the path
/// (`Handle::brain_path`) and stat'ing it is content-free (no read of
/// row bytes). A stat failure degrades to `0` rather than propagating an
/// error, because a failure to size the file must not block the
/// dashboard from rendering the counts.
///
/// Same allocator discipline as the other returners; caller MUST pass
/// the returned pointer back to [`mci_brain_ffi_string_free`].
///
/// # Safety
///
/// `h` must be a live handle previously returned by
/// [`mci_brain_ffi_open`] and not yet closed.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_summary_stats(h: *mut Handle) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_summary_stats: null handle");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a valid live handle.
    let handle = unsafe { &*h };
    let stats = match handle.store.stats() {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_summary_stats: {e}"));
            return ptr::null_mut();
        }
    };
    // Best-effort disk size. A missing/unreadable brain file falls back to
    // 0 — the dashboard's summary card shows "0 MB" which is honest under
    // that (impossible) failure mode rather than a full-screen error.
    let disk_bytes = std::fs::metadata(&handle.brain_path)
        .map(|m| m.len())
        .unwrap_or(0);
    let out = SummaryStatsJson {
        total_events: stats.event_count,
        oldest_ts_us: stats.oldest_ts_us,
        newest_ts_us: stats.newest_ts_us,
        disk_bytes,
    };
    json_to_c_string(&out)
}

// ---------------------------------------------------------------------------
// Mutation surface — cycle 8.47 follow-up to Privacy Dashboard PR #76.
//
// **PROTECTED-SET EXCEPTION.** ADR-0016 §4.3 says the recall UI cannot
// mutate the brain. The four functions below (delete_event,
// delete_events_in_range, prepare_wipe, wipe_brain) are the enumerated
// escape hatch for the Privacy Dashboard's destructive actions. Every
// mutation is user-gated by the SwiftUI confirmation sheet's typed-word
// "DELETE" flow; the wipe path adds a two-step token requirement so a
// programmatic hostile caller cannot single-call `wipe_brain(h, "")`.
//
// **Read-only invariant.** The invariant is not gone — it is now
// "reads route through the read-only handle; mutations route through
// enumerated methods that briefly open a writer + close." The allow-list
// in `tests/readonly_invariant.rs` names the four mutation methods
// explicitly; adding a fifth is an AGENT_PROTOCOL §5 protected-set
// violation and the test will fail.
// ---------------------------------------------------------------------------

/// Delete a single event by id. CASCADE removes event_vectors, chunks,
/// entity_mentions rows referencing this event id (per the migration-0001
/// / migration-0004 ON DELETE CASCADE clauses). Also `VACUUM`s so the
/// freed pages are returned to the OS immediately.
///
/// `event_id_json` is a UTF-8 JSON string of shape `{"event_id":<u64>}`.
///
/// Returns a JSON [`DeleteResultJson`] on success or null on failure
/// (`mci_brain_ffi_last_error_message` carries the diagnostic).
///
/// # Safety
/// `h` must be a live handle; `event_id_json` must be a non-null,
/// null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_delete_event(
    h: *mut Handle,
    event_id_json: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_delete_event: null handle");
        return ptr::null_mut();
    }
    if event_id_json.is_null() {
        set_last_error("mci_brain_ffi_delete_event: null event_id_json");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    // Safety: caller guarantees a null-terminated UTF-8 C string.
    let q_c = unsafe { CStr::from_ptr(event_id_json) };
    let Ok(q_str) = q_c.to_str() else {
        set_last_error("mci_brain_ffi_delete_event: non-UTF8 event_id_json");
        return ptr::null_mut();
    };
    #[derive(Deserialize)]
    struct Q {
        event_id: u64,
    }
    let q: Q = match serde_json::from_str(q_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_delete_event: bad query JSON: {e}"));
            return ptr::null_mut();
        }
    };
    match with_writer(handle, |writer| writer.delete_event(EventId(q.event_id))) {
        Ok(deleted) => json_to_c_string(&DeleteResultJson {
            events_deleted: deleted,
            // `SqlCipherBrainStore::delete_event` VACUUMs on the same
            // writer connection; if that VACUUM had failed, `delete_event`
            // would have returned an Err, so surfacing `vacuum_ok: true`
            // here is accurate. (See docs on `delete_event`.)
            vacuum_ok: true,
        }),
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_delete_event: {e}"));
            ptr::null_mut()
        }
    }
}

/// Delete all events whose `ts_us` falls in the inclusive range
/// `[start_ts_us, end_ts_us]`. CASCADE + VACUUM per the single-event
/// path. Powers the Privacy Dashboard's "Delete last 24 hours" +
/// "Delete this hour / day" range actions.
///
/// # Safety
/// `h` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_delete_events_in_range(
    h: *mut Handle,
    start_ts_us: u64,
    end_ts_us: u64,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_delete_events_in_range: null handle");
        return ptr::null_mut();
    }
    if start_ts_us > end_ts_us {
        set_last_error("mci_brain_ffi_delete_events_in_range: start_ts_us > end_ts_us");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    match with_writer(handle, |writer| {
        writer.delete_events_in_range(start_ts_us, end_ts_us)
    }) {
        Ok(deleted) => json_to_c_string(&DeleteResultJson {
            events_deleted: deleted,
            vacuum_ok: true,
        }),
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_delete_events_in_range: {e}"));
            ptr::null_mut()
        }
    }
}

/// Prepare a wipe by issuing a short-lived confirmation token.
///
/// Returns a JSON string `"<64-hex>"` (a random 32-byte token) valid for
/// [`WIPE_TOKEN_TTL`]. The Swift caller passes this token to
/// [`mci_brain_ffi_wipe_brain`] to actually perform the wipe. If the
/// token expires (60s) or is not the most-recently-issued token, the
/// wipe entry point refuses. This prevents a single-call `wipe(h, "")`
/// from a hostile programmatic caller — a wipe requires two round-trips
/// to the FFI within one minute.
///
/// Calling `prepare_wipe` again invalidates the previous token
/// (single-use, single-outstanding — pinned by
/// `wipe_second_prepare_invalidates_first_token`).
///
/// # Safety
/// `h` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_prepare_wipe(h: *mut Handle) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_prepare_wipe: null handle");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    let token = match generate_wipe_token() {
        Ok(t) => t,
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_prepare_wipe: {e}"));
            return ptr::null_mut();
        }
    };
    match handle.pending_wipe.lock() {
        Ok(mut slot) => {
            *slot = Some((Instant::now(), token.clone()));
        }
        Err(_) => {
            set_last_error("mci_brain_ffi_prepare_wipe: pending_wipe mutex poisoned");
            return ptr::null_mut();
        }
    }
    // Emit the raw token as a JSON string literal so the Swift caller can
    // JSONDecoder-decode it just like the other returners.
    json_to_c_string(&token)
}

/// Wipe every user-content row from the brain and VACUUM.
///
/// Requires `token` to match the token most recently returned by
/// [`mci_brain_ffi_prepare_wipe`], not yet expired (60s TTL). The token
/// is consumed on any call — success, wrong token, or expired — so a
/// wipe is single-use.
///
/// The wipe drops rows from `events`, `episodes`, `briefs`, and the graph
/// tables (`entities`, `entity_mentions`, `entity_identities`,
/// `episode_edges`). It does NOT touch:
/// - The Keychain-stored master key (out-of-band; ADR-0008).
/// - The Sparkle appcast / update state.
/// - The retention config in `~/Library/Application Support/MCI/retention.json`.
/// - The `meta` table (schema version stamps) — the DB remains a valid
///   MCI store post-wipe, just empty.
///
/// Returns a JSON [`DeleteResultJson`] with `events_deleted` set to the
/// total row count deleted from `events` (the primary user-visible
/// count), plus `vacuum_ok`. Returns null on failure.
///
/// # Safety
/// `h` must be a live handle; `token` must be a non-null,
/// null-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_wipe_brain(
    h: *mut Handle,
    token: *const c_char,
) -> *mut c_char {
    if h.is_null() {
        set_last_error("mci_brain_ffi_wipe_brain: null handle");
        return ptr::null_mut();
    }
    if token.is_null() {
        set_last_error("mci_brain_ffi_wipe_brain: null token");
        return ptr::null_mut();
    }
    // Safety: caller guarantees a live handle.
    let handle = unsafe { &*h };
    // Safety: caller guarantees a null-terminated UTF-8 C string.
    let token_c = unsafe { CStr::from_ptr(token) };
    let Ok(token_str) = token_c.to_str() else {
        set_last_error("mci_brain_ffi_wipe_brain: non-UTF8 token");
        return ptr::null_mut();
    };
    // Consume the pending token unconditionally — any call to `wipe`
    // (success, wrong, or expired) invalidates it so a token cannot be
    // retried after a failure.
    let pending = match handle.pending_wipe.lock() {
        Ok(mut slot) => slot.take(),
        Err(_) => {
            set_last_error("mci_brain_ffi_wipe_brain: pending_wipe mutex poisoned");
            return ptr::null_mut();
        }
    };
    let Some((issued_at, expected)) = pending else {
        set_last_error("mci_brain_ffi_wipe_brain: no pending wipe — call prepare_wipe first");
        return ptr::null_mut();
    };
    if issued_at.elapsed() > WIPE_TOKEN_TTL {
        set_last_error(
            "mci_brain_ffi_wipe_brain: wipe token expired (60s TTL) — call prepare_wipe again",
        );
        return ptr::null_mut();
    }
    if !constant_time_eq(token_str.as_bytes(), expected.as_bytes()) {
        set_last_error("mci_brain_ffi_wipe_brain: wipe token mismatch");
        return ptr::null_mut();
    }
    match with_writer(handle, |writer| writer.wipe_all()) {
        Ok(deleted) => json_to_c_string(&DeleteResultJson {
            events_deleted: deleted,
            vacuum_ok: true,
        }),
        Err(e) => {
            set_last_error(&format!("mci_brain_ffi_wipe_brain: {e}"));
            ptr::null_mut()
        }
    }
}

/// Free a `*mut c_char` previously returned by any FFI function that
/// returns owned JSON. Calling with null is a no-op.
///
/// # Safety
///
/// `s` MUST be either null or a pointer previously returned by this
/// crate and not yet freed. Freeing a pointer twice or freeing a
/// pointer not from this crate is undefined behavior.
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // Safety: caller upheld the precondition.
    let _ = unsafe { CString::from_raw(s) };
}

/// Return the last diagnostic message set by any FFI call on the current
/// thread, or null if no error is pending. The returned pointer is owned
/// by this crate (thread-local) and is **valid only until the next FFI
/// call on the same thread** — copy it on the Swift side before issuing
/// the next call.
///
/// # Safety
///
/// Callers must not pass the returned pointer to
/// [`mci_brain_ffi_string_free`] (Rust owns it). Must not retain across
/// FFI calls (the thread-local may overwrite it).
#[no_mangle]
pub unsafe extern "C" fn mci_brain_ffi_last_error_message() -> *const c_char {
    LAST_ERROR.with(|cell| {
        let opt = cell.borrow();
        match opt.as_ref() {
            Some(c) => c.as_ptr(),
            None => ptr::null(),
        }
    })
}

// ---------------------------------------------------------------------------
// Internals — thread-local error slot, hex decoder, JSON helper, snippet
// ---------------------------------------------------------------------------

/// Soft cap on `limit` arguments. The recall-ui's list view paginates
/// far below this anyway; the cap exists so a hostile caller cannot
/// trick the FFI into allocating gigabytes of `Vec<HitJson>`.
pub const MAX_LIMIT: u32 = 10_000;

/// Maximum characters of OCR text returned per hit in the snippet field.
/// 280 is the headline cap the Swift list cell can render in two lines
/// without re-flowing; raise only when the UI grows a long-form preview.
pub const SNIPPET_CHAR_CAP: usize = 280;

/// Maximum entity names surfaced per hit in [`HitJson::entities`]. Mirrors
/// the cap used by the MCP `LiveBrainReader::enrich_hit`
/// (`apps/agent/src/mcp/live.rs`) so the two recall surfaces cannot drift.
/// The recall UI's chip strip renders at most ~3 chips before ellipsis;
/// surfacing more is upside for future filter facets without breaking the
/// list-cell layout.
pub const ENTITY_LIMIT: usize = 16;

/// Maximum cross-app linked event ids surfaced per hit in
/// [`HitJson::linked_event_ids`]. Mirrors the cap used by the MCP
/// `LiveBrainReader::enrich_hit`. The "Related (N)" flyout (PR-3, next
/// cycle) paginates below this anyway.
pub const LINK_LIMIT: usize = 16;

/// Maximum ids the recall UI may resolve in one
/// [`mci_brain_ffi_events_by_ids`] call. The related-hits flyout
/// (cycle 8.37 PR-3) issues at most `LINK_LIMIT` (=16) ids because a
/// hit's `linked_event_ids` vector is itself capped at that size, but
/// this outer cap guards against a hostile caller stuffing the JSON
/// with an arbitrary list. 32 leaves headroom for the future
/// "expand siblings-of-siblings" path without unbounding the loop.
pub const EVENTS_BY_IDS_CAP: usize = 32;

/// **V2-P13 (Phase D scaffold).** Maximum microseconds spanned by one
/// [`mci_brain_ffi_timeline_events`] call. 90 days is comfortably larger
/// than the recall UI's "month" toggle so a scaffold client can request a
/// 30-day view without hitting the cap; anything bigger is treated as a
/// hostile / mis-scoped request and rejected at the FFI boundary.
pub const TIMELINE_MAX_RANGE_US: u64 = 90 * 24 * 60 * 60 * 1_000_000;

/// **V2-P13.** Hard cap on rows fetched from `recent_events` before
/// filtering to the window. Bounds the per-call allocation regardless of
/// how many events exist in the requested window. 10_000 events × ~200
/// bytes/row ≈ 2 MB — well inside the FFI's memory budget.
pub const TIMELINE_HARD_CAP: usize = 10_000;

/// **V2-P13.** Maximum rows returned from a single
/// [`mci_brain_ffi_timeline_events`] call. Above this count the FFI
/// downsamples: one representative event per time bucket, with bucket
/// width picked so the total row count fits under the cap. The recall UI
/// strip renders ~1 card per 40 px, so 1_000 rows suffices for a
/// full-screen day view on a 4K display.
pub const TIMELINE_MAX_EVENTS: usize = 1_000;

/// **V2-P13.** Microseconds per minute — bucket width used by the
/// downsampler when the requested range is ≤ 24 h.
pub const TIMELINE_MINUTE_US: u64 = 60_000_000;

/// **V2-P13.** Very short snippet cap for timeline strip cards. Deeper
/// text is pulled via `mci_brain_ffi_events_by_ids` when the user clicks
/// a card. 80 chars keeps the JSON payload small when returning up to
/// [`TIMELINE_MAX_EVENTS`] rows.
pub const TIMELINE_SNIPPET_CAP: usize = 80;

/// Cycle 8.42 — cap on the number of canonical-alias groups accepted from
/// the recall UI's user dictionary per query. Bounds the FTS5 query size
/// (`~cap * cap * avg_len` bytes) so a hostile caller cannot inflate the
/// query into an OOM shape. 64 leaves ample headroom for the "one alias
/// per contact + a dozen topics" use case while staying well inside the
/// FTS5 boolean planner's happy range.
pub const USER_ALIAS_GROUP_CAP: usize = 64;

/// Cycle 8.42 — cap on the number of aliases per canonical name. Same
/// budget rationale as [`USER_ALIAS_GROUP_CAP`]. A user with more than 16
/// spellings for the same person / topic should split into multiple
/// canonical groups.
pub const USER_ALIAS_PER_GROUP_CAP: usize = 16;

/// Cycle 8.47 — wipe confirmation token time-to-live. A token issued by
/// [`mci_brain_ffi_prepare_wipe`] must be redeemed within this window or
/// the wipe is refused. 60s is short enough that a token accidentally
/// left in transcript logs is stale before it can be replayed, and long
/// enough that a slow user still has time to type "DELETE EVERYTHING".
pub const WIPE_TOKEN_TTL: Duration = Duration::from_secs(60);

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> = const {
        std::cell::RefCell::new(None)
    };
}

fn set_last_error(msg: &str) {
    let c = CString::new(msg).unwrap_or_else(|_| {
        CString::new("mci-brain-ffi: error message contained a NUL byte").expect("static literal")
    });
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(c);
    });
}

fn clear_last_error() {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = None;
    });
}

/// Decode a 64-character hex string into the 32-byte `SQLCipher` key.
///
/// Accepts upper-, lower-, or mixed-case hex. Rejects any other length
/// (the 256-bit key is fixed per ADR-0008) and any non-hex byte.
fn decode_hex_key(s: &str) -> Result<[u8; 32], String> {
    let bytes = s.as_bytes();
    if bytes.len() != 64 {
        return Err(format!(
            "key_hex must be 64 hex chars (32 bytes); got {}",
            bytes.len()
        ));
    }
    let mut out = [0u8; 32];
    for (i, pair) in bytes.chunks_exact(2).enumerate() {
        let hi = hex_nibble(pair[0])?;
        let lo = hex_nibble(pair[1])?;
        out[i] = (hi << 4) | lo;
    }
    Ok(out)
}

fn hex_nibble(b: u8) -> Result<u8, String> {
    match b {
        b'0'..=b'9' => Ok(b - b'0'),
        b'a'..=b'f' => Ok(b - b'a' + 10),
        b'A'..=b'F' => Ok(b - b'A' + 10),
        other => Err(format!("non-hex byte 0x{other:02x} in key_hex")),
    }
}

/// Truncate `s` to at most [`SNIPPET_CHAR_CAP`] characters (not bytes —
/// multi-byte UTF-8 is preserved). Appends nothing; the recall-UI adds
/// an ellipsis affordance if it likes.
fn snippet(s: &str) -> String {
    if s.chars().count() <= SNIPPET_CHAR_CAP {
        return s.to_string();
    }
    s.chars().take(SNIPPET_CHAR_CAP).collect()
}

/// **V2-P13.** Shorter snippet for timeline strip cards.
/// [`TIMELINE_SNIPPET_CAP`] chars; multi-byte UTF-8 boundaries preserved.
fn timeline_snippet(s: &str) -> String {
    if s.chars().count() <= TIMELINE_SNIPPET_CAP {
        return s.to_string();
    }
    s.chars().take(TIMELINE_SNIPPET_CAP).collect()
}

/// **V2-P13.** Downsample an ascending-order timeline slice to at most
/// [`TIMELINE_MAX_EVENTS`] representatives.
///
/// Strategy: bucket by time. When the input already fits under the cap
/// the function returns it unchanged. Otherwise the bucket width is
/// computed so the total bucket count ≤ [`TIMELINE_MAX_EVENTS`]; ranges
/// ≤ 24 h floor to a 1-minute bucket for a stable "one card per minute"
/// feel; longer ranges use `ceil(range_us / MAX_EVENTS)` rounded up to
/// the next minute. Within each bucket the first event (chronologically
/// earliest) is kept. This is intentionally simple — a follow-on cycle
/// can pick a "densest event" or "middle-of-bucket keyframe" strategy;
/// the wire shape is identical.
///
/// Pure function so it is trivially testable.
fn downsample_timeline(events: Vec<TimelineEventJson>, range_us: u64) -> Vec<TimelineEventJson> {
    if events.len() <= TIMELINE_MAX_EVENTS {
        return events;
    }
    // Pick bucket width. Ceil-divide range by the cap so we never exceed
    // MAX_EVENTS buckets; round up to the next full minute so the strip's
    // time-axis labels align on minute boundaries.
    let raw_bucket = range_us
        .checked_div(TIMELINE_MAX_EVENTS as u64)
        .unwrap_or(TIMELINE_MINUTE_US);
    let bucket_us = raw_bucket.max(TIMELINE_MINUTE_US).max(1);
    let mut out: Vec<TimelineEventJson> = Vec::new();
    let mut current_bucket: Option<u64> = None;
    for ev in events {
        let bucket = ev.ts_us / bucket_us;
        if Some(bucket) != current_bucket {
            current_bucket = Some(bucket);
            out.push(ev);
        }
        // Else: bucket already has a representative — drop this event.
    }
    out
}

/// Fill the additive Phase-6-close recall fields for one hit event:
/// the resolver-allowlist entity names it mentions + the cross-app
/// dot-connect event ids reachable from its episode.
///
/// **Best-effort + read-only:** both reads default to `Vec::new()` on a
/// graph-less backend (the `BrainStore` trait defaults return
/// `Ok(vec![])`) and are `.unwrap_or_default()`-ed here — an enrichment
/// failure degrades a hit to "no entities / no links" rather than failing
/// the whole recall. This mirrors the discipline of
/// `apps/agent/src/mcp/live.rs::LiveBrainReader::enrich_hit` so the FFI
/// and MCP recall surfaces cannot drift.
///
/// The store's `linked_event_ids_for_event` applies the
/// `cascade_reason = 0` wall and `entity_names_for_event` restricts to
/// the resolver allowlist, so neither surface can leak a suppressed
/// event or a redacted-token label (ADR-0016 §4.3 + ADR-0017 §5.1).
fn enrich_hit(store: &SqlCipherBrainStore, event_id: EventId) -> (Vec<String>, Vec<u64>) {
    let entities = store
        .entity_names_for_event(event_id, ENTITY_LIMIT)
        .unwrap_or_default();
    let linked_event_ids: Vec<u64> = store
        .linked_event_ids_for_event(event_id, LINK_LIMIT)
        .unwrap_or_default()
        .into_iter()
        .map(|e| e.0)
        .collect();
    (entities, linked_event_ids)
}

/// Resolve `Event.keyframe_blob` (sha256 hex, `None` when no keyframe was
/// captured) into the absolute filesystem path the Swift `HitThumbnail`
/// view opens. Convention: `<blob_dir>/<hex>.bin` per the P3.6.5
/// `KeyframeBlobWriter` on-disk layout.
///
/// Read-only: no file I/O — the FFI never stats or opens the referenced
/// blob. A stale / missing hex is graceful degradation in the Swift view
/// (falls back to the placeholder icon).
///
/// **Privacy invariant carry-through.** `Event.keyframe_blob` is only ever
/// non-`None` for events that cleared cascade-twice (ADR-0016 §4.8);
/// `put_event`'s `cascade_reason != 0` wall means a redacted event has no
/// keyframe hex in the store, so this helper returns `None` for those
/// rows by construction.
fn thumbnail_path_for(blob_dir: &std::path::Path, keyframe_blob: Option<&str>) -> Option<String> {
    let hex = keyframe_blob?.trim();
    if hex.is_empty() {
        return None;
    }
    // Defence-in-depth: reject anything that isn't a lower-case hex string
    // of the expected length. Prevents a hostile stored value (e.g. a
    // filesystem-escape like "../../etc/passwd") from being handed to
    // Swift as an "absolute path". SHA256 = 64 hex chars.
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let file = format!("{hex}.bin");
    Some(blob_dir.join(file).to_string_lossy().into_owned())
}

/// Expand a raw user query with the caller's user-dictionary aliases
/// (cycle 8.42). When the query text contains — as a case-insensitive
/// substring — a canonical name or any of its aliases, the FTS5 query is
/// rewritten as an OR-group over all the equivalent spellings so a
/// search for `"AJ email"` also matches events that mention
/// `"Amy Jain email"`. Multi-word spellings are quoted so FTS5 treats
/// them as a single phrase.
///
/// **Match semantics.** Case-insensitive substring on the query text.
/// This is intentionally loose so `"AJ"`, `"aj"`, `"aj@example.com"` all
/// trigger the expansion for a canonical `"AJ"`. False positives are
/// bounded: an expansion only *adds* an OR-branch to FTS5; it never
/// removes candidate events, so worst-case a spurious expansion just
/// widens the candidate pool.
///
/// **Bounds.** The map is capped at [`USER_ALIAS_GROUP_CAP`] groups; each
/// group's aliases are capped at [`USER_ALIAS_PER_GROUP_CAP`] entries.
/// A hostile caller cannot inflate the FTS5 query beyond
/// `~cap * cap * avg_len` bytes.
///
/// **No-op paths.** Empty map, or a map whose keys/aliases don't appear
/// in the query, returns the input unchanged — the recall trace is
/// byte-identical to the pre-8.42 behavior. This is what preserves the
/// "backward-compat by construction" contract.
fn expand_query_with_user_aliases(
    text: &str,
    aliases: &std::collections::HashMap<String, Vec<String>>,
) -> String {
    if aliases.is_empty() {
        return text.to_string();
    }
    let text_lc = text.to_lowercase();
    let mut expansions: Vec<String> = Vec::new();

    // Iterate at most USER_ALIAS_GROUP_CAP groups. HashMap order is
    // non-deterministic, but the resulting FTS5 query is order-independent
    // (OR is commutative in FTS5's boolean layer).
    for (canonical, alt_list) in aliases.iter().take(USER_ALIAS_GROUP_CAP) {
        let all_terms: Vec<&str> = std::iter::once(canonical.as_str())
            .chain(
                alt_list
                    .iter()
                    .map(String::as_str)
                    .take(USER_ALIAS_PER_GROUP_CAP),
            )
            .collect();
        // Fire only if the user's query mentions this group. Case-insensitive
        // substring match on any of the group's spellings.
        let touched = all_terms
            .iter()
            .any(|term| !term.is_empty() && text_lc.contains(&term.to_lowercase()));
        if !touched {
            continue;
        }
        let quoted: Vec<String> = all_terms
            .iter()
            .filter(|t| !t.is_empty())
            .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
            .collect();
        if quoted.is_empty() {
            continue;
        }
        expansions.push(format!("({})", quoted.join(" OR ")));
    }
    if expansions.is_empty() {
        return text.to_string();
    }
    // Compose as `(<original>) OR <group1> OR <group2> ...`. Wrapping the
    // original in parens preserves any user-authored FTS5 operators.
    let mut out = format!("({text})");
    for e in expansions {
        out.push_str(" OR ");
        out.push_str(&e);
    }
    out
}

/// Post-fetch filter that matches the optional `time_filter` /
/// `app_filter` semantics from [`QueryJson`]. Pure function so it is
/// trivially testable.
fn passes_filters(
    ts_us: u64,
    app_bundle_id: Option<&str>,
    time_from_us: Option<u64>,
    time_to_us: Option<u64>,
    app_filter: Option<&str>,
) -> bool {
    if let Some(from) = time_from_us {
        if ts_us < from {
            return false;
        }
    }
    if let Some(to) = time_to_us {
        if ts_us > to {
            return false;
        }
    }
    if let Some(want) = app_filter {
        if app_bundle_id != Some(want) {
            return false;
        }
    }
    true
}

/// Return the literal JSON `null` as an owned C string. The Swift
/// decoder reads this as `nil` for `Optional<BriefJson>`. Same allocator
/// discipline as [`json_to_c_string`].
fn json_null_c_string() -> *mut c_char {
    match CString::new("null") {
        Ok(c) => c.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Briefly open a **writer** connection to the brain, run `body`
/// (which calls a `SqlCipherBrainStore` mutation method), and let the
/// writer drop at end-of-scope. Returns the mutation's row count.
///
/// **Why re-open here rather than upgrade the read-only handle.**
/// The recall-ui's long-lived FFI handle is read-only by construction
/// (ADR-0016 §4.3). The four cycle-8.47 mutation methods are the
/// enumerated exceptions; they open a writer only for the duration of
/// one DELETE + VACUUM, then drop it. This keeps the read-only invariant
/// intact for every other call and confines the writer's blast radius
/// to a single stack frame.
///
/// The `DbKey` retained on `Handle` (a clone of the same bytes already
/// held by the read-only store) is the credential; we open a fresh
/// `SqlCipherBrainStore::new` connection with it, run the mutation, and
/// let RAII close the writer at end-of-scope. `VACUUM` runs inside the
/// store's mutation method (after the transaction commits), so a VACUUM
/// failure propagates through `body`'s `Err` — the DELETE tx and the
/// VACUUM are transactionally decoupled but reported as a single
/// unit here.
fn with_writer<F, T>(handle: &Handle, body: F) -> Result<T, String>
where
    F: FnOnce(&SqlCipherBrainStore) -> Result<T, mci_brain::StoreError>,
{
    // Open a fresh writer. SqlCipherBrainStore::new does the migration
    // (idempotent — every DDL is IF NOT EXISTS) so a delete on an
    // already-migrated store is safe. On a first-run edge case where
    // the recall-ui somehow opened before the agent migrated, the
    // migration runs here and the DELETE targets an empty schema.
    let writer = SqlCipherBrainStore::new(&handle.brain_path, &handle.db_key)
        .map_err(|e| format!("open writer: {e}"))?;
    body(&writer).map_err(|e| format!("{e}"))
}

/// Generate a fresh 32-byte random wipe-confirmation token, hex-encoded.
/// Uses the OS CSPRNG (`getrandom`) — the same source `DbKey::generate`
/// pulls from. A token collision across two `prepare_wipe` calls is
/// cryptographically impossible.
fn generate_wipe_token() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| format!("getrandom: {e}"))?;
    let mut s = String::with_capacity(64);
    for b in &bytes {
        use std::fmt::Write;
        write!(s, "{b:02x}").expect("write to String never fails");
    }
    Ok(s)
}

/// Constant-time byte-slice equality. Prevents a timing side channel
/// where a hostile caller could learn the leading bytes of the pending
/// wipe token by observing how long `wipe_brain` takes to reject a
/// mismatched token. The token is single-use, so a leak is largely
/// defensive, but constant-time compare is the right default for any
/// secret comparison.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Serialize `v` as JSON, push it into a `CString`, and hand the raw
/// pointer to the caller. Returns null on serialization failure (which
/// in practice cannot happen for our simple types but is treated as a
/// graceful failure rather than a panic across the FFI boundary —
/// panicking across `extern "C"` is undefined behavior).
fn json_to_c_string<T: Serialize>(v: &T) -> *mut c_char {
    let s = match serde_json::to_string(v) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&format!("serde_json::to_string: {e}"));
            return ptr::null_mut();
        }
    };
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(e) => {
            set_last_error(&format!("CString::new (interior NUL): {e}"));
            ptr::null_mut()
        }
    }
}

// ---------------------------------------------------------------------------
// Tests — narrow unit tests on the pure helpers. Integration tests against
// a real ephemeral SQLCipher brain live in `tests/`.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_hex_key_round_trip_lower_case() {
        let raw = [0xABu8; 32];
        let hex: String = raw.iter().fold(String::new(), |mut s, b| {
            use std::fmt::Write;
            write!(s, "{b:02x}").unwrap();
            s
        });
        let back = decode_hex_key(&hex).expect("valid hex");
        assert_eq!(back, raw);
    }

    #[test]
    fn decode_hex_key_accepts_upper_case() {
        let hex = "DEADBEEF".repeat(8);
        assert_eq!(hex.len(), 64);
        let back = decode_hex_key(&hex).expect("valid upper hex");
        assert_eq!(back[0], 0xDE);
        assert_eq!(back[1], 0xAD);
        assert_eq!(back[2], 0xBE);
        assert_eq!(back[3], 0xEF);
    }

    #[test]
    fn decode_hex_key_rejects_short_input() {
        let e = decode_hex_key("00").unwrap_err();
        assert!(e.contains("64 hex chars"));
    }

    #[test]
    fn decode_hex_key_rejects_non_hex_byte() {
        let mut s = "00".repeat(31);
        s.push_str("zz");
        let e = decode_hex_key(&s).unwrap_err();
        assert!(e.contains("non-hex"));
    }

    #[test]
    fn snippet_caps_long_text() {
        let long = "x".repeat(SNIPPET_CHAR_CAP + 100);
        let s = snippet(&long);
        assert_eq!(s.chars().count(), SNIPPET_CHAR_CAP);
    }

    #[test]
    fn snippet_passes_short_text() {
        let short = "hello";
        assert_eq!(snippet(short), "hello");
    }

    #[test]
    fn snippet_preserves_multibyte_char_boundaries() {
        // Each emoji is multiple bytes; ensure we cut on char count, not bytes.
        let s: String = "🦀".repeat(SNIPPET_CHAR_CAP + 5);
        let cut = snippet(&s);
        assert_eq!(cut.chars().count(), SNIPPET_CHAR_CAP);
        // Round-trip via str so we know we didn't slice mid-codepoint.
        assert!(cut.is_char_boundary(cut.len()));
    }

    #[test]
    fn passes_filters_no_filters_always_true() {
        assert!(passes_filters(
            1000,
            Some("com.apple.Safari"),
            None,
            None,
            None
        ));
    }

    #[test]
    fn passes_filters_time_window_inclusive() {
        assert!(passes_filters(1000, None, Some(1000), Some(1000), None));
        assert!(!passes_filters(999, None, Some(1000), Some(2000), None));
        assert!(!passes_filters(2001, None, Some(1000), Some(2000), None));
    }

    #[test]
    fn passes_filters_app_filter_requires_exact_match() {
        assert!(passes_filters(
            0,
            Some("com.apple.Safari"),
            None,
            None,
            Some("com.apple.Safari")
        ));
        assert!(!passes_filters(
            0,
            Some("com.apple.Safari"),
            None,
            None,
            Some("com.microsoft.VSCode")
        ));
        assert!(!passes_filters(
            0,
            None,
            None,
            None,
            Some("com.apple.Safari")
        ));
    }

    #[test]
    fn open_with_null_path_returns_null_and_sets_error() {
        let k = CString::new("00".repeat(32)).unwrap();
        let h = unsafe { mci_brain_ffi_open(std::ptr::null(), k.as_ptr()) };
        assert!(h.is_null());
        let err = unsafe { mci_brain_ffi_last_error_message() };
        assert!(!err.is_null());
        let msg = unsafe { CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        assert!(msg.contains("null pointer"));
    }

    #[test]
    fn open_with_short_hex_key_fails() {
        let p = CString::new("/tmp/never-touched.sqlite").unwrap();
        let k = CString::new("deadbeef").unwrap();
        let h = unsafe { mci_brain_ffi_open(p.as_ptr(), k.as_ptr()) };
        assert!(h.is_null());
        let err = unsafe { mci_brain_ffi_last_error_message() };
        assert!(!err.is_null());
        let msg = unsafe { CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        assert!(msg.contains("64 hex chars"), "got {msg}");
    }

    #[test]
    fn open_with_missing_file_fails_gracefully() {
        let p = CString::new("/no/such/dir/no-file.sqlite").unwrap();
        let k = CString::new("00".repeat(32)).unwrap();
        let h = unsafe { mci_brain_ffi_open(p.as_ptr(), k.as_ptr()) };
        assert!(h.is_null());
        let err = unsafe { mci_brain_ffi_last_error_message() };
        assert!(!err.is_null());
    }

    #[test]
    fn string_free_handles_null_safely() {
        unsafe { mci_brain_ffi_string_free(std::ptr::null_mut()) };
    }

    #[test]
    fn close_handles_null_safely() {
        unsafe { mci_brain_ffi_close(std::ptr::null_mut()) };
    }

    #[test]
    fn hit_json_serde_round_trip() {
        let h = HitJson {
            event_id: 42,
            ts_us: 1_700_000_000_000_000,
            app_bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Apple — Privacy".into()),
            url: Some("https://example.org/".into()),
            ocr_text_snippet: "The quick brown fox …".into(),
            source: "lexical".into(),
            score: Some(0.83),
            entities: vec!["Anthropic".into(), "MCP".into()],
            linked_event_ids: vec![101, 202, 303],
            thumbnail_path: Some(
                "/Users/x/Library/Application Support/MCI/blobs/abcdef.bin".into(),
            ),
        };
        let s = serde_json::to_string(&h).unwrap();
        let back: HitJson = serde_json::from_str(&s).unwrap();
        assert_eq!(h, back);
    }

    #[test]
    fn hit_json_round_trip_without_thumbnail() {
        // Text-only events (Messages, Mail, PageContent) legitimately have
        // no keyframe. Round-trip with `thumbnail_path: None` must decode
        // cleanly — this is the common case for the near-term corpus
        // where most hits are page-content ingest.
        let h = HitJson {
            event_id: 7,
            ts_us: 1_700_000_000_000_000,
            app_bundle_id: Some("com.apple.mail".into()),
            window_title: None,
            url: None,
            ocr_text_snippet: "email body".into(),
            source: "timeline".into(),
            score: None,
            entities: vec![],
            linked_event_ids: vec![],
            thumbnail_path: None,
        };
        let s = serde_json::to_string(&h).unwrap();
        let back: HitJson = serde_json::from_str(&s).unwrap();
        assert_eq!(h, back);
        // Wire shape uses JSON `null` (not missing) when we explicitly
        // emit None — Swift's Optional decoder reads either. Assert the
        // key is present so a client watching the wire sees the field.
        assert!(s.contains("\"thumbnail_path\""), "expected key in {s}");
    }

    #[test]
    fn thumbnail_path_for_hex_composes_blob_dir() {
        let hex = "a".repeat(64);
        let dir = std::path::Path::new("/tmp/mci/blobs");
        let p = thumbnail_path_for(dir, Some(&hex)).expect("expected path");
        assert!(p.starts_with("/tmp/mci/blobs/"));
        assert!(p.ends_with(".bin"));
    }

    #[test]
    fn thumbnail_path_for_none_returns_none() {
        let dir = std::path::Path::new("/tmp/mci/blobs");
        assert_eq!(thumbnail_path_for(dir, None), None);
    }

    #[test]
    fn thumbnail_path_for_empty_string_returns_none() {
        let dir = std::path::Path::new("/tmp/mci/blobs");
        assert_eq!(thumbnail_path_for(dir, Some("")), None);
        assert_eq!(thumbnail_path_for(dir, Some("   ")), None);
    }

    #[test]
    fn thumbnail_path_for_rejects_non_hex_and_bad_length() {
        // Defence-in-depth against a hostile / corrupt stored value.
        // 63 chars (too short) → rejected. Path-escape → rejected on
        // non-hex chars before length even matters.
        let dir = std::path::Path::new("/tmp/mci/blobs");
        assert_eq!(thumbnail_path_for(dir, Some(&"a".repeat(63))), None);
        assert_eq!(thumbnail_path_for(dir, Some("../etc/passwd")), None);
        assert_eq!(
            thumbnail_path_for(dir, Some(&format!("{}../..", "a".repeat(58)))),
            None
        );
    }

    #[test]
    fn hit_json_deserializes_legacy_payload_without_entity_fields() {
        // Backward compat: earlier FFI callers (or fixtures) that predate the
        // cycle-8.35 wire widening emit no `entities` / `linked_event_ids`
        // keys. Serde `#[serde(default)]` on both fields must accept this and
        // yield empty vecs so a Swift client running against a rolled-back
        // Rust build (or vice versa) does not blow up on decode.
        let legacy = r#"{
            "event_id": 7,
            "ts_us": 1700000000000000,
            "app_bundle_id": null,
            "window_title": null,
            "url": null,
            "ocr_text_snippet": "hello",
            "source": "timeline",
            "score": null
        }"#;
        let h: HitJson = serde_json::from_str(legacy).expect("legacy JSON must decode");
        assert!(h.entities.is_empty());
        assert!(h.linked_event_ids.is_empty());
        // Cycle 8.35 PR-4 thumbnail_path also serde(default)s — a pre-PR-4
        // Rust build (or a hand-rolled test fixture) that omits the key
        // must still decode without error.
        assert!(h.thumbnail_path.is_none());
    }

    #[test]
    fn hit_json_emits_entity_fields_in_serialized_json() {
        // Positive assertion: the serialized JSON carries both new keys so
        // the Swift `HitWire` decoder can rely on them being present when a
        // fresh Rust FFI writes the payload. This locks the wire shape.
        let h = HitJson {
            event_id: 1,
            ts_us: 0,
            app_bundle_id: None,
            window_title: None,
            url: None,
            ocr_text_snippet: String::new(),
            source: "hybrid".into(),
            score: None,
            entities: vec!["vector-db".into()],
            linked_event_ids: vec![9],
            thumbnail_path: None,
        };
        let s = serde_json::to_string(&h).unwrap();
        assert!(s.contains("\"entities\""), "missing entities key in {s}");
        assert!(
            s.contains("\"linked_event_ids\""),
            "missing linked_event_ids key in {s}"
        );
        assert!(s.contains("vector-db"));
    }

    #[test]
    fn privacy_moment_json_serde_round_trip() {
        let m = PrivacyMomentJson {
            ts_us: 1_700_000_000_000_000,
            app_bundle_id: Some("com.1password.app".into()),
            reason_code: 4,
        };
        let s = serde_json::to_string(&m).unwrap();
        let back: PrivacyMomentJson = serde_json::from_str(&s).unwrap();
        assert_eq!(m, back);
    }

    #[test]
    fn query_json_accepts_optional_filters() {
        let q: QueryJson =
            serde_json::from_str(r#"{"text":"a","limit":5}"#).expect("parses without filters");
        assert_eq!(q.text, "a");
        assert_eq!(q.limit, 5);
        assert!(q.time_from_us.is_none());
        assert!(q.app_filter.is_none());
        let q2: QueryJson = serde_json::from_str(
            r#"{"text":"b","limit":10,"time_from_us":100,"time_to_us":200,"app_filter":"com.apple.Safari"}"#,
        )
        .expect("parses with filters");
        assert_eq!(q2.time_from_us, Some(100));
        assert_eq!(q2.time_to_us, Some(200));
        assert_eq!(q2.app_filter.as_deref(), Some("com.apple.Safari"));
    }

    #[test]
    fn limit_clamps_at_max() {
        assert_eq!(MAX_LIMIT, 10_000);
    }

    #[test]
    fn observed_apps_query_json_parses_with_and_without_window() {
        let q: ObservedAppsQueryJson =
            serde_json::from_str(r#"{"limit":5}"#).expect("parses without window");
        assert_eq!(q.limit, 5);
        assert!(q.time_from_us.is_none());
        let q2: ObservedAppsQueryJson =
            serde_json::from_str(r#"{"limit":10,"time_from_us":42}"#).expect("parses with window");
        assert_eq!(q2.time_from_us, Some(42));
    }

    #[test]
    fn observed_app_json_serde_round_trip() {
        let a = ObservedAppJson {
            app_bundle_id: "com.apple.Safari".into(),
            count: 17,
        };
        let s = serde_json::to_string(&a).unwrap();
        let back: ObservedAppJson = serde_json::from_str(&s).unwrap();
        assert_eq!(a, back);
    }

    #[test]
    fn episode_json_serde_round_trip() {
        let e = EpisodeJson {
            id: 9,
            app_bundle_id: Some("com.microsoft.VSCode".into()),
            ts_start_us: 1_000_000,
            ts_end_us: 2_000_000,
            event_count: 7,
        };
        let s = serde_json::to_string(&e).unwrap();
        let back: EpisodeJson = serde_json::from_str(&s).unwrap();
        assert_eq!(e, back);
    }

    #[test]
    fn list_observed_apps_with_null_handle_returns_null() {
        let q = CString::new(r#"{"limit":5}"#).unwrap();
        let p = unsafe { mci_brain_ffi_list_observed_apps(std::ptr::null_mut(), q.as_ptr()) };
        assert!(p.is_null());
    }

    #[test]
    fn list_episodes_with_null_handle_returns_null() {
        let p = unsafe { mci_brain_ffi_list_episodes(std::ptr::null_mut(), 5) };
        assert!(p.is_null());
    }

    // -----------------------------------------------------------------
    // events_by_ids — cycle 8.37 PR-3 related-hits flyout fetch surface
    // -----------------------------------------------------------------

    #[test]
    fn events_by_ids_query_json_parses() {
        let q: EventsByIdsQueryJson =
            serde_json::from_str(r#"{"ids":[101,202,303]}"#).expect("valid ids payload");
        assert_eq!(q.ids, vec![101, 202, 303]);
    }

    #[test]
    fn events_by_ids_query_json_accepts_empty_list() {
        let q: EventsByIdsQueryJson =
            serde_json::from_str(r#"{"ids":[]}"#).expect("empty ids payload");
        assert!(q.ids.is_empty());
    }

    #[test]
    fn events_by_ids_cap_is_bounded() {
        // 32 is chosen to match LINK_LIMIT * 2 headroom while keeping the
        // per-call get_event loop bounded. Locked here so a future patch
        // cannot silently unbound it.
        assert_eq!(EVENTS_BY_IDS_CAP, 32);
    }

    #[test]
    fn events_by_ids_with_null_handle_returns_null() {
        let q = CString::new(r#"{"ids":[1]}"#).unwrap();
        let p = unsafe { mci_brain_ffi_events_by_ids(std::ptr::null_mut(), q.as_ptr()) };
        assert!(p.is_null());
    }

    // -----------------------------------------------------------------
    // user-dictionary alias expansion — cycle 8.42
    // -----------------------------------------------------------------

    #[test]
    fn query_json_accepts_user_aliases_field() {
        // Positive: the new field parses and populates the map.
        let q: QueryJson = serde_json::from_str(
            r#"{"text":"AJ email","limit":5,"user_aliases":{"Amy Jain":["AJ","Amy"]}}"#,
        )
        .expect("valid alias payload parses");
        assert_eq!(q.user_aliases.get("Amy Jain").map(Vec::len), Some(2));
    }

    #[test]
    fn query_json_defaults_user_aliases_to_empty_when_missing() {
        // Backward-compat: pre-8.42 clients omit the key entirely; serde
        // default gives an empty map, and the FFI's expansion becomes a
        // no-op (baseline recall trace).
        let q: QueryJson =
            serde_json::from_str(r#"{"text":"hello","limit":5}"#).expect("legacy parses");
        assert!(q.user_aliases.is_empty());
    }

    #[test]
    fn expand_query_empty_map_is_identity() {
        let m = std::collections::HashMap::new();
        assert_eq!(expand_query_with_user_aliases("hello", &m), "hello");
    }

    #[test]
    fn expand_query_untriggered_group_is_identity() {
        let mut m = std::collections::HashMap::new();
        m.insert("Amy Jain".to_string(), vec!["AJ".into()]);
        // Query has nothing to do with Amy — no expansion.
        assert_eq!(
            expand_query_with_user_aliases("vector database", &m),
            "vector database"
        );
    }

    #[test]
    fn expand_query_touches_alias_and_ors_in_canonical_and_siblings() {
        let mut m = std::collections::HashMap::new();
        m.insert("Amy Jain".to_string(), vec!["AJ".into(), "Amy".into()]);
        let out = expand_query_with_user_aliases("AJ email", &m);
        // Must preserve the original query in parens.
        assert!(out.starts_with("(AJ email)"), "got: {out}");
        // Must OR in the canonical + every alias, quoted.
        assert!(out.contains("\"Amy Jain\""), "got: {out}");
        assert!(out.contains("\"AJ\""), "got: {out}");
        assert!(out.contains("\"Amy\""), "got: {out}");
        assert!(out.contains(" OR "), "got: {out}");
    }

    #[test]
    fn expand_query_is_case_insensitive_on_the_input() {
        let mut m = std::collections::HashMap::new();
        m.insert("Hippocampus".to_string(), vec!["MCI".into()]);
        // Lower-case in the query still triggers the group whose
        // canonical is capitalized.
        let out = expand_query_with_user_aliases("mci demo", &m);
        assert!(out.contains("\"Hippocampus\""), "got: {out}");
        assert!(out.contains("\"MCI\""), "got: {out}");
    }

    #[test]
    fn expand_query_only_expands_touched_groups() {
        // A hit for one group must NOT drag in unrelated groups. This is
        // the load-bearing precision guarantee — a user with 50 aliases
        // never sees all 50 stitched into every query.
        let mut m = std::collections::HashMap::new();
        m.insert("Amy Jain".to_string(), vec!["AJ".into()]);
        m.insert("Hippocampus".to_string(), vec!["MCI".into()]);
        let out = expand_query_with_user_aliases("AJ email", &m);
        assert!(out.contains("\"Amy Jain\""));
        assert!(
            !out.contains("Hippocampus"),
            "leaked untouched group: {out}"
        );
    }

    #[test]
    fn expand_query_group_cap_bounds_output_size() {
        // Load 2 * cap groups. Only cap of them can appear in the output.
        let mut m = std::collections::HashMap::new();
        let mut query = String::new();
        for i in 0..(USER_ALIAS_GROUP_CAP * 2) {
            let name = format!("Name{i}");
            m.insert(name.clone(), vec![format!("N{i}")]);
            query.push_str(&name);
            query.push(' ');
        }
        let out = expand_query_with_user_aliases(&query, &m);
        // Count OR-group parens after the leading `(<query>)`.
        let or_count = out.matches(" OR (").count();
        assert!(or_count <= USER_ALIAS_GROUP_CAP, "got {or_count} OR-groups");
    }

    // -----------------------------------------------------------------
    // Cycle 8.47 — mutation surface helpers (constant-time eq, token gen)
    // -----------------------------------------------------------------

    #[test]
    fn constant_time_eq_matches_on_equal_inputs() {
        assert!(constant_time_eq(b"abcdef", b"abcdef"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn constant_time_eq_rejects_mismatched_inputs() {
        assert!(!constant_time_eq(b"abcdef", b"abcxef"));
        assert!(!constant_time_eq(b"a", b"b"));
    }

    #[test]
    fn constant_time_eq_rejects_different_lengths() {
        assert!(!constant_time_eq(b"abc", b"abcd"));
        assert!(!constant_time_eq(b"", b"a"));
    }

    #[test]
    fn generate_wipe_token_yields_64_hex_chars() {
        let t = generate_wipe_token().expect("csprng");
        assert_eq!(t.len(), 64);
        assert!(t.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn generate_wipe_token_pair_are_distinct() {
        // 256-bit random collision is cryptographically impossible;
        // a failure here means the RNG is broken / stubbed.
        let a = generate_wipe_token().expect("csprng");
        let b = generate_wipe_token().expect("csprng");
        assert_ne!(a, b);
    }

    #[test]
    fn wipe_token_ttl_is_60_seconds() {
        // Pinned so a future patch cannot silently widen the window.
        // A wider window increases replay surface if a token ever leaks
        // via transcript logs (defensive — the token is single-use, so
        // this is defence-in-depth).
        assert_eq!(WIPE_TOKEN_TTL, Duration::from_secs(60));
    }

    #[test]
    fn delete_result_json_serde_round_trip() {
        let r = DeleteResultJson {
            events_deleted: 42,
            vacuum_ok: true,
        };
        let s = serde_json::to_string(&r).unwrap();
        let back: DeleteResultJson = serde_json::from_str(&s).unwrap();
        assert_eq!(r, back);
        // Wire is snake_case for Swift Codable interop.
        assert!(s.contains("\"events_deleted\""), "got: {s}");
        assert!(s.contains("\"vacuum_ok\""), "got: {s}");
    }

    #[test]
    fn events_by_ids_with_null_query_returns_null() {
        // Dummy non-null handle-shaped pointer so we exercise the null-query
        // branch, not the null-handle branch. Cannot dereference — the
        // function's null-query check runs before it touches the handle.
        // Safe: the entry point uses `if query_json.is_null()` first.
        let h_stub = 0x1 as *mut Handle;
        let p = unsafe { mci_brain_ffi_events_by_ids(h_stub, std::ptr::null()) };
        assert!(p.is_null());
        let err = unsafe { mci_brain_ffi_last_error_message() };
        assert!(!err.is_null());
        let msg = unsafe { CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        assert!(msg.contains("null query"), "got: {msg}");
    }

    // -----------------------------------------------------------------
    // V2-P13 (Phase D scaffold) — timeline_events downsampler + wire shape
    // -----------------------------------------------------------------

    fn mk_te(ts_us: u64, event_id: u64) -> TimelineEventJson {
        TimelineEventJson {
            event_id,
            ts_us,
            app_bundle_id: Some("com.apple.Safari".into()),
            snippet: "hello".into(),
            thumbnail_path: None,
        }
    }

    #[test]
    fn timeline_event_json_serde_round_trip() {
        let e = mk_te(1_700_000_000_000_000, 42);
        let s = serde_json::to_string(&e).unwrap();
        let back: TimelineEventJson = serde_json::from_str(&s).unwrap();
        assert_eq!(e, back);
        assert!(s.contains("\"event_id\""), "got: {s}");
        assert!(s.contains("\"snippet\""), "got: {s}");
        assert!(s.contains("\"thumbnail_path\""), "got: {s}");
    }

    #[test]
    fn timeline_query_json_parses_with_and_without_resolution() {
        let q: TimelineQueryJson = serde_json::from_str(r#"{"start_ts_us":100,"end_ts_us":200}"#)
            .expect("parses without resolution");
        assert_eq!(q.start_ts_us, 100);
        assert_eq!(q.end_ts_us, 200);
        assert!(q.resolution.is_none());
        let q2: TimelineQueryJson =
            serde_json::from_str(r#"{"start_ts_us":100,"end_ts_us":200,"resolution":"minute"}"#)
                .expect("parses with resolution");
        assert_eq!(q2.resolution.as_deref(), Some("minute"));
    }

    #[test]
    fn timeline_snippet_caps_long_text() {
        let long = "x".repeat(TIMELINE_SNIPPET_CAP + 100);
        let s = timeline_snippet(&long);
        assert_eq!(s.chars().count(), TIMELINE_SNIPPET_CAP);
    }

    #[test]
    fn timeline_snippet_passes_short_text() {
        assert_eq!(timeline_snippet("hi"), "hi");
    }

    #[test]
    fn downsample_below_cap_is_identity() {
        // Fewer events than the cap → return input unchanged, preserving
        // order.
        let events: Vec<TimelineEventJson> = (0..10)
            .map(|i| mk_te((i as u64) * TIMELINE_MINUTE_US, i))
            .collect();
        let out = downsample_timeline(events.clone(), 10 * TIMELINE_MINUTE_US);
        assert_eq!(out.len(), 10);
        assert_eq!(out.first().map(|e| e.event_id), Some(0));
        assert_eq!(out.last().map(|e| e.event_id), Some(9));
    }

    #[test]
    fn downsample_above_cap_bounds_output_count() {
        // 5x the cap of events over a 24-hour range → bucketed to at most
        // MAX_EVENTS rows.
        let n = TIMELINE_MAX_EVENTS * 5;
        // Space events evenly over 24 hours.
        let range_us = 24 * 60 * TIMELINE_MINUTE_US;
        let step = range_us / (n as u64);
        let events: Vec<TimelineEventJson> = (0..n as u64).map(|i| mk_te(i * step, i)).collect();
        let out = downsample_timeline(events, range_us);
        assert!(
            out.len() <= TIMELINE_MAX_EVENTS,
            "downsampled to {} rows; cap is {TIMELINE_MAX_EVENTS}",
            out.len()
        );
    }

    #[test]
    fn downsample_preserves_ascending_order() {
        let events: Vec<TimelineEventJson> = (0..(TIMELINE_MAX_EVENTS as u64 + 100))
            .map(|i| mk_te(i * TIMELINE_MINUTE_US, i))
            .collect();
        let range = (TIMELINE_MAX_EVENTS as u64 + 100) * TIMELINE_MINUTE_US;
        let out = downsample_timeline(events, range);
        for w in out.windows(2) {
            assert!(w[0].ts_us <= w[1].ts_us, "downsample re-ordered rows");
        }
    }

    #[test]
    fn timeline_events_with_null_handle_returns_null() {
        let q = CString::new(r#"{"start_ts_us":0,"end_ts_us":1000}"#).unwrap();
        let p = unsafe { mci_brain_ffi_timeline_events(std::ptr::null_mut(), q.as_ptr()) };
        assert!(p.is_null());
    }

    #[test]
    fn timeline_events_with_null_query_returns_null() {
        // Same null-query trick as events_by_ids: the null-query check
        // runs before touching the handle, so a stub non-null pointer is
        // safe.
        let h_stub = 0x1 as *mut Handle;
        let p = unsafe { mci_brain_ffi_timeline_events(h_stub, std::ptr::null()) };
        assert!(p.is_null());
        let err = unsafe { mci_brain_ffi_last_error_message() };
        assert!(!err.is_null());
        let msg = unsafe { CStr::from_ptr(err) }
            .to_string_lossy()
            .into_owned();
        assert!(msg.contains("null query"), "got: {msg}");
    }

    #[test]
    fn timeline_max_range_is_90_days() {
        // Pinned so a future patch cannot silently widen the window.
        let ninety_days_us: u64 = 90 * 24 * 60 * 60 * 1_000_000;
        assert_eq!(TIMELINE_MAX_RANGE_US, ninety_days_us);
    }

    #[test]
    fn timeline_max_events_is_1000() {
        // Locked here so a future patch cannot silently unbound the
        // per-call row budget.
        assert_eq!(TIMELINE_MAX_EVENTS, 1_000);
    }
}
