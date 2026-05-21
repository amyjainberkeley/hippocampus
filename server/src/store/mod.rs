//! Workspace store trait + implementations.
//!
//! - [`InMemoryWorkspaceStore`] — tests and dev (no durability).
//! - [`SqliteWorkspaceStore`] — production (rusqlite, file-backed).

mod in_memory;
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
mod sqlite;

pub use in_memory::InMemoryWorkspaceStore;
pub use sqlite::SqliteWorkspaceStore;

use uuid::Uuid;

use crate::model::{
    BriefEnvelope, CreateBriefRequest, EnrollmentRequest, EnrollmentState, MemberId, VouchToken,
    WorkspaceId,
};

/// Errors from store operations.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("workspace not found: {0:?}")]
    WorkspaceNotFound(WorkspaceId),
    #[error("enrollment not found: {0}")]
    EnrollmentNotFound(Uuid),
    #[error("invalid state transition: {from:?} -> {to:?}")]
    InvalidTransition {
        from: EnrollmentState,
        to: EnrollmentState,
    },
    #[error("database error: {0}")]
    Database(String),
}

/// Workspace store contract. Implementations must be `Send + Sync` for axum handlers.
#[async_trait::async_trait]
pub trait WorkspaceStore: Send + Sync {
    /// Store a new brief envelope. Returns the server-assigned envelope.
    async fn put_brief(
        &self,
        workspace_id: WorkspaceId,
        req: CreateBriefRequest,
    ) -> Result<BriefEnvelope, StoreError>;

    /// Retrieve briefs for a workspace, optionally filtered by `since` timestamp.
    async fn get_briefs(
        &self,
        workspace_id: WorkspaceId,
        since: Option<u64>,
    ) -> Result<Vec<BriefEnvelope>, StoreError>;

    /// Start an enrollment request.
    async fn create_enrollment(
        &self,
        req: EnrollmentRequest,
    ) -> Result<EnrollmentRequest, StoreError>;

    /// Apply a vouch to a pending enrollment, transitioning it to Active.
    async fn apply_vouch(&self, vouch: VouchToken) -> Result<EnrollmentRequest, StoreError>;

    /// List enrolled (active) members for a workspace.
    async fn list_members(&self, workspace_id: WorkspaceId) -> Result<Vec<MemberId>, StoreError>;

    /// Seed a workspace with initial members (for test setup).
    async fn seed_workspace(
        &self,
        workspace_id: WorkspaceId,
        members: Vec<MemberId>,
    ) -> Result<(), StoreError>;
}

#[async_trait::async_trait]
impl WorkspaceStore for Box<dyn WorkspaceStore> {
    async fn put_brief(
        &self,
        workspace_id: WorkspaceId,
        req: CreateBriefRequest,
    ) -> Result<BriefEnvelope, StoreError> {
        (**self).put_brief(workspace_id, req).await
    }

    async fn get_briefs(
        &self,
        workspace_id: WorkspaceId,
        since: Option<u64>,
    ) -> Result<Vec<BriefEnvelope>, StoreError> {
        (**self).get_briefs(workspace_id, since).await
    }

    async fn create_enrollment(
        &self,
        req: EnrollmentRequest,
    ) -> Result<EnrollmentRequest, StoreError> {
        (**self).create_enrollment(req).await
    }

    async fn apply_vouch(&self, vouch: VouchToken) -> Result<EnrollmentRequest, StoreError> {
        (**self).apply_vouch(vouch).await
    }

    async fn list_members(&self, workspace_id: WorkspaceId) -> Result<Vec<MemberId>, StoreError> {
        (**self).list_members(workspace_id).await
    }

    async fn seed_workspace(
        &self,
        workspace_id: WorkspaceId,
        members: Vec<MemberId>,
    ) -> Result<(), StoreError> {
        (**self).seed_workspace(workspace_id, members).await
    }
}
