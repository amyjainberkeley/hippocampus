//! `mci-agent` — placeholder runnable binary.
//!
//! Phase-1 cycle 3 wires the real agent shell (menu-bar UI,
//! `tokio::process::Command` helper supervisor, `AF_UNIX` socketpair
//! fd-passing). This iter (11) ships a scaffold that proves the
//! in-process pipeline works end-to-end:
//!
//!   stdin (wire bytes) → `FrameReader` → classify →
//!     {Health → `pump_one` → `HealthLog` JSONL ; else → counted}
//!
//! CLI:
//!
//!   mci-agent --version
//!   mci-agent --help
//!   mci-agent --device-id-path PATH  (default ~/.mci/device-id)
//!            --log-path PATH         (default ~/Library/Logs/MCI/helper-health.jsonl)
//!            --drain-stdin           (read wire frames from stdin
//!                                     until EOF, drain to JSONL)
//!
//! The `--drain-stdin` mode is the CI smoke: feed it the output of
//! `mci-capture-helper --once`, observe a JSONL line written to the
//! configured log path. In Phase-1 cycle 3 the stdin reader is
//! replaced with the helper-child socket fd.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_agent::alias_resolver_worker;
use mci_agent::brain_ingest::{BrainIngestor, BrainPump};
use mci_agent::brief_worker;
use mci_agent::consolidator_worker;
use mci_agent::crash_recovery::{
    acquire_lock, default_lock_path, release_lock, LockAcquireOutcome,
};
use mci_agent::device_id::{load_or_generate, DeviceIdSource};
use mci_agent::episode_worker;
use mci_agent::health_log::{HealthLog, HealthLogConfig};
use mci_agent::health_summary::summarize_file;
use mci_agent::idle_batch;
use mci_agent::mcp::{serve_stdio, LiveBrainReader, Server};
use mci_agent::page_content::PageContentListener;
use mci_agent::panic_uploader::{self, PanicUploader};
#[cfg(target_os = "macos")]
use mci_agent::pump_supervisor::PumpSupervisor;
use mci_agent::retention_worker;
use mci_agent::runner::{drain_to_log, drain_to_log_with_brain};
#[cfg(unix)]
use mci_agent::user_allowlist::default_user_allowlist_path;
use mci_agent::wall_clock::{format_unix_ms, SystemWallClock};
use mci_brain::{IntegrityError, IntegrityScheduler, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const VERSION: &str = "0.0.3-phase1-cycle2-iter12";

const DEFAULT_HEALTH_SUMMARY_WINDOW_SECONDS: u64 = 3_600; // 1 hour

struct Args {
    device_id_path: PathBuf,
    log_path: PathBuf,
    mode: Mode,
}

enum Mode {
    Help,
    Version,
    /// P3.6.6 + P3.6.7 + P3.10c — wire-frame drainer.
    ///
    /// Health frames always go to JSONL. `OCREvent` frames go to the
    /// `SQLCipher` brain store IFF `MCI_DB_KEY_HEX` is set; otherwise
    /// they fall into the non-health counter (legacy behaviour).
    DrainStdin {
        db_path: PathBuf,
        strict: bool,
    },
    HealthSummary {
        window_seconds: u64,
    },
    /// P3.10b — localhost MCP server over stdio JSON-RPC 2.0.
    /// Resolves `db_path` and the DB key from env at start-up.
    McpServe {
        db_path: PathBuf,
    },
    /// Embed every event that has no row in `event_vectors`.
    ///
    /// Closes the last gap in the semantic-recall path. The store has
    /// always had the pieces (`unembedded_events` to find work,
    /// `set_event_embedding` to write, `vec_search` + `HybridRetriever`
    /// to read), but nothing drove the loop, so `event_vectors` stayed
    /// empty and recall silently degraded to FTS5-only even on a machine
    /// with a working embedder.
    EmbedBackfill {
        db_path: PathBuf,
        batch_size: usize,
    },
    /// Register Hippocampus as an MCP server in Claude Code's settings.
    RegisterMcp,
    /// Cycle 8.29 P0 #3 — empirical "is content reaching the brain
    /// from `source`?" probe. Used by
    /// `OnboardingKit.RealBrowserDetector.checkExtensionInstalled` to
    /// replace the pre-cycle-8.29 manifest-file-presence probe (which
    /// reported `.installed` even when no event ever reached the
    /// brain).
    ///
    /// Opens the SQLCipher brain read-only, counts events whose
    /// `app_bundle_id` belongs to `source`'s bundle set and whose
    /// `ts_us > now - since_seconds`, prints the integer count to
    /// stdout, exits 0. Stderr carries diagnostics. Exit 0 with
    /// count=0 is the "no traffic" signal.
    Stats {
        source: String,
        since_seconds: u64,
        db_path: PathBuf,
    },
}

fn default_device_id_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join(".mci/device-id")
}

fn default_log_path() -> PathBuf {
    HealthLogConfig::default_for_user().path
}

fn page_content_socket_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/page_content.sock")
}

fn default_db_path() -> PathBuf {
    // ~/Library/Application Support/MCI/mci.sqlite per ADR-0008 §1.4.
    // Expand $HOME at run-time (no glob-style ~ expansion in env vars).
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/mci.sqlite")
}

fn default_retention_json_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/retention.json")
}

const DEFAULT_STATS_WINDOW_SECONDS: u64 = 30;

/// Events embedded per batch by `embed-backfill`. Small enough that a
/// slow model reports progress often, large enough to amortize the
/// per-call Core ML overhead.
const DEFAULT_EMBED_BATCH_SIZE: usize = 32;

fn parse_args(argv: &[String]) -> Args {
    // Two-pass: first scan resolves the mode flag, second scan binds
    // mode-specific options. Keeps `--window-seconds 600
    // --health-summary` order-independent.
    let mut device_id_path = default_device_id_path();
    let mut log_path = default_log_path();
    let mut mode_kind = ModeKind::Help;
    let mut window_seconds = DEFAULT_HEALTH_SUMMARY_WINDOW_SECONDS;
    let mut db_path: Option<PathBuf> = None;
    let mut strict = false;
    let mut stats_source = String::new();
    let mut stats_since_seconds = DEFAULT_STATS_WINDOW_SECONDS;
    let mut embed_batch_size = DEFAULT_EMBED_BATCH_SIZE;

    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--device-id-path" if i + 1 < argv.len() => {
                device_id_path = PathBuf::from(&argv[i + 1]);
                i += 1;
            }
            "--log-path" if i + 1 < argv.len() => {
                log_path = PathBuf::from(&argv[i + 1]);
                i += 1;
            }
            "--db-path" if i + 1 < argv.len() => {
                db_path = Some(PathBuf::from(&argv[i + 1]));
                i += 1;
            }
            "--drain-stdin" => mode_kind = ModeKind::DrainStdin,
            "--strict" => strict = true,
            "--health-summary" => mode_kind = ModeKind::HealthSummary,
            "mcp-serve" => mode_kind = ModeKind::McpServe,
            "register-mcp" => mode_kind = ModeKind::RegisterMcp,
            "stats" => mode_kind = ModeKind::Stats,
            "embed-backfill" => mode_kind = ModeKind::EmbedBackfill,
            "--batch-size" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse::<usize>().ok()) {
                    embed_batch_size = v.max(1);
                    i += 1;
                }
            }
            "--source" if i + 1 < argv.len() => {
                stats_source = argv[i + 1].clone();
                i += 1;
            }
            "--since-seconds" if i + 1 < argv.len() => {
                if let Ok(n) = argv[i + 1].parse::<u64>() {
                    if n > 0 {
                        stats_since_seconds = n;
                    }
                }
                i += 1;
            }
            "--window-seconds" if i + 1 < argv.len() => {
                if let Ok(n) = argv[i + 1].parse::<u64>() {
                    if n > 0 {
                        window_seconds = n;
                    }
                }
                i += 1;
            }
            "-h" | "--help" => mode_kind = ModeKind::Help,
            "--version" => mode_kind = ModeKind::Version,
            _ => {
                // Unknown args silent for now (parity with the Swift
                // helper's parser); cycle 3 tightens this.
            }
        }
        i += 1;
    }

    let resolved_db_path = db_path
        .or_else(|| std::env::var_os("MCI_DB_PATH").map(PathBuf::from))
        .unwrap_or_else(default_db_path);
    let mode = match mode_kind {
        ModeKind::Help => Mode::Help,
        ModeKind::Version => Mode::Version,
        ModeKind::DrainStdin => Mode::DrainStdin {
            db_path: resolved_db_path.clone(),
            strict,
        },
        ModeKind::HealthSummary => Mode::HealthSummary { window_seconds },
        ModeKind::McpServe => Mode::McpServe {
            db_path: resolved_db_path.clone(),
        },
        ModeKind::RegisterMcp => Mode::RegisterMcp,
        ModeKind::Stats => Mode::Stats {
            source: stats_source,
            since_seconds: stats_since_seconds,
            db_path: resolved_db_path,
        },
        ModeKind::EmbedBackfill => Mode::EmbedBackfill {
            db_path: resolved_db_path,
            batch_size: embed_batch_size,
        },
    };
    Args {
        device_id_path,
        log_path,
        mode,
    }
}

