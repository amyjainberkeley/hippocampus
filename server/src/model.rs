//! Domain types for the workspace server.
//!
//! **ADR-0019 §4 invariant:** `BriefEnvelope` carries ONLY ciphertext + opaque
//! key-wraps. NO plaintext text/summary/url fields. Tests pin this.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Workspace identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WorkspaceId(pub Uuid);

/// Member identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct MemberId(pub Uuid);

/// A per-member wrapped key: the per-brief key encrypted under the member's
/// device key. The server stores these opaque blobs; it cannot unwrap them.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemberKeyWrap {
    pub member_id: MemberId,
    pub wrapped_key: Vec<u8>,
}

/// An encrypted brief envelope — the ONLY thing the server stores for brief content.
///
/// **NO PLAINTEXT FIELDS.** The server holds ciphertext + nonce + AAD + per-member
/// key wraps. It cannot decrypt any of this. ADR-0019 §4 invariants #1, #2, #10.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BriefEnvelope {
    /// Server-assigned envelope ID.
    pub id: Uuid,
    /// Which workspace this brief belongs to.
    pub workspace_id: WorkspaceId,
    /// Who uploaded it.
    pub uploaded_by: MemberId,
    /// Upload timestamp (microseconds since epoch).
    pub uploaded_at_us: u64,
    /// Brief timestamp — when the brief covers (microseconds since epoch).
    pub ts_brief_us: u64,
    /// Encrypted brief content (opaque ciphertext).
    pub ciphertext: Vec<u8>,
    /// AEAD nonce.
    pub nonce: Vec<u8>,
    /// Additional authenticated data (content-free metadata bound to the ciphertext).
    pub aad: Vec<u8>,
    /// Per-member key wraps: the per-brief key wrapped for each enrolled member.
    pub member_key_wraps: Vec<MemberKeyWrap>,
}

/// Request to create a new brief envelope (POST body).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateBriefRequest {
    pub uploaded_by: MemberId,
    pub ts_brief_us: u64,
    pub ciphertext: Vec<u8>,
    pub nonce: Vec<u8>,
    pub aad: Vec<u8>,
    pub member_key_wraps: Vec<MemberKeyWrap>,
}

/// Enrollment request — a new member wants to join a workspace.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnrollmentRequest {
    pub id: Uuid,
    pub workspace_id: WorkspaceId,
    pub requester_id: MemberId,
    /// Ephemeral public key the requester generated for the key-exchange.
    pub ephemeral_pubkey: Vec<u8>,
    pub state: EnrollmentState,
}

/// Vouch token — an existing member approves the enrollment.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VouchToken {
    pub enrollment_id: Uuid,
    pub voucher_id: MemberId,
    /// The workspace key wrapped under the requester's ephemeral pubkey.
    pub wrapped_workspace_key: Vec<u8>,
}

/// Enrollment state machine states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EnrollmentState {
    Pending,
    Vouched,
    Active,
    Rejected,
}

/// Query parameters for listing briefs.
#[derive(Debug, Clone, Deserialize)]
pub struct BriefsQuery {
    /// Only return briefs uploaded after this timestamp (microseconds since epoch).
    pub since: Option<u64>,
}
