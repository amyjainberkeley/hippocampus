//! Agent runner — the in-process pipeline that turns a `FrameReader`
//! over an `AsyncRead` transport into JSONL health records on disk.
//!
//! Phase-1 cycle 3 wires the production transport (a `tokio::net::
//! UnixStream` half from the helper child process). This iter (11)
//! provides the runner so the binary scaffold can drive it from a
//! synthetic stdin in `--demo` mode, end-to-end.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5 (agent shell logging). The
//! runner only ever produces typed `HealthLogRecord` values via
//! [`health_pump::pump_one`]; it does NOT have a path that surfaces
//! Tombstone / `StateTransition` / `ProtocolMisuse` / `EchoedControl` as
//! log records. Those variants are silently counted via tracing
//! (Phase-1 cycle 3+) but never reach the `HealthLog` JSONL file
//! (content-free invariant).

use mci_core::ipc::connection::Routed;
use mci_core::ipc::reader::FrameReader;
use mci_core::ipc::Message;
use tokio::io::AsyncRead;

use crate::device_id::DeviceId;
use crate::health_log::HealthLog;
use crate::health_pump::{pump_one, PumpError};
use crate::wall_clock::WallClock;

/// Per-run outcome counters. Caller (the binary's main) prints these.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct RunStats {
    /// Frames decoded off the input transport.
    pub frames_seen: u64,
    /// Frames that routed to `Routed::Health` and pumped into the
    /// `HealthLog` JSONL successfully.
    pub frames_logged: u64,
    /// Frames that routed to a non-`Health` variant — counted, never
    /// logged. Phase-1 cycle 3+ surfaces them through a separate
    /// tracing channel.
    pub frames_non_health: u64,
}

