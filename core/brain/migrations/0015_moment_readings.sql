-- 0015: moment readings, the cleaned text and the caption of a moment.
--
-- Fresh table and index only, every statement IF NOT EXISTS, so the apply is
-- idempotent on re-open (same discipline as 0009 and 0011 to 0014). Nothing
-- here alters an existing table. Nothing here replaces the stored text:
-- `events.text` keeps what was read, byte for byte, and stays what search
-- indexes. The schema version stays at 10: a reader that does not know this
-- table reads moments as before.
--
-- Everything here is made from one event and goes with it. The row cascades
-- from its event, and the store also deletes it explicitly before the event
-- goes, so forgetting a moment, deleting a range, retention and a wipe all
-- remove it (see `moment_readings::delete_for_events`).
CREATE TABLE IF NOT EXISTS moment_readings (
    event_id    INTEGER PRIMARY KEY NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    -- The rules that made this row (`moment_readings::READING_VERSION`). A
    -- row with the current version is done and is never made again.
    version     INTEGER NOT NULL CHECK (version >= 1),
    -- The moment's text with the chrome learned from many frames set apart.
    -- NULL when that rule moved nothing: the live reading is then the same.
    main        TEXT,
    rest        TEXT,
    -- One short plain line, or NULL when none could be made.
    caption     TEXT CHECK (caption IS NULL OR length(caption) BETWEEN 1 AND 200),
    -- Who wrote it: 'title' (made from the title, without a model), or the
    -- on-device model's label ('apple-foundation-models', 'local:<model>').
    caption_by  TEXT CHECK (caption_by IS NULL OR length(caption_by) BETWEEN 1 AND 128),
    -- The model was asked about this moment. Its line was used, or it was
    -- not grounded and the line made from the title stays; either way it is
    -- not asked again.
    model_tried INTEGER NOT NULL DEFAULT 0 CHECK (model_tried IN (0, 1)),
    updated_us  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS moment_readings_caption_work
    ON moment_readings(model_tried, caption_by);
