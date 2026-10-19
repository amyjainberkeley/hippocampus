/*
 * mci_brain_ffi.h — C ABI for the MCI Phase-3 brain.
 *
 * Consumed by the Swift recall-ui app (apps/recall-ui/).
 *
 * Allocator discipline: every `char *` this header returns by value
 * (i.e. the return value of mci_brain_ffi_search, _recent_events,
 * _recent_privacy_moments) is owned by Rust. Pass it back to
 * mci_brain_ffi_string_free when done. Do not call free() on it.
 *
 * Threading: each call is internally synchronized. The thread-local
 * error slot (mci_brain_ffi_last_error_message) is per-thread.
 *
 * Two tiers (post cycle 8.47, PR #76 follow-up):
 *   - READ tier: the long-lived FFI handle is SQLITE_OPEN_READ_ONLY.
 *     No read entry point can mutate the brain.
 *   - MUTATION tier: four enumerated methods (_delete_event,
 *     _delete_events_in_range, _prepare_wipe, _wipe_brain) open a
 *     transient writer for one DELETE + VACUUM, gated by the Swift
 *     Privacy Dashboard's typed-word ("DELETE") confirmation + a
 *     60s-TTL token flow for wipe. Adding a fifth mutation method is
 *     an AGENT_PROTOCOL §5 protected-set change; the
 *     `ffi_exports_no_mutating_surface_beyond_allowlist` test in
 *     `tests/readonly_invariant.rs` fails if the count changes.
 */

#ifndef MCI_BRAIN_FFI_H
#define MCI_BRAIN_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle. Obtain via mci_brain_ffi_open; release via
 * mci_brain_ffi_close. Single-close — the caller must enforce. */
typedef struct McibrainHandle McibrainHandle;

/* Open the brain at `path` with the hex-encoded SQLCipher key.
 * Returns NULL on failure; poll mci_brain_ffi_last_error_message
 * for a diagnostic. The connection is READ-ONLY. */
McibrainHandle *mci_brain_ffi_open(const char *path, const char *key_hex);

/* Open the same READ-ONLY brain with an explicit Arctic Embed S Core ML
 * model. A missing, incompatible, or non-predicting model returns NULL;
 * callers may retry mci_brain_ffi_open for lexical-only recall. */
McibrainHandle *mci_brain_ffi_open_with_model(
    const char *path,
    const char *key_hex,
    const char *model_path
);

/* Close a handle. NULL is a no-op. Double-close is undefined. */
void mci_brain_ffi_close(McibrainHandle *h);

/* Run a search. `query_json` is a UTF-8 JSON string of shape
 *   {"text":"...","limit":N,"time_from_us":<u64?>,"time_to_us":<u64?>,
 *    "app_filter":"<bundle>?"}
 * Returns a UTF-8 JSON array of HitJson rows on success; NULL on error.
 * Caller must mci_brain_ffi_string_free the return value. */
char *mci_brain_ffi_search(McibrainHandle *h, const char *query_json);

/* Fetch the `limit` most-recent events as a JSON array of HitJson. Each row
 * carries "caption": one short plain line saying what the moment was about
 * (stored by the re-clean job, or made from the title), or null. */
char *mci_brain_ffi_recent_events(McibrainHandle *h, uint32_t limit);

/* Half-open measured-activity window, max two days and 50,000 rows.
 * JSON {intervals:[{start_us,end_us,state,app_bundle_id}],truncated:bool}.
 * No run identity/content. NULL on invalid range or unavailable storage.
 * Free with mci_brain_ffi_string_free. */
char *mci_brain_activity_intervals(McibrainHandle *h, uint64_t start_us,
                                  uint64_t end_us, uint32_t limit);

/* Resolve a batch of event ids into full HitJson rows. Powers the recall
 * UI's related-hits flyout (cycle 8.37 PR-3): given a hit whose
 * `linked_event_ids` names its cross-app siblings, the Swift side calls
 * this to render the "your email about X is connected to your Slack
 * message about Y" strip.
 *   `query_json`: {"ids":[<u64>,<u64>,...]}
 *   returns: JSON array of HitJson rows (source="linked", score=null).
 * Order follows input order for ids that resolve; ids that no longer
 * exist in the store are silently dropped. Input is capped at 32 ids
 * (excess is truncated) to bound the per-call get_event loop. */
char *mci_brain_ffi_events_by_ids(McibrainHandle *h, const char *query_json);

/* Read one selected admitted event through the existing read-only handle,
 * for an audit. Returns {"event_id":N,"ts_us":N,"app_bundle_id":<string|null>,
 *          "text":"...","truncated":false}, or JSON null for
 * a missing/deleted/suppressed/invalid id. Text is every stored word of a
 * UTF-8 prefix capped at 128 KiB without splitting a scalar: no header line,
 * the separator between a window's content and its chrome as a blank line,
 * any other U+001E as a space, nothing cleaned. A person reads
 * mci_brain_ffi_event_reading instead. truncated means text was
 * omitted. Timestamp/app and text come from the same row snapshot. Callers
 * MUST match timestamp and nullable app against the selected Hit: IDs can reuse.
 * App identity is capped at 1 KiB; oversized identity returns JSON null.
 * Escaped JSON is bounded by 6 * (128 KiB + 1 KiB) + 256 bytes (plus NUL).
 * No arbitrary paths, vectors or blobs are read. NULL on error.
 * Keep h alive during the call. Free non-NULL with mci_brain_ffi_string_free. */