/// Errors the runner surfaces. Distinguishes transport / decode /
/// log-write paths so the binary's main can choose an exit code.
#[derive(Debug, thiserror::Error)]
pub enum RunError {
    /// Inbound transport read or decode failed. Hostile / malformed
    /// helper input lands here.
    #[error("runner read: {0}")]
    Read(#[from] mci_core::ipc::ReadError),
    /// JSONL log write failed. File-system error.
    #[error("runner log: {0}")]
    Log(#[from] crate::health_log::HealthLogError),
}

impl From<PumpError> for RunError {
    fn from(_: PumpError) -> Self {
        // The pump only returns `NotHealth`, which the runner handles
        // by counting + continuing, never by returning. Keeping the
        // From impl for symmetry; callers won't construct this branch.
        Self::Read(mci_core::ipc::ReadError::UnexpectedEof)
    }
}

/// Drive one connection-to-disk drain.
///
/// Reads frames from `rx` until clean EOF or a fatal error. For each
/// frame:
///
/// 1. Classify as `Health` / `Tombstone` / `StateTransition` /
///    `ProtocolMisuse` / `EchoedControl` (same logic
///    `HelperConnection::route` uses; duplicated here so the runner
///    is transport-symmetric — the helper-side `HelperConnection`
///    requires both `AsyncRead` + `AsyncWrite`, but in `--demo`
///    mode the agent only reads).
/// 2. If `Health`: pump → `HealthLogRecord` → append to JSONL.
/// 3. Else: increment counter, continue (NEVER log).
///
/// **Decode errors close the connection** per ADR-0007 trust-boundary
/// rules (caller may surface to a higher-level shutdown path).
pub async fn drain_to_log<R>(
    rx: &mut R,
    log: &HealthLog,
    clock: &dyn WallClock,
    device_id: &DeviceId,
) -> Result<RunStats, RunError>
where
    R: AsyncRead + Unpin,
{
    let mut reader = FrameReader::new();
    let mut stats = RunStats::default();

    while let Some(frame) = reader.read_frame(rx).await? {
        stats.frames_seen += 1;
        if matches!(frame.message, Message::HelperHealth { .. }) {
            let routed = Routed::Health(frame);
            match pump_one(&routed, clock, device_id) {
                Ok(rec) => {
                    log.record(&rec).await?;
                    stats.frames_logged += 1;
                }
                Err(PumpError::NotHealth) => {
                    // Can't happen: we just matched HelperHealth.
                    // Defensive non-fatal counter bump.
                    stats.frames_non_health += 1;
                }
            }
        } else {
            // Tombstone, StateTransition, SurfaceReleased,
            // CaptureStart/Stop — all counted, NEVER logged. Cycle 3+
            // routes them to their proper destinations (store, tracing
            // tap, etc); the runner's content-free guarantee means
            // this branch produces no JSONL output.
            stats.frames_non_health += 1;
        }
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::health_log::HealthLogConfig;
    use crate::wall_clock::test_support::FixedClock;
    use mci_core::ipc::wire::encode;
    use mci_core::ipc::RedactionReason;
    use std::io::Cursor;

    fn id() -> DeviceId {
        DeviceId::from_hex_for_test("0123456789abcdef0123456789abcdef")
    }

    #[tokio::test]
    async fn drains_three_health_frames_to_jsonl() {
        let tmp = tempfile::tempdir().unwrap();
        let log_path = tmp.path().join("h.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: log_path.clone(),
            max_bytes: 10 * 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(1_779_163_200_000);
        let id = id();

        let mut bytes = Vec::new();
        for seq in 0..3 {
            let f = encode(
                seq,
                &Message::HelperHealth {
                    uptime_ms: 1000 + seq * 10,
                    frames_delivered: seq * 5,
                    frames_suppressed: 0,
                    frames_redacted_by_failsafe: 0,
                    frames_dropped_backpressure: 0,
                    frames_dropped_late_ack: 0,
                },
            );
            bytes.extend(f);
        }
        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log(&mut cursor, &log, &clock, &id).await.unwrap();

        assert_eq!(stats.frames_seen, 3);
        assert_eq!(stats.frames_logged, 3);
        assert_eq!(stats.frames_non_health, 0);

        let body = tokio::fs::read_to_string(&log_path).await.unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 3);
        for line in lines {
            assert!(line.contains("\"device_id\":\"0123456789abcdef0123456789abcdef\""));
            assert!(line.contains("\"wall_ts\":\"2026-05-19T04:00:00.000Z\""));
        }
    }

    #[tokio::test]
    async fn non_health_frames_counted_not_logged() {
        let tmp = tempfile::tempdir().unwrap();
        let log_path = tmp.path().join("h.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: log_path.clone(),
            max_bytes: 10 * 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(0);
        let id = id();

        let mut bytes = Vec::new();
        bytes.extend(encode(
            0,
            &Message::PrivacyTombstone {
                ts_us: 1,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
        ));
        bytes.extend(encode(
            1,
            &Message::HelperHealth {
                uptime_ms: 0,
                frames_delivered: 0,
                frames_suppressed: 0,
                frames_redacted_by_failsafe: 0,
                frames_dropped_backpressure: 0,
                frames_dropped_late_ack: 0,
            },
        ));
        bytes.extend(encode(2, &Message::CaptureStop));
        bytes.extend(encode(
            3,
            &Message::SurfaceReleased {
                fd_index: 0,
                ack_seq: 1,
            },
        ));

        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log(&mut cursor, &log, &clock, &id).await.unwrap();
        assert_eq!(stats.frames_seen, 4);
        assert_eq!(stats.frames_logged, 1);
        assert_eq!(stats.frames_non_health, 3);

        // Log contains exactly one line (the Health).
        let body = tokio::fs::read_to_string(&log_path).await.unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 1);
        // And the line carries NONE of the forbidden field names.
        for forbidden in [
            "\"app_bundle\":",
            "\"window_title\":",
            "\"url\":",
            "\"text\":",
            "\"summary\":",
            "\"entities\":",
        ] {
            assert!(
                !lines[0].contains(forbidden),
                "log contains forbidden {forbidden}"
            );
        }
    }

    #[tokio::test]
    async fn empty_input_yields_zero_stats() {
        let tmp = tempfile::tempdir().unwrap();
        let log = HealthLog::new(HealthLogConfig {
            path: tmp.path().join("h.jsonl"),
            max_bytes: 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let mut empty = Cursor::new(Vec::<u8>::new());
        let stats = drain_to_log(&mut empty, &log, &clock, &id).await.unwrap();
        assert_eq!(stats, RunStats::default());
    }

    #[tokio::test]
    async fn malformed_input_returns_read_error() {
        let tmp = tempfile::tempdir().unwrap();
        let log = HealthLog::new(HealthLogConfig {
            path: tmp.path().join("h.jsonl"),
            max_bytes: 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        // Bad magic byte.
        let mut bytes = encode(0, &Message::CaptureStop);
        bytes[0] = 0xFF;
        let mut cursor = Cursor::new(bytes);
        let err = drain_to_log(&mut cursor, &log, &clock, &id)
            .await
            .unwrap_err();
        assert!(matches!(err, RunError::Read(_)));
    }
}
