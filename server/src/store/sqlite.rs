//! SQLite-backed workspace store for production.
//!
//! All content columns (`envelope`, `vouch_token`, `ephemeral_pubkey`,
//! `wrapped_workspace_key`) are BLOB — opaque ciphertext the server never
//! interprets. ADR-0019 §4 invariant: NO BACKDOOR KEY, no decrypt surface.
//!
//! Uses `rusqlite` (already on workspace lockfile via mci-brain) with
//! `tokio::task::spawn_blocking` for async compatibility.

use std::path::Path;
use std::sync::Arc;

use rusqlite::{params, Connection};
use tokio::sync::Mutex;
use uuid::Uuid;

use super::{StoreError, WorkspaceStore};
use crate::model::{
    BriefEnvelope, CreateBriefRequest, EnrollmentRequest, EnrollmentState, MemberId, MemberKeyWrap,
    VouchToken, WorkspaceId,
};

/// Production workspace store backed by a single `SQLite` file.
///
/// Thread-safety: wraps `rusqlite::Connection` in `Arc<Mutex<_>>` so
/// `spawn_blocking` closures can borrow it. Single-writer is fine for
/// the workspace server's expected write rate.
pub struct SqliteWorkspaceStore {
    conn: Arc<Mutex<Connection>>,
}

impl SqliteWorkspaceStore {
    /// Open (or create) the database at `path` and run migrations.
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        let conn = Connection::open(path).map_err(|e| StoreError::Database(e.to_string()))?;
        Self::apply_migrations(&conn)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    fn apply_migrations(conn: &Connection) -> Result<(), StoreError> {
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS briefs (
                envelope_id  BLOB NOT NULL PRIMARY KEY,
                workspace_id BLOB NOT NULL,
                uploaded_by  BLOB NOT NULL,
                uploaded_at_us INTEGER NOT NULL,
                ts_brief_us  INTEGER NOT NULL,
                ciphertext   BLOB NOT NULL,
                nonce        BLOB NOT NULL,
                aad          BLOB NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_briefs_workspace_ts
                ON briefs (workspace_id, uploaded_at_us);

            CREATE TABLE IF NOT EXISTS brief_key_wraps (
                envelope_id  BLOB NOT NULL,
                member_id    BLOB NOT NULL,
                wrapped_key  BLOB NOT NULL,
                PRIMARY KEY (envelope_id, member_id)
            );

            CREATE TABLE IF NOT EXISTS members (
                workspace_id BLOB NOT NULL,
                member_id    BLOB NOT NULL,
                joined_at_us INTEGER NOT NULL,
                PRIMARY KEY (workspace_id, member_id)
            );

            CREATE TABLE IF NOT EXISTS enrollments (
                request_id       BLOB NOT NULL PRIMARY KEY,
                workspace_id     BLOB NOT NULL,
                requester_id     BLOB NOT NULL,
                ephemeral_pubkey BLOB NOT NULL,
                state            TEXT NOT NULL DEFAULT 'pending'
            );
            ",
        )
        .map_err(|e| StoreError::Database(e.to_string()))
    }
}

fn uuid_to_bytes(u: &Uuid) -> Vec<u8> {
    u.as_bytes().to_vec()
}

fn bytes_to_uuid(b: &[u8]) -> Result<Uuid, StoreError> {
    Uuid::from_slice(b).map_err(|e| StoreError::Database(format!("bad UUID blob: {e}")))
}

fn state_to_str(s: EnrollmentState) -> &'static str {
    match s {
        EnrollmentState::Pending => "pending",
        EnrollmentState::Vouched => "vouched",
        EnrollmentState::Active => "active",
        EnrollmentState::Rejected => "rejected",
    }
}

fn str_to_state(s: &str) -> Result<EnrollmentState, StoreError> {
    match s {
        "pending" => Ok(EnrollmentState::Pending),
        "vouched" => Ok(EnrollmentState::Vouched),
        "active" => Ok(EnrollmentState::Active),
        "rejected" => Ok(EnrollmentState::Rejected),
        other => Err(StoreError::Database(format!("unknown state: {other}"))),
    }
}

#[async_trait::async_trait]
impl WorkspaceStore for SqliteWorkspaceStore {
    async fn put_brief(
        &self,
        workspace_id: WorkspaceId,
        req: CreateBriefRequest,
    ) -> Result<BriefEnvelope, StoreError> {
        let envelope_id = Uuid::new_v4();
        let conn = self.conn.clone();

        let envelope = BriefEnvelope {
            id: envelope_id,
            workspace_id,
            uploaded_by: req.uploaded_by,
            uploaded_at_us: req.ts_brief_us,
            ts_brief_us: req.ts_brief_us,
            ciphertext: req.ciphertext,
            nonce: req.nonce,
            aad: req.aad,
            member_key_wraps: req.member_key_wraps,
        };
        let env_clone = envelope.clone();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let tx = conn.unchecked_transaction().map_err(|e| StoreError::Database(e.to_string()))?;

            tx.execute(
                "INSERT INTO briefs (envelope_id, workspace_id, uploaded_by, uploaded_at_us, ts_brief_us, ciphertext, nonce, aad)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    uuid_to_bytes(&env_clone.id),
                    uuid_to_bytes(&env_clone.workspace_id.0),
                    uuid_to_bytes(&env_clone.uploaded_by.0),
                    env_clone.uploaded_at_us as i64,
                    env_clone.ts_brief_us as i64,
                    env_clone.ciphertext,
                    env_clone.nonce,
                    env_clone.aad,
                ],
            )
            .map_err(|e| StoreError::Database(e.to_string()))?;

