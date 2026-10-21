//! What a change of the memory's key needs from the store
//! (storage-security review S4).
//!
//! A key that once sat in a file (`dev.key`) is replaced by a fresh one. The
//! agent's key change (`apps/agent/src/key_change.rs`) drives the steps; this
//! module owns the SQL they need:
//!
//! - re-encrypting the database in place under the new key
//!   ([`SqlCipherBrainStore::rekey_in_place`]);
//! - the screenshots the memory names, and moving each name to its re-sealed
//!   copy ([`SqlCipherBrainStore::retarget_keyframes`]), recorded in the
//!   `key_change_keyframes` table in the same transaction, so a crash resumes
//!   where it stopped and a failure can be undone
//!   ([`SqlCipherBrainStore::revert_keyframe_retargets`]);
//! - the screenshot index kept with the encrypted backup copy, under the old
//!   key, until the change is verified
//!   ([`SqlCipherBrainStore::record_blob_index`]).

use rusqlite::params;

use mci_core::crypto::DbKey;

use crate::sqlcipher_brain_store::{checkpoint_and_truncate_wal, is_keyframe_digest};
use crate::{SqlCipherBrainStore, StoreError};

/// One screenshot in the backup's index: its digest, its size, and whether
/// it opened with the old key when the backup was made (a screenshot that
/// was already unreadable is never counted as lost by the change).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlobIndexEntry {
    /// Lowercase SHA-256 hex naming `<blobs>/<digest>.bin`.
    pub digest: String,
    /// Bytes of the sealed file; 0 when it was missing.
    pub bytes: u64,
    /// Whether it opened with the key it was sealed under.
    pub opened: bool,
}

const CREATE_RETARGETS: &str = "CREATE TABLE IF NOT EXISTS key_change_keyframes (
    old TEXT PRIMARY KEY NOT NULL,
    new TEXT NOT NULL
)";

const CREATE_BLOB_INDEX: &str = "CREATE TABLE IF NOT EXISTS key_change_blob_index (
    digest TEXT PRIMARY KEY NOT NULL,
    bytes INTEGER NOT NULL,
    opened INTEGER NOT NULL
)";

fn backend(context: &str, error: impl std::fmt::Display) -> StoreError {
    StoreError::Backend(format!("{context}: {error}"))
}

fn table_exists(connection: &rusqlite::Connection, name: &str) -> Result<bool, StoreError> {
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
            params![name],
            |row| row.get(0),
        )
        .map_err(|e| backend("probe key-change table", e))
}

