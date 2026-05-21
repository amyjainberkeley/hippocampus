//! Encrypted `SQLite` store.
//!
//! [`schema`] holds the DDL constants + the schema-version constant.
//! [`open`] (Phase 1, PRIORITY-REDIRECT P1) wires them against a real
//! `rusqlite::Connection` opened with bundled `SQLCipher`
//! (`bundled-sqlcipher-vendored-openssl`): `PRAGMA key` from a
//! [`crate::crypto::DbKey`] (never argv/env), wrong-key probe, WAL +
//! `foreign_keys`, the all-DDL init transaction, and the
//! arbitrary-path guard for the sqlite-vec extension. The sqlite-vec
//! dlopen itself ships with the bundled binary (see
//! [`open::SchemaPolicy`]); the master-key Keychain/Secure-Enclave
//! wrap is OS-specific and lives in `adapters/macos/` behind
//! [`crate::crypto::KeyWrap`] (cross-platform-seam invariant).
//!
//! Binding ADRs:
//! - `docs/decisions/0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md`
//!   — page-encryption engine, Keychain key custody, extension loading rules.
//! - `docs/decisions/0009-pin-sqlite-vec-dimension-384.md`
//!   — vector column is `float[384]`; vectors stored L2-normalized.
//! - `docs/decisions/0010-event-episode-retrieval-unit-cc-fusion.md`
//!   — `events.summary`, `events.entities`, `events.episode_id`; new
//!   `episodes` table.
//! - `docs/decisions/0012-zero-knowledge-spec-tightening.md`
//!   — `sync_log` is hash-chained (`prev_hash` + AEAD `tag`); deletion is
//!   crypto-shredding (per-segment keys + tombstones).
//!
//! Anything written under this module is **protected-set** per
//! `AGENT_PROTOCOL` §5. Modifying any DDL constant — especially the
//! `event_vectors` dimension or the `sync_log` hash-chain fields —
//! requires a fresh CSO review.

pub mod migrations;
pub mod open;
pub mod schema;
pub mod tombstone;

pub use migrations::MIGRATIONS;
pub use open::{
    init_schema, open, open_readonly, validate_vec_extension_path, verify_schema_version, Db,
    SchemaPolicy, StoreError,
};
pub use schema::{all_ddl, SCHEMA_VERSION};
pub use tombstone::{EventRow, TOMBSTONE_SOURCE_TYPE};
