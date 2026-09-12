-- Legacy rows intentionally have no attribution. Do not infer from app or text.
CREATE TABLE IF NOT EXISTS event_sources (
    event_id INTEGER PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
    source_kind TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS event_sources_kind ON event_sources(source_kind, event_id);