#[derive(Copy, Clone)]
enum ModeKind {
    Help,
    Version,
    DrainStdin,
    HealthSummary,
    McpServe,
    RegisterMcp,
    Stats,
    EmbedBackfill,
}

fn print_usage() {
    println!(
        "mci-agent {VERSION}\n\
        \n\
        Usage: mci-agent [OPTIONS] MODE\n\
        \n\
        Modes:\n\
        \x20 --drain-stdin              read wire frames from stdin and write JSONL\n\
        \x20 --health-summary           print one-line summary of helper-health.jsonl\n\
        \x20 mcp-serve                  run the localhost MCP server (stdio JSON-RPC 2.0)\n\
        \x20 register-mcp               register Hippocampus in Claude Code's MCP settings\n\
        \x20 embed-backfill             embed every event that has no vector yet, so\n\
        \x20                            mci_recall runs hybrid instead of keyword-only.\n\
        \x20                            Needs the ArcticEmbedS model; refuses without it.\n\
        \x20 stats --source SRC         count PageContentEvents from SRC in the last window\n\
        \x20                            (SRC = safari | chromium-native-host). Cycle 8.29\n\
        \x20                            P0 #3 — empirical onboarding probe.\n\
        \x20 --version                  print version and exit\n\
        \x20 -h, --help                 print this and exit\n\
        \n\
        Options:\n\
        \x20 --device-id-path PATH      default ~/.mci/device-id\n\
        \x20 --log-path PATH            default ~/Library/Logs/MCI/helper-health.jsonl\n\
        \x20 --db-path PATH             default $MCI_DB_PATH or\n\
        \x20                            ~/Library/Application Support/MCI/mci.sqlite\n\
        \x20 --window-seconds N         (with --health-summary) aggregation window. Default 3600.\n\
        \x20 --since-seconds N          (with stats) lookback window. Default 30.\n\
        \x20 --batch-size N             (with embed-backfill) events per batch. Default 32.\n\
        \x20 --strict                   (with --drain-stdin) exit non-zero if brain cannot\n\
        \x20                            be opened, instead of falling back to health-only.\n\
        \n\
        Env:\n\
        \x20 MCI_DB_PATH                brain SQLCipher path (--drain-stdin + mcp-serve)\n\
        \x20 MCI_DB_KEY_HEX             64-char hex SQLCipher key (TEMP — see\n\
        \x20                            docs/claude-code-mcp-setup.md; Keychain integration\n\
        \x20                            lands in Phase 4 onboarding). With --drain-stdin,\n\
        \x20                            absence falls back to health-only drain (no brain\n\
        \x20                            writes); presence routes OCREvents through the\n\
        \x20                            P3.6.6 wire-to-brain ingest pump.\n\
        \x20 MCI_EMBEDDER_DISABLED      set to 1 to force lexical-only recall in mcp-serve\n\
        \x20                            (skips HybridRetriever even if an embedder is\n\
        \x20                            available). Default fusion weights per ADR-0010:\n\
        \x20                            w_sem=0.5, w_lex=0.3, w_rec=0.15, w_src=0.05.\n\
        \x20 MCI_CRASH_REPORT_URL       HTTP endpoint for crash report uploads (e.g.\n\
        \x20                            http://127.0.0.1:3100/v1/crash-report).\n\
        \x20 MCI_CRASH_REPORT_OPTED_IN  set to 1 to enable crash report uploads.\n\
        \x20                            BOTH URL + OPTED_IN required. Default: OFF.\n"
    );
}

