-- mci-brain · migration 0003 · V2-P2 tab attribution: `events.tab_id`.
--
-- PROTECTED-SET per AGENT_PROTOCOL §5 — schema change to the `events`
-- table that holds user-readable content. CSO sign-off block on the
-- implementing PR (V2-P2) carries the audit. New column is `tab_id
-- INTEGER NULL` — same trust class as the existing `url` column per
-- ADR-0015 §4.1 (context-as-content). A `tab_id` value is meaningful
-- only when paired with a (source_browser, url) tuple; it is the
-- browser-assigned identifier of the tab the page-content event came
-- from, and is the missing key that lets cross-tab events sharing the
-- same URL be distinguished in recall.
--
-- Motivation:
--
--   The cycle 8.17 / 8.18 tab-attribution-mix root-cause memo
--   (docs/research/tab-attribution-mix-2026-05-29.md §3) traces the
--   "wrong tab's URL is attributed to my events" symptom in part to
--   `apps/agent/src/brain_ingest.rs` discarding the `tab_id` field
--   off the wire when unpacking a `PageContentEvent` (`tab_id: _`
--   destructure). The wire already carries the field as `u32`; the
--   brain side had no column to land it in. This migration adds the
--   column; the implementing brain_ingest plumb-through commit
--   forwards it.
--
-- Forward-only / NULL-safe:
--
--   • Adding a nullable column on an existing table is the simplest
--     SQLite ALTER pattern; no row rewrite. Existing rows keep
--     `tab_id = NULL`.
--   • The events_fts external-content virtual table indexes
--     `text + summary + window_title + url` (migration 0001
--     `events_fts` definition). `tab_id` is NOT FTS5-indexed: it is
--     an opaque integer identifier, not text content, and adding it
--     to the FTS5 surface would only widen the index without
--     improving recall on a string-query workload. Lexical search
--     keeps the original four columns.
--   • The existing `events_ai` / `events_au` / `events_ad` triggers
--     reference the four FTS5-indexed columns only. They do NOT
--     need to be re-created when a new non-FTS column is added.
--   • No `DEFAULT` clause: SQLite stores NULL for the new column on
--     every existing row (the cheapest path). New rows from V2-P2
--     callers pass an explicit `tab_id` value (or NULL for OCREvent
--     ingest paths that have no browser tab signal).
--
-- Privacy:
--
--   The `tab_id` is the browser's per-tab integer identifier
--   (chrome.tabs.Tab.id in Chromium-family; sender.tab.id in Safari
--   .appex / WebExtension). It is NOT user-typed content. ADR-0015
--   §4 invariants are preserved: the value reaches the brain only
--   when its source `PageContentEvent` cleared the cascade-equivalent
--   in the native messaging host (incognito gate, denylist consult,
--   secret-filter). No new IPC surface is introduced — the wire
--   already ships the field (`core/src/ipc/wire.rs`
--   `PageContentEvent::tab_id: u32`).

ALTER TABLE events ADD COLUMN tab_id INTEGER;

-- Index on (url, tab_id) so the "distinct events at the same URL
-- under different tabs" query pattern stays cheap as the brain grows.
-- Partial index — only rows where tab_id IS NOT NULL are
-- distinguishable by it, so a NULL-skipping index keeps the size to
-- the browser-sourced subset.
CREATE INDEX IF NOT EXISTS events_url_tab
    ON events(url, tab_id)
    WHERE tab_id IS NOT NULL;

-- Stamp the brain schema version. Lives under the existing
-- `brain_schema_version` meta key so the writer can detect "DB is at
-- V2-P2 or later" cheaply.
INSERT OR REPLACE INTO meta (key, value)
    VALUES ('brain_schema_version', '3');
