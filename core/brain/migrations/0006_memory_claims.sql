-- mci-brain migration 0006: governed source-backed memory.
--
-- Evidence, claims, and status transitions are append-only. A correction
-- inserts a new claim and a supersession transition; a retraction inserts a
-- transition. Canonical event text is never rewritten by this schema.

CREATE TABLE IF NOT EXISTS memory_deltas (
    id                  TEXT NOT NULL PRIMARY KEY,
    source_event_id     INTEGER NOT NULL,
    asserted_at_us      INTEGER NOT NULL,
    projector_version   TEXT NOT NULL,
    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS memory_evidence (
    id                  TEXT NOT NULL PRIMARY KEY,
    event_id            INTEGER NOT NULL,
    source_kind         TEXT NOT NULL,
    source_locator      TEXT NOT NULL,
    source_scope        TEXT NOT NULL,
    observed_at_us      INTEGER NOT NULL,
    content_hash        TEXT NOT NULL,
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS memory_evidence_event
    ON memory_evidence(event_id, id);

CREATE TABLE IF NOT EXISTS memory_claims (
    id                  TEXT NOT NULL PRIMARY KEY,
    source_event_id     INTEGER NOT NULL,
    subject             TEXT NOT NULL,
    predicate           TEXT NOT NULL,
    object              TEXT NOT NULL,
    scope               TEXT NOT NULL,
    attribution         TEXT,
    confidence          REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
    asserted_at_us      INTEGER NOT NULL,
    valid_from_us       INTEGER NOT NULL,
    valid_to_us         INTEGER,
    projector_version   TEXT NOT NULL,
    initial_status      TEXT NOT NULL CHECK (initial_status IN ('proposed', 'active')),
    supersedes_claim_id TEXT,
    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT,
    FOREIGN KEY (supersedes_claim_id) REFERENCES memory_claims(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS memory_claims_fact
    ON memory_claims(subject, predicate, scope, asserted_at_us, id);
CREATE INDEX IF NOT EXISTS memory_claims_validity
    ON memory_claims(valid_from_us, valid_to_us, asserted_at_us, id);
CREATE INDEX IF NOT EXISTS memory_claims_supersedes
    ON memory_claims(supersedes_claim_id, asserted_at_us, id);

CREATE TABLE IF NOT EXISTS memory_claim_evidence (
    claim_id            TEXT NOT NULL,
    evidence_id         TEXT NOT NULL,
    PRIMARY KEY (claim_id, evidence_id),
    FOREIGN KEY (claim_id) REFERENCES memory_claims(id) ON DELETE RESTRICT,
    FOREIGN KEY (evidence_id) REFERENCES memory_evidence(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS memory_claim_evidence_evidence
    ON memory_claim_evidence(evidence_id, claim_id);

CREATE TABLE IF NOT EXISTS memory_claim_transitions (
    id                  TEXT NOT NULL PRIMARY KEY,
    claim_id            TEXT NOT NULL,
    status              TEXT NOT NULL CHECK (status IN ('superseded', 'retracted', 'contradicted')),
    asserted_at_us      INTEGER NOT NULL,
    effective_at_us     INTEGER NOT NULL,
    reason              TEXT NOT NULL,
    source_event_id     INTEGER NOT NULL,
    projector_version   TEXT NOT NULL,
    FOREIGN KEY (claim_id) REFERENCES memory_claims(id) ON DELETE RESTRICT,
    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS memory_claim_transitions_latest
    ON memory_claim_transitions(claim_id, asserted_at_us, effective_at_us, id);

CREATE TABLE IF NOT EXISTS memory_event_retractions (
    id                  TEXT NOT NULL PRIMARY KEY,
    target_event_id     INTEGER NOT NULL,
    retraction_event_id INTEGER NOT NULL,
    asserted_at_us      INTEGER NOT NULL,
    effective_at_us     INTEGER NOT NULL,
    reason              TEXT NOT NULL,
    projector_version   TEXT NOT NULL,
    FOREIGN KEY (target_event_id) REFERENCES events(id) ON DELETE RESTRICT,
    FOREIGN KEY (retraction_event_id) REFERENCES events(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS memory_event_retractions_target
    ON memory_event_retractions(target_event_id, asserted_at_us, effective_at_us, id);