#[allow(clippy::too_many_lines)]
#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    mci_agent::panic_hook::install();

    // Best-effort drain of prior crash reports. Spawned early so it
    // runs in the background while the main mode proceeds. Default
    // OFF — both MCI_CRASH_REPORT_URL and MCI_CRASH_REPORT_OPTED_IN=1
    // must be set.
    if let Some(uploader) = PanicUploader::from_env() {
        let panic_log = mci_agent::panic_hook::default_panic_log_path();
        tokio::spawn(async move {
            match panic_uploader::drain_pending(&uploader, &panic_log).await {
                Ok(0) => {}
                Ok(n) => eprintln!("mci-agent: uploaded {n} crash report(s)"),
                Err(e) => eprintln!("mci-agent: crash report upload error: {e}"),
            }
        });
    }

    let raw_argv: Vec<String> = std::env::args().collect();
    let args = parse_args(&raw_argv);

    match args.mode {
        Mode::Version => {
            println!("mci-agent {VERSION}");
            ExitCode::SUCCESS
        }
        Mode::Help => {
            print_usage();
            ExitCode::SUCCESS
        }
        Mode::DrainStdin { db_path, strict } => {
            let (device_id, source) = match load_or_generate(args.device_id_path.clone()).await {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("mci-agent: device-id load failed: {e}");
                    return ExitCode::from(2);
                }
            };
            if matches!(source, DeviceIdSource::GeneratedAndPersisted) {
                eprintln!(
                    "mci-agent: generated new device id at {}",
                    args.device_id_path.display()
                );
            }

            let log = HealthLog::new(HealthLogConfig {
                path: args.log_path.clone(),
                max_bytes: 10 * 1024 * 1024,
            });
            let clock = SystemWallClock;
            let mut stdin = tokio::io::stdin();

            // V2-MCP-2 — boot the MCP-client registry from
            // `~/Library/Application Support/MCI/mcp-servers.toml`.
            // ADR-0001 §amendment 2026-05-31. Construction-graph
            // wiring per audit rows #8 + #9: the boot helper builds
            // the registry, the agent holds it for the rest of the
            // process lifetime, and V2-MCP-3 (cycle 8.30, Director-
            // Brain) picks it up. A missing config file is the
            // expected fresh-install state; failures are logged and
            // never abort startup. Runs BEFORE the brain-key check
            // so the registry status appears even if the brain is
            // not yet keyed.
            let mcp_client_boot = {
                let boot = mci_agent::mcp_client_supervisor::boot_default().await;
                eprintln!("{}", boot.log_line());
                boot
            };
            // V2-MCP-3 — handle to the registry so the aggregator can
            // be constructed inside the brain-store-OK arm below
            // alongside the deep-hook pump supervisor. Held here so
            // the registry survives if any later branch drops the
            // `mcp_client_boot` value.
            let mcp_registry = Arc::clone(&mcp_client_boot.registry);

            // P3.10c + P3.8 — open the brain store IFF `MCI_DB_KEY_HEX`
            // is set. The store is shared between:
            //   1. BrainPump (ingest: OCREvent → events table)
            //   2. idle-batch worker (embed: events → event_vectors)
            //
            // Shutdown channel coordinates both halves on SIGINT/SIGTERM.
            let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

            // V2-P5+ — the sync BERT NER backend, loaded once (lazily,
            // only when the store opens below) and SHARED by Arc across
            // both ingest pumps (main drain + page-content listener) so the
            // ~220 MB bert-base-NER working set is resident once, not twice.
            // None when the model is absent (opt-in download) or non-macOS.
            let mut ner_sync_backend: Option<Arc<dyn mci_brain::NerBackend>> = None;

            let brain_pump: Option<(BrainPump, Arc<SqlCipherBrainStore>)> = match resolve_key_hex()
            {
                Some(key_hex) => {
                    match decode_hex32(&key_hex) {
                        Some(key_bytes) => {
                            if let Some(parent) = db_path.parent() {
                                if !parent.exists() {
                                    if let Err(e) = std::fs::create_dir_all(parent) {
                                        eprintln!(
                                            "mci-agent: create_dir_all({}): {e}",
                                            parent.display()
                                        );
                                        return ExitCode::from(20);
                                    }
                                }
                            }
                            let key = DbKey::from_bytes(key_bytes);
                            // Cycle 8.44 audit — breakage risk #3 wiring #3:
                            // acquire the run-lock BEFORE opening the store
                            // so a live sibling instance aborts us early
                            // (ADR-0008 §1.4 "one file, one writer" — two
                            // writers on the same SQLCipher DB corrupt the
                            // store). A stale lock (unclean prior shutdown)
                            // triggers an extra integrity check after open.
                            let lock_path = default_lock_path();
                            let unclean_prior_shutdown = match acquire_lock(&lock_path) {
                                Ok(LockAcquireOutcome::CleanBoot) => false,
                                Ok(LockAcquireOutcome::UncleanShutdown { stale_pid }) => {
                                    eprintln!(
                                        "mci-agent: unclean prior shutdown detected (stale pid {stale_pid}) — will run extra integrity_check",
                                    );
                                    true
                                }
                                Ok(LockAcquireOutcome::AnotherInstanceRunning { live_pid }) => {
                                    eprintln!(
                                        "mci-agent: another mci-agent instance is running (pid {live_pid}) — refusing to open store (ADR-0008 §1.4 one-writer invariant)",
                                    );
                                    return ExitCode::from(21);
                                }
                                Err(e) => {
                                    eprintln!("mci-agent: crash_recovery::acquire_lock: {e}");
                                    // Treat lock-file I/O failure as unclean
                                    // — safer to run the extra check than
                                    // to skip it.
                                    true
                                }
                            };
                            match SqlCipherBrainStore::new(&db_path, &key) {
                                Ok(store) => {
                                    let store = Arc::new(store);
                                    // Cycle 8.44 audit — breakage risk #3
                                    // wiring #1: verify SQLCipher integrity
                                    // BEFORE serving any read/write. On
                                    // failure the agent refuses to spawn
                                    // ingest pumps or the MCP surface.
                                    if let Err(e) = store.verify_integrity_on_boot() {
                                        match &e {
                                            IntegrityError::Corrupted(rows) => {
                                                eprintln!(
                                                    "mci-agent: brain integrity_check FAILED — refusing to serve. rows={rows:?}",
                                                );
                                            }
                                            IntegrityError::Backend(msg) => {
                                                eprintln!(
                                                    "mci-agent: brain integrity_check backend error — refusing to serve. err={msg}",
                                                );
                                            }
                                        }
                                        // Emit a structured helper_health-adjacent
                                        // line so the launchd log picks it up.
                                        eprintln!(
                                            "mci-agent: helper_health integrity_check_failed=true",
                                        );
                                        // Release the lock so a follow-up
                                        // repair boot doesn't false-positive
                                        // as "another instance running".
                                        let _ = release_lock(&lock_path);
                                        return ExitCode::from(22);
                                    }
                                    // Post-crash-recovery re-check (wiring #3):
                                    // an unclean prior shutdown MAY have
                                    // left the DB in a torn state that a
                                    // single boot check misses if pages
                                    // were half-written. Run a second pass;
                                    // treat any failure the same as boot.
                                    if unclean_prior_shutdown {
                                        if let Err(e) = store.verify_integrity_on_boot() {
                                            eprintln!(
                                                "mci-agent: post-crash integrity_check FAILED — refusing to serve. err={e}",
                                            );
                                            eprintln!(
                                                "mci-agent: helper_health integrity_check_failed=true (post-crash)",
                                            );
                                            let _ = release_lock(&lock_path);
                                            return ExitCode::from(22);
                                        }
                                    }
                                    let embedder = load_embedder_backend();
                                    // V2-P5+ construction-graph wire: build
                                    // the sync BERT NER backend and inject it
                                    // into the ingest pump. THIS is the
                                    // production caller `git grep
                                    // NerTier2Backend` must surface on the
                                    // live ingest path (per
                                    // [[project-v2p1-unit-tests-passed-but-never-wired]]
                                    // — without this the backend is dead code).
                                    ner_sync_backend = load_ner_sync_backend();
                                    let base_pump = BrainPump::new(
                                        Arc::clone(&store) as Arc<dyn mci_brain::BrainStore>,
                                        None,
                                    );
                                    let pump = match &ner_sync_backend {
                                        Some(b) => base_pump.with_ner_sync(Arc::clone(b)),
                                        None => base_pump,
                                    };
                                    eprintln!(
                                        "mci-agent: brain ingest + idle-batch enabled. db={} embedder={} sync_ner={}",
                                        db_path.display(),
                                        if embedder.1 { "CoreML" } else { "zero-fallback" },
                                        if pump.ner_sync_enabled() { "bert-base-NER/cpu_only" } else { "off" },
                                    );

                                    let worker_store = Arc::clone(&store);
                                    // Clone the embedder Arc BEFORE moving
                                    // it into the idle-batch task — the
                                    // V2-P10 pump supervisor shares the
                                    // same embedder for the deep-hook
                                    // Allow path.
                                    let supervisor_embedder = Arc::clone(&embedder.0);
                                    let worker_embedder = embedder.0;
                                    let worker_shutdown = shutdown_rx.clone();
                                    tokio::spawn(async move {
                                        match idle_batch::run_idle_batch_worker(
                                            worker_store,
                                            worker_embedder,
                                            32,
                                            std::time::Duration::from_secs(5),
                                            worker_shutdown,
                                        )
                                        .await
                                        {
                                            Ok(stats) => {
                                                eprintln!(
                                                    "mci-agent: idle-batch exited. embedded={} batches={} embed_errors={} store_errors={}",
                                                    stats.events_embedded, stats.batches_run,
                                                    stats.embed_errors, stats.store_errors,
                                                );
                                            }
                                            Err(e) => {
                                                eprintln!("mci-agent: idle-batch error: {e}");
                                            }
                                        }
                                    });

                                    let ep_store = Arc::clone(&store);
                                    let ep_shutdown = shutdown_rx.clone();
                                    tokio::spawn(async move {
                                        let segmenter = Arc::new(
                                            mci_brain::episode_segmenter::HeuristicEpisodeSegmenter::new(),
                                        );
                                        match episode_worker::run_episode_worker(
                                            ep_store,
                                            segmenter,
                                            64,
                                            std::time::Duration::from_secs(5),
                                            ep_shutdown,
                                        )
                                        .await
                                        {
                                            Ok(stats) => {
                                                eprintln!(
                                                    "mci-agent: episode-worker exited. assigned={} created={} batches={}",
                                                    stats.events_assigned, stats.episodes_created,
                                                    stats.batches_run,
                                                );
                                            }
                                            Err(e) => {
                                                eprintln!("mci-agent: episode-worker error: {e}");
                                            }
                                        }
                                    });

                                    // V2-P6 construction-graph wire: the
                                    // AliasResolver idle worker. THIS is the
                                    // production caller `git grep
                                    // run_alias_resolver_worker` must surface
                                    // on the live agent path — without it the
                                    // resolver is dead code (the
                                    // [[project-v2p1-unit-tests-passed-but-never-wired]]
                                    // lesson). Runs off the hot path: a cheap
                                    // watermark gates the full resolve, so a
                                    // steady-state session does one watermark
                                    // query per interval and no more.
                                    let alias_store = Arc::clone(&store);
                                    let alias_shutdown = shutdown_rx.clone();
                                    tokio::spawn(async move {
                                        match alias_resolver_worker::run_alias_resolver_worker(
                                            alias_store,
                                            std::time::Duration::from_secs(30),
                                            alias_shutdown,
                                        )
                                        .await
                                        {
                                            Ok(stats) => {
                                                eprintln!(
                                                    "mci-agent: alias-resolver exited. cycles={} memberships_written={} memberships_pruned={} identities_last={} store_errors={}",
                                                    stats.cycles_run, stats.memberships_written,
                                                    stats.memberships_pruned,
                                                    stats.identities_last, stats.store_errors,
                                                );
                                            }
                                            Err(e) => {
                                                eprintln!("mci-agent: alias-resolver error: {e}");
                                            }
                                        }
                                    });

                                    // V2-P6 construction-graph wire: the
                                    // episode-edge Consolidator idle worker
                                    // — the LAST graph-construction step
                                    // before the Phase-6 dot-connect demo.
                                    // THIS is the production caller `git grep
                                    // run_consolidator_worker` must surface on
                                    // the live agent path; without it the
                                    // consolidator is dead code (the
                                    // [[project-v2p1-unit-tests-passed-but-never-wired]]
                                    // lesson). Runs AFTER identities resolve
                                    // (it reads `entity_identities`), off the
                                    // hot path: a cheap watermark gates the
                                    // derive, so a steady-state session does
                                    // one watermark query per interval.
                                    let consolidator_store = Arc::clone(&store);
                                    let consolidator_shutdown = shutdown_rx.clone();
                                    tokio::spawn(async move {
                                        match consolidator_worker::run_consolidator_worker(
                                            consolidator_store,
                                            std::time::Duration::from_secs(60),
                                            consolidator_shutdown,
                                        )
                                        .await
                                        {
                                            Ok(stats) => {
                                                eprintln!(
                                                    "mci-agent: consolidator exited. cycles={} edges_written={} edges_pruned={} edges_derived_last={} store_errors={}",
                                                    stats.cycles_run, stats.edges_written,
                                                    stats.edges_pruned, stats.edges_derived_last,
                                                    stats.store_errors,
                                                );
                                            }
                                            Err(e) => {
                                                eprintln!("mci-agent: consolidator error: {e}");
                                            }
                                        }
                                    });

                                    let retention_store = Arc::clone(&store);
                                    let retention_shutdown = shutdown_rx.clone();
                                    let retention_json = default_retention_json_path();
                                    tokio::spawn(async move {
                                        match retention_worker::run_retention_worker(
                                            retention_store,
                                            retention_json,
                                            std::time::Duration::from_secs(86_400),
                                            retention_shutdown,
                                        )
                                        .await
                                        {
                                            Ok(stats) => {
                                                eprintln!(
                                                    "mci-agent: retention worker exited. cycles={} events_deleted={} vectors_deleted={} episodes_deleted={} errors={}",
                                                    stats.cycles_run, stats.total_events_deleted,
                                                    stats.total_vectors_deleted, stats.total_episodes_deleted,
                                                    stats.cycle_errors,
                                                );
                                            }
                                            Err(e) => {
                                                eprintln!("mci-agent: retention worker error: {e}");
                                            }
                                        }
                                    });

                                    // ADR-0028 — daily brief worker. Fires at
                                    // 06:00 local. Disabled-idle if the Qwen3
                                    // model is not present OR
                                    // MCI_BRIEFS_DISABLED=1.
                                    spawn_brief_worker(Arc::clone(&store), shutdown_rx.clone());

                                    // V2-P5 — Tier 2 Qwen NER idle-batch
                                    // worker (FORK 8 = A; CTO Phase 6 PR 9).
                                    // Reuses the brief author's Qwen3-1.7B
                                    // Core ML model when present on disk.
                                    // Polls
                                    // `SqlCipherBrainStore::events_pending_tier2`
                                    // for events lacking the
                                    // (extractor_status,
                                    // qwen_tier2_processed) sentinel
                                    // mention, runs each through a
                                    // `Tier2Extractor` (cascade-marker SKIP
                                    // + V2-P4 token-REDACT downstream SKIP
                                    // filters applied above the Qwen
                                    // backend), writes
                                    // (extractor_kind = "qwen") mentions to
                                    // `entity_mentions`. Disabled-idle when
                                    // the Qwen .mlmodelc is not downloaded
                                    // (same UX as brief worker); V2-P4
                                    // Tier 1 regex mentions continue on the
                                    // hot path regardless. Construction-
                                    // graph wiring at integration site —
                                    // per
                                    // [[project-v2p1-unit-tests-passed-but-never-wired]]
                                    // this is the load-bearing wire.
                                    spawn_tier2_worker(Arc::clone(&store), shutdown_rx.clone());

                                    // V2-P10 — deep-hook pump supervisor.
                                    // Reads ~/Library/Application Support/MCI/
                                    // user-allowlist.toml, probes FDA per
                                    // bundle, starts MessagesPluginPump +
                                    // MailIngestPump for any allowlist row
                                    // with capture_enabled=true AND
                                    // deep_hook_enabled=true. Driver-CSO
                                    // audit row 7: construction-graph wiring
                                    // at integration site. Per
                                    // [[project-v2p1-unit-tests-passed-but-never-wired]]
                                    // this is the load-bearing wire — without
                                    // it the V2-P7 + V2-P8 cascade-equivalents
                                    // never see production input.
                                    spawn_pump_supervisor(
                                        Arc::clone(&store),
                                        supervisor_embedder,
                                        shutdown_rx.clone(),
                                    );

                                    // V2-MCP-3 — MCP aggregator.
                                    // Consumes the registry built by
                                    // `mcp_client_supervisor::boot_default()`
                                    // above; runs the hybrid materialize-
                                    // or-catalog policy against each
                                    // registered server's resources.
                                    // Persists Events with
                                    // `app_bundle_id = "mcp:<name>"` so
                                    // V2-P12 (Phase 7 chat surface) can
                                    // structurally apply prompt-injection
                                    // mitigation per CRS Fork-6 = A.
                                    // Driver-CSO audit row 7
                                    // (construction-graph wiring at
                                    // integration site) — per
                                    // [[project-v2p1-unit-tests-passed-but-never-wired]]
                                    // this is the load-bearing wire for
                                    // V2-MCP-3: without it the
                                    // aggregator module would never run
                                    // against production input.
                                    spawn_mcp_aggregator(
                                        Arc::clone(&mcp_registry),
                                        Arc::clone(&store) as Arc<dyn mci_brain::BrainStore>,
                                        None,
                                        shutdown_rx.clone(),
                                    );

                                    Some((pump, store))
                                }
                                Err(e) => {
                                    eprintln!("\n========================================================");
                                    eprintln!(
                                        "WARNING: BRAIN OPEN FAILED — CAPTURE IS NOT BEING SAVED"
                                    );
                                    eprintln!(
                                        "========================================================"
                                    );
                                    eprintln!("  Error: {e}");
                                    eprintln!("  Path:  {}", db_path.display());
                                    eprintln!();
                                    eprintln!(
                                        "  Hippocampus is running but your screen activity is NOT"
                                    );
                                    eprintln!("  being stored in the brain. Possible causes:");
                                    eprintln!("    * Stale brain encrypted with old key");
                                    eprintln!("    * Wrong MCI_DB_KEY_HEX env var");
                                    eprintln!("    * Permissions issue on brain file");
                                    eprintln!();
                                    eprintln!("  To reset: quit Hippocampus.app, delete");
                                    eprintln!(
                                        "  ~/Library/Application Support/MCI/mci.sqlite + dev.key,"
                                    );
                                    eprintln!("  then relaunch the app to start fresh.");
                                    eprintln!("========================================================\n");
                                    if strict {
                                        return ExitCode::from(21);
                                    }
                                    None
                                }
                            }
                        }
                        None => {
                            eprintln!(
                                "mci-agent: brain key must be 64 hex chars (32 bytes). Falling back to health-only drain."
                            );
                            if strict {
                                return ExitCode::from(22);
                            }
                            None
                        }
                    }
                }
                None => {
                    eprintln!(
                            "mci-agent: no brain key found (MCI_DB_KEY_HEX not set, no dev.key). \
                             Health-only drain. Set the key or launch Hippocampus.app to initialize."
                        );
                    if strict {
                        return ExitCode::from(23);
                    }
                    None
                }
            };

            // Cycle 8.44 audit — breakage risk #3 wiring #2: start the
            // weekly background integrity scheduler. Handle lives at
            // this outer scope so it survives past the brain-open
            // match arm; dropped at end-of-DrainStdin, which joins the
            // background thread (mpsc shutdown signal → recv_timeout
            // returns Disconnected → thread exits). Only meaningful
            // when brain_pump is Some — otherwise the store isn't
            // open and there's nothing to scan.
            let _integrity_scheduler = brain_pump
                .as_ref()
                .map(|(_, store)| IntegrityScheduler::start_weekly(Arc::clone(store)));

            // Page-content socket listener — accepts PageContentEvent
            // wire frames from the native messaging host (Chromium) and
            // the container-app Safari inbox reader. Shares the store
            // with the main drain loop via a second BrainPump.
            let _pc_listener_task = if let Some((_, store)) = brain_pump.as_ref() {
                let sock = page_content_socket_path();
                match PageContentListener::bind(&sock) {
                    Ok((listener, unix_listener)) => {
                        // Page-content events get the same sync NER tier as
                        // the OCR drain — share the one resident backend Arc.
                        let pc_base = BrainPump::new(
                            Arc::clone(store) as Arc<dyn mci_brain::BrainStore>,
                            None,
                        );
                        let pc_pump_inner = match &ner_sync_backend {
                            Some(b) => pc_base.with_ner_sync(Arc::clone(b)),
                            None => pc_base,
                        };
                        let pc_pump: Arc<dyn BrainIngestor> = Arc::new(pc_pump_inner);
                        eprintln!("mci-agent: page-content listener on {}", sock.display(),);
                        Some(tokio::spawn(async move {
                            listener.run(unix_listener, pc_pump).await;
                        }))
                    }
                    Err(e) => {
                        eprintln!("mci-agent: page-content listener bind failed: {e}");
                        None
                    }
                }
            } else {
                None
            };

            let drain_result = match brain_pump.as_ref() {
                Some((pump, _store)) => {
                    drain_to_log_with_brain(&mut stdin, &log, &clock, &device_id, pump).await
                }
                None => drain_to_log(&mut stdin, &log, &clock, &device_id).await,
            };

            // Signal shutdown to idle-batch + episode workers.
            let _ = shutdown_tx.send(true);

            // Cycle 8.44 audit — breakage risk #3 wiring #3: release
            // the run-lock on clean shutdown. Absence of the file on
            // next boot signals a clean prior exit; presence with a
            // stale PID triggers the extra integrity check.
            if brain_pump.is_some() {
                if let Err(e) = release_lock(&default_lock_path()) {
                    eprintln!("mci-agent: crash_recovery::release_lock: {e}");
                }
            }
            match drain_result {
                Ok(stats) => {
                    eprintln!(
                        "mci-agent: drained {} frame(s); {} logged, {} non-health, {} to brain",
                        stats.frames_seen,
                        stats.frames_logged,
                        stats.frames_non_health,
                        stats.frames_to_brain
                    );
                    eprintln!("mci-agent: log = {}", args.log_path.display());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("mci-agent: drain error: {e}");
                    ExitCode::from(3)
                }
            }
        }
        Mode::RegisterMcp => match register_mcp() {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("mci-agent register-mcp: {e}");
                ExitCode::from(14)
            }
        },
        Mode::EmbedBackfill {
            db_path,
            batch_size,
        } => match run_embed_backfill(&db_path, batch_size) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::McpServe { db_path } => match run_mcp_serve(db_path).await {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::Stats {
            source,
            since_seconds,
            db_path,
        } => run_stats(&source, since_seconds, &db_path),
        Mode::HealthSummary { window_seconds } => {
            // Compute the cutoff RFC-3339 string once. The summary
            // comparator does a lexicographic compare against each
            // record's wall_ts; both are produced by the same
            // `format_unix_ms` so the compare is chronological.
            let now_unix_ms: u128 = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or(std::time::Duration::ZERO)
                .as_millis();
            let window_ms = u128::from(window_seconds).saturating_mul(1000);
            let cutoff_ts = format_unix_ms(now_unix_ms.saturating_sub(window_ms));

            match summarize_file(&args.log_path, cutoff_ts).await {
                Ok(summary) => {
                    println!("{}", summary.to_human_line());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("mci-agent: health-summary error: {e}");
                    ExitCode::from(4)
                }
            }
        }
    }
}

