//! Privacy-tombstone row materialization.
//!
//! Bridges the helper-IPC surface ([`crate::ipc::Message::PrivacyTombstone`])
//! to the encrypted-store `events`-table row shape (per ADR-0013 §4).
//! Does NOT open a database connection — that's Phase-1 cycle 3 (the
//! Phase-1 store-init code). This module is the pure data transform
//! that the eventual store-write layer will invoke.
//!
//! Binding ADRs:
//! - `docs/decisions/0013-native-grade-sensitive-surface-suppression.md` §4
//!   — privacy tombstones materialize as `events` rows with
//!   `source_type = 'redacted'` and a `redaction_reason` matching the
//!   cascade rule that fired.
//! - `docs/decisions/0012-zero-knowledge-spec-tightening.md` §1
//!   — the helper / core trust boundary; the wire decoder has already
//!   classified `reason` before we materialize it here.
//!
//! **CSO sign-off (binding).** The materializer DOES NOT validate
//! `app_bundle` strings — they are arbitrary UTF-8 from the helper, and
//! the wire decoder is the trust boundary. The store-write layer must
//! parameterize the SQL insert so the bundle string is treated as data,
//! never SQL; SQL injection via a hostile bundle string is a
//! protected-set concern. The `EventRow::sql_param_columns()` constant
//! below names the columns in INSERT order; the Phase-1 store-init code
//! uses positional binds.

use crate::ipc::{Frame, Message};

/// The fixed `source_type` value for every privacy tombstone, per
/// ADR-0013 §4. Stored as TEXT in `events.source_type`.
pub const TOMBSTONE_SOURCE_TYPE: &str = "redacted";

/// A row materialized for the `events` table from a wire-protocol
/// [`Message::PrivacyTombstone`].
///
/// Only the columns the tombstone populates are present — every other
/// `events` column is NULL by design (no `keyframe_blob_ref`, no
/// `summary`, no `entities`, no `dhash`, no `window_title`, no `url`,
/// no `dwell_ms`, no `episode_id`). The ADR-0013 §2 "no pixels, no
/// event-level text, no window title, no URL" guarantee is enforced
/// at this struct's shape — there is no field for any of those.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventRow {
    /// `events.ts` — capture timestamp in milliseconds since epoch.
    /// The wire-protocol value is microseconds; the store layer
    /// divides by 1000 here (single conversion point).
    pub ts_ms: i64,
    /// `events.device_id` — opaque per-device identifier the helper
    /// did not carry (the helper has no `device_id` of its own).
    /// The Phase-1 store-init code supplies this from the agent's
    /// per-device config at insert time; we expose a placeholder so
    /// the row shape stays explicit.
    pub device_id: String,
    /// `events.app_bundle` — foreground app at the time of
    /// suppression. UTF-8 from the helper; binds as a SQL parameter.
    pub app_bundle: String,
    /// `events.source_type` — always [`TOMBSTONE_SOURCE_TYPE`]
    /// (`"redacted"`) for a privacy tombstone.
    pub source_type: &'static str,
    /// `events.redaction_reason` — kebab-case string from
    /// [`RedactionReason::as_db_str`]. New column added by migration
    /// V0002.
    pub redaction_reason: &'static str,
}

impl EventRow {
    /// The column names this row populates, in the order the Phase-1
    /// store-init code will use for positional binds.
    ///
    /// Locked: changing the order requires re-numbering every prepared
    /// `INSERT` statement. The store-init code asserts the column count
    /// matches `events` table columns it expects to populate.
    pub const SQL_PARAM_COLUMNS: &[&'static str] = &[
        "ts",
        "device_id",
        "app_bundle",
        "source_type",
        "redaction_reason",
    ];

    /// Build an `EventRow` from a wire-protocol [`Message::PrivacyTombstone`].
    ///
    /// `device_id` is supplied by the caller (the agent shell knows the
    /// per-device identifier; the helper does not).
    ///
    /// Returns `None` if `frame.message` is not a `PrivacyTombstone` —
    /// the caller should route other variants elsewhere (state-transition
    /// events go through a different materializer).
    #[must_use]
    pub fn from_tombstone(frame: &Frame, device_id: &str) -> Option<Self> {
        let Message::PrivacyTombstone {
            ts_us,
            app_bundle,
            reason,
        } = &frame.message
        else {
            return None;
        };
        Some(Self {
            ts_ms: micros_to_millis(*ts_us),
            device_id: device_id.to_string(),
            app_bundle: app_bundle.clone(),
            source_type: TOMBSTONE_SOURCE_TYPE,
            redaction_reason: reason.as_db_str(),
        })
    }
}

