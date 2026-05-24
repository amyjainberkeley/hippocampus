/*
 * mci_brain_ffi.h — C ABI for the MCI Phase-3 brain, READ-ONLY.
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
 * Read-only by construction: there is no mutating entry point. Adding
 * one is an AGENT_PROTOCOL §5 protected-set change.
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

/* Close a handle. NULL is a no-op. Double-close is undefined. */
void mci_brain_ffi_close(McibrainHandle *h);

/* Run a search. `query_json` is a UTF-8 JSON string of shape
 *   {"text":"...","limit":N,"time_from_us":<u64?>,"time_to_us":<u64?>,
 *    "app_filter":"<bundle>?"}
 * Returns a UTF-8 JSON array of HitJson rows on success; NULL on error.
 * Caller must mci_brain_ffi_string_free the return value. */
char *mci_brain_ffi_search(McibrainHandle *h, const char *query_json);

/* Fetch the `limit` most-recent events as a JSON array of HitJson. */
char *mci_brain_ffi_recent_events(McibrainHandle *h, uint32_t limit);

/* Fetch the `limit` most-recent privacy moments as a JSON array.
 * Each row carries ONLY {ts_us, app_bundle_id?, reason_code}.
 * NEVER OCR text / keyframe / windowTitle / url
 * (ADR-0017 §5.1 + ADR-0016 §4.5).
 * P3.9b returns an empty list — the tombstone source is a separate
 * file (`mci-tombstones.bin`) and surfacing it is P3.9c. */
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
