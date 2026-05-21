//! Existing-member-vouches enrollment state machine (skeleton).
//!
//! ADR-0019 §2.2: adding a member requires an existing member's vouch.
//! No auto-enrollment, no email-link-clicks. The enrollment state machine:
//!
//! ```text
//! Pending ──(existing member vouches)──▶ Active
//!    │
//!    └──(admin rejects / timeout)──▶ Rejected
//! ```
//!
//! The full out-of-band fingerprint verification + ephemeral key exchange
//! is a follow-on PR. This skeleton defines the state transitions and
//! validates them.

use crate::model::EnrollmentState;

/// Validate that a state transition is legal.
#[must_use]
pub fn valid_transition(from: EnrollmentState, to: EnrollmentState) -> bool {
    matches!(
        (from, to),
        (
            EnrollmentState::Pending | EnrollmentState::Vouched,
            EnrollmentState::Active
        ) | (
            EnrollmentState::Pending,
            EnrollmentState::Rejected | EnrollmentState::Vouched
        )
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_to_active_valid() {
        assert!(valid_transition(
            EnrollmentState::Pending,
            EnrollmentState::Active
        ));
    }

    #[test]
    fn pending_to_rejected_valid() {
        assert!(valid_transition(
            EnrollmentState::Pending,
            EnrollmentState::Rejected
        ));
    }

    #[test]
    fn active_to_pending_invalid() {
        assert!(!valid_transition(
            EnrollmentState::Active,
            EnrollmentState::Pending
        ));
    }

    #[test]
    fn rejected_to_active_invalid() {
        assert!(!valid_transition(
            EnrollmentState::Rejected,
            EnrollmentState::Active
        ));
    }
}
