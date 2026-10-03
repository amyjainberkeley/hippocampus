-- 0011: per-file resume points for the transcript importers (Claude Code,
-- Codex). One row per transcript path. `byte_offset` is the first byte not
-- yet consumed, `line_no` the number of complete lines consumed so far (so a
-- resumed run can still stamp 1-based source line numbers without re-reading
-- the prefix). `file_size` and `mtime_us` describe the file as it was when
-- the cursor was stored; a smaller file on the next run means it was
-- rewritten and is re-read from 0. Content-free: paths and integers only.
CREATE TABLE IF NOT EXISTS import_cursors (
  path          TEXT PRIMARY KEY,
  byte_offset   INTEGER NOT NULL,
  file_size     INTEGER NOT NULL,
  mtime_us      INTEGER NOT NULL,
  updated_at_us INTEGER NOT NULL,
  line_no       INTEGER NOT NULL DEFAULT 0
);