/// Bundle ids that count toward each `--source` value of `mci-agent
/// stats`. Source of truth for the `RealBrowserDetector` probe.
///
/// `chromium-native-host` covers every Chromium-family browser the
/// onboarding's `BrowserExtensionViewModel` can write a host manifest
/// for. `firefox` is included because `browser_bundle_id` (in
/// `brain_ingest.rs`) maps the Firefox `source_browser` to
/// `org.mozilla.firefox`; if a Gecko-family extension ever ships, the
/// same probe row continues to function.
fn bundle_ids_for_source(source: &str) -> Option<Vec<&'static str>> {
    match source {
        "safari" => Some(vec!["com.apple.Safari"]),
        "chromium-native-host" => Some(vec![
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
        ]),
        _ => None,
    }
}

/// Cycle 8.29 P0 #3 — empirical delivery probe.
///
/// Opens the brain SQLCipher store **read-only** (per
/// `SqlCipherBrainStore::open_readonly`, ADR-0017 §5), aggregates events
/// inserted since `now - since_seconds` whose `app_bundle_id` belongs to
/// the bundle set associated with `source`, prints the integer total to
/// stdout, exits 0.
///
/// Exit codes:
///   0 — query ran (count is on stdout; may be zero)
///   2 — `source` unknown
///   3 — brain key missing (`MCI_DB_KEY_HEX` unset AND no dev.key file)
///   4 — brain open / query failure (the probe surface from the
///       onboarding's `RealBrowserDetector` falls back to `.unknown`
///       on any non-zero exit)
fn run_stats(source: &str, since_seconds: u64, db_path: &std::path::Path) -> ExitCode {
    let Some(bundles) = bundle_ids_for_source(source) else {
        eprintln!(
            "mci-agent stats: unknown source '{source}'. Expected: safari | chromium-native-host"
        );
        return ExitCode::from(2);
    };

    let Some(key_hex) = resolve_key_hex() else {
        eprintln!(
            "mci-agent stats: brain key unavailable (set MCI_DB_KEY_HEX or write\n\
             ~/Library/Application Support/MCI/dev.key with a 64-char hex key)"
        );
        return ExitCode::from(3);
    };
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent stats: brain key is not a 32-byte hex string");
        return ExitCode::from(3);
    };
    let key = DbKey::from_bytes(key_bytes);

    let store = match SqlCipherBrainStore::open_readonly(db_path, &key) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("mci-agent stats: open_readonly {}: {e}", db_path.display());
            return ExitCode::from(4);
        }
    };

    let now_us: u64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX))
        .unwrap_or(0);
    let window_us = since_seconds.saturating_mul(1_000_000);
    let since_us = now_us.saturating_sub(window_us);

    // Reuse `observed_apps` — returns counts grouped by `app_bundle_id`
    // for events with `ts_us >= since_us`. We sum the rows whose bundle
    // is in our `bundles` set. The 4096 limit is a safety cap; in
    // practice the brain has < 100 distinct bundles even on a fully-
    // populated install.
    let rows = match store.observed_apps(4096, Some(since_us)) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("mci-agent stats: observed_apps: {e}");
            return ExitCode::from(4);
        }
    };
    let total: u64 = rows
        .into_iter()
        .filter(|(app, _)| bundles.iter().any(|b| *b == app))
        .map(|(_, n)| n)
        .sum();

    println!("{total}");
    ExitCode::SUCCESS
}

