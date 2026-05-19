//! Encrypted `SQLite` store skeleton.
//!
//! Phase 0 skeleton only. Just the schema DDL and the schema-version
//! constant; **no `rusqlite` / `SQLCipher` dependency yet**. The Phase-1
//! store-init code (in a follow-up PR) will execute these constants against
//! a real `rusqlite::Connection` opened with `SQLCipher`'s bundled feature,
//! `sqlite-vec` loaded as a runtime extension from the bundled binary path,
//! the master DB key unwrapped from the Keychain item described in ADR-0008.
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
pub mod schema;

pub use migrations::MIGRATIONS;
pub use schema::{all_ddl, SCHEMA_VERSION};
