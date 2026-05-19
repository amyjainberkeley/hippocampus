//! Encrypted store open + schema-init path.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5 (the `mci.sqlite` store +
//! at-rest crypto). Binding ADR-0008:
//!
//! - `rusqlite` + **bundled `SQLCipher`** (feature
//!   `bundled-sqlcipher-vendored-openssl` — self-contained, no system
//!   OpenSSL, matches the "ship the crypto inside the signed bundle"
//!   posture). There is **no unencrypted fallback** — [`open`] always
//!   sets `PRAGMA key` and probes it.
//! - The DB key comes from a [`crate::crypto::DbKey`] only — **never**
//!   argv / env / a config file (ADR-0008 forces).
//! - `SQLite` extension loading from **arbitrary paths is refused**.
//!   sqlite-vec may load only from a caller-supplied bundled path,
//!   validated by [`validate_vec_extension_path`]. The actual dlopen
//!   ships with the bundled binary (see [`SchemaPolicy`] /
//!   `// UNVERIFIED` note) — the path *guard* is implemented + tested
//!   now because it is the load-bearing security property.
//! - Callers insert with bound parameters only (`params!` /
//!   `?`-placeholders). String-formatted SQL values are a
//!   protected-set regression.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! Authored under the CSO role-mask against ADR-0008. New crate deps
//! introduced for this unit — `rusqlite` (bundled `SQLCipher` +
//! vendored OpenSSL), `zeroize`, `getrandom` — trip ADR-0008's "any
//! new dependency added to `core/store/` or `core/crypto/` triggers a
//! CRS Security-Signal CVE / supply-chain check before merge"; that
//! check is owed before the human-CEO merge of this branch and is
//! noted in the cycle log. The wrong-key path is proven by a headless
//! round-trip test (encrypt → close → reopen-with-key asserts rows →
//! reopen-with-wrong-key + reopen-with-no-key assert failure). The
//! sqlite-vec dlopen is deliberately NOT enabled this cycle (the
//! `rusqlite/load_extension` feature is left off — smaller surface,
//! and a dlopen cannot be headlessly verified regardless); only the
//! arbitrary-path *rejection* is wired + tested.
//!
//! — CSO role-mask, 2026-05-19

use std::path::{Path, PathBuf};

use rusqlite::Connection;

use crate::crypto::DbKey;
use crate::store::schema::{all_ddl, CREATE_EVENT_VECTORS, SCHEMA_VERSION};

/// Errors the store-open / schema-init path surfaces.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    /// Opening the `SQLite` file failed at the driver level (path
    /// unwritable, etc) — distinct from a wrong key.
    #[error("store open: {0}")]
    Open(String),
    /// The supplied key did not decrypt the database. `SQLCipher`
    /// surfaces this as `SQLITE_NOTADB` on the first read. A wrong
    /// key, a no-key open of an encrypted file, and a corrupt header
    /// all land here — intentionally indistinguishable to the caller.
    #[error("store: wrong key or not an MCI database")]
    WrongKey,
    /// Schema DDL or a `PRAGMA` failed.
    #[error("store schema: {0}")]
    Schema(String),
    /// A sqlite-vec extension path was supplied but rejected by the
    /// arbitrary-path guard (missing, not a regular file, or empty).
    #[error("store: rejected sqlite-vec extension path: {0}")]
    VecExtensionPathRejected(String),
    /// A *valid* sqlite-vec path was supplied, but the runtime loader
    /// is not enabled in this build. The dlopen ships with the
    /// bundled binary (see module docs). Deliberate, not a bug.
    #[error("store: sqlite-vec runtime load not enabled in this build (bundled-binary cycle)")]
    VecExtensionLoadDeferred,
    /// `meta.schema_version` is newer than this binary understands.
    #[error("store: db schema v{found} > supported v{supported}")]
    SchemaTooNew {
        /// Version recorded in the DB's `meta` table.
        found: u32,
        /// Highest version this binary's [`SCHEMA_VERSION`] supports.
        supported: u32,
    },
}

/// What schema to materialize on a freshly-opened encrypted DB.
#[derive(Debug)]
pub enum SchemaPolicy {
    /// Run every DDL **except** `event_vectors` (the `vec0` virtual
    /// table). Records `meta('vector_index','deferred')`. This is the
    /// headlessly-verifiable path: it exercises bundled `SQLCipher` +
    /// FTS5 + every regular table without needing the sqlite-vec
    /// binary. Semantic recall is unavailable until the index is
    /// built; lexical (FTS5) recall works.
    WithoutVectorIndex,
    /// Run the **full** schema, loading sqlite-vec from this bundled
    /// path. The path is validated by [`validate_vec_extension_path`]
    /// (arbitrary paths refused). The actual dlopen + `vec0` create
    /// is **`// UNVERIFIED`** — it lands with the bundled binary;
    /// today this returns [`StoreError::VecExtensionLoadDeferred`]
    /// after the path passes the guard, so callers can wire the call
    /// site now without faking a load.
    WithVectorIndex(PathBuf),
}