/// Read the dev.key file (64-char hex) from
/// `~/Library/Application Support/MCI/dev.key`.
fn read_dev_key_hex() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let path = PathBuf::from(home).join("Library/Application Support/MCI/dev.key");
    std::fs::read_to_string(&path)
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit()))
}

/// Resolve the brain key: env var first, then dev.key file.
fn resolve_key_hex() -> Option<String> {
    std::env::var("MCI_DB_KEY_HEX")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(read_dev_key_hex)
}

/// Register Hippocampus as an MCP server in Claude Code's MCP config
/// (`~/.claude.json`). Merges the `hippocampus` entry under
/// `mcpServers` without clobbering other servers. Includes an `env`
/// block with `MCI_DB_KEY_HEX` when the dev.key file exists.
fn register_mcp() -> Result<(), String> {
    let exe =
        std::env::current_exe().map_err(|e| format!("cannot resolve own binary path: {e}"))?;
    let exe_str = exe.to_str().ok_or("binary path is not valid UTF-8")?;

    let home = std::env::var("HOME").map_err(|_| "HOME not set")?;
    let settings_path = PathBuf::from(&home).join(".claude.json");

    let mut root: serde_json::Map<String, serde_json::Value> = if settings_path.exists() {
        let content = std::fs::read_to_string(&settings_path)
            .map_err(|e| format!("read {}: {e}", settings_path.display()))?;
        serde_json::from_str(&content)
            .map_err(|e| format!("parse {}: {e}", settings_path.display()))?
    } else {
        serde_json::Map::new()
    };

    let key_path = PathBuf::from(&home).join("Library/Application Support/MCI/dev.key");
    let key_hex: Option<String> = std::fs::read_to_string(&key_path)
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit()));

    let mut hippocampus_entry = serde_json::json!({
        "type": "stdio",
        "command": exe_str,
        "args": ["mcp-serve"]
    });
    if let Some(k) = &key_hex {
        hippocampus_entry["env"] = serde_json::json!({"MCI_DB_KEY_HEX": k});
    } else {
        eprintln!(
            "Note: brain key not yet generated at {}. Launch Hippocampus.app once to initialize, then re-run `mci-agent register-mcp`.",
            key_path.display()
        );
    }

    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| serde_json::json!({}));
    if let Some(obj) = servers.as_object_mut() {
        if obj.contains_key("hippocampus") {
            let existing = &obj["hippocampus"];
            if existing.get("command").and_then(|v| v.as_str()) == Some(exe_str)
                && existing.get("env") == hippocampus_entry.get("env")
            {
                println!(
                    "Hippocampus already registered with Claude Code (path and key unchanged)."
                );
                return Ok(());
            }
        }
        obj.insert("hippocampus".to_owned(), hippocampus_entry);
    }

    let output =
        serde_json::to_string_pretty(&root).map_err(|e| format!("serialize settings: {e}"))?;
    std::fs::write(&settings_path, output.as_bytes())
        .map_err(|e| format!("write {}: {e}", settings_path.display()))?;

    println!("Hippocampus registered with Claude Code. Restart Claude Code to connect.");
    Ok(())
}

/// Resolve the `SQLCipher` key from `MCI_DB_KEY_HEX`, open the brain,
/// optionally construct the embedder for hybrid recall, build the
/// [`Server`], and run [`serve_stdio`].
///
/// # Embedder resolution (P3.10d)
///
/// - `MCI_EMBEDDER_DISABLED=1` → force lexical-only mode.
/// - Otherwise, attempt to construct the production `ArcticEmbedSEmbedder`
///   via the Core ML backend. If construction fails (no `.mlpackage`
///   bundled — expected until P3.8 ships the model), log a warning and
///   fall back to `Embedder=None`. The server still boots with FTS5-only
///   recall; when embeddings exist in `event_vectors` AND a working
///   embedder is constructed, the same code path lights up full hybrid
///   (ADR-0010 min-max CC fusion) automatically.
///
/// `MCI_DB_KEY_HEX` is the **interim** key-resolution mechanism for
/// P3.10b. Phase-4 onboarding wires the Keychain-backed `KeyWrap`
/// surface; the env-var path stays as a developer / CI fallback. See
/// `docs/claude-code-mcp-setup.md` for the full operator note.
async fn run_mcp_serve(db_path: PathBuf) -> Result<(), u8> {
    let Some(key_hex) = resolve_key_hex() else {
        eprintln!(
            "mci-agent mcp-serve: MCI_DB_KEY_HEX not set and no dev.key found at \
             ~/Library/Application Support/MCI/dev.key. \
             Launch Hippocampus.app once to initialize, or see docs/claude-code-mcp-setup.md."
        );
        return Err(10);
    };
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!(
            "mci-agent mcp-serve: MCI_DB_KEY_HEX must be 64 lowercase-or-uppercase \
             hex characters (32 bytes)."
        );
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    // P3.8 / CRS G3 fix: wire the query-side embedder so `mci_recall` runs
    // full ADR-0010 hybrid (FTS5 + semantic min-max CC), not lexical-only.
    // Mirrors the ingest-side `load_embedder_backend()` pattern (see
    // `run` path around line 391) but constructs `new_query` (adds the
    // model-card query prefix per ADR-0011 §3) instead of `new_document`.
    // Core ML compute units stay pinned to `cpu_only` inside
    // `load_backend_or_fallback` — the "all" tier is the latency trap
    // ([[reference-coreml-computeunits-all-trap]]).
    let embedder: Option<Arc<dyn mci_brain::Embedder>> =
        if std::env::var("MCI_EMBEDDER_DISABLED").as_deref() == Ok("1") {
            eprintln!(
                "mci-agent mcp-serve: embedder disabled (MCI_EMBEDDER_DISABLED=1). \
                 Lexical-only recall."
            );
            None
        } else {
            let (emb, is_real) = load_query_embedder_backend();
            if is_real {
                Some(emb)
            } else {
                // Zero-vector / non-macOS fallback: hybrid retriever would
                // just add noise (every doc "matches" the zero query with
                // cosine 0), so stay on FTS5-only until a real backend is
                // bundled.
                eprintln!(
                    "mci-agent mcp-serve: query embedder unavailable \
                     (no ArcticEmbedS model bundled or non-macOS). \
                     Lexical-only recall."
                );
                None
            }
        };

    let recall_mode = if embedder.is_some() {
        "hybrid (FTS5 + semantic, ADR-0010 min-max CC)"
    } else {
        "lexical-only (FTS5)"
    };

    let reader = match LiveBrainReader::open_with_embedder(&db_path, &key, embedder) {
        Ok(r) => r,
        Err(e) => {
            eprintln!(
                "mci-agent mcp-serve: open brain at {}: {e}",
                db_path.display()
            );
            return Err(12);
        }
    };
    let server = Arc::new(Server::new(Arc::new(reader)));
    eprintln!(
        "mci-agent mcp-serve: ready on stdio. db={} recall={recall_mode}",
        db_path.display()
    );
    let stdout = tokio::io::stdout();
    if let Err(e) = serve_stdio(server, stdout).await {
        eprintln!("mci-agent mcp-serve: stdio loop error: {e}");
        return Err(13);
    }
    Ok(())
}

