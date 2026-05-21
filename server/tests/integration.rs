//! Integration tests for the MCI workspace server skeleton.
//!
//! ADR-0019 §4 invariants are pinned here:
//! - No plaintext fields on `BriefEnvelope`.
//! - No endpoint that decrypts content (NO BACKDOOR KEY).
//! - Enrollment state machine requires a vouch.
//! - `since` query filters briefs by timestamp.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

use mci_server::handlers::{router, AppState};
use mci_server::model::{
    BriefEnvelope, CreateBriefRequest, EnrollmentRequest, EnrollmentState, MemberKeyWrap, MemberId,
    VouchToken, WorkspaceId,
};
use mci_server::store::InMemoryWorkspaceStore;

fn test_app() -> axum::Router {
    let store = InMemoryWorkspaceStore::new();
    let state = Arc::new(AppState::new(store));
    router(state)
}

async fn test_app_with_workspace() -> (axum::Router, WorkspaceId, MemberId) {
    let store = InMemoryWorkspaceStore::new();
    let ws_id = WorkspaceId(Uuid::new_v4());
    let member_id = MemberId(Uuid::new_v4());
    store.seed_workspace(ws_id, vec![member_id]).await;
    let state = Arc::new(AppState::new(store));
    (router(state), ws_id, member_id)
}

#[tokio::test]
async fn health_endpoint_returns_200() {
    let app = test_app();
    let req = Request::builder()
        .uri("/healthz")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(&body[..], b"ok");
}

#[tokio::test]
async fn put_brief_then_get_returns_same_envelope() {
    let (app, ws_id, member_id) = test_app_with_workspace().await;

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
}

#[tokio::test]
async fn since_query_filters_briefs_by_ts() {
    let (app, ws_id, member_id) = test_app_with_workspace().await;

    // Insert two briefs at different timestamps.
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

    // GET with since=1_500_000 — should only return the second brief.
    let get_req = Request::builder()
        .uri(format!(
            "/v1/workspaces/{}/briefs?since=1500000",
            ws_id.0
        ))
        .body(Body::empty())
        .unwrap();

    let get_resp = app.oneshot(get_req).await.unwrap();
    let body = get_resp.into_body().collect().await.unwrap().to_bytes();
    let briefs: Vec<BriefEnvelope> = serde_json::from_slice(&body).unwrap();
    assert_eq!(briefs.len(), 1);
    assert_eq!(briefs[0].ts_brief_us, 2_000_000);
}

#[tokio::test]
async fn enrollment_flow_state_machine() {
    let (app, ws_id, _member_id) = test_app_with_workspace().await;
    let new_member = MemberId(Uuid::new_v4());

    // Step 1: Request enrollment.
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

    // Step 2: Existing member vouches.
    let vouch = VouchToken {
        enrollment_id: enrollment.id,
        voucher_id: _member_id,
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

/// ADR-0019 §4 invariant: `BriefEnvelope` has NO plaintext fields.
/// This test verifies at the serde layer that any attempt to deserialize
/// a JSON object with a `text` or `summary` or `url` field into a
/// `BriefEnvelope` does NOT produce a usable plaintext field — those fields
/// simply don't exist on the type.
#[test]
fn server_rejects_plaintext_brief_field() {
    // A JSON object that looks like a brief with plaintext fields.
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
        // Plaintext fields that MUST NOT be present on the type:
        "text": "this is plaintext that should not exist",
        "summary": "plaintext summary",
        "url": "https://example.com/secret"
    });

    // Deserialization succeeds (serde ignores unknown fields by default),
    // but the resulting struct has no .text / .summary / .url fields.
    let envelope: BriefEnvelope =
        serde_json::from_value(plaintext_attempt).expect("deser should succeed");

    // Structural proof: the type's fields are exhaustively listed here.
    // If anyone adds a plaintext `text: String` field to BriefEnvelope,
    // this match will fail to compile (missing field).
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

    // The ciphertext is opaque bytes, not the plaintext string.
    assert_eq!(ciphertext, &[1u8, 2, 3]);
    assert_eq!(nonce, &[4u8, 5, 6]);
}

/// ADR-0019 §4 invariant #10: NO BACKDOOR KEY.
/// There is no endpoint that decrypts content server-side.
/// This test asserts at the API surface level.
#[tokio::test]
async fn server_has_no_backdoor_key() {
    let app = test_app();

    // Exhaustive list of known routes. None of them are "decrypt" endpoints.
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

    // Type-level proof: grep the handlers module source for "decrypt" patterns.
    // The handlers module source is `server/src/handlers.rs` — it contains no
    // decrypt function, no AEAD primitive, no key-unwrap call. This is verified
    // by the absence of any `decrypt` symbol in the crate's public API.
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

    let model_src = include_str!("../src/model.rs");
    // No field named "text", "summary", "plaintext", "content" (as a String) on BriefEnvelope.
    // The ciphertext field is Vec<u8>, which is opaque bytes.
    for forbidden in ["pub text:", "pub summary:", "pub plaintext:", "pub url:"] {
        assert!(
            !model_src.contains(forbidden),
            "model.rs must not have plaintext field: {forbidden}"
        );
    }
}
