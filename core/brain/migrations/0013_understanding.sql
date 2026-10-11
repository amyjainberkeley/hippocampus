-- 0013: the understanding layer.
--
-- Fresh tables only, every statement IF NOT EXISTS, so the apply is
-- idempotent on re-open (same discipline as 0009, 0011 and 0012). Nothing
-- here alters an existing table.
--
-- Everything below is derived from captured events and must disappear with
-- them: rows that name an event cascade from it, and the store deletes any
-- proposition, session note or day report built on a deleted event before the
-- event itself goes (see `understanding::delete_for_events`).

-- Input counts per sampling interval: how many key presses, clicks, scroll
-- steps and pointer moves the system counted. Counts only; never which keys.
CREATE TABLE IF NOT EXISTS interaction_counts (
    start_us INTEGER PRIMARY KEY NOT NULL CHECK (typeof(start_us) = 'integer' AND start_us > 0),
    end_us   INTEGER NOT NULL CHECK (typeof(end_us) = 'integer' AND end_us > start_us AND end_us - start_us <= 60000000),
    keys     INTEGER NOT NULL CHECK (keys >= 0),
    clicks   INTEGER NOT NULL CHECK (clicks >= 0),
    scrolls  INTEGER NOT NULL CHECK (scrolls >= 0),
    moves    INTEGER NOT NULL CHECK (moves >= 0)
) WITHOUT ROWID;

-- A search the user ran, read from the URL of a captured page or window.
CREATE TABLE IF NOT EXISTS search_queries (
    event_id INTEGER PRIMARY KEY NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    ts_us    INTEGER NOT NULL,
    engine   TEXT NOT NULL CHECK (length(engine) BETWEEN 1 AND 64),
    query    TEXT NOT NULL CHECK (length(query) BETWEEN 1 AND 512)
);
CREATE INDEX IF NOT EXISTS search_queries_ts ON search_queries(ts_us);

-- General user model (GUM): natural-language propositions about the user,
-- each with the model's reasoning, a calibrated confidence, a decay rate (how
-- quickly it goes stale) and the events it rests on. A proposition the user
-- marks wrong is kept as 'rejected' so it is not proposed again.
CREATE TABLE IF NOT EXISTS propositions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    text         TEXT NOT NULL CHECK (length(text) BETWEEN 1 AND 1000),
    reasoning    TEXT NOT NULL DEFAULT '' CHECK (length(reasoning) <= 4000),
    kind         TEXT NOT NULL DEFAULT 'state'
                 CHECK (kind IN ('project', 'goal', 'state', 'habit', 'preference', 'skill', 'relationship', 'struggle')),
    confidence   REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    decay        REAL NOT NULL CHECK (decay >= 0 AND decay <= 1),
    status       TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'retired', 'rejected')),
    created_us   INTEGER NOT NULL,
    updated_us   INTEGER NOT NULL,
    revised_from INTEGER,
    model        TEXT NOT NULL CHECK (length(model) BETWEEN 1 AND 128)
);
CREATE INDEX IF NOT EXISTS propositions_status_updated ON propositions(status, updated_us);

CREATE TABLE IF NOT EXISTS proposition_evidence (
    proposition_id INTEGER NOT NULL REFERENCES propositions(id) ON DELETE CASCADE,
    event_id       INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    PRIMARY KEY (proposition_id, event_id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS proposition_evidence_event ON proposition_evidence(event_id);

CREATE VIRTUAL TABLE IF NOT EXISTS propositions_fts USING fts5(
    text, reasoning, content='propositions', content_rowid='id'
);
CREATE TRIGGER IF NOT EXISTS propositions_ai AFTER INSERT ON propositions BEGIN
    INSERT INTO propositions_fts(rowid, text, reasoning) VALUES (new.id, new.text, new.reasoning);
END;
CREATE TRIGGER IF NOT EXISTS propositions_ad AFTER DELETE ON propositions BEGIN
    INSERT INTO propositions_fts(propositions_fts, rowid, text, reasoning)
    VALUES ('delete', old.id, old.text, old.reasoning);
END;
CREATE TRIGGER IF NOT EXISTS propositions_au AFTER UPDATE OF text, reasoning ON propositions BEGIN
    INSERT INTO propositions_fts(propositions_fts, rowid, text, reasoning)
    VALUES ('delete', old.id, old.text, old.reasoning);
    INSERT INTO propositions_fts(rowid, text, reasoning) VALUES (new.id, new.text, new.reasoning);
END;

-- A work session: a stretch of activity across apps, bounded by idle gaps.
-- What was on the surface, what lay beneath it, and the measured signals
-- (JSON). Rewritten if more events arrive inside it.
CREATE TABLE IF NOT EXISTS session_notes (
    start_us     INTEGER PRIMARY KEY NOT NULL CHECK (start_us > 0),
    end_us       INTEGER NOT NULL CHECK (end_us >= start_us),
    title        TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    surface      TEXT NOT NULL CHECK (length(surface) <= 4000),
    beneath      TEXT NOT NULL CHECK (length(beneath) <= 4000),
    signals      TEXT NOT NULL DEFAULT '{}',
    event_count  INTEGER NOT NULL CHECK (event_count >= 0),
    generated_us INTEGER NOT NULL,
    model        TEXT NOT NULL CHECK (length(model) BETWEEN 1 AND 128)
);
CREATE INDEX IF NOT EXISTS session_notes_end ON session_notes(end_us);

-- One written account of a local day: the measured breakdown plus what the
-- user model reads beneath it (JSON).
CREATE TABLE IF NOT EXISTS day_reports (
    date_local   TEXT PRIMARY KEY NOT NULL CHECK (date_local GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
    start_us     INTEGER NOT NULL,
    end_us       INTEGER NOT NULL CHECK (end_us > start_us),
    generated_us INTEGER NOT NULL,
    model        TEXT NOT NULL CHECK (length(model) BETWEEN 1 AND 128),
    body         TEXT NOT NULL
);

-- Progress markers for the understanding worker (last event observed, and
-- similar). Content-free.
CREATE TABLE IF NOT EXISTS understanding_state (
    key   TEXT PRIMARY KEY NOT NULL CHECK (length(key) BETWEEN 1 AND 64),
    value TEXT NOT NULL
);