/// Embed every event that has no vector yet.
///
/// This is the loop that was missing. `event_vectors` stayed empty
/// because nothing ever called `set_event_embedding`, which meant
/// `HybridRetriever` had no semantic side to fuse and `mci_recall`
/// quietly degraded to FTS5-only even where a real embedder existed.
///
/// Opened read-write via `SqlCipherBrainStore::new` (every other read
/// surface uses `open_readonly`; this one has to write).
///
/// Refuses to run without a real embedder rather than writing zero
/// vectors, because a zero vector matches every query at cosine 0 and
/// would poison recall in a way that looks like a ranking bug.
fn run_embed_backfill(db_path: &std::path::Path, batch_size: usize) -> Result<(), u8> {
    let Some(key_hex) = resolve_key_hex() else {
        eprintln!(
            "mci-agent embed-backfill: MCI_DB_KEY_HEX not set and no dev.key found. \
             See docs/claude-code-mcp-setup.md."
        );
        return Err(10);
    };
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent embed-backfill: MCI_DB_KEY_HEX must be 64 hex characters.");
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    let (embedder, is_real) = load_embedder_backend();
    if !is_real {
        eprintln!(
            "mci-agent embed-backfill: no real embedder available, refusing to run.\n\
             \n\
             Semantic recall needs the ArcticEmbedS Core ML model, which is ~33 MB\n\
             and is not checked into the repository. Build it with:\n\
             \n\
               python3 -m venv .venv-ml && source .venv-ml/bin/activate\n\
               pip install -r scripts/requirements-ml.txt\n\
               python scripts/convert_embedder.py\n\
             \n\
             Until then recall works, but keyword-only. Nothing is broken;\n\
             there is just no semantic half to fill in yet."
        );
        return Err(20);
    }

    let store = match SqlCipherBrainStore::new(db_path, &key) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "mci-agent embed-backfill: open brain at {}: {e}",
                db_path.display()
            );
            return Err(12);
        }
    };

    // Reuses the same read-embed-write sequence as the live-capture
    // idle-batch worker, in its one-shot form. See `idle_batch`.
    let stats = match mci_agent::idle_batch::backfill_until_drained(
        &store,
        embedder.as_ref(),
        batch_size,
        |s| {
            eprintln!(
                "mci-agent embed-backfill: {} embedded so far",
                s.events_embedded
            )
        },
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("mci-agent embed-backfill: {e}");
            return Err(13);
        }
    };

    let skipped = stats.embed_errors + stats.store_errors;
    if skipped > 0 {
        eprintln!(
            "mci-agent embed-backfill: done. {} embedded, {skipped} skipped \
             ({} embed errors, {} store errors).",
            stats.events_embedded, stats.embed_errors, stats.store_errors
        );
        return Err(22);
    }
    eprintln!(
        "mci-agent embed-backfill: done. {} embedded in {} batch(es). \
         Restart mcp-serve to pick up hybrid recall.",
        stats.events_embedded, stats.batches_run
    );
    Ok(())
}

/// Candidate on-disk paths for the `ArcticEmbedS` Core ML model, in probe
/// order. Shared by the ingest-side (document) and query-side embedder
/// loaders so both surfaces resolve the same bundle-first, dev-fallback
/// list. See ADR-0028 §4 for the bundle-path contract.
#[cfg(target_os = "macos")]
fn arctic_embed_s_model_candidates() -> Vec<std::path::PathBuf> {
    let home = std::env::var_os("HOME").map_or_else(
        || std::path::PathBuf::from("/tmp"),
        std::path::PathBuf::from,
    );
    let env_path = std::env::var_os("MCI_ARCTIC_MODEL_PATH").map(std::path::PathBuf::from);

    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Some(p) = &env_path {
        candidates.push(p.clone());
    }
    // Hippocampus.app bundle path (per ADR-0028 §4 — embedder bundled in
    // Contents/Resources/Models/ as produced by build-app.sh + Wave 16).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // exe at Contents/MacOS/mci-agent → Contents/Resources/Models/
            candidates.push(dir.join("../Resources/Models/ArcticEmbedS_INT8.mlmodelc"));
            candidates.push(dir.join("../Resources/Models/ArcticEmbedS_INT8.mlpackage"));
            // Dev/legacy paths (executable-relative)
            candidates.push(dir.join("ArcticEmbedS_INT8.mlmodelc"));
            candidates.push(dir.join("ArcticEmbedS_INT8.mlpackage"));
            candidates.push(dir.join("arctic-embed-s.mlpackage"));
            candidates.push(dir.join("../Resources/arctic-embed-s.mlpackage"));
        }
    }
    // Repo-root dev paths (when running mci-agent from cargo target)
    candidates.push(home.join("Documents/GitHub/mci/models/ArcticEmbedS_INT8.mlmodelc"));
    candidates.push(home.join("Documents/GitHub/mci/models/ArcticEmbedS_INT8.mlpackage"));
    // Old MCICaptureHelper.app path kept for legacy installs
    candidates.push(
        home.join("Applications/MCICaptureHelper.app/Contents/Resources/arctic-embed-s.mlpackage"),
    );
    candidates
}

/// Load the best available embedder backend for the idle-batch worker.
///
/// On macOS: tries to load the Core ML `.mlpackage` from candidate
/// paths; falls back to the zero-vector backend when the model isn't
/// bundled (development builds). Returns `(Arc<dyn Embedder>, is_real)`.
///
/// The ArcticEmbedSEmbedder wrapper applies the model-card prefix
/// discipline + L2-norm (ADR-0011 §3). Document-side prefix (empty
/// for arctic-embed-s) is used for idle-batch embedding.
#[cfg(target_os = "macos")]
fn load_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    use mci_brain::arctic_embed_s::ArcticEmbedSEmbedder;
    use mci_embed_coreml::load_backend_or_fallback;
    use std::path::Path;

    let candidates = arctic_embed_s_model_candidates();
    let path_refs: Vec<&Path> = candidates.iter().map(|p| p.as_path()).collect();
    let (backend, is_real) = load_backend_or_fallback(&path_refs);
    let embedder = ArcticEmbedSEmbedder::new_document(backend);

    // Load-time smoke embed: prove the model can actually PREDICT, not just
    // load. mci-embed-coreml's verify_schema is type-only and passes even on
    // a model whose predict path would throw — so a successful load does NOT
    // guarantee a working embedder. Probe once at startup so a dead embedder
    // is known loudly here, instead of inferred from a climbing embed_errors
    // aggregate at idle-batch worker exit. (Content-free: a fixed probe
    // string, never user content.)
    {
        use mci_brain::Embedder as _;
        let smoke = embedder.embed_one("mci embedder load-time smoke probe");
        match (&smoke, is_real) {
            (Ok(v), true) => {
                let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
                let healthy = v.len() == 384 && norm.is_finite() && (norm - 1.0).abs() < 1e-2;
                if healthy {
                    eprintln!(
                        "mci-agent: embedder smoke OK — CoreML (cpu_only pin), dim={} |v|={norm:.4}",
                        v.len(),
                    );
                } else {
                    eprintln!(
                        "mci-agent: WARNING embedder loaded but smoke vector looks wrong \
                         (dim={} |v|={norm:.4}, expected dim=384 |v|~1.0) — semantic ingest \
                         may be degraded.",
                        v.len(),
                    );
                }
            }
            (Err(e), true) => {
                eprintln!(
                    "mci-agent: WARNING embedder LOADED but smoke embed FAILED — semantic \
                     ingest is DEAD: {e}. Events will accumulate unembedded (embed_errors \
                     will climb). Check the bundled ArcticEmbedS model / compute-unit pin.",
                );
            }
            // is_real == false: ZeroBackend fallback. The degradation is
            // already reported at the call site via the `embedder=zero-fallback`
            // log line; the smoke "succeeds" trivially (zeros), so stay quiet.
            (_, false) => {}
        }
    }

    (Arc::new(embedder), is_real)
}

