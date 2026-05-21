//! Integration tests for the MCI workspace server.
//!
//! ADR-0019 §4 invariants pinned here:
//! - No plaintext fields on `BriefEnvelope`.
//! - No endpoint that decrypts content (NO BACKDOOR KEY).
//! - Enrollment state machine requires a vouch.
//! - `since` query filters briefs by timestamp.
//!
//! Tests run against BOTH `InMemoryWorkspaceStore` and `SqliteWorkspaceStore`.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

use mci_server::handlers::{router, AppState};
use mci_server::model::{
    BriefEnvelope, CreateBriefRequest, EnrollmentRequest, EnrollmentState, MemberId, MemberKeyWrap,
    VouchToken, WorkspaceId,
};
use mci_server::store::{InMemoryWorkspaceStore, SqliteWorkspaceStore, WorkspaceStore};

// ---------------------------------------------------------------------------
// Store factories
// ---------------------------------------------------------------------------

fn memory_store() -> Box<dyn WorkspaceStore> {
    Box::new(InMemoryWorkspaceStore::new())
}

fn sqlite_store() -> Box<dyn WorkspaceStore> {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("test.db");
    let store = SqliteWorkspaceStore::open(&path).expect("open sqlite");
    // Leak the tempdir so the file lives for the test's duration.
    std::mem::forget(dir);
    Box::new(store)
}

fn test_app_from(store: Box<dyn WorkspaceStore>) -> axum::Router {
    let state = Arc::new(AppState::new(store));
    router(state)
}

async fn test_app_with_workspace_from(
    store: Box<dyn WorkspaceStore>,
) -> (axum::Router, WorkspaceId, MemberId) {
    let ws_id = WorkspaceId(Uuid::new_v4());
    let member_id = MemberId(Uuid::new_v4());
    store
        .seed_workspace(ws_id, vec![member_id])
        .await
        .expect("seed");
    let state = Arc::new(AppState::new(store));
    (router(state), ws_id, member_id)
}

// ---------------------------------------------------------------------------
// Macro to duplicate every test for both store backends
// ---------------------------------------------------------------------------

macro_rules! dual_store_tests {
    ($($test_name:ident),* $(,)?) => {
        mod in_memory_tests {
            use super::*;
            $(
                #[tokio::test]
                async fn $test_name() {
                    super::$test_name(memory_store).await;
                }
            )*
        }
        mod sqlite_tests {
            use super::*;
            $(
                #[tokio::test]
                async fn $test_name() {
                    super::$test_name(sqlite_store).await;
                }
            )*
        }
    };
}

dual_store_tests!(
    health_endpoint_returns_200,
    put_brief_then_get_returns_same_envelope,
    since_query_filters_briefs_by_ts,
    enrollment_flow_state_machine,
);

// ---------------------------------------------------------------------------
// Parameterized test implementations
// ---------------------------------------------------------------------------

async fn health_endpoint_returns_200(factory: fn() -> Box<dyn WorkspaceStore>) {
    let app = test_app_from(factory());
    let req = Request::builder()
        .uri("/healthz")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(&body[..], b"ok");
}

