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

pub mod alias_resolver_worker;
pub mod brain_cli;
pub mod brain_ingest;
pub mod brief_worker;
pub mod consolidator_worker;
/// Cycle 8.44 audit — lock-file-based unclean-shutdown detection.
/// On boot, [`crash_recovery::acquire_lock`] returns a
/// [`crash_recovery::LockAcquireOutcome`] that tells the caller whether
/// the prior process exited cleanly, crashed, or is still running. A
/// crash outcome triggers an extra `SqlCipherBrainStore::verify_integrity_on_boot`
/// call before serving. Companion to
/// `mci_brain::integrity_scheduler` (weekly background check).
pub mod crash_recovery;
pub mod device_id;
pub mod episode_worker;
pub mod health_log;
pub mod health_pump;
pub mod health_summary;
pub mod idle_batch;
#[cfg(target_os = "macos")]
pub mod mail_ingest;
pub mod mcp;
/// V2-MCP-3 — MCP aggregator: consumes the registry built by
/// [`mcp_client_supervisor`], connects to each registered server,
/// catalogs `tools/list`, and runs a hybrid materialize-or-catalog
/// policy on `resources/list` results. Persists Events with
/// `app_bundle_id = "mcp:<server-name>"` so V2-P12 (Phase 7 chat
/// surface) can structurally apply prompt-injection mitigation per
/// CRS Fork-6 = A.
pub mod mcp_aggregator;
/// V2-MCP-2 — boot-time MCP-client registry builder. Reads
/// `~/Library/Application Support/MCI/mcp-servers.toml`, constructs a
/// `ServerRegistry`, and surfaces a log-friendly status struct. Held
/// by the agent for the process lifetime; V2-MCP-3 aggregator (cycle
/// 8.30, Director-Brain) consumes the registry without a re-init.
pub mod mcp_client_supervisor;
#[cfg(target_os = "macos")]
pub mod messages_ingest;
pub mod page_content;
pub mod panic_hook;
pub mod panic_uploader;
#[cfg(target_os = "macos")]
pub mod pump_supervisor;
pub mod retention_worker;
pub mod runner;
pub mod supervisor;
/// V2-P5+ — `dslim/bert-base-NER`-backed `NerBackend` for the **sync**
/// Tier-2 NER tier (the CEO-ratified hot-path entity extractor, INT8,
/// `cpu_only`). Runs the committed P2′ tokenizer + `decode_bio` through
/// `mci_coreml_bridge`. Injected into `BrainPump` via `with_ner_sync`
/// and run inline after Tier 1 on the ingest Allow arm.
#[cfg(target_os = "macos")]
pub mod tier2_ner_backend;
/// V2-P5 — Qwen-backed `NerBackend` for Tier 2 entity extraction.
/// Wraps `mci_brief::LlamaBackend` (production: `Qwen3CoreMLBackend`)
/// with a structured-output prompt + JSON parser. Held by the
/// `tier2_worker` for the lifetime of the agent.
#[cfg(target_os = "macos")]
pub mod tier2_qwen_backend;
/// V2-P5 — async idle-batch worker. Polls
/// `SqlCipherBrainStore::events_pending_tier2` for events lacking the
/// `(extractor_status, qwen_tier2_processed)` sentinel mention, runs
/// each through a `Tier2Extractor`, writes Tier 2 entity mentions +
/// the sentinel marker, then sleeps. Mirrors `idle_batch.rs` /
/// `brief_worker.rs` patterns; single-flight by design so the ~500 MB
/// Qwen working set stays predictable.
pub mod tier2_worker;
#[cfg(unix)]
pub mod user_allowlist;
/// V2-P1 M4-lift runtime gate (Phase 7 PR 14, this PR).
///
/// Reads `HIPPOCAMPUS_ENABLE_V2P1` at agent boot; when set to `"1"`
/// the supervisor appends `--capture` to the helper argv AND the Swift
/// helper's `MciV2P1Gate` flips `killOcrEmit` off. Env var unset or
/// any other value ⇒ pre-M4-lift behavior preserved. Matched pair
/// with `MCICaptureHelperKit/Capture/MciV2P1Gate.swift`. Removed by a
/// follow-up PR once Amy's live-Mac §7-equivalent smoke test passes.
pub mod v2p1_gate;
pub mod wall_clock;

pub use brain_ingest::{BrainIngestor, BrainPump, IngestError, IngestOutcome, NoopBrainIngestor};
pub use device_id::{load_or_generate, DeviceId, DeviceIdError, DeviceIdSource};
pub use health_log::{HealthLog, HealthLogConfig, HealthLogError, HealthLogRecord};
pub use health_pump::{pump_one, PumpError};
pub use health_summary::{
    parse_jsonl_line, summarize_file, summarize_lines, HealthSummary, ParseError, SummaryError,
};
pub use page_content::{CachedPageContent, PageContentCache, PageContentListener};
pub use runner::{drain_to_log, drain_to_log_with_brain, RunError, RunStats};
pub use supervisor::{HelperSpawnConfig, SupervisorError};
pub use wall_clock::{format_unix_ms, SystemWallClock, WallClock};
