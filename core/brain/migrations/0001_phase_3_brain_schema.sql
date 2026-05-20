-- mci-brain · migration 0001 · Phase 3 brain schema (ADR-0016 §1.4 verbatim).
--
-- PROTECTED-SET per AGENT_PROTOCOL §5 — touches the encrypted store and
-- materializes the first tables that hold user-readable content. CSO
-- sign-off on this DDL is binding (PR P3.2).
--
-- The migration runs inside one transaction. Order matters where
-- REFERENCES is involved: episodes before events; events before
-- event_vectors / chunks / events_fts triggers.
--
-- vec_events (sqlite-vec vec0 mirror over event_vectors.embedding) is
-- DEFERRED in this migration: the rusqlite/load_extension feature is not
-- enabled in mci-core (see core/src/store/open.rs module docs — the
-- runtime dlopen ships with the bundled binary in a later cycle), so
-- creating a vec0 virtual table here would fail with "no such module:
-- vec0". vec_search in P3.2 brute-forces over event_vectors.embedding
-- BLOB. The full vec0 mirror lands when the bundled sqlite-vec binary
-- + rusqlite load_extension feature are wired together.
--
-- meta.brain_schema_version stamps this migration's apply at the end.
-- The stamp lives under a brain-specific key so it cannot collide with
-- mci-core's existing meta.schema_version (mci-core's store-init is
-- currently not called by any production code path; the two schemas may
-- co-exist in the same encrypted file iff each side stamps a separate
-- meta key. P3.2 is the first phase to materialize anything in this file
-- via production code).

-- meta — schema-version + brain-state pointers
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- episodes — contiguous app/task runs; backfilled by the segmenter.
CREATE TABLE IF NOT EXISTS episodes (
    id              INTEGER PRIMARY KEY,
    ts_start        INTEGER NOT NULL,
    ts_end          INTEGER NOT NULL,
    app_bundle_id   TEXT,
    summary         TEXT,
    entities        TEXT
);

-- events — the retrieval and index unit per ADR-0010 / ADR-0016 §1.4.
CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY,
    ts_us           INTEGER NOT NULL,
    app_bundle_id   TEXT,
    window_title    TEXT,
    url             TEXT,
    text            TEXT NOT NULL,
    summary         TEXT,
    entities        TEXT,
    episode_id      INTEGER,
    cascade_reason  INTEGER NOT NULL DEFAULT 0,
    keyframe_blob   TEXT,
    FOREIGN KEY (episode_id) REFERENCES episodes(id)
);

CREATE INDEX IF NOT EXISTS events_ts ON events(ts_us);
CREATE INDEX IF NOT EXISTS events_app ON events(app_bundle_id);
CREATE INDEX IF NOT EXISTS events_episode ON events(episode_id);

-- events_fts — FTS5 external-content virtual table over the searchable
-- columns of `events`. Tokenizer per ADR-0016 §1.4: porter stemming +
-- unicode61 + remove_diacritics 2 (NFC + diacritic stripping).
CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
    text, summary, window_title, url,
    content='events',
    content_rowid='id',
    tokenize = "porter unicode61 remove_diacritics 2"
);

-- External-content sync triggers (standard FTS5 contentless-rowid
-- pattern). Triggers must execute inside the same transaction as the
-- `events` INSERT so half-indexed rows are unobservable.
CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
    INSERT INTO events_fts(rowid, text, summary, window_title, url)
    VALUES (new.id, new.text, new.summary, new.window_title, new.url);
END;

CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
    INSERT INTO events_fts(events_fts, rowid, text, summary, window_title, url)
    VALUES('delete', old.id, old.text, old.summary, old.window_title, old.url);
END;

CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
    INSERT INTO events_fts(events_fts, rowid, text, summary, window_title, url)
    VALUES('delete', old.id, old.text, old.summary, old.window_title, old.url);
    INSERT INTO events_fts(rowid, text, summary, window_title, url)
    VALUES (new.id, new.text, new.summary, new.window_title, new.url);
END;

-- event_vectors — regular table holding the 384×f32 L2-normalized
-- embedding as a raw little-endian BLOB. ADR-0009 pins the dimension; the
-- BLOB is exactly 1536 bytes (384 * 4) when present. ON DELETE CASCADE
-- ties vector lifetime to the parent event.
CREATE TABLE IF NOT EXISTS event_vectors (
    event_id   INTEGER PRIMARY KEY,
    embedding  BLOB NOT NULL,
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
);

-- chunks — sub-units for over-long events (ADR-0010 §4 / ADR-0016 §1.4).
-- P3.2 creates the table; P3.4 wires the EventChunker writer.
CREATE TABLE IF NOT EXISTS chunks (
    id              INTEGER PRIMARY KEY,
    event_id        INTEGER NOT NULL,
    text            TEXT NOT NULL,
    embedding       BLOB,
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
);

-- Stamp the brain schema version. Lives under a brain-specific meta key
-- to leave room for mci-core's separate schema_version stamp (which lives
-- under key 'schema_version' in mci-core's store-init path).
INSERT OR REPLACE INTO meta (key, value) VALUES ('brain_schema_version', '1');
INSERT OR REPLACE INTO meta (key, value) VALUES ('vec_events_mirror', 'deferred');