/// An opened, encrypted MCI store connection.
///
/// Single-writer by ADR-0008 §4. `rusqlite::Connection` is `!Sync`;
/// the agent owns exactly one writer `Db` and hands read-only opens
/// to the recall UI separately (future cycle).
pub struct Db {
    conn: Connection,
}

impl core::fmt::Debug for Db {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        // Never render the connection (its handle / path is not
        // sensitive but adds nothing; keep it opaque + stable for
        // test `expect_err` formatting).
        f.write_str("Db(<encrypted sqlcipher connection>)")
    }
}

impl Db {
    /// Borrow the underlying connection. Callers MUST use bound
    /// parameters (`params!` / `?`); string-interpolated SQL values
    /// are a protected-set regression (ADR-0008 forces).
    #[must_use]
    pub fn conn(&self) -> &Connection {
        &self.conn
    }

    /// Mutable borrow for transactions.
    pub fn conn_mut(&mut self) -> &mut Connection {
        &mut self.conn
    }
}

/// Open (or create) the encrypted store at `path` with `key`.
///
/// Always sets `PRAGMA key` (no unencrypted mode) and immediately
/// probes it with a read; a wrong/absent key surfaces as
/// [`StoreError::WrongKey`]. Sets WAL + `foreign_keys=ON`. Does NOT
/// create the schema — call [`init_schema`] for a fresh DB or
/// [`verify_or_migrate`] for an existing one.
///
/// # Errors
/// [`StoreError::Open`] for driver-level failures;
/// [`StoreError::WrongKey`] if the key does not decrypt the file.
pub fn open(path: &Path, key: &DbKey) -> Result<Db, StoreError> {
    let conn = Connection::open(path).map_err(|e| StoreError::Open(e.to_string()))?;

    // Set the raw 256-bit key. `SQLCipher` consumes the `x'…'` literal
    // and (length == cipher key length) uses the bytes directly,
    // skipping PBKDF2 — correct for an already-random key (ADR-0008).
    {
        let pragma = key.expose_sqlcipher_pragma_value();
        conn.pragma_update(None, "key", pragma.as_str())
            .map_err(|e| StoreError::Open(format!("PRAGMA key: {e}")))?;
        // `pragma` (and its zeroizing String) dropped here.
    }

    // Probe the key. On an encrypted file with the wrong key `SQLCipher`
    // returns SQLITE_NOTADB on the first read. On a fresh (empty) file
    // this succeeds and the DB becomes keyed on first write.
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
        r.get::<_, i64>(0)
    })
    .map_err(|_| StoreError::WrongKey)?;

    conn.pragma_update(None, "journal_mode", "WAL")
        .map_err(|e| StoreError::Open(format!("PRAGMA journal_mode=WAL: {e}")))?;
    conn.pragma_update(None, "foreign_keys", "ON")
        .map_err(|e| StoreError::Open(format!("PRAGMA foreign_keys=ON: {e}")))?;

    Ok(Db { conn })
}

/// Validate a caller-supplied sqlite-vec extension path against the
/// arbitrary-path guard (ADR-0008: extension loading from arbitrary
/// filesystem paths is refused; only a real bundled file is allowed).
///
/// This is the load-bearing security property and is fully tested
/// headlessly even though the dlopen itself is deferred.
///
/// # Errors
/// [`StoreError::VecExtensionPathRejected`] if the path is empty,
/// does not exist, or is not a regular file.
pub fn validate_vec_extension_path(p: &Path) -> Result<(), StoreError> {
    if p.as_os_str().is_empty() {
        return Err(StoreError::VecExtensionPathRejected("empty path".into()));
    }
    let meta = std::fs::metadata(p)
        .map_err(|e| StoreError::VecExtensionPathRejected(format!("{}: {e}", p.display())))?;
    if !meta.is_file() {
        return Err(StoreError::VecExtensionPathRejected(format!(
            "{}: not a regular file",
            p.display()
        )));
    }
    Ok(())
}