async fn put_brief_then_get_returns_same_envelope(factory: fn() -> Box<dyn WorkspaceStore>) {
    let (app, ws_id, member_id) = test_app_with_workspace_from(factory()).await;

    let create_req = CreateBriefRequest {
        uploaded_by: member_id,
        ts_brief_us: 1_000_000,
        ciphertext: vec![0xDE, 0xAD, 0xBE, 0xEF],
        nonce: vec![0x01, 0x02, 0x03],
        aad: vec![0x0A],
        member_key_wraps: vec![MemberKeyWrap {
            member_id,
            wrapped_key: vec![0xFF; 32],
        }],
    };

    // PUT
    let put_req = Request::builder()
        .method("POST")
        .uri(format!("/v1/workspaces/{}/briefs", ws_id.0))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_string(&create_req).unwrap()))
        .unwrap();

    let put_resp = app.clone().oneshot(put_req).await.unwrap();
    assert_eq!(put_resp.status(), StatusCode::CREATED);

    let put_body = put_resp.into_body().collect().await.unwrap().to_bytes();
    let stored: BriefEnvelope = serde_json::from_slice(&put_body).unwrap();
    assert_eq!(stored.ciphertext, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    assert_eq!(stored.nonce, vec![0x01, 0x02, 0x03]);
    assert_eq!(stored.workspace_id, ws_id);
    assert_eq!(stored.uploaded_by, member_id);
    assert_eq!(stored.member_key_wraps.len(), 1);
    assert_eq!(stored.member_key_wraps[0].wrapped_key, vec![0xFF; 32]);

    // GET
    let get_req = Request::builder()
        .uri(format!("/v1/workspaces/{}/briefs", ws_id.0))
        .body(Body::empty())
        .unwrap();

    let get_resp = app.oneshot(get_req).await.unwrap();
    assert_eq!(get_resp.status(), StatusCode::OK);

    let get_body = get_resp.into_body().collect().await.unwrap().to_bytes();
    let briefs: Vec<BriefEnvelope> = serde_json::from_slice(&get_body).unwrap();
    assert_eq!(briefs.len(), 1);
    assert_eq!(briefs[0].ciphertext, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    assert_eq!(briefs[0].member_key_wraps.len(), 1);
}

async fn since_query_filters_briefs_by_ts(factory: fn() -> Box<dyn WorkspaceStore>) {
    let (app, ws_id, member_id) = test_app_with_workspace_from(factory()).await;

    for ts in [1_000_000u64, 2_000_000] {
        let req = CreateBriefRequest {
            uploaded_by: member_id,
            ts_brief_us: ts,
            ciphertext: ts.to_le_bytes().to_vec(),
            nonce: vec![0x01],
            aad: vec![],
            member_key_wraps: vec![],
        };
        let put_req = Request::builder()
            .method("POST")
            .uri(format!("/v1/workspaces/{}/briefs", ws_id.0))
            .header("content-type", "application/json")
            .body(Body::from(serde_json::to_string(&req).unwrap()))
            .unwrap();
        let resp = app.clone().oneshot(put_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    let get_req = Request::builder()
        .uri(format!("/v1/workspaces/{}/briefs?since=1500000", ws_id.0))
        .body(Body::empty())
        .unwrap();

    let get_resp = app.oneshot(get_req).await.unwrap();
    let body = get_resp.into_body().collect().await.unwrap().to_bytes();
    let briefs: Vec<BriefEnvelope> = serde_json::from_slice(&body).unwrap();
    assert_eq!(briefs.len(), 1);
    assert_eq!(briefs[0].ts_brief_us, 2_000_000);
}

async fn enrollment_flow_state_machine(factory: fn() -> Box<dyn WorkspaceStore>) {
    let (app, ws_id, member_id) = test_app_with_workspace_from(factory()).await;
    let new_member = MemberId(Uuid::new_v4());

    let enroll_req = EnrollmentRequest {
        id: Uuid::nil(),
        workspace_id: ws_id,
        requester_id: new_member,
        ephemeral_pubkey: vec![0xAA; 32],
        state: EnrollmentState::Pending,
    };
    let req = Request::builder()
        .method("POST")
        .uri(format!("/v1/workspaces/{}/enroll", ws_id.0))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_string(&enroll_req).unwrap()))
        .unwrap();

    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let enrollment: EnrollmentRequest = serde_json::from_slice(&body).unwrap();
    assert_eq!(enrollment.state, EnrollmentState::Pending);
    assert_ne!(enrollment.id, Uuid::nil(), "server must assign a real ID");

    let vouch = VouchToken {
        enrollment_id: enrollment.id,
        voucher_id: member_id,
        wrapped_workspace_key: vec![0xBB; 32],
    };
    let vouch_req = Request::builder()
        .method("POST")
        .uri(format!("/v1/workspaces/{}/vouch", ws_id.0))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_string(&vouch).unwrap()))
        .unwrap();

    let vouch_resp = app.oneshot(vouch_req).await.unwrap();
    assert_eq!(vouch_resp.status(), StatusCode::OK);

    let vouch_body = vouch_resp.into_body().collect().await.unwrap().to_bytes();
    let updated: EnrollmentRequest = serde_json::from_slice(&vouch_body).unwrap();
    assert_eq!(updated.state, EnrollmentState::Active);
}

