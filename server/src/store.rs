//! Workspace store trait + in-memory implementation.
//!
//! The `WorkspaceStore` trait defines read/write operations for briefs and
//! enrollment. The in-memory implementation (`InMemoryWorkspaceStore`) is for
//! tests and dev; a SQLite/Postgres-backed production implementation is
//! DEFERRED to a separate ADR + PR.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
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
    async fn list_members(
        &self,
        workspace_id: WorkspaceId,
    ) -> Result<Vec<MemberId>, StoreError>;
}

/// In-memory workspace store for tests and dev. NOT for production — no durability.
#[derive(Debug, Default, Clone)]
pub struct InMemoryWorkspaceStore {
    briefs: Arc<RwLock<HashMap<WorkspaceId, Vec<BriefEnvelope>>>>,
    enrollments: Arc<RwLock<HashMap<Uuid, EnrollmentRequest>>>,
    members: Arc<RwLock<HashMap<WorkspaceId, Vec<MemberId>>>>,
}

impl InMemoryWorkspaceStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Seed a workspace with initial members (for test setup).
    pub async fn seed_workspace(&self, workspace_id: WorkspaceId, members: Vec<MemberId>) {
        self.members
            .write()
            .await
            .insert(workspace_id, members);
        self.briefs
            .write()
            .await
            .entry(workspace_id)
            .or_default();
    }
}

#[async_trait::async_trait]
impl WorkspaceStore for InMemoryWorkspaceStore {
    async fn put_brief(
        &self,
        workspace_id: WorkspaceId,
        req: CreateBriefRequest,
    ) -> Result<BriefEnvelope, StoreError> {
        let envelope = BriefEnvelope {
            id: Uuid::new_v4(),
            workspace_id,
            uploaded_by: req.uploaded_by,
            uploaded_at_us: req.ts_brief_us,
            ts_brief_us: req.ts_brief_us,
            ciphertext: req.ciphertext,
            nonce: req.nonce,
            aad: req.aad,
            member_key_wraps: req.member_key_wraps,
        };
        self.briefs
            .write()
            .await
            .entry(workspace_id)
            .or_default()
            .push(envelope.clone());
        Ok(envelope)
    }

    async fn get_briefs(
        &self,
        workspace_id: WorkspaceId,
        since: Option<u64>,
    ) -> Result<Vec<BriefEnvelope>, StoreError> {
        let guard = self.briefs.read().await;
        let briefs = guard
            .get(&workspace_id)
            .cloned()
            .unwrap_or_default();
        Ok(match since {
            Some(ts) => briefs
                .into_iter()
                .filter(|b| b.uploaded_at_us > ts)
                .collect(),
            None => briefs,
        })
    }

    async fn create_enrollment(
        &self,
        req: EnrollmentRequest,
    ) -> Result<EnrollmentRequest, StoreError> {
        self.enrollments
            .write()
            .await
            .insert(req.id, req.clone());
        Ok(req)
    }

    async fn apply_vouch(&self, vouch: VouchToken) -> Result<EnrollmentRequest, StoreError> {
        let mut guard = self.enrollments.write().await;
        let enrollment = guard
            .get_mut(&vouch.enrollment_id)
            .ok_or(StoreError::EnrollmentNotFound(vouch.enrollment_id))?;

        if enrollment.state != EnrollmentState::Pending {
            return Err(StoreError::InvalidTransition {
                from: enrollment.state,
                to: EnrollmentState::Active,
            });
        }

        enrollment.state = EnrollmentState::Active;

        // Add member to workspace membership.
        self.members
            .write()
            .await
            .entry(enrollment.workspace_id)
            .or_default()
            .push(enrollment.requester_id);

        Ok(enrollment.clone())
    }

    async fn list_members(
        &self,
        workspace_id: WorkspaceId,
    ) -> Result<Vec<MemberId>, StoreError> {
        Ok(self
            .members
            .read()
            .await
            .get(&workspace_id)
            .cloned()
            .unwrap_or_default())
    }
}