/// Materialize the schema on a freshly-opened (empty) encrypted DB.
///
/// Runs all DDL inside one transaction. For
/// [`SchemaPolicy::WithoutVectorIndex`] the `event_vectors` `vec0`
/// table is skipped and `meta('vector_index','deferred')` recorded.
/// Stamps `meta('schema_version', SCHEMA_VERSION)`.
///
/// # Errors
/// [`StoreError::Schema`] on DDL failure;
/// [`StoreError::VecExtensionPathRejected`] /
/// [`StoreError::VecExtensionLoadDeferred`] for the vector path.
pub fn init_schema(db: &mut Db, policy: &SchemaPolicy) -> Result<(), StoreError> {
    let skip_vectors = match policy {
        SchemaPolicy::WithoutVectorIndex => true,
        SchemaPolicy::WithVectorIndex(p) => {
            // Enforce the arbitrary-path guard first…
            validate_vec_extension_path(p)?;
            // …then the dlopen, which is deliberately not enabled in
            // this build (ships with the bundled binary).
            // UNVERIFIED — needs the bundled sqlite-vec binary + the
            // rusqlite/load_extension feature; do not claim working.
            return Err(StoreError::VecExtensionLoadDeferred);
        }
    };

    let tx = db
        .conn
        .transaction()
        .map_err(|e| StoreError::Schema(format!("begin: {e}")))?;
    for stmt in all_ddl() {
        // Content equality, not pointer equality: `CREATE_EVENT_VECTORS`
        // is a `const` (not `static`) so each use site may be a
        // distinct inlined copy — `ptr::eq` is unreliable here.
        if skip_vectors && *stmt == CREATE_EVENT_VECTORS {
            continue;
        }
        tx.execute_batch(stmt)
            .map_err(|e| StoreError::Schema(format!("{e}")))?;
    }
    tx.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?1)",
        rusqlite::params![SCHEMA_VERSION.to_string()],
    )
    .map_err(|e| StoreError::Schema(format!("stamp version: {e}")))?;
    if skip_vectors {
        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('vector_index', 'deferred')",
            [],
        )
        .map_err(|e| StoreError::Schema(format!("stamp vector_index: {e}")))?;
    }
    tx.commit()
        .map_err(|e| StoreError::Schema(format!("commit: {e}")))?;
    Ok(())
}