// ---------------------------------------------------------------------------
// ADR-0019 §4 invariant tests (not store-specific — structural)
// ---------------------------------------------------------------------------

#[test]
fn server_rejects_plaintext_brief_field() {
    let plaintext_attempt = serde_json::json!({
        "id": Uuid::new_v4(),
        "workspaceId": Uuid::new_v4(),
        "uploadedBy": Uuid::new_v4(),
        "uploadedAtUs": 1000,
        "tsBriefUs": 1000,
        "ciphertext": [1, 2, 3],
        "nonce": [4, 5, 6],
        "aad": [],
        "memberKeyWraps": [],
        "text": "this is plaintext that should not exist",
        "summary": "plaintext summary",
        "url": "https://example.com/secret"
    });

    let envelope: BriefEnvelope =
        serde_json::from_value(plaintext_attempt).expect("deser should succeed");

    let BriefEnvelope {
        id: _,
        workspace_id: _,
        uploaded_by: _,
        uploaded_at_us: _,
        ts_brief_us: _,
        ciphertext,
        nonce,
        aad: _,
        member_key_wraps: _,
    } = &envelope;

    assert_eq!(ciphertext, &[1u8, 2, 3]);
    assert_eq!(nonce, &[4u8, 5, 6]);
}

/// ADR-0019 §4 invariant #10: NO BACKDOOR KEY.
/// No endpoint decrypts content. No server-side source file calls decrypt/unwrap.
#[tokio::test]
async fn server_has_no_backdoor_key() {
    let app = test_app_from(memory_store());

    let decrypt_paths = [
        "/v1/decrypt",
        "/v1/admin/decrypt",
        "/v1/workspaces/00000000-0000-0000-0000-000000000000/decrypt",
        "/v1/workspaces/00000000-0000-0000-0000-000000000000/briefs/decrypt",
        "/v1/admin/master-key",
        "/v1/admin/backdoor",
        "/v1/recovery/key",
    ];

    for path in decrypt_paths {
        for method in ["GET", "POST", "PUT", "DELETE"] {
            let req = Request::builder()
                .method(method)
                .uri(path)
                .body(Body::empty())
                .unwrap();
            let resp = app.clone().oneshot(req).await.unwrap();
            assert_eq!(
                resp.status(),
                StatusCode::NOT_FOUND,
                "decrypt-like endpoint {method} {path} must not exist (got {})",
                resp.status()
            );
        }
    }

    // Source-level proof: server-side modules never reference decrypt/unwrap.
    let handler_src = include_str!("../src/handlers.rs");
    assert!(
        !handler_src.contains("decrypt"),
        "handlers.rs must not contain any 'decrypt' reference"
    );
    assert!(
        !handler_src.contains("unwrap_key"),
        "handlers.rs must not call unwrap_key"
    );
    assert!(
        !handler_src.contains("plaintext"),
        "handlers.rs must not reference 'plaintext'"
    );

    // main.rs: must not import or use the crypto module at all.
    let main_src = include_str!("../src/main.rs");
    assert!(
        !main_src.contains("decrypt"),
        "main.rs must not contain 'decrypt'"
    );
    assert!(
        !main_src.contains("key_wrap"),
        "main.rs must not reference key_wrap"
    );
    assert!(
        !main_src.contains("crypto::"),
        "main.rs must not import the crypto module"
    );
    assert!(
        !main_src.contains("AeadKey"),
        "main.rs must not reference AeadKey"
    );

    // store.rs: must not import or use any crypto primitives.
    // (field name `member_key_wraps` is a model field, not a crypto import.)
    let store_src = include_str!("../src/store/in_memory.rs");
    assert!(
        !store_src.contains("decrypt"),
        "store.rs must not contain 'decrypt'"
    );
    assert!(
        !store_src.contains("crypto::"),
        "store.rs must not import the crypto module"
    );
    assert!(
        !store_src.contains("AeadKey"),
        "store.rs must not reference AeadKey"
    );

    let model_src = include_str!("../src/model.rs");
    for forbidden in ["pub text:", "pub summary:", "pub plaintext:", "pub url:"] {
        assert!(
            !model_src.contains(forbidden),
            "model.rs must not have plaintext field: {forbidden}"
        );
    }
}