/// Convert wire-protocol microseconds (helper-side monotonic) to the
/// `events.ts` millisecond convention.
///
/// Safe by construction: `u64::MAX / 1000 ≈ 1.8 × 10¹⁶` is well below
/// `i64::MAX ≈ 9.2 × 10¹⁸`, so the post-divide value always fits in
/// `i64` without wrap. The `#[allow]` documents the proof; the unit
/// test `micros_to_millis_max_u64_does_not_wrap` is the regression
/// gate.
#[allow(clippy::cast_possible_wrap)]
const fn micros_to_millis(us: u64) -> i64 {
    (us / 1000) as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::wire::Frame;
    use crate::ipc::{Message, RedactionReason};

    fn frame(ts_us: u64, app: &str, reason: RedactionReason) -> Frame {
        Frame {
            seq: 1,
            message: Message::PrivacyTombstone {
                ts_us,
                app_bundle: app.to_string(),
                reason,
            },
        }
    }

    #[test]
    fn materializes_all_columns() {
        let f = frame(
            1_500_000,
            "com.apple.Safari",
            RedactionReason::AxSecureSubrole,
        );
        let row = EventRow::from_tombstone(&f, "device-A").expect("row");
        assert_eq!(row.ts_ms, 1500);
        assert_eq!(row.device_id, "device-A");
        assert_eq!(row.app_bundle, "com.apple.Safari");
        assert_eq!(row.source_type, "redacted");
        assert_eq!(row.redaction_reason, "ax-secure-subrole");
    }

    #[test]
    fn source_type_is_always_redacted() {
        for reason in [
            RedactionReason::DenylistSource,
            RedactionReason::OsBlackedRegion,
            RedactionReason::SecureEventInput,
            RedactionReason::AxSecureSubrole,
            RedactionReason::DenylistPostCapture,
            RedactionReason::FailsafeUnknown,
        ] {
            let f = frame(0, "x", reason);
            let row = EventRow::from_tombstone(&f, "d").unwrap();
            assert_eq!(row.source_type, TOMBSTONE_SOURCE_TYPE);
            assert_eq!(row.redaction_reason, reason.as_db_str());
        }
    }

    #[test]
    fn returns_none_for_non_tombstone_frames() {
        let f = Frame {
            seq: 1,
            message: Message::CaptureStop,
        };
        assert!(EventRow::from_tombstone(&f, "d").is_none());
    }

    #[test]
    fn micros_to_millis_zero() {
        assert_eq!(micros_to_millis(0), 0);
    }

    #[test]
    fn micros_to_millis_floor_division() {
        // 1999 us → 1 ms (we don't round up; the helper's resolution
        // is microseconds, the store's is milliseconds, so partial-ms
        // discards the sub-millisecond remainder).
        assert_eq!(micros_to_millis(1_999), 1);
    }

    #[test]
    #[allow(clippy::cast_possible_wrap)]
    fn micros_to_millis_max_u64_does_not_wrap() {
        // u64::MAX / 1000 ≈ 1.8 × 10¹⁶ — well below i64::MAX ≈ 9.2 × 10¹⁸.
        // The cast is safe by construction; this test pins it.
        let result = micros_to_millis(u64::MAX);
        assert!(
            result > 0,
            "result must be positive (no wrap), got {result}"
        );
        assert_eq!(result, (u64::MAX / 1000) as i64);
    }

    #[test]
    fn empty_app_bundle_is_preserved_not_validated() {
        // Per CSO sign-off, the materializer does NOT validate
        // app_bundle strings — they're arbitrary UTF-8 from the helper.
        // SQL safety lives in the parameterized-insert layer.
        let f = frame(0, "", RedactionReason::FailsafeUnknown);
        let row = EventRow::from_tombstone(&f, "d").unwrap();
        assert_eq!(row.app_bundle, "");
    }

    #[test]
    fn sql_param_columns_matches_event_row_field_count() {
        // 5 named columns ⇔ 5 fields in EventRow that populate them.
        // (ts_ms, device_id, app_bundle, source_type, redaction_reason)
        assert_eq!(EventRow::SQL_PARAM_COLUMNS.len(), 5);
        // Spot-check the ordering — the Phase-1 store-init code will
        // use positional binds.
        assert_eq!(EventRow::SQL_PARAM_COLUMNS[0], "ts");
        assert_eq!(EventRow::SQL_PARAM_COLUMNS[1], "device_id");
        assert_eq!(EventRow::SQL_PARAM_COLUMNS[2], "app_bundle");
        assert_eq!(EventRow::SQL_PARAM_COLUMNS[3], "source_type");
        assert_eq!(EventRow::SQL_PARAM_COLUMNS[4], "redaction_reason");
    }

    #[test]
    fn unicode_app_bundle_round_trips() {
        // The wire decoder handles UTF-8 length-prefixed strings; the
        // materializer must not corrupt them.
        let f = frame(
            0,
            "com.example.密码管理器",
            RedactionReason::AxSecureSubrole,
        );
        let row = EventRow::from_tombstone(&f, "d").unwrap();
        assert_eq!(row.app_bundle, "com.example.密码管理器");
    }
}
