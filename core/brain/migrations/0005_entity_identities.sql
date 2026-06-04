-- mci-brain · migration 0005 · V2-P6 AliasResolver — canonical-identity
-- membership (`entity_identities`).
--
-- PROTECTED-SET per AGENT_PROTOCOL §5 — this table lands in the
-- SQLCipher-encrypted brain store and holds user-content-derived
-- attribution (it asserts "alias entity X is the same real-world
-- Person/Org/Location as the canonical identity Y"). It is a SCHEMA
-- change → the implementing PR (V2-P6) carries a FULLER CSO review
-- note (not just a driver mini-audit). No capture-scope change, no new
-- IPC, no new network surface — the zero-knowledge invariant (ADR-0001
-- / ADR-0012 / ADR-0031) is preserved by construction; this migration
-- is pure schema over already-extracted, post-cascade entities.
--
-- Motivation:
--
--   The V2-P6 AliasResolver clusters the alias entities the V2-P4
--   regex (`extractor_kind = "regex"`) and V2-P5 NER (`"ner"`) tiers
--   write — e.g. a person's display name (`person_name`), their email
--   (`email`) and their phone (`phone`) — into ONE canonical identity
--   so the dot-connect recall surface can walk a single Person/Org
--   across apps. `entities` already names each alias; this table names
--   the IDENTITY each alias belongs to.
--
--   The model is deliberately a grow-only **membership** table (one
--   row per (identity, member-entity)) rather than a second
--   `identities` table + join, or a mutable `entities.identity_id`
--   column. Rationale:
--     • grow-only / append-only → matches the migration-0004 CRDT
--       discipline (Phase 8 sync reads it as a grow-only set keyed on
--       PK; ADR-0023), and never fights the V2-P5 summary writer that
--       UPDATEs `entities`.
--     • carries per-edge provenance (`rule`, `confidence`) — which
--       high-confidence rule merged this member — which a column on
--       `entities` could not.
--     • the identity "exists" iff ≥1 membership row references its
--       `identity_id`; no separate identities table to keep in sync.
--
-- Sync-ready ULID discipline (mirrors migration 0004 / ADR-0023):
--
--   • `id` (the membership-row PK) is a 26-char Crockford-base32 ULID,
--     content-derived from `(identity_id, entity_id)` — see
--     `core/brain/src/graph.rs` `EntityIdentity::derive_id`.
--   • `identity_id` is itself a content-stable ULID derived from the
--     identity's `(identity_kind, normalized-anchor)` — see
--     `Identity::derive_id`. Two devices that independently resolve the
--     same cluster converge on the same `identity_id` without
--     coordination (the anchor is the cluster's stable canonical name,
--     not its membership, so adding an alias does not move the id).
--   • The resolver emits each member entity into AT MOST ONE identity
--     (precision-over-recall; a wrong merge is far worse than a missed
--     one), so `(entity_id)` is effectively a function to `identity_id`
--     — but no UNIQUE constraint is placed on `entity_id` so a future
--     multi-identity model (e.g. a shared mailbox) is not blocked.
--
-- Forward-only / NULL-safe:
--
--   • `CREATE TABLE`/`CREATE INDEX` carry `IF NOT EXISTS` — re-running
--     on an already-migrated DB is a no-op (mirrors 0001/0004).
--   • The FK on `entity_id` lands with `ON DELETE CASCADE` so the
--     retention purger (`core/brain/src/retention_purger.rs`) tears
--     down an identity's membership rows when its member entities are
--     deleted, without knowing about this table. `identity_id` carries
--     NO foreign key — there is no `identities` row to reference; the
--     identity is the set of rows sharing the value.
--   • Ships zero `ALTER TABLE`.

-- entity_identities — grow-only canonical-identity membership.
-- One row per (canonical identity, member alias-entity).
CREATE TABLE IF NOT EXISTS entity_identities (
    -- Content-stable ULID = derive(identity_id, entity_id).
    id                       TEXT PRIMARY KEY,
    -- The alias entity that belongs to this identity. FK → entities.id.
    entity_id                TEXT NOT NULL,
    -- Content-stable identity ULID (the cluster key). Derived from the
    -- identity's (identity_kind, normalized canonical_name). NOT a FK —
    -- the identity is the set of rows sharing this value.
    identity_id              TEXT NOT NULL,
    -- Identity-level kind: "person" | "org" | "location". Distinct from
    -- the entity-level kind ("person_name" / "organization" / ...).
    identity_kind            TEXT NOT NULL,
    -- Deterministic display name for the identity (Title-Cased from the
    -- normalized anchor; stable regardless of which surface forms are
    -- present, so denormalizing it onto every membership row cannot
    -- drift between rows of the same identity).
    identity_canonical_name  TEXT NOT NULL,
    -- Which high-confidence rule attached this member:
    -- "anchor" (the name/org/loc that seeds the identity),
    -- "exact_name" (another entity with the identical normalized name),
    -- "name_variant" (an unambiguous single-token first/last name),
    -- "email_name" (email localpart token-matches the name),
    -- "phone_cooccur" (phone co-occurs with exactly this identity),
    -- "domain_org" (a URL host label equals the org name).
    rule                     TEXT NOT NULL,
    -- Per-member merge confidence in [0.0, 1.0].
    confidence               REAL NOT NULL DEFAULT 1.0,
    -- First-write wall-clock, microseconds since UNIX epoch. Preserved
    -- on PK conflict (grow-only INSERT OR IGNORE) so a re-run is a true
    -- row-level no-op.
    ts_us                    INTEGER NOT NULL,
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS entity_identities_entity
    ON entity_identities(entity_id);
CREATE INDEX IF NOT EXISTS entity_identities_identity
    ON entity_identities(identity_id);
CREATE INDEX IF NOT EXISTS entity_identities_kind
    ON entity_identities(identity_kind);
CREATE INDEX IF NOT EXISTS entity_identities_ts
    ON entity_identities(ts_us);

-- Stamp the brain schema version.
INSERT OR REPLACE INTO meta (key, value)
    VALUES ('brain_schema_version', '5');
