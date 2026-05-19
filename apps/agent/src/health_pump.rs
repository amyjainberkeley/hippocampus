//! `health_pump` — pure transform from a [`mci_core::ipc::Routed::Health`]
//! frame into a [`crate::health_log::HealthLogRecord`].
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. The pump enforces the
//! content-free property on the wire-to-disk path:
//!
//!   `Routed::Health` (typed wire frame, counters only)
//!         │
//!         │ `pump_one(routed`, clock, `device_id`)
//!         ▼
//!   `HealthLogRecord` (typed log row, counters + opaque `device_id`)
//!
//! There is no overload that takes an arbitrary `Frame` and emits a
//! `HealthLogRecord` — the pump consumes the **already-classified
//! Routed variant** only. Trying to log a `Routed::Tombstone` or
//! `Routed::StateTransition` through this path is a type error.
//!
//! No I/O. The actual write goes through `HealthLog::record()` after
//! the pump.

use mci_core::ipc::{Message, Routed};

use crate::device_id::DeviceId;
use crate::health_log::HealthLogRecord;
use crate::wall_clock::WallClock;

/// Pump errors. Only one variant today; the type stays for future
/// growth (rate-limiting, malformed-counter-rejection, etc).
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PumpError {
    /// The caller handed a `Routed` variant that isn't `Health`. The
    /// pump rejects it rather than logging garbage. Caller routes the
    /// other variants to their own materializers.
    #[error("pump received non-Health Routed variant")]
    NotHealth,
}

/// Transform one classified `Routed::Health` frame into a typed
/// `HealthLogRecord` using `clock` for the wall timestamp and
/// `device_id` for the row's `device_id` field.
///
/// `clock` is borrowed (caller owns the clock). `device_id` is
/// borrowed (caller owns the id). The pump allocates only the
/// returned `HealthLogRecord`.
///
/// # Errors
/// Returns [`PumpError::NotHealth`] if the routed variant isn't
/// `Health`.
pub fn pump_one(
    routed: &Routed,
    clock: &dyn WallClock,
    device_id: &DeviceId,
) -> Result<HealthLogRecord, PumpError> {
    let Routed::Health(frame) = routed else {
        return Err(PumpError::NotHealth);
    };
    let Message::HelperHealth {
        uptime_ms,
        frames_delivered,
        frames_suppressed,
        frames_dropped_backpressure,
        frames_dropped_late_ack,
    } = &frame.message
    else {
        // `Routed::Health` is only constructed from `HelperHealth`
        // frames (see `core::ipc::connection::HelperConnection::route`);
        // this branch is defensive against a future routing change.
        return Err(PumpError::NotHealth);
    };
    Ok(HealthLogRecord {
        wall_ts: clock.now_rfc3339(),
        device_id: device_id.as_str().to_owned(),
        uptime_ms: *uptime_ms,
        frames_delivered: *frames_delivered,
        frames_suppressed: *frames_suppressed,
        frames_dropped_backpressure: *frames_dropped_backpressure,
        frames_dropped_late_ack: *frames_dropped_late_ack,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wall_clock::test_support::FixedClock;
    use mci_core::ipc::wire::Frame;
    use mci_core::ipc::{Message, RedactionReason};

    fn id() -> DeviceId {
        DeviceId::from_hex_for_test("0123456789abcdef0123456789abcdef")
    }

    fn health_frame() -> Frame {
        Frame {
            seq: 7,
            message: Message::HelperHealth {
                uptime_ms: 5_000,
                frames_delivered: 100,
                frames_suppressed: 12,
                frames_dropped_backpressure: 1,
                frames_dropped_late_ack: 0,
            },
        }
    }

    #[test]
    fn pumps_health_to_record() {
        let clock = FixedClock::at_unix_ms(1_779_163_200_000); // 2026-05-19T04:00:00Z
        let id = id();
        let routed = Routed::Health(health_frame());

        let rec = pump_one(&routed, &clock, &id).expect("ok");
        assert_eq!(rec.wall_ts, "2026-05-19T04:00:00.000Z");
        assert_eq!(rec.device_id, "0123456789abcdef0123456789abcdef");
        assert_eq!(rec.uptime_ms, 5_000);
        assert_eq!(rec.frames_delivered, 100);
        assert_eq!(rec.frames_suppressed, 12);
        assert_eq!(rec.frames_dropped_backpressure, 1);
        assert_eq!(rec.frames_dropped_late_ack, 0);
    }

    #[test]
    fn rejects_tombstone_variant() {
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let routed = Routed::Tombstone(mci_core::store::EventRow {
            ts_ms: 0,
            device_id: "x".to_string(),
            app_bundle: "x".to_string(),
            source_type: "redacted",
            redaction_reason: "ax-secure-subrole",
        });
        let err = pump_one(&routed, &clock, &id).unwrap_err();
        assert_eq!(err, PumpError::NotHealth);
    }

    #[test]
    fn rejects_state_transition_variant() {
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let frame = Frame {
            seq: 0,
            message: Message::StateTransitionEvent {
                ts_us: 0,
                fd_index: 0,
                width_px: 0,
                height_px: 0,
                status_flags: 0,
                dirty_rects: vec![],
            },
        };
        let routed = Routed::StateTransition(frame);
        let err = pump_one(&routed, &clock, &id).unwrap_err();
        assert_eq!(err, PumpError::NotHealth);
    }

    #[test]
    fn rejects_protocol_misuse_variant() {
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let frame = Frame {
            seq: 0,
            message: Message::SurfaceReleased {
                fd_index: 0,
                ack_seq: 0,
            },
        };
        let routed = Routed::ProtocolMisuse(frame);
        let err = pump_one(&routed, &clock, &id).unwrap_err();
        assert_eq!(err, PumpError::NotHealth);
    }

    #[test]
    fn rejects_echoed_control_variant() {
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let frame = Frame {
            seq: 0,
            message: Message::CaptureStop,
        };
        let routed = Routed::EchoedControl(frame);
        let err = pump_one(&routed, &clock, &id).unwrap_err();
        assert_eq!(err, PumpError::NotHealth);
    }

    /// The pump emits a record whose `to_json_line()` survives the
    /// `HealthLogRecord` trip-wire test. End-to-end sanity that the
    /// pump cannot smuggle a forbidden field through.
    #[test]
    fn pumped_record_passes_no_user_content_invariant() {
        let clock = FixedClock::at_unix_ms(1_779_163_200_000);
        let id = id();
        let routed = Routed::Health(health_frame());
        let rec = pump_one(&routed, &clock, &id).unwrap();
        let line = rec.to_json_line();
        for forbidden in [
            "\"app_bundle\":",
            "\"window_title\":",
            "\"url\":",
            "\"text\":",
            "\"summary\":",
            "\"entities\":",
        ] {
            assert!(
                !line.contains(forbidden),
                "pumped record contains {forbidden}"
            );
        }
    }

    /// Suppress unused-import warning for `RedactionReason` — the type
    /// is imported for the doc-link checking; this test is the
    /// "we actually used it" proof so the unused-import lint stays
    /// quiet under -D warnings.
    #[test]
    fn redaction_reason_is_a_valid_type_in_scope() {
        // Exercise both the type's existence + its as_db_str helper so
        // clippy doesn't flag the binding as unused.
        let r = RedactionReason::AxSecureSubrole;
        assert_eq!(r.as_db_str(), "ax-secure-subrole");
    }
}