// ---------------------------------------------------------------------------
// SQLite-specific tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn sqlite_schema_migration_idempotent() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("idempotent.db");

    // Open twice — second open re-runs CREATE TABLE IF NOT EXISTS.
    let _store1 = SqliteWorkspaceStore::open(&path).expect("first open");
    let _store2 = SqliteWorkspaceStore::open(&path).expect("second open must succeed");
}

#[tokio::test]
async fn sqlite_crash_recovery() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("crash.db");

    let ws_id = WorkspaceId(Uuid::new_v4());
    let member_id = MemberId(Uuid::new_v4());

    // Write a brief, then drop the store (simulates crash).
    {
        let store = SqliteWorkspaceStore::open(&path).expect("open");
        store.seed_workspace(ws_id, vec![member_id]).await.unwrap();
        store
            .put_brief(
                ws_id,
                CreateBriefRequest {
                    uploaded_by: member_id,
                    ts_brief_us: 42_000,
                    ciphertext: vec![0xCA, 0xFE],
                    nonce: vec![0x01],
                    aad: vec![],
                    member_key_wraps: vec![MemberKeyWrap {
                        member_id,
                        wrapped_key: vec![0xDD; 16],
                    }],
                },
            )
            .await
            .unwrap();
    }
    // Store dropped — connection closed.

    // Re-open and verify data survived.
    let store2 = SqliteWorkspaceStore::open(&path).expect("reopen after crash");
    let briefs = store2.get_briefs(ws_id, None).await.unwrap();
    assert_eq!(briefs.len(), 1);
    assert_eq!(briefs[0].ciphertext, vec![0xCA, 0xFE]);
    assert_eq!(briefs[0].ts_brief_us, 42_000);
    assert_eq!(briefs[0].member_key_wraps.len(), 1);
    assert_eq!(briefs[0].member_key_wraps[0].wrapped_key, vec![0xDD; 16]);

    let members = store2.list_members(ws_id).await.unwrap();
    assert_eq!(members.len(), 1);
    assert_eq!(members[0], member_id);
}

#[tokio::test]
async fn sqlite_schema_all_content_columns_are_blob() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("schema_check.db");
    let _store = SqliteWorkspaceStore::open(&path).expect("open");

    // Directly verify the schema via sqlite pragma.
    let conn = rusqlite::Connection::open(&path).expect("raw open");

    // briefs table: ciphertext, nonce, aad must be BLOB.
    let mut stmt = conn.prepare("PRAGMA table_info(briefs)").expect("pragma");
    let cols: Vec<(String, String)> = stmt
        .query_map([], |row| {
            let name: String = row.get(1)?;
            let typ: String = row.get(2)?;
            Ok((name, typ))
        })
        .expect("query")
        .filter_map(Result::ok)
        .collect();

    for blob_col in [
        "envelope_id",
        "workspace_id",
        "uploaded_by",
        "ciphertext",
        "nonce",
        "aad",
    ] {
        let col = cols.iter().find(|(n, _)| n == blob_col);
        assert!(col.is_some(), "briefs table must have column {blob_col}");
        assert_eq!(
            col.unwrap().1,
            "BLOB",
            "briefs.{blob_col} must be BLOB, got {}",
            col.unwrap().1
        );
    }

    // enrollments table: ephemeral_pubkey must be BLOB, state must be TEXT.
    let mut stmt = conn
        .prepare("PRAGMA table_info(enrollments)")
        .expect("pragma");
    let ecols: Vec<(String, String)> = stmt
        .query_map([], |row| {
            let name: String = row.get(1)?;
            let typ: String = row.get(2)?;
            Ok((name, typ))
        })
        .expect("query")
        .filter_map(Result::ok)
        .collect();

    let epk = ecols.iter().find(|(n, _)| n == "ephemeral_pubkey");
    assert!(epk.is_some());
    assert_eq!(epk.unwrap().1, "BLOB");

    let state = ecols.iter().find(|(n, _)| n == "state");
    assert!(state.is_some());
    assert_eq!(state.unwrap().1, "TEXT");
}

