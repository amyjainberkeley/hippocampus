//! MCI agent shell library.
//!
//! The agent shell is the long-running macOS process the user installs.
//! Per `docs/decisions/0007-macos-capture-separate-signed-helper-process.md`
//! it supervises the Swift `mci-capture-helper` child process and is the
//! place the per-device identifier + the user's runtime config live.
//!
//! Phase 1 cycle 2 lands the **supervisor scaffold**: the per-device-id
//! load/generate, the helper child-process spawn protocol shape, the
//! `select!`-loop building blocks. Cycle 3 wires the real `AF_UNIX`
//! socketpair fd hand-off + a `tokio::net::UnixStream`-backed
//! [`mci_core::ipc::HelperConnection`] consumer.
//!
//! Nothing in this crate calls `SCStream` — the cross-platform-seam
//! invariant (`AGENT_PROTOCOL` §4) is honored; only the Swift helper
//! touches OS capture APIs.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod device_id;
pub mod health_log;
pub mod health_pump;
pub mod runner;
pub mod supervisor;
pub mod wall_clock;

pub use device_id::{load_or_generate, DeviceId, DeviceIdError, DeviceIdSource};
pub use health_log::{HealthLog, HealthLogConfig, HealthLogError, HealthLogRecord};
pub use health_pump::{pump_one, PumpError};
pub use runner::{drain_to_log, RunError, RunStats};
pub use supervisor::{HelperSpawnConfig, SupervisorError};
pub use wall_clock::{format_unix_ms, SystemWallClock, WallClock};