impl SqlCipherBrainStore {
    /// Re-encrypt every page under `new_key` with `PRAGMA rekey`, folding the
    /// write-ahead log in before and truncating it after, so no frame under
    /// the old key is left in `-wal`.
    ///
    /// The rekey writes every page again in one transaction, so it is
    /// atomic: the file opens with the old key until that transaction
    /// commits, and with the new key only after it, whether or not the log
    /// was folded in yet. `SQLCipher` reports no rekey failure (see
    /// [`mci_core::store::rekey`]): drop this store and prove the result by
    /// opening the file again with `new_key`.
    ///
    /// # Errors
    /// The statement was rejected.
    pub fn rekey_in_place(&self, new_key: &DbKey) -> Result<(), StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        // Best effort, both times: a reader on an old snapshot can keep the
        // log busy. Every page is rewritten after the old frames either way,
        // and the next truncation empties the log.
        let _ = checkpoint_and_truncate_wal(guard.conn());
        mci_core::store::rekey(&guard, new_key).map_err(|e| backend("rekey", e))?;
        let _ = checkpoint_and_truncate_wal(guard.conn());
        Ok(())
    }

    /// Fold the write-ahead log into the database and truncate it.
    ///
    /// # Errors
    /// The checkpoint failed or a reader kept the log busy.
    pub fn checkpoint_wal(&self) -> Result<(), StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        checkpoint_and_truncate_wal(guard.conn()).map_err(|e| backend("checkpoint", e))
    }

    /// `PRAGMA quick_check`: every page reads back and decrypts.
    ///
    /// # Errors
    /// [`StoreError::Backend`] naming the first problem.
    pub fn quick_check(&self) -> Result<(), StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let verdict: String = guard
            .conn()
            .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
            .map_err(|e| backend("quick_check", e))?;
        if verdict == "ok" {
            Ok(())
        } else {
            Err(StoreError::Backend(format!("quick_check: {verdict}")))
        }
    }

    /// Every distinct screenshot digest a moment names, in order. Values
    /// that are not a digest are skipped (they name no managed file).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on a read failure.
    pub fn referenced_keyframe_digests(&self) -> Result<Vec<String>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut statement = guard
            .conn()
            .prepare(
                "SELECT DISTINCT keyframe_blob FROM events
                 WHERE keyframe_blob IS NOT NULL ORDER BY keyframe_blob",
            )
            .map_err(|e| backend("prepare keyframe digests", e))?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| backend("query keyframe digests", e))?;
        let mut digests = Vec::new();
        for row in rows {
            let digest = row.map_err(|e| backend("read keyframe digest", e))?;
            if is_keyframe_digest(digest.trim()) {
                digests.push(digest.trim().to_owned());
            }
        }
        Ok(digests)
    }

    /// For each `(old, new)` pair, point every moment that names `old` at
    /// `new`, and record the pair, all in one transaction: either every name
    /// moved and is recorded, or none did. A pair already recorded is
    /// skipped, so a repeat after a crash changes nothing. Returns the moments
    /// moved.
    ///
    /// # Errors
    /// A value that is not a digest, or a write failure (nothing changes).
    pub fn retarget_keyframes(&self, pairs: &[(String, String)]) -> Result<u64, StoreError> {
        if pairs
            .iter()
            .any(|(old, new)| !is_keyframe_digest(old) || !is_keyframe_digest(new))
        {
            return Err(StoreError::InvalidInput(
                "keyframe retarget needs two digests".into(),
            ));
        }
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|e| backend("begin keyframe retarget", e))?;
        tx.execute_batch(CREATE_RETARGETS)
            .map_err(|e| backend("create keyframe retargets", e))?;
        let mut moved = 0_u64;
        for (old, new) in pairs {
            let recorded = tx
                .execute(
                    "INSERT OR IGNORE INTO key_change_keyframes(old, new) VALUES (?1, ?2)",
                    params![old, new],
                )
                .map_err(|e| backend("record keyframe retarget", e))?;
            if recorded == 0 {
                continue;
            }
            let changed = tx
                .execute(
                    "UPDATE events SET keyframe_blob = ?2 WHERE keyframe_blob = ?1",
                    params![old, new],
                )
                .map_err(|e| backend("retarget keyframe", e))?;
            moved = moved.saturating_add(changed as u64);
        }
        tx.commit()
            .map_err(|e| backend("commit keyframe retarget", e))?;
        Ok(moved)
    }

    /// The `(old, new)` pairs recorded by [`Self::retarget_keyframes`], in
    /// order of the old digest. Empty when none are.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on a read failure.
    pub fn keyframe_retargets(&self) -> Result<Vec<(String, String)>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "key_change_keyframes")? {
            return Ok(Vec::new());
        }
        let mut statement = guard
            .conn()
            .prepare("SELECT old, new FROM key_change_keyframes ORDER BY old")
            .map_err(|e| backend("prepare keyframe retargets", e))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| backend("query keyframe retargets", e))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read keyframe retargets", e))
    }

    /// Undo [`Self::retarget_keyframes`]: every moment still naming a
    /// re-sealed copy names its original again, and the record goes, in one
    /// transaction. A moment deleted in between stays deleted. Returns the
    /// moments moved back.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on a write failure (nothing changes).
    pub fn revert_keyframe_retargets(&self) -> Result<u64, StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "key_change_keyframes")? {
            return Ok(0);
        }
        let tx = guard
            .conn_mut()
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|e| backend("begin keyframe revert", e))?;
        let moved = tx
            .execute(
                "UPDATE events SET keyframe_blob =
                    (SELECT old FROM key_change_keyframes WHERE new = events.keyframe_blob)
                 WHERE keyframe_blob IN (SELECT new FROM key_change_keyframes)",
                [],
            )
            .map_err(|e| backend("revert keyframes", e))?;
        tx.execute_batch("DROP TABLE key_change_keyframes")
            .map_err(|e| backend("drop keyframe retargets", e))?;
        tx.commit()
            .map_err(|e| backend("commit keyframe revert", e))?;
        Ok(moved as u64)
    }

    /// Forget the record of moved screenshots once the change is committed.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on a write failure.
    pub fn clear_keyframe_retargets(&self) -> Result<(), StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute_batch("DROP TABLE IF EXISTS key_change_keyframes")
            .map_err(|e| backend("clear keyframe retargets", e))
    }

    /// Write the screenshot index into this store: meant for the backup copy
    /// made before a key change, which keeps the old key.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on a write failure (nothing changes).
    pub fn record_blob_index(&self, entries: &[BlobIndexEntry]) -> Result<(), StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|e| backend("begin blob index", e))?;
        tx.execute_batch(CREATE_BLOB_INDEX)
            .map_err(|e| backend("create blob index", e))?;
        tx.execute("DELETE FROM key_change_blob_index", [])
            .map_err(|e| backend("reset blob index", e))?;
        for entry in entries {
            tx.execute(
                "INSERT INTO key_change_blob_index(digest, bytes, opened) VALUES (?1, ?2, ?3)",
                params![
                    entry.digest,
                    i64::try_from(entry.bytes).unwrap_or(i64::MAX),
                    i64::from(entry.opened)
                ],
            )
            .map_err(|e| backend("write blob index", e))?;
        }
        tx.commit().map_err(|e| backend("commit blob index", e))
    }

    /// The screenshot index [`Self::record_blob_index`] wrote. Empty when
    /// there is none.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on a read failure.
    pub fn blob_index(&self) -> Result<Vec<BlobIndexEntry>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        if !table_exists(guard.conn(), "key_change_blob_index")? {
            return Ok(Vec::new());
        }
        let mut statement = guard
            .conn()
            .prepare("SELECT digest, bytes, opened FROM key_change_blob_index ORDER BY digest")
            .map_err(|e| backend("prepare blob index", e))?;
        let rows = statement
            .query_map([], |row| {
                Ok(BlobIndexEntry {
                    digest: row.get(0)?,
                    bytes: u64::try_from(row.get::<_, i64>(1)?).unwrap_or(0),
                    opened: row.get::<_, i64>(2)? != 0,
                })
            })
            .map_err(|e| backend("query blob index", e))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| backend("read blob index", e))
    }
}