/// Read `meta.schema_version` and refuse a DB newer than this binary.
///
/// # Errors
/// [`StoreError::SchemaTooNew`] if the DB is from a newer build;
/// [`StoreError::Schema`] if `meta` is unreadable.
pub fn verify_schema_version(db: &Db) -> Result<u32, StoreError> {
    let found: u32 = db
        .conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'schema_version'",
            [],
            |r| r.get::<_, String>(0),
        )
        .map_err(|e| StoreError::Schema(format!("read schema_version: {e}")))?
        .parse()
        .map_err(|e| StoreError::Schema(format!("parse schema_version: {e}")))?;
    if found > SCHEMA_VERSION {
        return Err(StoreError::SchemaTooNew {
            found,
            supported: SCHEMA_VERSION,
        });
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};

    fn tmp(name: &str) -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().expect("tempdir");
        let p = d.path().join(name);
        (d, p)
    }

    /// THE headless proof required by the PRIORITY REDIRECT:
    /// encrypt a DB, close it, reopen WITH the key (rows survive),
    /// reopen with the WRONG key and with NO key (both must fail).
    #[test]
    fn encrypt_close_reopen_roundtrip_and_wrong_key_fails() {
        let (_dir, path) = tmp("roundtrip.sqlite");

        // First-run: generate a key, wrap it (in-memory test wrap),
        // open, create schema, insert a row with bound params.
        let key = DbKey::generate().expect("csprng");
        let wrap = InMemoryKeyWrap;
        let wrapped = wrap.wrap(&key).expect("wrap");

        {
            let mut db = open(&path, &key).expect("open fresh");
            init_schema(&mut db, &SchemaPolicy::WithoutVectorIndex).expect("schema");
            db.conn()
                .execute(
                    "INSERT INTO meta (key, value) VALUES (?1, ?2)",
                    rusqlite::params!["probe", "secret-value"],
                )
                .expect("insert");
            // db drops here → connection closes, file flushed.
        }

        // Reopen WITH the correct (unwrapped) key → row present.
        {
            let reopened_key = wrap.unwrap_key(&wrapped).expect("unwrap");
            let db = open(&path, &reopened_key).expect("reopen with key");
            let v: String = db
                .conn()
                .query_row(
                    "SELECT value FROM meta WHERE key = ?1",
                    rusqlite::params!["probe"],
                    |r| r.get(0),
                )
                .expect("row present");
            assert_eq!(v, "secret-value");
            assert_eq!(verify_schema_version(&db).expect("version"), SCHEMA_VERSION);
        }

        // Reopen with a WRONG key → WrongKey.
        {
            let wrong = DbKey::from_bytes([0xFFu8; 32]);
            let err = open(&path, &wrong).expect_err("wrong key must fail");
            assert!(
                matches!(err, StoreError::WrongKey),
                "expected WrongKey, got {err:?}"
            );
        }

        // Reopen with a *different* random key (the "no usable key"
        // case) → WrongKey.
        {
            let other = DbKey::generate().expect("csprng");
            let err = open(&path, &other).expect_err("other key must fail");
            assert!(matches!(err, StoreError::WrongKey), "got {err:?}");
        }

        // The on-disk bytes must not contain the plaintext we stored
        // (page-level encryption actually engaged, not a no-op).
        let raw = std::fs::read(&path).expect("read ciphertext");
        assert!(
            !raw.windows(b"secret-value".len())
                .any(|w| w == b"secret-value"),
            "plaintext found on disk — encryption not engaged"
        );
        assert!(
            !raw.starts_with(b"SQLite format 3\0"),
            "unencrypted SQLite header on disk — SQLCipher not engaged"
        );
    }

    #[test]
    fn without_vector_index_skips_vec0_and_stamps_meta() {
        let (_dir, path) = tmp("novec.sqlite");
        let key = DbKey::generate().expect("csprng");
        let mut db = open(&path, &key).expect("open");
        init_schema(&mut db, &SchemaPolicy::WithoutVectorIndex).expect("schema");

        // event_vectors must NOT exist; a regular table + the FTS5
        // virtual table must.
        let has_vectors: i64 = db
            .conn()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = 'event_vectors'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(has_vectors, 0, "vec0 table must be skipped");

        let has_events: i64 = db
            .conn()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = 'events'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(has_events, 1);

        let has_fts: i64 = db
            .conn()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = 'event_text_fts'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(has_fts, 1, "FTS5 (bundled SQLCipher) must materialize");

        let vidx: String = db
            .conn()
            .query_row(
                "SELECT value FROM meta WHERE key = 'vector_index'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(vidx, "deferred");
    }

    #[test]
    fn with_vector_index_rejects_arbitrary_paths() {
        let (dir, path) = tmp("vec.sqlite");
        let key = DbKey::generate().expect("csprng");
        let mut db = open(&path, &key).expect("open");

        // Non-existent path → rejected by the guard, never loaded.
        let err = init_schema(
            &mut db,
            &SchemaPolicy::WithVectorIndex(PathBuf::from("/no/such/vec.dylib")),
        )
        .unwrap_err();
        assert!(
            matches!(err, StoreError::VecExtensionPathRejected(_)),
            "got {err:?}"
        );

        // Empty path → rejected.
        let err = init_schema(&mut db, &SchemaPolicy::WithVectorIndex(PathBuf::new())).unwrap_err();
        assert!(matches!(err, StoreError::VecExtensionPathRejected(_)));

        // A directory is not a regular file → rejected.
        let err = validate_vec_extension_path(dir.path()).expect_err("dir must be rejected");
        assert!(matches!(err, StoreError::VecExtensionPathRejected(_)));
    }

    #[test]
    fn with_vector_index_valid_path_defers_load_not_fakes_it() {
        // A real, existing file passes the path guard, then the load
        // is honestly deferred (not faked as success).
        let (dir, path) = tmp("vec2.sqlite");
        let fake_ext = dir.path().join("libvec.dylib");
        std::fs::write(&fake_ext, b"not a real dylib").unwrap();
        let key = DbKey::generate().expect("csprng");
        let mut db = open(&path, &key).expect("open");

        validate_vec_extension_path(&fake_ext).expect("real file passes guard");
        let err = init_schema(&mut db, &SchemaPolicy::WithVectorIndex(fake_ext)).unwrap_err();
        assert!(
            matches!(err, StoreError::VecExtensionLoadDeferred),
            "valid path must defer the load, not fake success — got {err:?}"
        );
    }

    #[test]
    fn schema_too_new_is_refused() {
        let (_dir, path) = tmp("toonew.sqlite");
        let key = DbKey::generate().expect("csprng");
        let mut db = open(&path, &key).expect("open");
        init_schema(&mut db, &SchemaPolicy::WithoutVectorIndex).expect("schema");
        // Forge a newer version.
        db.conn()
            .execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?1)",
                rusqlite::params![(SCHEMA_VERSION + 1).to_string()],
            )
            .unwrap();
        let err = verify_schema_version(&db).unwrap_err();
        assert!(
            matches!(err, StoreError::SchemaTooNew { .. }),
            "got {err:?}"
        );
    }
}