char *mci_brain_ffi_event_text(McibrainHandle *h, uint64_t event_id);

/* The readable text of one selected event, for the detail view. Returns
 *   {"event_id":N,"ts_us":N,"app_bundle_id":<string|null>,
 *    "source_kind":"screen_ocr","main":"...","rest":"...",
 *    "match_in":"main"|"rest"|null,"truncated":false,"caption":<string|null>}
 * or JSON null for a missing/deleted/suppressed/invalid id. main is what the
 * person was reading; rest is everything else in the window (tabs, sidebars,
 * menus, status bars), and for a browser page read both ways the text read
 * off the screen; empty when there is nothing else. Neither holds the stored
 * header or U+001E. When the re-clean job stored a cleaned reading of the
 * current rules, main and rest are that one. `query` is NULL or a search's UTF-8 text; match_in says
 * whether its words are in main or only in rest (null without a query, or
 * when neither holds them; words such as "the" count only when the search has
 * no other). Reads the same 128 KiB prefix as mci_brain_ffi_event_text;
 * main and rest together are at most 128 KiB + 1 KiB, cut after a whole
 * line, and truncated says when either the read or that bound left text out.
 * NULL on error. Free non-NULL with mci_brain_ffi_string_free. */
char *mci_brain_ffi_event_reading(McibrainHandle *h, uint64_t event_id,
                                  const char *query);

/* The readable text of text that was never stored (a screenshot read
 * again), by the same rules as stored text. No handle: nothing is read from
 * memory.
 *   input_json: {"stored":"...","source":"screen_ocr"?,"app":"..."?,
 *                "title":"..."?,"url":"..."?}
 *   returns: {"main":"...","rest":"...","caption":<string|null>}
 * A missing or unknown source is shown as given. NULL on bad input or input
 * over 256 KiB.
 * Free non-NULL with mci_brain_ffi_string_free. */
char *mci_brain_ffi_reading(const char *input_json);

/* The readable name of an app from its bundle id: the one table of app
 * names, so the app under a row and in its caption agree. No handle.
 * Returns "Unknown app" for an empty id, NULL on a NULL or non-UTF8 id.
 * Free non-NULL with mci_brain_ffi_string_free. */
char *mci_brain_ffi_app_name(const char *bundle_id);

/* V2-P13 (Phase D scaffold) — Return a lightweight event summary for a
 * time range, downsampled to at most ~1000 rows per call.
 *   query_json: {"start_ts_us":<u64>,"end_ts_us":<u64>,
 *                "resolution":"minute|hour|day"?}
 *   returns: JSON array of TimelineEventJson rows:
 *     {"event_id":N,"ts_us":N,"app_bundle_id":"..?",
 *      "snippet":"..","thumbnail_path":"..?"}
 * Sorted by ts_us ASCENDING (left-to-right on the timeline strip). The
 * FFI rejects windows wider than 90 days and returns NULL on error.
 * Read-only: uses the same read-only handle as _recent_events. */
char *mci_brain_ffi_timeline_events(McibrainHandle *h, const char *query_json);

/* Fetch the `limit` most-recent privacy moments as a JSON array.
 * Each row carries ONLY {ts_us, app_bundle_id?, reason_code}.
 * NEVER OCR text / keyframe / windowTitle / url
 * (ADR-0017 §5.1 + ADR-0016 §4.5).
 * Returns an empty list until the separate append-only tombstone file
 * (`mci-tombstones.bin`) is exposed through this read-only boundary. */
char *mci_brain_ffi_recent_privacy_moments(McibrainHandle *h, uint32_t limit);

/* List the most-observed app_bundle_id values + their event counts.
 * `query_json` is a UTF-8 JSON string of shape
 *   {"limit": N, "time_from_us": <u64?>}
 * Returns a UTF-8 JSON array of {"app_bundle_id":"...","count":N}.
 * Sorted by count DESC, then bundle id ASC. Excludes nil-app rows.
 * Surface for the recall-UI dynamic per-app filter pills. */
char *mci_brain_ffi_list_observed_apps(McibrainHandle *h, const char *query_json);

/* List the `limit` most-recent episode rows from the episode_segmenter.
 * Returns a UTF-8 JSON array of
 *   {"id":N, "app_bundle_id":"...?", "ts_start_us":N, "ts_end_us":N,
 *    "event_count":N}
 * sorted by ts_start_us DESC. Surface for the recall-UI Episodes tab. */
char *mci_brain_ffi_list_episodes(McibrainHandle *h, uint32_t limit);

