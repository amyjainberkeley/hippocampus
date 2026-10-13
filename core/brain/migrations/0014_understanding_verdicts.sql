-- 0014: what the user confirmed.
--
-- One fresh table, IF NOT EXISTS, so the apply is idempotent on re-open (same
-- discipline as 0013). Nothing here alters an existing table.
--
-- A row means the user said the proposition is right. It is what lets a
-- confirmation outlive a rebuild of the user model, and what stops a merge
-- from rewriting the wording the user agreed to. Saying it is wrong removes
-- the row (the proposition itself is kept as 'rejected'), and the row goes
-- with its proposition, so it also goes when an event the proposition rests
-- on is deleted.
CREATE TABLE IF NOT EXISTS proposition_verdicts (
    proposition_id INTEGER PRIMARY KEY REFERENCES propositions(id) ON DELETE CASCADE,
    verdict        TEXT CHECK (verdict IN ('confirmed')),
    ts_us          INTEGER
) WITHOUT ROWID;
