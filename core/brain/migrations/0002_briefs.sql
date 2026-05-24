-- mci-brain · migration 0002 · Daily Brief storage.
--
-- Backs `docs/design/brief-viewer-spec.md` (the Daily Brief Viewer tab in
-- the Recall UI) + ADR-0028 (Qwen3-1.7B brief-author model).
--
-- Schema decision: a SEPARATE `briefs` table — not an `events` row type.
-- Rationale:
--
--   • Briefs are a sibling content kind with their own lifecycle (one per
--     local day; regeneration overwrites; date-keyed lookup) and a wholly
--     different access pattern from events (no FTS5, no vector recall).
--   • Mixing them into `events` would force a discriminator column on
--     every row, a `NULL` embedding on every brief, and a write to
--     `events_fts` no consumer ever queries — pure overhead.
--   • The separate-table cost is one `CREATE TABLE IF NOT EXISTS`. Both
--     migrations apply inside the same transaction (see
--     `run_brain_migration` in `sqlcipher_brain_store.rs`), and every
--     statement is idempotent, so re-running on an already-migrated DB
--     is a no-op.
--
-- Protected-set context:
--
--   The briefs table holds user-readable content. It lives inside the
--   existing SQLCipher store (ADR-0008) under the same key-wrap as
--   `events` — there is no new crypto surface, no new key, no new
--   network call. The retention purger (`retention_purger.rs`) gains a
--   second DELETE pass that honors the user's existing retention window
--   on briefs, so the user's "30 / 90 / Forever" choice continues to be
--   the SOLE source of truth for what disappears. CSO sign-off block in
--   the PR body covers this addition.
--
-- Reversibility:
--
--   `down.sql` drops the table, indices, and the `briefs_schema_version`
--   meta stamp. Tests (`sqlcipher_brain_store::tests::briefs_*`) round-
--   trip the schema by applying up → down → up.

-- briefs — one row per local day. UNIQUE(date_local) ⇒ INSERT OR REPLACE
-- semantics on regeneration; the row keeps a stable primary key so any
-- downstream reference (a notification's brief_id, an audit log entry,
-- etc.) survives a regenerate.
CREATE TABLE IF NOT EXISTS briefs (
    id                  INTEGER PRIMARY KEY,
    -- ISO 8601 local date "YYYY-MM-DD". Local timezone because the spec
    -- says "yesterday's brief" — a calendar concept the user reasons
    -- about in their own timezone, not UTC. The Swift author passes the
    -- local-zone date string; the FFI does no zone conversion.
    date_local          TEXT NOT NULL,
    -- Wall-clock generation time, microseconds since UNIX epoch. Same
    -- unit as `events.ts_us` so retention math is identical.
    generated_ts_us     INTEGER NOT NULL,
    -- Model identifier (e.g. "qwen3-1.7b-int4" per ADR-0028) for the
    -- brief header. NOT a foreign key — models come and go independently
    -- of the row.
    model_id            TEXT NOT NULL,
    -- Free-form model version string for the brief header — surface only,
    -- never matched on.
    model_version       TEXT NOT NULL,
    -- Brief title rendered above the body. Author may set; user-editable
    -- in a future cycle.
    title               TEXT NOT NULL,
    -- Markdown body. Author writes; reader renders. No length cap at the
    -- DDL level (a 200-event day's brief is still a few KB).
    body                TEXT NOT NULL,
    -- Word count for the header. Stored (not derived) so the header is
    -- cheap to render in lists.
    word_count          INTEGER NOT NULL,
    -- How many events the author saw when composing. Surfaces in the
    -- "based on N events" footer. 0 is allowed for stub/synthetic briefs.
    source_event_count  INTEGER NOT NULL DEFAULT 0
);

-- One brief per local day. Regeneration is `INSERT OR REPLACE` keyed on
-- date_local. The unique index is doubly indexed (date_local is the
-- common lookup column too) so the cost is one B-tree.
CREATE UNIQUE INDEX IF NOT EXISTS briefs_date_uniq
    ON briefs(date_local);

-- Index on generation time so the retention purger's
-- `DELETE FROM briefs WHERE generated_ts_us < ?` runs index-driven.
CREATE INDEX IF NOT EXISTS briefs_generated
    ON briefs(generated_ts_us);

-- Stamp the briefs sub-schema version. Lives under its own meta key so
-- future briefs-only migrations bump independently of the main brain
-- schema version.
INSERT OR REPLACE INTO meta (key, value)
    VALUES ('briefs_schema_version', '1');
