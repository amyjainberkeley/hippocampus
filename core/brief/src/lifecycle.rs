//! 5-state machine: Draft → Reviewing → Approved → Synced → Archived.
//!
//! [`advance`] is the single chokepoint for all state transitions.
//! Every `(BriefState, LifecycleAction)` pair is handled explicitly —
//! no wildcard arms, no implicit transitions. Tests pin the exhaustive
//! matrix.
//!
//! # ADR-0018 §4 invariants enforced here
//!
//! - **NO AUTO-APPROVE:** `Approve` action requires `human_approver_id`.
//! - **Tripwire is structural:** `Approve` carries citation violations;
//!   non-empty violations block the transition.

use crate::model::{Brief, BriefState};
use crate::tripwire::CitationViolation;

use thiserror::Error;

/// Actions that drive the lifecycle state machine.
#[derive(Debug)]
pub enum LifecycleAction {
    /// Move from Draft to Reviewing.
    Submit,
    /// Move from Reviewing to Approved. Requires `human_approver_id`
    /// and an empty `citation_violations` vec (tripwire must pass).
    Approve {
        /// The human who approved this brief. Cannot be empty.
        human_approver_id: String,
        /// Result of [`crate::tripwire::validate_citations`]. Must be
        /// empty for approval to succeed — the lifecycle function is
        /// the structural chokepoint.
        citation_violations: Vec<CitationViolation>,
    },
    /// Move from Approved to Synced (ADR-0019 upload completed).
    Sync,
    /// Move from Synced to Archived (terminal).
    Archive,
}

/// Errors from [`advance`].
#[derive(Debug, Error)]
pub enum LifecycleError {
    /// The `(state, action)` pair is not a valid transition.
    #[error("invalid transition: {from} cannot accept {action}")]
    InvalidTransition {
        /// Current state.
        from: BriefState,
        /// Action name that was attempted.
        action: &'static str,
    },
    /// Approve action had an empty `human_approver_id`.
    #[error("approval requires a non-empty human_approver_id")]
    MissingApprover,
    /// Tripwire detected citation violations — approval blocked.
    #[error("tripwire failed: {} citation violation(s)", .0.len())]
    TripwireFailed(Vec<CitationViolation>),
}

/// Advance a brief through the lifecycle state machine.
///
/// This is the **sole chokepoint** for state transitions. Every
/// `(state, action)` pair is handled explicitly. Bypassing the
/// tripwire or the human-approver requirement requires changing this
/// function — visible in code review.
pub fn advance(brief: &mut Brief, action: LifecycleAction) -> Result<(), LifecycleError> {
    match (&brief.state, action) {
        (BriefState::Draft, LifecycleAction::Submit) => {
            brief.state = BriefState::Reviewing;
            Ok(())
        }
        (BriefState::Reviewing, LifecycleAction::Approve { human_approver_id, citation_violations }) => {
            if human_approver_id.is_empty() {
                return Err(LifecycleError::MissingApprover);
            }
            if !citation_violations.is_empty() {
                return Err(LifecycleError::TripwireFailed(citation_violations));
            }
            brief.human_approver_id = Some(human_approver_id);
            brief.state = BriefState::Approved;
            Ok(())
        }
        (BriefState::Approved, LifecycleAction::Sync) => {
            brief.state = BriefState::Synced;
            Ok(())
        }
        (BriefState::Synced, LifecycleAction::Archive) => {
            brief.state = BriefState::Archived;
            Ok(())
        }

        // Exhaustive rejection of all invalid (state, action) pairs.
        (BriefState::Draft, LifecycleAction::Approve { .. }) => Err(LifecycleError::InvalidTransition { from: BriefState::Draft, action: "Approve" }),
        (BriefState::Draft, LifecycleAction::Sync) => Err(LifecycleError::InvalidTransition { from: BriefState::Draft, action: "Sync" }),
        (BriefState::Draft, LifecycleAction::Archive) => Err(LifecycleError::InvalidTransition { from: BriefState::Draft, action: "Archive" }),

        (BriefState::Reviewing, LifecycleAction::Submit) => Err(LifecycleError::InvalidTransition { from: BriefState::Reviewing, action: "Submit" }),
        (BriefState::Reviewing, LifecycleAction::Sync) => Err(LifecycleError::InvalidTransition { from: BriefState::Reviewing, action: "Sync" }),
        (BriefState::Reviewing, LifecycleAction::Archive) => Err(LifecycleError::InvalidTransition { from: BriefState::Reviewing, action: "Archive" }),

        (BriefState::Approved, LifecycleAction::Submit) => Err(LifecycleError::InvalidTransition { from: BriefState::Approved, action: "Submit" }),
        (BriefState::Approved, LifecycleAction::Approve { .. }) => Err(LifecycleError::InvalidTransition { from: BriefState::Approved, action: "Approve" }),
        (BriefState::Approved, LifecycleAction::Archive) => Err(LifecycleError::InvalidTransition { from: BriefState::Approved, action: "Archive" }),

        (BriefState::Synced, LifecycleAction::Submit) => Err(LifecycleError::InvalidTransition { from: BriefState::Synced, action: "Submit" }),
        (BriefState::Synced, LifecycleAction::Approve { .. }) => Err(LifecycleError::InvalidTransition { from: BriefState::Synced, action: "Approve" }),
        (BriefState::Synced, LifecycleAction::Sync) => Err(LifecycleError::InvalidTransition { from: BriefState::Synced, action: "Sync" }),

        (BriefState::Archived, LifecycleAction::Submit) => Err(LifecycleError::InvalidTransition { from: BriefState::Archived, action: "Submit" }),
        (BriefState::Archived, LifecycleAction::Approve { .. }) => Err(LifecycleError::InvalidTransition { from: BriefState::Archived, action: "Approve" }),
        (BriefState::Archived, LifecycleAction::Sync) => Err(LifecycleError::InvalidTransition { from: BriefState::Archived, action: "Sync" }),
        (BriefState::Archived, LifecycleAction::Archive) => Err(LifecycleError::InvalidTransition { from: BriefState::Archived, action: "Archive" }),
    }
}