#[cfg(not(target_os = "macos"))]
fn load_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    // Non-macOS: no Core ML / ONNX available yet (Phase 8).
    // Zero-vector embedder marks events "embedded" to avoid busy-loop.
    struct ZeroEmbedder;
    impl mci_brain::Embedder for ZeroEmbedder {
        fn dimension(&self) -> usize {
            384
        }
        fn embed_one(&self, _text: &str) -> Result<Vec<f32>, mci_brain::EmbedError> {
            Ok(vec![0.0_f32; 384])
        }
    }
    eprintln!("mci-agent: non-macOS platform — using zero-vector embedder fallback");
    (Arc::new(ZeroEmbedder), false)
}

/// Load the query-side embedder for `mci-agent mcp-serve` (recall path).
///
/// Mirrors [`load_embedder_backend`] but constructs `new_query` so the
/// `ArcticEmbedS` model-card query prefix (per ADR-0011 §3) is applied to
/// every recall-time embed call. Same Core ML backend + `cpu_only` pin
/// (per PR #310 lesson — the "all" compute-unit setting is the latency
/// trap [[reference-coreml-computeunits-all-trap]]); a separate wrapper
/// instance because the prefix is baked into the wrapper, not selectable
/// per call.
///
/// Returns `(Arc<dyn Embedder>, is_real)` where `is_real == false` means
/// the `ZeroBackend` fallback fired (no model on disk) — callers should
/// prefer FTS5-only recall in that case rather than feeding a zero
/// vector into `HybridRetriever`.
#[cfg(target_os = "macos")]
fn load_query_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    use mci_brain::arctic_embed_s::ArcticEmbedSEmbedder;
    use mci_embed_coreml::load_backend_or_fallback;
    use std::path::Path;

    let candidates = arctic_embed_s_model_candidates();
    let path_refs: Vec<&Path> = candidates.iter().map(|p| p.as_path()).collect();
    let (backend, is_real) = load_backend_or_fallback(&path_refs);
    let embedder = ArcticEmbedSEmbedder::new_query(backend);

    // Load-time smoke embed: same probe discipline as the ingest-side
    // loader (PR #310) — verify_schema is type-only, so a "loaded" model
    // whose predict path throws will still light up the recall path
    // producing errors on every user query. Probe once at startup so a
    // dead query embedder is known loudly here.
    if is_real {
        use mci_brain::Embedder as _;
        match embedder.embed_one("mci query embedder load-time smoke probe") {
            Ok(v) => {
                let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
                let healthy = v.len() == 384 && norm.is_finite() && (norm - 1.0).abs() < 1e-2;
                if healthy {
                    eprintln!(
                        "mci-agent: query embedder smoke OK — CoreML (cpu_only pin), dim={} |v|={norm:.4}",
                        v.len(),
                    );
                } else {
                    eprintln!(
                        "mci-agent: WARNING query embedder loaded but smoke vector looks wrong \
                         (dim={} |v|={norm:.4}, expected dim=384 |v|~1.0) — hybrid recall may \
                         be degraded.",
                        v.len(),
                    );
                }
            }
            Err(e) => {
                eprintln!(
                    "mci-agent: WARNING query embedder LOADED but smoke embed FAILED — hybrid \
                     recall is DEAD: {e}. Check the bundled ArcticEmbedS model / compute-unit pin.",
                );
            }
        }
    }

    (Arc::new(embedder), is_real)
}

#[cfg(not(target_os = "macos"))]
fn load_query_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    // Non-macOS: no Core ML / ONNX yet (Phase 8). Return a zero-vector
    // embedder marked `is_real = false` so the caller stays on FTS5-only
    // rather than seeding HybridRetriever with a useless zero vector.
    struct ZeroEmbedder;
    impl mci_brain::Embedder for ZeroEmbedder {
        fn dimension(&self) -> usize {
            384
        }
        fn embed_one(&self, _text: &str) -> Result<Vec<f32>, mci_brain::EmbedError> {
            Ok(vec![0.0_f32; 384])
        }
    }
    (Arc::new(ZeroEmbedder), false)
}

/// Resolve + load the V2-P5+ SYNC BERT NER backend (`dslim/bert-base-NER`,
/// INT8, `cpu_only`). Returns `None` when no `.mlmodelc` is found on disk
/// (opt-in download — Tier 1 + the async Qwen tier still run regardless) or
/// the load fails. The bundled WordPiece tokenizer travels inside
/// `mci-brain` (`load_bundled`), so only the model path is resolved here.
/// Compute units are pinned to CPU inside `NerTier2Backend::load` — never
/// the `all` latency trap ([[reference-coreml-computeunits-all-trap]]).
#[cfg(target_os = "macos")]
fn load_ner_sync_backend() -> Option<Arc<dyn mci_brain::NerBackend>> {
    use mci_agent::tier2_ner_backend::NerTier2Backend;
    use std::path::PathBuf;

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(p) = std::env::var_os("MCI_NER_MODEL_PATH") {
        candidates.push(PathBuf::from(p));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // Hippocampus.app bundle: Contents/MacOS → Contents/Resources/Models.
            candidates.push(dir.join("../Resources/Models/bert_base_NER_INT8.mlmodelc"));
            candidates.push(dir.join("bert_base_NER_INT8.mlmodelc"));
        }
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        candidates.push(home.join("Documents/GitHub/mci/models/bert_base_NER_INT8.mlmodelc"));
    }

    let model_path = candidates.into_iter().find(|p| p.exists())?;
    match NerTier2Backend::load(&model_path) {
        Ok(backend) => {
            eprintln!(
                "mci-agent: sync NER enabled (bert-base-NER, cpu_only). model={}",
                model_path.display()
            );
            Some(Arc::new(backend) as Arc<dyn mci_brain::NerBackend>)
        }
        Err(e) => {
            eprintln!("mci-agent: sync NER disabled (model load failed): {e}");
            None
        }
    }
}

/// Non-macOS: no Core ML yet (Phase 8). Sync NER stays disabled; the Tier 1
/// regex mentions still flow on the hot path.
#[cfg(not(target_os = "macos"))]
fn load_ner_sync_backend() -> Option<Arc<dyn mci_brain::NerBackend>> {
    None
}

/// Spawn the daily-brief worker (ADR-0028). Selects between the
/// production Qwen3 Core ML backend and the disabled-idle path based on
/// `MCI_BRIEFS_DISABLED`, the presence of the model, and the host OS.
#[cfg(target_os = "macos")]
fn spawn_brief_worker(
    store: Arc<mci_brain::SqlCipherBrainStore>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    use mci_brief::author::BriefAuthor;
    use mci_brief::llama_author::LlamaBriefAuthor;
    use mci_brief::llama_backend::LlamaBackend;

    if brief_worker::briefs_disabled_via_env() {
        tokio::spawn(async move {
            let stats = brief_worker::run_disabled_idle("MCI_BRIEFS_DISABLED=1", shutdown).await;
            eprintln!(
                "mci-agent: brief worker exited (disabled). generated={} skipped_empty={} errors={}",
                stats.briefs_generated, stats.cycles_skipped_empty, stats.cycle_errors,
            );
        });
        return;
    }

    let model_dir = brief_worker::default_model_dir();
    if !brief_worker::qwen3_model_present(&model_dir) {
        tokio::spawn(async move {
            let stats =
                brief_worker::run_disabled_idle("Qwen3 model not installed", shutdown).await;
            eprintln!(
                "mci-agent: brief worker exited (no model). generated={} skipped_empty={} errors={}",
                stats.briefs_generated, stats.cycles_skipped_empty, stats.cycle_errors,
            );
        });
        return;
    }

    // Path layout matches `ModelDownloadManager`'s unpack convention:
    // `<model_dir>/<modelID>/<basename>/...`. Both sides reference the
    // same constants from `brief_worker` to keep the seam tight.
    let model_subdir = model_dir.join(brief_worker::QWEN3_MODEL_ID);
    let model_path = model_subdir.join(brief_worker::QWEN3_MODEL_BASENAME);
    let tokenizer_dir = model_subdir.clone();
    let factory: brief_worker::AuthorFactory = Arc::new(move || {
        let backend = mci_coreml_bridge::Qwen3CoreMLBackend::open(&model_path, &tokenizer_dir)
            .map_err(|e| {
                brief_worker::BriefWorkerError::Author(format!("Qwen3CoreMLBackend::open: {e}"))
            })?;
        let backend_arc: Arc<dyn LlamaBackend> = Arc::new(backend);
        let author = LlamaBriefAuthor::new(backend_arc);
        let boxed: Box<dyn BriefAuthor> = Box::new(author);
        Ok(boxed)
    });

    let tz_resolver: Arc<dyn Fn() -> i32 + Send + Sync> =
        Arc::new(brief_worker::current_tz_offset_secs);

    tokio::spawn(async move {
        match brief_worker::run_brief_worker(
            store,
            factory,
            brief_worker::DEFAULT_BRIEF_HOUR,
            tz_resolver,
            shutdown,
        )
        .await
        {
            Ok(stats) => {
                eprintln!(
                    "mci-agent: brief worker exited. generated={} skipped_empty={} errors={} disabled={}",
                    stats.briefs_generated,
                    stats.cycles_skipped_empty,
                    stats.cycle_errors,
                    stats.disabled,
                );
            }
            Err(e) => {
                eprintln!("mci-agent: brief worker fatal: {e}");
            }
        }
    });
}

