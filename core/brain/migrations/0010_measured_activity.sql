-- Storage foundation only: intervals must come from a dedicated sampler.
-- No event linkage or synthetic duration inferred from screenshots.
-- The store validates existing objects before running migration DDL. A v10
-- brain missing any of these objects must refuse to open, not recreate an empty
-- deletion history. IF NOT EXISTS is not a repair policy. Writer and reader
-- opens compare the canonical schema and stream-validate barrier ordering once;
-- bounded admission then relies on these constraints and store-owned writes.
CREATE TABLE IF NOT EXISTS measured_activity (
    start_us INTEGER PRIMARY KEY NOT NULL CHECK (typeof(start_us) = 'integer' AND start_us > 0),
    end_us INTEGER NOT NULL CHECK (typeof(end_us) = 'integer' AND end_us > start_us AND end_us - start_us <= 5000000),
    state TEXT NOT NULL CHECK (state IN ('input_active', 'input_idle', 'unknown')),
    app_bundle_id TEXT,
    capture_generation TEXT NOT NULL CHECK (
        typeof(capture_generation) = 'text'
        AND length(capture_generation) BETWEEN 1 AND 128
        AND instr(capture_generation, char(0)) = 0
        AND capture_generation NOT GLOB '*[^A-Za-z0-9_-]*'
    ),
    CHECK (
        (state = 'unknown' AND app_bundle_id IS NULL)
        OR (state IN ('input_active', 'input_idle')
            AND app_bundle_id IS NOT NULL
            AND typeof(app_bundle_id) = 'text'
            AND length(app_bundle_id) BETWEEN 3 AND 255
            AND instr(app_bundle_id, char(0)) = 0
            AND instr(app_bundle_id, '.') > 0
            AND app_bundle_id NOT GLOB '*[^A-Za-z0-9.-]*'
            AND substr(app_bundle_id, 1, 1) GLOB '[A-Za-z0-9]'
            AND substr(app_bundle_id, -1, 1) GLOB '[A-Za-z0-9]'
            AND instr(app_bundle_id, '..') = 0
            AND instr(app_bundle_id, '.-') = 0
            AND instr(app_bundle_id, '-.') = 0)
    )
) WITHOUT ROWID;

CREATE TRIGGER IF NOT EXISTS measured_activity_no_insert_overlap
BEFORE INSERT ON measured_activity
WHEN EXISTS (
    SELECT 1 FROM measured_activity
    WHERE start_us > NEW.start_us - 5000000
      AND start_us < NEW.end_us AND end_us > NEW.start_us
)
BEGIN
    SELECT RAISE(ABORT, 'activity interval overlap');
END;

-- Content-free half-open privacy ranges survive deletion and wipe. Merging
-- adjacent ranges keeps their endpoints ordered and supports one seek per admit.
CREATE TABLE IF NOT EXISTS activity_deletion_barriers (
    start_us INTEGER PRIMARY KEY NOT NULL CHECK (typeof(start_us) = 'integer' AND start_us >= 0),
    end_us INTEGER NOT NULL CHECK (typeof(end_us) = 'integer' AND end_us > start_us)
) WITHOUT ROWID;

CREATE TRIGGER IF NOT EXISTS activity_deletion_barriers_no_insert_overlap
BEFORE INSERT ON activity_deletion_barriers
WHEN COALESCE((
    SELECT end_us FROM activity_deletion_barriers
    WHERE start_us <= NEW.end_us ORDER BY start_us DESC LIMIT 1
), -1) >= NEW.start_us
BEGIN
    SELECT RAISE(ABORT, 'activity deletion barriers must be merged');
END;

CREATE TRIGGER IF NOT EXISTS activity_deletion_barriers_no_update_overlap
BEFORE UPDATE ON activity_deletion_barriers
WHEN COALESCE((
    SELECT end_us FROM activity_deletion_barriers
    WHERE start_us != OLD.start_us AND start_us <= NEW.end_us
    ORDER BY start_us DESC LIMIT 1
), -1) >= NEW.start_us
BEGIN
    SELECT RAISE(ABORT, 'activity deletion barriers must be merged');
END;

CREATE TRIGGER IF NOT EXISTS measured_activity_no_update_overlap
BEFORE UPDATE ON measured_activity
WHEN EXISTS (
    SELECT 1 FROM measured_activity
    WHERE start_us != OLD.start_us AND start_us > NEW.start_us - 5000000
      AND start_us < NEW.end_us AND end_us > NEW.start_us
)
BEGIN
    SELECT RAISE(ABORT, 'activity interval overlap');
END;