/* Daily Brief read surface — `docs/design/brief-viewer-spec.md`.
 * READ-ONLY by construction (no put_brief / delete_brief). Writes flow
 * through the agent process via SqlCipherBrainStore::put_brief. */

/* Fetch the brief for an ISO-8601 local date "YYYY-MM-DD".
 * Returns a UTF-8 JSON object of shape
 *   {"id":N,"date_local":"YYYY-MM-DD","generated_ts_us":N,
 *    "model_id":"...","model_version":"...","title":"...",
 *    "body":"...","word_count":N,"source_event_count":N}
 * or the literal JSON `null` when no brief exists for the date.
 * Returns NULL on error; caller must mci_brain_ffi_string_free the
 * (non-NULL) return value. */
char *mci_brain_ffi_brief_for_date(McibrainHandle *h, const char *date_local);

/* Fetch the most-recently-generated brief, or JSON `null` when the
 * store has no briefs. Returns NULL on error. */
char *mci_brain_ffi_latest_brief(McibrainHandle *h);

/* Fetch up to `limit` brief dates ("YYYY-MM-DD") as a JSON array of
 * strings, ordered most-recent first. `limit` is clamped at the FFI
 * boundary so a hostile value cannot allocate unbounded memory. */
char *mci_brain_ffi_brief_dates(McibrainHandle *h, uint32_t limit);

/* Content-free summary for the Privacy Dashboard's top card.
 * Returns a UTF-8 JSON object of shape
 *   {"total_events":N,"oldest_ts_us":<u64?>,"newest_ts_us":<u64?>,
 *    "disk_bytes":N,"storage":null}
 * disk_bytes is legacy database-only bytes, not total storage. This entrypoint
 * never enumerates blobs. A breakdown requires an explicit storage_usage call.
 * — total event count, oldest/newest ts (nil on empty store), and the
 * on-disk byte size of the SQLCipher brain file. NO row content is
 * exposed. Same allocator discipline as the other returners. */
char *mci_brain_ffi_summary_stats(McibrainHandle *h);

/* Explicit metadata-only logical storage snapshot, called off the UI thread.
 * Returns {"database":<measurement>,"wal":<measurement>,"shm":<measurement>,
 * "managed_blobs":<measurement>,"reported_total_bytes":<u64?>,"complete":<bool>}.
 * Measurements are {"logical_bytes":<u64?>,"status":<string>}.
 * Missing, unreadable, skipped and scan-limited components are explicit.
 * No symlink traversal, no recursion, no keys/data reads. At most 64 path
 * components and 20,000 entries. The 200ms budget is best-effort between
 * local metadata calls, not a hard latency bound on an OS call.
 * Do not use for polling. Same allocation/free discipline as summary_stats. */
char *mci_brain_ffi_storage_usage(McibrainHandle *h);

/* Cycle 8.47 — Privacy Dashboard mutation surface (PR #76 follow-up).
 *
 * The four functions below are the enumerated escape hatch from the
 * read-only invariant, gated by the Swift Privacy Dashboard's
 * typed-word ("DELETE" / "DELETE EVERYTHING") confirmation flow.
 * wipe_brain additionally requires a 60s-TTL token from prepare_wipe.
 *
 * Every mutation opens a transient writer connection, commits DELETE,
 * then attempts storage cleanup before closing. Returns UTF-8 JSON:
 * {"committed": true, "events_deleted": N, "vacuum_ok": bool,
 * "blob_cleanup_ok": bool}. Cleanup flags may be false after commit.
 * NULL means no committed outcome; caller must free via string_free. */

/* Delete a single event by id. `event_id_json` is
 * {"event_id": <u64>}. */
char *mci_brain_ffi_delete_event(McibrainHandle *h, const char *event_id_json);

/* Delete every event with `ts_us` in [start_ts_us, end_ts_us] (inclusive
 * bounds). Powers "Delete last 24 hours" range action. */
char *mci_brain_ffi_delete_events_in_range(McibrainHandle *h,
                                           uint64_t start_ts_us,
                                           uint64_t end_ts_us);

/* Issue a wipe-confirmation token. The returned string is a JSON string
 * literal (`"<64-hex>"`). Token expires 60s after issue; a second
 * prepare_wipe invalidates the previous token. Pass the decoded token
 * into wipe_brain to actually perform the wipe. */
char *mci_brain_ffi_prepare_wipe(McibrainHandle *h);

/* Wipe every user-content row. Requires `token` = the token returned by
 * the most-recent prepare_wipe (not expired). Any wipe_brain call —
 * success, wrong token, expired — consumes the pending token.
 * DOES NOT touch Keychain / Sparkle / retention config. */
char *mci_brain_ffi_wipe_brain(McibrainHandle *h, const char *token);

/* Free a string previously returned by this header's functions.
 * NULL is a no-op. Double-free is undefined. */
void mci_brain_ffi_string_free(char *s);

/* Last diagnostic from the current thread; valid only until the next
 * FFI call on this thread. Do NOT free. */
const char *mci_brain_ffi_last_error_message(void);

#ifdef __cplusplus
}
#endif

#endif /* MCI_BRAIN_FFI_H */