/// Non-macOS: there is no Core ML, no Qwen3 backend, so the brief
/// worker stays in disabled-idle mode.
#[cfg(not(target_os = "macos"))]
fn spawn_brief_worker(
    _store: Arc<mci_brain::SqlCipherBrainStore>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    tokio::spawn(async move {
        let stats = brief_worker::run_disabled_idle("non-macOS platform", shutdown).await;
        eprintln!(
            "mci-agent: brief worker exited (non-macOS). generated={} skipped_empty={} errors={}",
            stats.briefs_generated, stats.cycles_skipped_empty, stats.cycle_errors,
        );
    });
}

/// V2-P5 — spawn the Tier 2 Qwen NER idle-batch worker (FORK 8 = A;
/// Phase 6 PR 9). Reuses the brief author's Qwen3-1.7B Core ML
/// `LlamaBackend`; selects between the production Qwen-backed path
/// and disabled-idle based on the `.mlmodelc` presence + the host OS.
/// Construction-graph wiring at integration site — this is the
/// load-bearing call site that turns the V2-P5 module + worker into
/// production behaviour. Per
/// [[project-v2p1-unit-tests-passed-but-never-wired]] the wire is
/// the lift; without this call the Tier 2 worker would never run.
#[cfg(target_os = "macos")]
fn spawn_tier2_worker(
    store: Arc<mci_brain::SqlCipherBrainStore>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    use mci_agent::tier2_qwen_backend::QwenTier2Backend;
    use mci_agent::tier2_worker::{run_disabled_idle, run_tier2_worker};
    use mci_brain::{NerBackend, Tier2Extractor};
    use mci_brief::llama_backend::LlamaBackend;
    use std::time::Duration;

    /// How many events to scan per batch. Bounded to keep one
    /// cycle's worth of work tractable on the single-flight Qwen
    /// call site; events accumulate across cycles.
    const TIER2_BATCH_SIZE: usize = 8;
    /// Sleep between idle-batch cycles when the queue is drained.
    /// 30 s is the same cadence as the embedder idle-batch loop;
    /// it bounds the steady-state cost while keeping catch-up
    /// reasonable after a long-running session.
    const TIER2_IDLE_INTERVAL: Duration = Duration::from_secs(30);

    let model_dir = brief_worker::default_model_dir();
    if !brief_worker::qwen3_model_present(&model_dir) {
        tokio::spawn(async move {
            let stats = run_disabled_idle("Qwen3 model not installed", shutdown).await;
            eprintln!(
                "mci-agent: tier2 NER worker exited (no model). scanned={} mentions={} ner_errors={} disabled={}",
                stats.events_scanned,
                stats.mentions_inserted,
                stats.ner_errors,
                stats.disabled,
            );
        });
        return;
    }

    // Path layout matches `ModelDownloadManager`'s unpack convention.
    // Same constants as `spawn_brief_worker` — both workers reuse the
    // SAME `.mlmodelc` on disk. The model is loaded twice (once per
    // worker) which is acceptable: each worker is single-flight, so
    // peak RAM is bounded by one Qwen working set per workflow, not
    // two at once.
    let model_subdir = model_dir.join(brief_worker::QWEN3_MODEL_ID);
    let model_path = model_subdir.join(brief_worker::QWEN3_MODEL_BASENAME);
    let tokenizer_dir = model_subdir;

    let backend_result = mci_coreml_bridge::Qwen3CoreMLBackend::open(&model_path, &tokenizer_dir);
    let backend = match backend_result {
        Ok(b) => b,
        Err(e) => {
            tokio::spawn(async move {
                let reason = format!("Qwen3CoreMLBackend::open failed: {e}");
                let stats = run_disabled_idle(&reason, shutdown).await;
                eprintln!(
                    "mci-agent: tier2 NER worker exited (open failed). disabled={}",
                    stats.disabled,
                );
            });
            return;
        }
    };

    let llama: Arc<dyn LlamaBackend> = Arc::new(backend);
    let ner_backend: Arc<dyn NerBackend> = Arc::new(QwenTier2Backend::new(llama));
    let extractor = Tier2Extractor::new(ner_backend);

    tokio::spawn(async move {
        match run_tier2_worker(
            store,
            extractor,
            TIER2_BATCH_SIZE,
            TIER2_IDLE_INTERVAL,
            shutdown,
        )
        .await
        {
            Ok(stats) => {
                eprintln!(
                    "mci-agent: tier2 NER worker exited. scanned={} mentions={} batches={} ner_errors={} store_errors={} disabled={}",
                    stats.events_scanned,
                    stats.mentions_inserted,
                    stats.batches_run,
                    stats.ner_errors,
                    stats.store_errors,
                    stats.disabled,
                );
            }
            Err(e) => {
                eprintln!("mci-agent: tier2 NER worker fatal: {e}");
            }
        }
    });
}

/// Non-macOS: no Core ML, no Qwen3 backend, so the Tier 2 worker
/// stays in disabled-idle mode. The mci-brain V2-P4 Tier 1 regex
/// extractor still runs on the hot path so structural entities
/// continue to land.
#[cfg(not(target_os = "macos"))]
fn spawn_tier2_worker(
    _store: Arc<mci_brain::SqlCipherBrainStore>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    use mci_agent::tier2_worker::run_disabled_idle;
    tokio::spawn(async move {
        let stats = run_disabled_idle("non-macOS platform", shutdown).await;
        eprintln!(
            "mci-agent: tier2 NER worker exited (non-macOS). disabled={}",
            stats.disabled,
        );
    });
}

/// V2-P10 — spawn the deep-hook pump supervisor.
///
/// Constructs a [`PumpSupervisor`] over the same `SqlCipherBrainStore`
/// + embedder the wire-frame brain pump uses, points it at the
/// canonical user-allowlist path, and runs the reconcile loop until
/// shutdown.
#[cfg(target_os = "macos")]
fn spawn_pump_supervisor(
    store: Arc<mci_brain::SqlCipherBrainStore>,
    embedder: Arc<dyn mci_brain::Embedder>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    let supervisor = Arc::new(PumpSupervisor::new(
        store as Arc<dyn mci_brain::BrainStore>,
        Some(embedder),
        default_user_allowlist_path(),
    ));
    eprintln!(
        "mci-agent: deep-hook pump supervisor started. allowlist={}",
        default_user_allowlist_path().display(),
    );
    tokio::spawn(async move {
        supervisor.run(shutdown).await;
        eprintln!("mci-agent: pump supervisor exited cleanly");
    });
}

/// Non-macOS: deep-hook pumps are macOS-only (chat.db + emlx are
/// macOS surfaces). No-op on Linux / Windows so the workspace
/// compiles uniformly.
#[cfg(not(target_os = "macos"))]
fn spawn_pump_supervisor(
    _store: Arc<mci_brain::SqlCipherBrainStore>,
    _embedder: Arc<dyn mci_brain::Embedder>,
    _shutdown: tokio::sync::watch::Receiver<bool>,
) {
}

/// V2-MCP-3 wiring point. Constructs the
/// [`mci_agent::mcp_aggregator::McpAggregator`] over the V2-MCP-2
/// `ServerRegistry` + the shared brain store, then spawns its
/// reconcile loop on the tokio runtime with the shared shutdown
/// channel.
///
/// Cross-platform — unlike `spawn_pump_supervisor` above, the MCP
/// aggregator runs anywhere the agent runs (its inputs are MCP
/// servers the user registered; no OS-specific source).
///
/// Driver-CSO audit row 7: `git log -S "McpAggregator::new" --
/// apps/agent/src/bin/mci_agent.rs` returns this PR's commit per
/// [[project-v2p1-unit-tests-passed-but-never-wired]] discipline.
fn spawn_mcp_aggregator(
    registry: Arc<mci_mcp_client::ServerRegistry>,
    store: Arc<dyn mci_brain::BrainStore>,
    embedder: Option<Arc<dyn mci_brain::Embedder>>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    let aggregator = mci_agent::mcp_aggregator::McpAggregator::new(registry, store, embedder);
    eprintln!(
        "mci-agent: MCP aggregator started (reconcile every {}s; materialize cap {} bytes)",
        mci_agent::mcp_aggregator::DEFAULT_RECONCILE_INTERVAL.as_secs(),
        mci_agent::mcp_aggregator::DEFAULT_MATERIALIZE_MAX_BYTES,
    );
    tokio::spawn(async move {
        aggregator.run(shutdown).await;
        eprintln!("mci-agent: MCP aggregator exited cleanly");
    });
}

/// Decode a 64-char hex string into a 32-byte key. Returns `None` on any
/// non-hex character or length mismatch.
fn decode_hex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in s.as_bytes().chunks_exact(2).enumerate() {
        let hi = hex_nibble(chunk[0])?;
        let lo = hex_nibble(chunk[1])?;
        out[i] = (hi << 4) | lo;
    }
    Some(out)
}

fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}
