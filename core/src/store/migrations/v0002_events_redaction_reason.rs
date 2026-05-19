//! V0002 — add `events.redaction_reason TEXT` per ADR-0013 §4.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. This migration is the schema
//! side of the privacy-tombstone surface: every suppression-fired event
//! lands as an `events` row with `source_type = 'redacted'` and a
//! `redaction_reason` matching the cascade rule that fired (see
//! [`crate::ipc::RedactionReason::as_db_str`] for the stable string
//! values).
//!
//! ## CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! The column is `TEXT` (not an enum) so the store layer does not need
//! to validate values on insert — the wire-protocol decoder
//! ([`crate::ipc::RedactionReason::from_u8`]) is the trust boundary;
//! anything that reaches the store has already been classified by it.
//! The column is nullable because every PRE-V0002 `events` row has no
//! recorded reason; the recall UI treats NULL as "not a tombstone."
//!
//! Adding this column does NOT require re-encoding existing rows.
//! `ALTER TABLE events ADD COLUMN redaction_reason TEXT` is a no-op
//! on row data — `SQLite` stores it as NULL for every existing row at
//! application time. `SQLCipher` inherits this; no plaintext touches
//! disk during the migration.
//!
//! — CSO, 2026-05-19

use super::Migration;

/// `events.redaction_reason TEXT` — the column that materializes
/// ADR-0013 §4's privacy tombstone in the store.
///
/// Stable string values written here come from
/// [`crate::ipc::RedactionReason::as_db_str`]:
///   `denylist-source` | `os-blacked-region` | `secure-event-input`
///   | `ax-secure-subrole` | `denylist-postcapture` | `failsafe-unknown`
pub const V0002: Migration = Migration {
    from_version: 1,
    to_version: 2,
    name: "0002_events_redaction_reason",
    statements: &["ALTER TABLE events ADD COLUMN redaction_reason TEXT;"],
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::RedactionReason;

    #[test]
    fn v0002_targets_events_table() {
        assert_eq!(V0002.statements.len(), 1);
        assert!(V0002.statements[0].contains("ALTER TABLE events"));
        assert!(V0002.statements[0].contains("redaction_reason"));
        assert!(V0002.statements[0].contains("TEXT"));
    }

    #[test]
    fn v0002_is_first_phase_one_migration() {
        assert_eq!(V0002.from_version, 1);
        assert_eq!(V0002.to_version, 2);
    }

    /// ADR-0013 §4 binding: every wire-protocol `RedactionReason` has
    /// a stable `as_db_str()` that this column is meant to hold. Any
    /// drift (e.g. someone renames `as_db_str()` outputs to use
    /// underscores instead of dashes) breaks the round-trip the recall
    /// UI relies on. This trip-wire test asserts every variant returns
    /// the kebab-case form the recall-UI tombstone surface expects.
    #[test]
    fn redaction_reason_db_strings_are_stable_kebab_case() {
        let expected: &[(RedactionReason, &str)] = &[
            (RedactionReason::DenylistSource, "denylist-source"),
            (RedactionReason::OsBlackedRegion, "os-blacked-region"),
            (RedactionReason::SecureEventInput, "secure-event-input"),
            (RedactionReason::AxSecureSubrole, "ax-secure-subrole"),
            (RedactionReason::DenylistPostCapture, "denylist-postcapture"),
            (RedactionReason::FailsafeUnknown, "failsafe-unknown"),
        ];
        for &(r, s) in expected {
            assert_eq!(r.as_db_str(), s, "RedactionReason {r:?} db string drifted");
            // Sanity check that the form is kebab — recall UI parses on
            // this assumption when grouping tombstones by reason.
            assert!(
                !s.contains('_'),
                "RedactionReason db string must be kebab-case, got {s}"
            );
        }
    }
}