            for wrap in &env_clone.member_key_wraps {
                tx.execute(
                    "INSERT INTO brief_key_wraps (envelope_id, member_id, wrapped_key) VALUES (?1, ?2, ?3)",
                    params![
                        uuid_to_bytes(&env_clone.id),
                        uuid_to_bytes(&wrap.member_id.0),
                        wrap.wrapped_key,
                    ],
                )
                .map_err(|e| StoreError::Database(e.to_string()))?;
            }

            tx.commit().map_err(|e| StoreError::Database(e.to_string()))?;
            Ok::<_, StoreError>(())
        })
        .await
        .map_err(|e| StoreError::Database(format!("spawn_blocking join: {e}")))??;

        Ok(envelope)
    }

    async fn get_briefs(
        &self,
        workspace_id: WorkspaceId,
        since: Option<u64>,
    ) -> Result<Vec<BriefEnvelope>, StoreError> {
        let conn = self.conn.clone();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();

            let (sql, params_vec): (&str, Vec<Box<dyn rusqlite::types::ToSql>>) = match since {
                Some(ts) => (
                    "SELECT envelope_id, workspace_id, uploaded_by, uploaded_at_us, ts_brief_us, ciphertext, nonce, aad
                     FROM briefs WHERE workspace_id = ?1 AND uploaded_at_us > ?2 ORDER BY uploaded_at_us",
                    vec![
                        Box::new(uuid_to_bytes(&workspace_id.0)) as Box<dyn rusqlite::types::ToSql>,
                        Box::new(ts as i64),
                    ],
                ),
                None => (
                    "SELECT envelope_id, workspace_id, uploaded_by, uploaded_at_us, ts_brief_us, ciphertext, nonce, aad
                     FROM briefs WHERE workspace_id = ?1 ORDER BY uploaded_at_us",
                    vec![Box::new(uuid_to_bytes(&workspace_id.0)) as Box<dyn rusqlite::types::ToSql>],
                ),
            };

            let mut stmt = conn.prepare(sql).map_err(|e| StoreError::Database(e.to_string()))?;
            let param_refs: Vec<&dyn rusqlite::types::ToSql> = params_vec.iter().map(AsRef::as_ref).collect();
            let rows = stmt
                .query_map(param_refs.as_slice(), |row| {
                    let eid: Vec<u8> = row.get(0)?;
                    let wsid: Vec<u8> = row.get(1)?;
                    let upby: Vec<u8> = row.get(2)?;
                    let uploaded_at: i64 = row.get(3)?;
                    let ts_brief: i64 = row.get(4)?;
                    let ct: Vec<u8> = row.get(5)?;
                    let nonce: Vec<u8> = row.get(6)?;
                    let aad: Vec<u8> = row.get(7)?;
                    Ok((eid, wsid, upby, uploaded_at, ts_brief, ct, nonce, aad))
                })
                .map_err(|e| StoreError::Database(e.to_string()))?;

            let mut envelopes = Vec::new();
            for row in rows {
                let (eid, wsid, upby, uploaded_at, ts_brief, ct, nonce, aad) =
                    row.map_err(|e| StoreError::Database(e.to_string()))?;

                let envelope_id = bytes_to_uuid(&eid)?;

                // Load key wraps for this envelope.
                let mut wrap_stmt = conn
                    .prepare("SELECT member_id, wrapped_key FROM brief_key_wraps WHERE envelope_id = ?1")
                    .map_err(|e| StoreError::Database(e.to_string()))?;
                let wraps = wrap_stmt
                    .query_map(params![eid], |r| {
                        let mid: Vec<u8> = r.get(0)?;
                        let wk: Vec<u8> = r.get(1)?;
                        Ok((mid, wk))
                    })
                    .map_err(|e| StoreError::Database(e.to_string()))?;

                let mut key_wraps = Vec::new();
                for w in wraps {
                    let (mid, wk) = w.map_err(|e| StoreError::Database(e.to_string()))?;
                    key_wraps.push(MemberKeyWrap {
                        member_id: MemberId(bytes_to_uuid(&mid)?),
                        wrapped_key: wk,
                    });
                }

                envelopes.push(BriefEnvelope {
                    id: envelope_id,
                    workspace_id: WorkspaceId(bytes_to_uuid(&wsid)?),
                    uploaded_by: MemberId(bytes_to_uuid(&upby)?),
                    uploaded_at_us: uploaded_at as u64,
                    ts_brief_us: ts_brief as u64,
                    ciphertext: ct,
                    nonce,
                    aad,
                    member_key_wraps: key_wraps,
                });
            }
            Ok(envelopes)
        })
        .await
        .map_err(|e| StoreError::Database(format!("spawn_blocking join: {e}")))?
    }

    async fn create_enrollment(
        &self,
        req: EnrollmentRequest,
    ) -> Result<EnrollmentRequest, StoreError> {
        let conn = self.conn.clone();
        let req_clone = req.clone();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            conn.execute(
                "INSERT INTO enrollments (request_id, workspace_id, requester_id, ephemeral_pubkey, state)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    uuid_to_bytes(&req_clone.id),
                    uuid_to_bytes(&req_clone.workspace_id.0),
                    uuid_to_bytes(&req_clone.requester_id.0),
                    req_clone.ephemeral_pubkey,
                    state_to_str(req_clone.state),
                ],
            )
            .map_err(|e| StoreError::Database(e.to_string()))
        })
        .await
        .map_err(|e| StoreError::Database(format!("spawn_blocking join: {e}")))??;

        Ok(req)
    }

    async fn apply_vouch(&self, vouch: VouchToken) -> Result<EnrollmentRequest, StoreError> {
        let conn = self.conn.clone();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let tx = conn.unchecked_transaction().map_err(|e| StoreError::Database(e.to_string()))?;

            // Read current enrollment state.
            let (ws_bytes, req_bytes, epk, state_str): (Vec<u8>, Vec<u8>, Vec<u8>, String) = tx
                .query_row(
                    "SELECT workspace_id, requester_id, ephemeral_pubkey, state FROM enrollments WHERE request_id = ?1",
                    params![uuid_to_bytes(&vouch.enrollment_id)],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .map_err(|e| match e {
                    rusqlite::Error::QueryReturnedNoRows => {
                        StoreError::EnrollmentNotFound(vouch.enrollment_id)
                    }
                    other => StoreError::Database(other.to_string()),
                })?;

            let current_state = str_to_state(&state_str)?;
            if current_state != EnrollmentState::Pending {
                return Err(StoreError::InvalidTransition {
                    from: current_state,
                    to: EnrollmentState::Active,
                });
            }

            // Transition to active.
            tx.execute(
                "UPDATE enrollments SET state = ?1 WHERE request_id = ?2",
                params![state_to_str(EnrollmentState::Active), uuid_to_bytes(&vouch.enrollment_id)],
            )
            .map_err(|e| StoreError::Database(e.to_string()))?;

            // Add requester as member.
            let now_us = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_micros() as i64;

            tx.execute(
                "INSERT OR IGNORE INTO members (workspace_id, member_id, joined_at_us) VALUES (?1, ?2, ?3)",
                params![&ws_bytes, &req_bytes, now_us],
            )
            .map_err(|e| StoreError::Database(e.to_string()))?;

            tx.commit().map_err(|e| StoreError::Database(e.to_string()))?;

            let ws_id = bytes_to_uuid(&ws_bytes)?;
            let req_id = bytes_to_uuid(&req_bytes)?;
            Ok(EnrollmentRequest {
                id: vouch.enrollment_id,
                workspace_id: WorkspaceId(ws_id),
                requester_id: MemberId(req_id),
                ephemeral_pubkey: epk,
                state: EnrollmentState::Active,
            })
        })
        .await
        .map_err(|e| StoreError::Database(format!("spawn_blocking join: {e}")))?
    }

    async fn list_members(&self, workspace_id: WorkspaceId) -> Result<Vec<MemberId>, StoreError> {
        let conn = self.conn.clone();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let mut stmt = conn
                .prepare("SELECT member_id FROM members WHERE workspace_id = ?1")
                .map_err(|e| StoreError::Database(e.to_string()))?;
            let rows = stmt
                .query_map(params![uuid_to_bytes(&workspace_id.0)], |row| {
                    let mid: Vec<u8> = row.get(0)?;
                    Ok(mid)
                })
                .map_err(|e| StoreError::Database(e.to_string()))?;

            let mut members = Vec::new();
            for row in rows {
                let mid = row.map_err(|e| StoreError::Database(e.to_string()))?;
                members.push(MemberId(bytes_to_uuid(&mid)?));
            }
            Ok(members)
        })
        .await
        .map_err(|e| StoreError::Database(format!("spawn_blocking join: {e}")))?
    }

    async fn seed_workspace(
        &self,
        workspace_id: WorkspaceId,
        members: Vec<MemberId>,
    ) -> Result<(), StoreError> {
        let conn = self.conn.clone();

        tokio::task::spawn_blocking(move || {
            let conn = conn.blocking_lock();
            let now_us = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_micros() as i64;

            for m in &members {
                conn.execute(
                    "INSERT OR IGNORE INTO members (workspace_id, member_id, joined_at_us) VALUES (?1, ?2, ?3)",
                    params![uuid_to_bytes(&workspace_id.0), uuid_to_bytes(&m.0), now_us],
                )
                .map_err(|e| StoreError::Database(e.to_string()))?;
            }
            Ok(())
        })
        .await
        .map_err(|e| StoreError::Database(format!("spawn_blocking join: {e}")))?
    }
}
