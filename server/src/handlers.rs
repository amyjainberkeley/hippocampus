//! Axum HTTP route handlers.
//!
//! ADR-0019 §4 invariant #2: the server never processes brief content.
//! These handlers ferry opaque bytes only — no crypto primitives here.

use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use uuid::Uuid;

use crate::model::{
    BriefsQuery, CreateBriefRequest, EnrollmentRequest, EnrollmentState, VouchToken, WorkspaceId,
};
use crate::store::WorkspaceStore;

/// Application state shared across handlers.
pub struct AppState<S: WorkspaceStore> {
    pub store: S,
}

/// Build the axum router with all workspace server routes.
pub fn router<S: WorkspaceStore + 'static>(state: Arc<AppState<S>>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route(
            "/v1/workspaces/{id}/briefs",
            post(put_brief::<S>).get(get_briefs::<S>),
        )
        .route("/v1/workspaces/{id}/enroll", post(enroll::<S>))
        .route("/v1/workspaces/{id}/vouch", post(vouch::<S>))
        .with_state(state)
}

async fn healthz() -> &'static str {
    "ok"
}

async fn put_brief<S: WorkspaceStore>(
    State(state): State<Arc<AppState<S>>>,
    Path(workspace_id): Path<Uuid>,
    Json(req): Json<CreateBriefRequest>,
) -> impl IntoResponse {
    let ws_id = WorkspaceId(workspace_id);
    match state.store.put_brief(ws_id, req).await {
        Ok(envelope) => (StatusCode::CREATED, Json(envelope)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn get_briefs<S: WorkspaceStore>(
    State(state): State<Arc<AppState<S>>>,
    Path(workspace_id): Path<Uuid>,
    Query(query): Query<BriefsQuery>,
) -> impl IntoResponse {
    let ws_id = WorkspaceId(workspace_id);
    match state.store.get_briefs(ws_id, query.since).await {
        Ok(briefs) => Json(briefs).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn enroll<S: WorkspaceStore>(
    State(state): State<Arc<AppState<S>>>,
    Path(workspace_id): Path<Uuid>,
    Json(mut req): Json<EnrollmentRequest>,
) -> impl IntoResponse {
    req.workspace_id = WorkspaceId(workspace_id);
    req.state = EnrollmentState::Pending;
    req.id = Uuid::new_v4();
    match state.store.create_enrollment(req).await {
        Ok(enrollment) => (StatusCode::OK, Json(enrollment)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn vouch<S: WorkspaceStore>(
    State(state): State<Arc<AppState<S>>>,
    Path(_workspace_id): Path<Uuid>,
    Json(vouch): Json<VouchToken>,
) -> impl IntoResponse {
    match state.store.apply_vouch(vouch).await {
        Ok(enrollment) => Json(enrollment).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e.to_string()).into_response(),
    }
}

/// Typed response for lists of briefs (used by integration tests).
impl<S: WorkspaceStore> AppState<S> {
    /// Convenience: create from a store.
    pub fn new(store: S) -> Self {
        Self { store }
    }
}
