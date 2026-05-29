-- mci-brain · migration 0004 · V2-P3 graph foundation
-- (entities + entity_mentions + episode_edges).
--
-- PROTECTED-SET per AGENT_PROTOCOL §5 — every new table lands in the
-- SQLCipher-encrypted brain store and holds user-content-derived
-- attribution. CSO sign-off block on the implementing PR (V2-P3)
-- carries the audit. No capture-scope change, no new IPC, no new
-- network surface (zero-knowledge invariant per ADR-0001 / ADR-0012 /
-- ADR-0031 preserved by construction — this migration is pure
-- schema).
--
-- Motivation:
--
--   §7.2 of `docs/research/brain-architecture-v2-vision-2026-05-29.md`
--   lights up the typed entity / relation / cross-app-edge data
--   model the v2 vision rests on. V2-P3 is "pure schema + writer
--   trait." No extractor, no consolidator, no recall surface — those
--   ride later PRs (V2-P4 / V2-P5 / V2-P6 / V2-P12).
--
-- Sync-ready ULID discipline (per §7.6 ratified plan + ADR-0023
-- multi-device sync model):
--
--   • Every PK on the three new tables is a **26-char Crockford
--     base32 ULID** held in a TEXT column.
--   • ULID bytes are **content-stable**: derived from a canonical
--     SHA-256 over the row's natural-key bytes (see
--     `core/brain/src/graph.rs` module doc — the derivation rules
--     are LOAD-BEARING for two-device convergence in Phase 8 sync).
--     Two devices that independently extract the same entity from
--     the same content converge on the same ULID without coordination.
--   • Lex-sortable: the underlying base32 alphabet preserves byte
--     order, so `ORDER BY id` is meaningful for stable iteration
--     even when the value is content-derived (not time-derived).
--   • Phase 8 sync (out of V2-P3 scope) reads these tables as a
--     CRDT-grow-only set keyed on PK; conflicting writers converge
--     on the same row by construction.
--
-- Forward-only / NULL-safe:
--
--   • Every CREATE carries `IF NOT EXISTS` so re-running on an
--     already-migrated DB is a no-op (mirrors migration 0001
--     discipline).
--   • Foreign keys land with `ON DELETE CASCADE` so the retention
--     purger (`core/brain/src/retention_purger.rs`) does not need
--     to know about the graph tables — deleting an event or
--     episode tears down its mentions / edges in one pass.
--   • The events_fts external-content virtual table is NOT touched.
--     Entity content is searched via the new `summary` /
--     `canonical_name` columns + their indexes; FTS5 over entities
--     is a follow-up (V2-P4 lights up regex-derived entities; FTS5
--     over canonical names is V2-P6 alias-resolver territory).
--
-- vec-mirror discipline (mirrors migration 0001 `vec_events`
-- deferral):
--
--   `entities.summary_embedding` is stored as a regular BLOB column
--   (1536 bytes = 384 × 4-byte f32, ADR-0009 pin), brute-forced
--   by callers exactly as `event_vectors.embedding` is today. The
--   `vec_entity_summaries` vec0 virtual table lands together with
--   the bundled sqlite-vec runtime extension in a follow-on cycle
--   (the same cycle that wires `vec_events`). The `meta` row
--   `vec_entity_summaries_mirror = 'deferred'` records the upgrade
--   path so it is unambiguous. ADR-0011's scaling ladder is unaffected
--   — Phase 3 corpora are well inside the brute-force regime.

-- entities — typed nodes (Person / Topic / Thread / URL / File /
-- Project / …). `kind` and `canonical_name` together are the
-- natural key for ULID derivation.
CREATE TABLE IF NOT EXISTS entities (
    id                  TEXT PRIMARY KEY,
    kind                TEXT NOT NULL,
    canonical_name      TEXT NOT NULL,
    summary             TEXT,
    summary_embedding   BLOB,
    content_hash        TEXT NOT NULL,
    created_ts_us       INTEGER NOT NULL,
    updated_ts_us       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS entities_kind_name
    ON entities(kind, canonical_name);
CREATE INDEX IF NOT EXISTS entities_canonical_name
    ON entities(canonical_name);
CREATE INDEX IF NOT EXISTS entities_content_hash
    ON entities(content_hash);
CREATE INDEX IF NOT EXISTS entities_updated_ts
    ON entities(updated_ts_us);

-- entity_mentions — one row per (entity, event) appearance. Spans
-- the join from a stored event to the canonical entity it mentions.
-- `extractor_kind` is the provenance: "regex" / "qwen" / "user"
-- (V2-P4 fills "regex"; V2-P5 fills "qwen"; the user-tagged path
-- lands with the recall UI in V2-P12).
CREATE TABLE IF NOT EXISTS entity_mentions (
    id              TEXT PRIMARY KEY,
    entity_id       TEXT NOT NULL,
    event_id        INTEGER NOT NULL,
    mention_text    TEXT,
    confidence      REAL NOT NULL DEFAULT 1.0,
    extractor_kind  TEXT NOT NULL,
    ts_us           INTEGER NOT NULL,
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE,
    FOREIGN KEY (event_id)  REFERENCES events(id)   ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS entity_mentions_entity
    ON entity_mentions(entity_id);
CREATE INDEX IF NOT EXISTS entity_mentions_event
    ON entity_mentions(event_id);
CREATE INDEX IF NOT EXISTS entity_mentions_ts
    ON entity_mentions(ts_us);
CREATE INDEX IF NOT EXISTS entity_mentions_extractor
    ON entity_mentions(extractor_kind);

-- episode_edges — typed cross-app links between episodes. The
-- `evidence_entity_ids` column is a JSON-encoded array of entity
-- ULIDs (no FK, since SQLite can't FK into a JSON column; the
-- referenced entities live in `entities.id`). `edge_kind` values:
-- "co_active" (overlapping in time), "referenced" (one episode
-- references the other's entity), "responded_to" (one episode is a
-- reply to the other) — see §5.3 of the v2 vision memo.
CREATE TABLE IF NOT EXISTS episode_edges (
    id                   TEXT PRIMARY KEY,
    src_episode_id       INTEGER NOT NULL,
    dst_episode_id       INTEGER NOT NULL,
    edge_kind            TEXT NOT NULL,
    evidence_entity_ids  TEXT,
    ts_us                INTEGER NOT NULL,
    FOREIGN KEY (src_episode_id) REFERENCES episodes(id) ON DELETE CASCADE,
    FOREIGN KEY (dst_episode_id) REFERENCES episodes(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS episode_edges_src
    ON episode_edges(src_episode_id);
CREATE INDEX IF NOT EXISTS episode_edges_dst
    ON episode_edges(dst_episode_id);
CREATE INDEX IF NOT EXISTS episode_edges_kind
    ON episode_edges(edge_kind);
CREATE INDEX IF NOT EXISTS episode_edges_ts
    ON episode_edges(ts_us);

-- Stamp the brain schema version. Lives under the existing
-- `brain_schema_version` meta key. `vec_entity_summaries_mirror`
-- records the vec0 mirror deferral (mirrors `vec_events_mirror`
-- in migration 0001).
INSERT OR REPLACE INTO meta (key, value)
    VALUES ('brain_schema_version', '4');
INSERT OR REPLACE INTO meta (key, value)
    VALUES ('vec_entity_summaries_mirror', 'deferred');
