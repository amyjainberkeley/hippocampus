-- mci-brain · migration 0002 · DOWN — daily-brief storage.
--
-- Reverses `0002_briefs.sql`. Used only by the
-- `briefs_schema_round_trips_up_down_up` regression test to prove the
-- migration is reversible. Production never runs this — the encrypted
-- store is forward-only and the user deletes their brain by wiping the
-- file. The reversibility test is the gate that keeps the schema honest.

DROP INDEX IF EXISTS briefs_generated;
DROP INDEX IF EXISTS briefs_date_uniq;
DROP TABLE  IF EXISTS briefs;

DELETE FROM meta WHERE key = 'briefs_schema_version';