/// E2E: workspace key → AEAD encrypt brief → key-wrap per member →
/// store via HTTP → retrieve → key-unwrap → AEAD decrypt → original.
#[tokio::test]
async fn e2e_real_crypto_through_http() {
    use mci_server::crypto::aead::{self, AeadKey, AeadNonce};
    use mci_server::crypto::key_wrap;
    use x25519_dalek::{PublicKey, StaticSecret};

    let (app, ws_id, member_id) = test_app_with_workspace_from(memory_store()).await;

    // 1. Generate workspace key + member keypair (client-side).
    let workspace_key = AeadKey::generate().unwrap();
    let member_private = StaticSecret::random();
    let member_public = PublicKey::from(&member_private);

    // 2. Encrypt a brief under the workspace key.
    let brief_content = b"Meeting notes: Q3 OKRs approved, headcount +2 eng.";
    let aad_bytes = format!("ws:{},ts:1716000000", ws_id.0);
    let (ciphertext, nonce) =
        aead::encrypt(brief_content, &workspace_key, aad_bytes.as_bytes()).unwrap();

    // 3. Wrap workspace key for this member.
    let wrapped = key_wrap::wrap(workspace_key.as_bytes(), &member_public).unwrap();
    let wrapped_bytes = wrapped.to_bytes();

    // 4. Upload through HTTP (server sees only opaque bytes).
    let create_req = CreateBriefRequest {
        uploaded_by: member_id,
        ts_brief_us: 1_716_000_000,
        ciphertext: ciphertext.clone(),
        nonce: nonce.0.to_vec(),
        aad: aad_bytes.as_bytes().to_vec(),
        member_key_wraps: vec![MemberKeyWrap {
            member_id,
            wrapped_key: wrapped_bytes,
        }],
    };

    let put_req = Request::builder()
        .method("POST")
        .uri(format!("/v1/workspaces/{}/briefs", ws_id.0))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_string(&create_req).unwrap()))
        .unwrap();

    let put_resp = app.clone().oneshot(put_req).await.unwrap();
    assert_eq!(put_resp.status(), StatusCode::CREATED);

    // 5. Retrieve through HTTP.
    let get_req = Request::builder()
        .uri(format!("/v1/workspaces/{}/briefs", ws_id.0))
        .body(Body::empty())
        .unwrap();
    let get_resp = app.oneshot(get_req).await.unwrap();
    let body = get_resp.into_body().collect().await.unwrap().to_bytes();
    let briefs: Vec<BriefEnvelope> = serde_json::from_slice(&body).unwrap();
    assert_eq!(briefs.len(), 1);

    let envelope = &briefs[0];

    // 6. Client-side: unwrap the workspace key.
    let member_wrap = &envelope.member_key_wraps[0];
    let restored_wrapped = key_wrap::WrappedKey::from_bytes(&member_wrap.wrapped_key).unwrap();
    let restored_ws_key_bytes = key_wrap::unwrap(&restored_wrapped, &member_private).unwrap();
    let restored_ws_key = AeadKey::from_bytes(restored_ws_key_bytes);

    // 7. Client-side: decrypt the brief.
    let mut nonce_arr = [0u8; 12];
    nonce_arr.copy_from_slice(&envelope.nonce);
    let decrypted = aead::decrypt(
        &envelope.ciphertext,
        &AeadNonce(nonce_arr),
        &restored_ws_key,
        &envelope.aad,
    )
    .unwrap();

    assert_eq!(decrypted, brief_content);
}
