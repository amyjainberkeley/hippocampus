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

#![forbid(unsafe_code)]

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use mci_agent::embedder_load::{load_embedder_backend, load_query_embedder_backend};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_agent::alias_resolver_worker;
use mci_agent::brain_ingest::{BrainIngestor, BrainPump};
use mci_agent::brief_worker;
use mci_agent::client_registry::{
    ClientRegistration, ClientRegistry, RegistrationChange, RegistrationStatus,
};
use mci_agent::consolidator_worker;
use mci_agent::crash_recovery::{acquire_lock, lock_path_for_brain, LockAcquireOutcome, LockError};
use mci_agent::device_id::{load_or_generate, DeviceIdSource};
use mci_agent::episode_worker;
use mci_agent::health_log::{HealthLog, HealthLogConfig};
use mci_agent::health_summary::summarize_file;
use mci_agent::idle_batch;
use mci_agent::key_resolver;
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
const COMMAND_INTEGRITY_FAILURE_EXIT_CODE: u8 = 22;

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
    /// `SQLCipher` brain store when the production Keychain reference resolves;
    /// otherwise they fall into the non-health counter (legacy behaviour).
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
    /// One-command setup: key, import, enrich, register.
    Init {
        db_path: PathBuf,
        root: PathBuf,
    },
    /// Ensure the production Keychain item exists without importing data.
    EnsureKey {
        db_path: PathBuf,
    },
    /// Import Claude Code session transcripts into the brain.
    ImportSessions {
        db_path: PathBuf,
        root: PathBuf,
    },
    /// Explain why the brain is empty.
    Doctor {
        db_path: PathBuf,
    },
    /// Write one daily brief over an existing brain.
    ///
    /// The brief worker was reachable only from inside `--drain-stdin`,
    /// the live-capture path, which ships off. On a brain filled any other
    /// way it never fired, and there was no command that produced a brief.
    Brief {
        db_path: PathBuf,
        /// `YYYY-MM-DD` local day to summarize. `None` = the last 24 h,
        /// which is what the scheduled worker covers.
        date: Option<String>,
        /// Directory holding the Qwen3 `.mlmodelc`. `None` = the default
        /// install location.
        model_dir: Option<PathBuf>,
    },
    /// Run every understanding stage over an existing brain.
    ///
    /// The five workers that turn events into entities, episodes and
    /// identities were reachable only from the live-capture ingest path,
    /// which ships off. On any brain filled another way they never ran.
    Enrich {
        db_path: PathBuf,
        batch_size: usize,
    },
    /// Pull every registered MCP server's resources into the brain, once.
    ///
    /// The V2-MCP-3 aggregator was constructed only inside the
    /// `--drain-stdin` live-capture arm. Live capture ships off, so a
    /// server registered in `mcp-servers.toml` never reached the brain.
    McpSync {
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
    /// A subcommand this build does not have. Carries the token so the
    /// error can name it.
    UnknownCommand {
        name: String,
    },
    /// Register Hippocampus as an MCP server in Claude Code's settings.
    RegisterMcp {
        db_path: PathBuf,
    },
    /// Register the read-only memory server with every detected local client.
    ConnectAll {
        db_path: PathBuf,
    },
    /// Cycle 8.29 P0 #3 — empirical "is content reaching the brain
    /// from `source`?" probe. Used by
    /// `OnboardingKit.RealBrowserDetector.checkExtensionInstalled` to
    /// replace the pre-cycle-8.29 manifest-file-presence probe (which
    /// reported `.installed` even when no event ever reached the
    /// brain).
    ///
    /// Opens the `SQLCipher` brain read-only, counts events whose
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

fn capture_ingestion_enabled(environment_value: Option<&str>) -> bool {
    match environment_value {
        None => true,
        Some(value) => matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true"),
    }
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

#[allow(clippy::too_many_lines)] // One two-pass parser keeps option precedence explicit.
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
    let mut brief_date: Option<String> = None;
    let mut model_dir: Option<PathBuf> = None;
    let mut transcript_root: Option<PathBuf> = None;
    let mut unknown_command: Option<String> = None;

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
            "connect" => mode_kind = ModeKind::ConnectAll,
            "stats" => mode_kind = ModeKind::Stats,
            "embed-backfill" => mode_kind = ModeKind::EmbedBackfill,
            "enrich" => mode_kind = ModeKind::Enrich,
            "mcp-sync" => mode_kind = ModeKind::McpSync,
            "doctor" => mode_kind = ModeKind::Doctor,
            "brief" => mode_kind = ModeKind::Brief,
            "--date" if i + 1 < argv.len() => {
                brief_date = Some(argv[i + 1].clone());
                i += 1;
            }
            "--model-dir" if i + 1 < argv.len() => {
                model_dir = Some(PathBuf::from(&argv[i + 1]));
                i += 1;
            }
            "import-sessions" => mode_kind = ModeKind::ImportSessions,
            "init" => mode_kind = ModeKind::Init,
            "ensure-key" => mode_kind = ModeKind::EnsureKey,
            "--transcript-root" => {
                if let Some(v) = argv.get(i + 1) {
                    transcript_root = Some(PathBuf::from(v));
                    i += 1;
                }
            }
            "--batch-size" => {
                if let Some(v) = argv.get(i + 1).and_then(|s| s.parse::<usize>().ok()) {
                    embed_batch_size = v.max(1);
                    i += 1;
                }
            }
            "--source" if i + 1 < argv.len() => {
                stats_source.clone_from(&argv[i + 1]);
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
            // An unrecognised *flag* stays silent: the Swift host passes
            // its own, and rejecting them would break the app whenever the
            // two halves ship out of step. An unrecognised *subcommand* is
            // a different thing entirely — it means the user typed a
            // command this build does not have, and printing the usage
            // text with exit 0 tells them it worked.
            //
            // Only remembered, not acted on yet. An unknown flag's *value*
            // is also a bare token, so `--future-flag /some/path` would
            // otherwise make `/some/path` fatal — which is the same
            // ships-out-of-step outage the flag rule exists to avoid. The
            // decision is deferred until the whole argv has been read, and
            // taken only if no mode was recognised anywhere in it.
            other if !other.starts_with('-') && unknown_command.is_none() => {
                unknown_command = Some(other.to_owned());
            }
            _ => {}
        }
        i += 1;
    }

    let resolved_db_path = db_path
        .or_else(|| std::env::var_os("MCI_DB_PATH").map(PathBuf::from))
        .unwrap_or_else(default_db_path);
    // Deferred from the parse loop: a stray bare token is only an error
    // when nothing else in argv named a mode.
    if matches!(mode_kind, ModeKind::Help) && unknown_command.is_some() {
        mode_kind = ModeKind::UnknownCommand;
    }

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
        ModeKind::UnknownCommand => Mode::UnknownCommand {
            name: unknown_command.unwrap_or_default(),
        },
        ModeKind::RegisterMcp => Mode::RegisterMcp {
            db_path: resolved_db_path,
        },
        ModeKind::ConnectAll => Mode::ConnectAll {
            db_path: resolved_db_path,
        },
        ModeKind::Stats => Mode::Stats {
            source: stats_source,
            since_seconds: stats_since_seconds,
            db_path: resolved_db_path,
        },
        ModeKind::EmbedBackfill => Mode::EmbedBackfill {
            db_path: resolved_db_path,
            batch_size: embed_batch_size,
        },
        ModeKind::Enrich => Mode::Enrich {
            db_path: resolved_db_path,
            batch_size: embed_batch_size,
        },
        ModeKind::McpSync => Mode::McpSync {
            db_path: resolved_db_path,
        },
        ModeKind::Doctor => Mode::Doctor {
            db_path: resolved_db_path,
        },
        ModeKind::Brief => Mode::Brief {
            db_path: resolved_db_path.clone(),
            date: brief_date,
            model_dir,
        },
        ModeKind::Init => Mode::Init {
            db_path: resolved_db_path.clone(),
            root: transcript_root
                .clone()
                .unwrap_or_else(mci_agent::import_sessions::default_transcript_root),
        },
        ModeKind::EnsureKey => Mode::EnsureKey {
            db_path: resolved_db_path,
        },
        ModeKind::ImportSessions => Mode::ImportSessions {
            db_path: resolved_db_path,
            root: transcript_root
                .unwrap_or_else(mci_agent::import_sessions::default_transcript_root),
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
    ConnectAll,
    Stats,
    EmbedBackfill,
    Enrich,
    McpSync,
    Doctor,
    Brief,
    ImportSessions,
    Init,
    EnsureKey,
    UnknownCommand,
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
        \x20 connect --all              register Hippocampus with detected Claude Code and\n\
        \x20                            Codex clients without serializing a database key\n\
        \x20 init                       one-command setup: make a key, import your\n\
        \x20                            Claude Code history, index it, and connect\n\
        \x20                            detected Claude Code and Codex clients\n\
        \x20 ensure-key                 initialize or validate the bundled macOS\n\
        \x20                            Keychain item without importing data\n\
        \x20 import-sessions            import Claude Code transcripts from\n\
        \x20                            ~/.claude/projects into the brain\n\
        \x20 doctor                     say why the brain is empty and what to fix\n\
        \x20 enrich                     run every understanding stage over an existing\n\
        \x20                            brain: extract entities, embed, segment episodes,\n\
        \x20                            resolve identities, link related episodes.\n\
        \x20 brief                      write the daily brief for an existing brain, now,\n\
        \x20                            instead of waiting for the 06:00 worker (which only\n\
        \x20                            runs inside live capture). Needs the Qwen3 model;\n\
        \x20                            refuses, loudly, without it. The brief is a DRAFT:\n\
        \x20                            approving one takes a human, per ADR-0018.\n\
        \x20                            Regenerating a date replaces that date's brief.\n\
        \x20 mcp-sync                   pull resources from every MCP server registered in\n\
        \x20                            ~/Library/Application Support/MCI/mcp-servers.toml\n\
        \x20                            into the brain, once, then exit. Safe to re-run:\n\
        \x20                            a resource already ingested is not written twice.\n\
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
        \x20 --date YYYY-MM-DD          (with brief) summarize that local day. Default is\n\
        \x20                            the last 24 hours, same window as the worker.\n\
        \x20 --model-dir PATH           (with brief) where the Qwen3 .mlmodelc lives.\n\
        \x20                            Default ~/Library/Application Support/MCI/Models\n\
        \x20 --strict                   (with --drain-stdin) exit non-zero if brain cannot\n\
        \x20                            be opened, instead of falling back to health-only.\n\
        \n\
        Env:\n\
        \x20 MCI_DB_PATH                brain SQLCipher path (--drain-stdin + mcp-serve)\n\
        \x20 MCI_DB_KEYCHAIN_SERVICE    content-free Keychain service reference; production\n\
        \x20 MCI_DB_KEYCHAIN_ACCOUNT    account reference. Defaults match Hippocampus.app.\n\
        \x20 MCI_DEVELOPMENT_FILE_KEY   set to 1 only for local development to allow dev.key\n\
        \x20                            MCI_DB_KEY_FILE, or MCI_DB_KEY_HEX. Production\n\
        \x20                            ignores raw/file keys.\n\
        \x20 MCI_EMBEDDER_DISABLED      set to 1 to force lexical-only recall in mcp-serve\n\
        \x20                            (skips HybridRetriever even if an embedder is\n\
        \x20                            available). Default fusion weights per ADR-0010:\n\
        \x20                            w_sem=0.5, w_lex=0.3, w_rec=0.15, w_src=0.05.\n\
        \x20 MCI_BRIEFS_DISABLED        set to 1 to switch daily briefs off. The worker\n\
        \x20                            idles; `brief` refuses and says so.\n\
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
            let capture_ingestion_enabled =
                capture_ingestion_enabled(std::env::var("MCI_CAPTURE_ENABLED").ok().as_deref());
            eprintln!(
                "mci-agent: observation ingestion {}",
                if capture_ingestion_enabled {
                    "enabled"
                } else {
                    "disabled; maintenance remains active"
                }
            );
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

            // P3.10c + P3.8 — open the brain store only after the production
            // Keychain reference resolves. The store is shared between:
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
            let mut writer_run_lock = None;

            let brain_pump: Option<(BrainPump, Arc<SqlCipherBrainStore>)> = match resolve_key_hex()
            {
                Ok(key_hex) => {
                    if let Some(key_bytes) = decode_hex32(&key_hex) {
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
                        let lock_path = lock_path_for_brain(&db_path);
                        let unclean_prior_shutdown = match acquire_lock(&lock_path) {
                            Ok((LockAcquireOutcome::CleanBoot, lock)) => {
                                writer_run_lock = Some(lock);
                                false
                            }
                            Ok((LockAcquireOutcome::UncleanShutdown { stale_pid }, lock)) => {
                                writer_run_lock = Some(lock);
                                eprintln!(
                                    "mci-agent: unclean prior shutdown detected (stale pid {stale_pid:?}) — will run extra integrity_check",
                                );
                                true
                            }
                            Err(LockError::WriterLeaseHeld { owner_pid }) => {
                                eprintln!(
                                    "mci-agent: another writer owns the process-lifetime lease (pid {owner_pid:?}) — refusing to open store (ADR-0008 §1.4 one-writer invariant)",
                                );
                                return ExitCode::from(21);
                            }
                            Err(e) => {
                                eprintln!("mci-agent: crash_recovery::acquire_lock: {e}");
                                return ExitCode::from(21);
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
                                    if let Some(lock) = writer_run_lock.take() {
                                        let _ = lock.release();
                                    }
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
                                        if let Some(lock) = writer_run_lock.take() {
                                            let _ = lock.release();
                                        }
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
                                                "mci-agent: retention worker exited. cycles={} events_deleted={} vectors_deleted={} episodes_deleted={} referenced_blobs_deleted={} orphaned_blobs_deleted={} stale_temps_deleted={} referenced_blobs_missing_last={} blob_cleanup_errors={} errors={}",
                                                stats.cycles_run, stats.total_events_deleted,
                                                stats.total_vectors_deleted, stats.total_episodes_deleted,
                                                stats.total_blobs_deleted,
                                                stats.total_orphaned_blobs_deleted,
                                                stats.total_stale_temporary_files_deleted,
                                                stats.referenced_blobs_missing_last,
                                                stats.total_blob_cleanup_errors,
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
                                if capture_ingestion_enabled {
                                    spawn_pump_supervisor(
                                        Arc::clone(&store),
                                        supervisor_embedder,
                                        shutdown_rx.clone(),
                                    );
                                }

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
                                if capture_ingestion_enabled {
                                    spawn_mcp_aggregator(
                                        Arc::clone(&mcp_registry),
                                        Arc::clone(&store),
                                        None,
                                        shutdown_rx.clone(),
                                    );
                                }

                                Some((pump, store))
                            }
                            Err(e) => {
                                if let Some(lock) = writer_run_lock.take() {
                                    let _ = lock.release();
                                }
                                eprintln!(
                                    "\n========================================================"
                                );
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
                                eprintln!("    * Database and Keychain item do not match");
                                eprintln!("    * Permissions issue on brain file");
                                eprintln!();
                                eprintln!("  Quit and relaunch Hippocampus.app after confirming");
                                eprintln!("  Keychain access. Do not replace an existing key.");
                                eprintln!(
                                    "========================================================\n"
                                );
                                if strict {
                                    return ExitCode::from(21);
                                }
                                None
                            }
                        }
                    } else {
                        eprintln!(
                            "mci-agent: brain key must be 64 hex chars (32 bytes). Falling back to health-only drain."
                        );
                        if strict {
                            return ExitCode::from(22);
                        }
                        None
                    }
                }
                Err(error) => {
                    report_key_resolution_error("--drain-stdin", &error);
                    if !matches!(error, key_resolver::KeyResolutionError::MissingKey { .. }) {
                        return ExitCode::from(23);
                    }
                    eprintln!(
                            "mci-agent: no brain key found in Keychain. \
                             Health-only drain. Launch Hippocampus.app or run `mci-agent init` to initialize."
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
            let _pc_listener_task = if capture_ingestion_enabled {
                if let Some((_, store)) = brain_pump.as_ref() {
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
                            eprintln!("mci-agent: page-content listener on {}", sock.display());
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
                }
            } else {
                None
            };

            let drain_result = match (capture_ingestion_enabled, brain_pump.as_ref()) {
                (true, Some((pump, _store))) => {
                    drain_to_log_with_brain(&mut stdin, &log, &clock, &device_id, pump).await
                }
                _ => drain_to_log(&mut stdin, &log, &clock, &device_id).await,
            };

            // Signal shutdown to idle-batch + episode workers.
            let _ = shutdown_tx.send(true);

            // Mark the run clean, but retain the advisory descriptor until
            // process teardown. Background Tokio/runtime cleanup therefore
            // cannot outlive the one-writer lease.
            if let Some(lock) = writer_run_lock.take() {
                if let Err(e) = lock.release_at_process_exit() {
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
        Mode::UnknownCommand { name } => {
            eprintln!("mci-agent: unknown command `{name}`.\n");
            print_usage();
            ExitCode::from(2)
        }
        Mode::RegisterMcp { db_path } => match register_mcp(&db_path) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("mci-agent register-mcp: {e}");
                ExitCode::from(14)
            }
        },
        Mode::ConnectAll { db_path } => match run_connect_all_cmd(&db_path) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::Init { db_path, root } => match run_init_cmd(&db_path, &root) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::EnsureKey { db_path } => match run_ensure_key_cmd(&db_path) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::ImportSessions { db_path, root } => match run_import_sessions_cmd(&db_path, &root) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::Doctor { db_path } => match run_doctor_cmd(&db_path) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::Enrich {
            db_path,
            batch_size,
        } => match run_enrich_cmd(&db_path, batch_size) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::Brief {
            db_path,
            date,
            model_dir,
        } => match run_brief_cmd(&db_path, date.as_deref(), model_dir) {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
        Mode::McpSync { db_path } => match run_mcp_sync_cmd(&db_path).await {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
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
/// Opens the brain `SQLCipher` store **read-only** (per
/// `SqlCipherBrainStore::open_readonly`, ADR-0017 §5), aggregates events
/// inserted since `now - since_seconds` whose `app_bundle_id` belongs to
/// the bundle set associated with `source`, prints the integer total to
/// stdout, exits 0.
///
/// Exit codes:
///   0 — query ran (count is on stdout; may be zero)
///   2 — `source` unknown
///   3 — production Keychain reference unavailable
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

    let Ok(key_hex) = resolve_key_for_command("stats") else {
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
        .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX));
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

/// Read the development file key when the explicit development gate is set.
fn read_dev_key_hex() -> Option<String> {
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let explicit_key_file = std::env::var_os("MCI_DB_KEY_FILE").map(PathBuf::from);
    development_key_hex_from(
        std::env::var("MCI_DEVELOPMENT_FILE_KEY").ok().as_deref(),
        std::env::var("MCI_DB_KEY_HEX").ok().as_deref(),
        explicit_key_file.as_deref(),
        home.as_deref(),
    )
}

fn development_key_hex_from(
    marker: Option<&str>,
    raw_key: Option<&str>,
    explicit_key_file: Option<&Path>,
    home: Option<&Path>,
) -> Option<String> {
    guard_development_marker(marker)?;
    if let Some(path) = explicit_key_file {
        return read_development_key_file(path);
    }
    raw_key
        .filter(|key| key_resolver::is_valid_database_key(key))
        .map(str::to_owned)
        .or_else(|| {
            let path = home?.join("Library/Application Support/MCI/dev.key");
            read_development_key_file(&path)
        })
}

fn read_development_key_file(path: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(path).ok()?;
    let key = contents
        .strip_suffix("\r\n")
        .or_else(|| contents.strip_suffix('\n'))
        .unwrap_or(&contents);
    key_resolver::is_valid_database_key(key).then(|| key.to_owned())
}

fn guard_development_marker(marker: Option<&str>) -> Option<()> {
    (marker == Some("1")).then_some(())
}

/// Resolve the brain key from Keychain. Raw/file keys are development-only
/// and, when explicitly enabled, take precedence over Keychain. This lets an
/// ad-hoc child avoid an ACL-denied production item without weakening release
/// custody: the marker is never emitted by a Developer ID bundle.
fn resolve_key_hex() -> Result<String, key_resolver::KeyResolutionError> {
    if let Some(key) = read_dev_key_hex() {
        return Ok(key);
    }
    key_resolver::resolve_database_key()
}

fn report_key_resolution_error(command: &str, error: &key_resolver::KeyResolutionError) {
    eprintln!(
        "mci-agent {command}: cannot resolve the database key from the macOS Keychain: {error}. \
         Launch the bundled Hippocampus.app to initialize or unlock access. \
         MCI_DEVELOPMENT_FILE_KEY=1 enables raw/file keys for development only."
    );
}

fn resolve_key_for_command(command: &str) -> Result<String, u8> {
    resolve_key_hex().map_err(|error| {
        report_key_resolution_error(command, &error);
        10
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WriterCommand {
    Init,
    ImportSessions,
    Enrich,
    Brief,
    McpSync,
    EmbedBackfill,
}

impl WriterCommand {
    #[cfg(test)]
    const ALL: [Self; 6] = [
        Self::Init,
        Self::ImportSessions,
        Self::Enrich,
        Self::Brief,
        Self::McpSync,
        Self::EmbedBackfill,
    ];

    const fn label(self) -> &'static str {
        match self {
            Self::Init => "init",
            Self::ImportSessions => "import-sessions",
            Self::Enrich => "enrich",
            Self::Brief => "brief",
            Self::McpSync => "mcp-sync",
            Self::EmbedBackfill => "embed-backfill",
        }
    }
}

#[derive(Debug)]
struct CommandWriterLease {
    command: WriterCommand,
    unclean_prior_shutdown: bool,
    lock: Option<mci_agent::crash_recovery::RunLock>,
}

impl Drop for CommandWriterLease {
    fn drop(&mut self) {
        if let Some(lock) = self.lock.take() {
            if let Err(error) = lock.release() {
                eprintln!(
                    "mci-agent {}: writer lease clean-release failed: {error}",
                    self.command.label()
                );
            }
        }
    }
}

fn acquire_command_writer_lease(
    command: WriterCommand,
    db_path: &Path,
) -> Result<CommandWriterLease, u8> {
    let command_label = command.label();
    let run_lock_path = lock_path_for_brain(db_path);
    match acquire_lock(&run_lock_path) {
        Ok((outcome, lock)) => {
            let unclean_prior_shutdown =
                matches!(outcome, LockAcquireOutcome::UncleanShutdown { .. });
            if let LockAcquireOutcome::UncleanShutdown { stale_pid } = outcome {
                eprintln!(
                    "mci-agent {command_label}: prior writer ended uncleanly (stale pid {stale_pid:?})"
                );
            }
            Ok(CommandWriterLease {
                command,
                unclean_prior_shutdown,
                lock: Some(lock),
            })
        }
        Err(LockError::WriterLeaseHeld { owner_pid }) => {
            eprintln!(
                "mci-agent {command_label}: another writer owns the brain lease (pid {owner_pid:?}); refusing to mutate"
            );
            Err(26)
        }
        Err(error) => {
            eprintln!(
                "mci-agent {command_label}: cannot establish exclusive brain writer lease: {error}"
            );
            Err(26)
        }
    }
}

fn verify_command_writer_integrity<E, F>(
    command: WriterCommand,
    lease: &CommandWriterLease,
    mut verify: F,
) -> Result<(), u8>
where
    E: std::fmt::Display,
    F: FnMut() -> Result<(), E>,
{
    let pass_count = if lease.unclean_prior_shutdown { 2 } else { 1 };
    for pass in 1..=pass_count {
        if let Err(error) = verify() {
            eprintln!(
                "mci-agent {}: integrity_check failed before mutation (pass {pass}/{pass_count}): {error}",
                command.label()
            );
            return Err(COMMAND_INTEGRITY_FAILURE_EXIT_CODE);
        }
    }
    Ok(())
}

fn open_command_writer(
    command: WriterCommand,
    db_path: &Path,
    key: &DbKey,
    lease: &CommandWriterLease,
) -> Result<SqlCipherBrainStore, u8> {
    let command_label = command.label();
    let store = SqlCipherBrainStore::new(db_path, key).map_err(|error| {
        eprintln!(
            "mci-agent {command_label}: open brain at {}: {error}",
            db_path.display()
        );
        12
    })?;
    verify_command_writer_integrity(command, lease, || store.verify_integrity_on_boot())?;
    Ok(store)
}

/// Register Hippocampus as an MCP server in Claude Code's MCP config
/// (`~/.claude.json`). Merges the `hippocampus` entry under
/// `mcpServers` without clobbering other servers. Includes an `env`
/// block with a Keychain reference, never with reusable key material.
/// Write the Hippocampus entry into Claude Code's `~/.claude.json`.
///
/// `db_path` is the brain this agent just resolved. It has to be recorded
/// explicitly: `mcp-serve` otherwise falls back to the hardcoded default,
/// so a user who imported into any other path would register a server that
/// opens an empty (or absent) database and reports success while doing it.
fn register_mcp(db_path: &Path) -> Result<(), String> {
    let registry = ClientRegistry::discover()?;
    match registry
        .register_claude(db_path)
        .map_err(|error| error.to_string())?
    {
        RegistrationChange::Updated => {
            println!("Hippocampus registered with Claude Code. Restart Claude Code to connect.");
        }
        RegistrationChange::AlreadyCurrent => {
            println!("Hippocampus is already registered with Claude Code.");
        }
    }
    Ok(())
}

fn run_connect_all_cmd(db_path: &Path) -> Result<(), u8> {
    let registry = ClientRegistry::discover().map_err(|error| {
        eprintln!("mci-agent connect --all: {error}");
        14
    })?;
    let report = registry.connect_all(db_path);
    let claude_failed = print_client_registration("Claude Code", &report.claude);
    let codex_failed = print_client_registration("Codex", &report.codex);
    if claude_failed || codex_failed {
        Err(14)
    } else {
        Ok(())
    }
}

fn print_client_registration(name: &str, registration: &ClientRegistration) -> bool {
    match registration.status {
        RegistrationStatus::Registered => {
            println!("  {name:<11} connected");
            false
        }
        RegistrationStatus::Unchanged => {
            println!("  {name:<11} already connected");
            false
        }
        RegistrationStatus::NotInstalled => {
            println!("  {name:<11} not installed, skipped");
            false
        }
        RegistrationStatus::BlockedMalformed
        | RegistrationStatus::NameConflict
        | RegistrationStatus::Failed => {
            eprintln!(
                "  {name:<11} failed: {}",
                registration.detail.as_deref().unwrap_or("unknown error")
            );
            true
        }
    }
}

/// Resolve the `SQLCipher` key from the production Keychain reference, open the brain,
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
/// Production resolves the file-Keychain service/account reference. Raw and
/// file keys remain available only behind `MCI_DEVELOPMENT_FILE_KEY=1`.
async fn run_mcp_serve(db_path: PathBuf) -> Result<(), u8> {
    let key_hex = resolve_key_for_command("mcp-serve")?;
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!(
            "mci-agent mcp-serve: resolved database key is malformed; refusing to open the brain."
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

/// Import Claude Code session transcripts.
///
/// Opened read-write: this writes events. It reads only transcripts the user
/// already has on disk, and indexes only the conversation text, never tool
/// output or model reasoning.
fn run_import_sessions_cmd(db_path: &std::path::Path, root: &std::path::Path) -> Result<(), u8> {
    let lease = acquire_command_writer_lease(WriterCommand::ImportSessions, db_path)?;
    run_import_sessions_with_lease(db_path, root, &lease)
}

fn run_import_sessions_with_lease(
    db_path: &Path,
    root: &Path,
    lease: &CommandWriterLease,
) -> Result<(), u8> {
    let key_hex = resolve_key_for_command("import-sessions")?;
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent import-sessions: resolved database key is malformed.");
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    let store = open_command_writer(WriterCommand::ImportSessions, db_path, &key, lease)?;

    eprintln!("mci-agent import-sessions: reading {}", root.display());
    let stats = match mci_agent::import_sessions::import_sessions(&store, root, |s| {
        if s.files_scanned % 10 == 0 {
            eprintln!(
                "mci-agent import-sessions: {} files, {} events",
                s.files_scanned, s.events_written
            );
        }
    }) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("mci-agent import-sessions: {e}");
            return Err(24);
        }
    };

    eprintln!(
        "mci-agent import-sessions: done. {} files, {} records, {} events written \
         ({} had no conversation text, {} malformed lines).",
        stats.files_scanned,
        stats.records_read,
        stats.events_written,
        stats.skipped_no_text,
        stats.malformed_lines,
    );
    eprintln!("mci-agent import-sessions: next, run `mci-agent enrich`.");
    Ok(())
}

#[cfg(target_os = "macos")]
struct NativeKeychainWriter;

#[cfg(target_os = "macos")]
impl key_resolver::KeychainWriter for NativeKeychainWriter {
    fn add_generic_password(
        &self,
        service: &str,
        account: &str,
        secret: &str,
        trusted_application_paths: &[PathBuf],
    ) -> Result<(), key_resolver::KeyResolutionError> {
        match mci_keychain::add_file_generic_password_with_acl(
            service,
            account,
            secret.as_bytes(),
            trusted_application_paths,
        ) {
            Ok(()) => Ok(()),
            Err(mci_keychain::Error::Status(-25299)) => {
                Err(key_resolver::KeyResolutionError::KeyAlreadyExists)
            }
            Err(mci_keychain::Error::Status(status)) => {
                Err(key_resolver::KeyResolutionError::WriteFailure { status })
            }
            Err(mci_keychain::Error::AclStatus(status)) => {
                Err(key_resolver::KeyResolutionError::AclUnavailable {
                    reason: format!("Security.framework ACL creation failed with status {status}"),
                })
            }
            Err(mci_keychain::Error::EmptyTrustedApplications) => {
                Err(key_resolver::KeyResolutionError::AclUnavailable {
                    reason: "trusted executable list is empty".to_owned(),
                })
            }
            Err(mci_keychain::Error::InvalidPath) => {
                Err(key_resolver::KeyResolutionError::AclUnavailable {
                    reason: "trusted executable path contains a NUL byte".to_owned(),
                })
            }
            Err(mci_keychain::Error::InvalidResult) => {
                Err(key_resolver::KeyResolutionError::WriteFailure { status: -26275 })
            }
        }
    }
}

fn run_ensure_key_cmd(db_path: &Path) -> Result<(), u8> {
    let home = if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home)
    } else {
        eprintln!("hippocampus ensure-key: HOME is not set.");
        return Err(30);
    };
    let support = home.join("Library/Application Support/MCI");
    if let Err(error) = std::fs::create_dir_all(&support) {
        eprintln!(
            "hippocampus ensure-key: create {}: {error}",
            support.display()
        );
        return Err(31);
    }

    #[cfg(target_os = "macos")]
    {
        let contract =
            key_resolver::KeychainAclContract::from_current_executable().map_err(|error| {
                eprintln!("hippocampus ensure-key: {error}. Launch the bundled Hippocampus.app.");
                33
            })?;
        let outcome = key_resolver::initialize_database_key_with(
            &key_resolver::SystemKeychainReader,
            &NativeKeychainWriter,
            &key_resolver::SqlCipherDatabaseKeyValidator,
            &key_resolver::KeychainKeyReference::default(),
            &contract.trusted_application_paths,
            db_path,
            &support.join("dev.key"),
            || {
                let mut bytes = [0u8; 32];
                getrandom::fill(&mut bytes).map_err(|error| {
                    key_resolver::KeyResolutionError::GenerationFailure {
                        reason: error.to_string(),
                    }
                })?;
                let mut encoded = String::with_capacity(bytes.len() * 2);
                for byte in bytes {
                    write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
                }
                Ok(encoded)
            },
        )
        .map_err(|error| {
            eprintln!("hippocampus ensure-key: database key unchanged: {error}");
            33
        })?;

        match outcome {
            key_resolver::KeyInitializationOutcome::AlreadyPresent => {
                println!("  key      existing Keychain item validated");
            }
            key_resolver::KeyInitializationOutcome::Created => {
                println!("  key      created in macOS Keychain with bundled-executable ACL");
            }
            key_resolver::KeyInitializationOutcome::MigratedLegacyKey => {
                println!("  key      legacy database key migrated and validated");
            }
            key_resolver::KeyInitializationOutcome::ConcurrentItemValidated => {
                println!("  key      concurrent Keychain item re-read and validated");
            }
            key_resolver::KeyInitializationOutcome::CompletedInterruptedMigration => {
                println!("  key      interrupted legacy migration completed and plaintext removed");
            }
        }
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = db_path;
        eprintln!("hippocampus ensure-key: production Keychain initialization requires macOS");
        Err(33)
    }
}

/// One-command setup.
///
/// Chains what a new user would otherwise do by hand: make a key, import
/// their Claude Code history, index it, and register as an MCP server. The
/// point is that none of it needs an environment variable, because
/// `resolve_key_hex` reads the Keychain reference this writes.
///
/// Safe to re-run. It never overwrites an existing key, because doing so
/// would make an existing brain permanently unreadable.
fn run_init_cmd(db_path: &std::path::Path, root: &std::path::Path) -> Result<(), u8> {
    let lease = acquire_command_writer_lease(WriterCommand::Init, db_path)?;

    // 1. Key. This is the same migration/validation path the app runs before
    // starting capture, so CLI initialization cannot fork custody behavior.
    run_ensure_key_cmd(db_path)?;

    // 2. Import. Missing transcripts is not an error: plenty of people have
    // never run Claude Code, and they should still get a working install.
    if root.exists() {
        match run_import_sessions_with_lease(db_path, root, &lease) {
            Ok(()) => {}
            Err(code) => return Err(code),
        }
    } else {
        println!(
            "  import   skipped, no transcripts at {} (nothing to import yet)",
            root.display()
        );
    }

    // 3. Index.
    run_enrich_with_lease(db_path, DEFAULT_EMBED_BATCH_SIZE, &lease)?;

    // 4. Register every detected local client with reference-only custody.
    run_connect_all_cmd(db_path)?;

    println!("\nDone. Try it:\n");
    println!("  mci-brain search \"some phrase you remember\"");
    println!("\nOr restart Claude Code or Codex and ask what you were working on.");
    println!("Run `mci-agent doctor` if anything looks wrong.");
    Ok(())
}

/// Print the diagnostic report.
///
/// Read-only: opens the brain with `open_readonly` and reads logs it
/// already owns. Exits non-zero when something is blocking, so it can gate
/// a script.
fn run_doctor_cmd(db_path: &std::path::Path) -> Result<(), u8> {
    let key_hex = resolve_key_for_command("doctor")?;
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent doctor: resolved database key is malformed.");
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    let checks = match mci_agent::doctor::diagnose(db_path, &key) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("mci-agent doctor: {e}");
            return Err(12);
        }
    };

    println!("Hippocampus doctor — {}\n", db_path.display());
    print!("{}", mci_agent::doctor::render(&checks));

    let blocked = checks
        .iter()
        .any(|c| c.status == mci_agent::doctor::Status::Fail);
    if blocked {
        return Err(1);
    }
    Ok(())
}

/// Run every understanding stage over an existing brain.
///
/// Opened read-write, unlike every other read surface: this writes
/// entities, episodes, identities and edges derived from events already in
/// the store. It writes no new events, so it cannot introduce content the
/// capture cascade did not already allow.
///
/// The embedder is optional. Without one the embed stage is skipped with a
/// note and everything else still runs, because entities, episodes and
/// identities need no model.
fn run_enrich_cmd(db_path: &std::path::Path, batch_size: usize) -> Result<(), u8> {
    let lease = acquire_command_writer_lease(WriterCommand::Enrich, db_path)?;
    run_enrich_with_lease(db_path, batch_size, &lease)
}

fn run_enrich_with_lease(
    db_path: &Path,
    batch_size: usize,
    lease: &CommandWriterLease,
) -> Result<(), u8> {
    let key_hex = resolve_key_for_command("enrich")?;
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent enrich: resolved database key is malformed.");
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    let store = open_command_writer(WriterCommand::Enrich, db_path, &key, lease)?;

    let (embedder, is_real) = load_embedder_backend();
    let embedder_ref: Option<&dyn mci_brain::Embedder> = if is_real {
        Some(embedder.as_ref())
    } else {
        None
    };

    let stats =
        match mci_agent::enrich::run_enrich(&store, embedder_ref, batch_size, |stage, msg| {
            eprintln!("mci-agent enrich: [{}] {msg}", stage.label());
        }) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("mci-agent enrich: {e}");
                return Err(23);
            }
        };

    eprintln!(
        "mci-agent enrich: done. {} events scanned, {} mentions, {} embedded, \
         {} events in {} episodes, {} identities, {} episode links.",
        stats.events_scanned,
        stats.mentions_written,
        stats.embedded,
        stats.events_segmented,
        stats.episodes_created,
        stats.identities,
        stats.edges_written,
    );
    if !is_real {
        eprintln!(
            "mci-agent enrich: note — no embedder, so recall stays keyword-only. \
             See `mci-agent embed-backfill` for how to build the model."
        );
    }
    Ok(())
}

/// Write one daily brief over an existing brain.
///
/// # Why this exists
///
/// `spawn_brief_worker` is called from inside the `--drain-stdin` arm, so
/// the only way to reach the brief pipeline was to be running live capture.
/// Capture can be disabled in app preferences, so on a brain filled by the
/// seeder, the Mail or Messages readers, or an import, the worker was
/// never spawned at all and no command existed that produced a brief. The
/// pipeline was finished and unreachable.
///
/// This calls `brief_worker::generate_brief_once` — the same function the
/// scheduled worker calls, once, then exits.
///
/// # ADR-0018
///
/// The brief lands in `Draft`. There is deliberately no flag here that
/// approves one: reaching `Approved` requires `lifecycle::advance` with an
/// explicit human approver id, and no CLI argument can stand in for a
/// person.
fn run_brief_cmd(
    db_path: &std::path::Path,
    date: Option<&str>,
    model_dir: Option<PathBuf>,
) -> Result<(), u8> {
    let model_dir = model_dir.unwrap_or_else(brief_worker::default_model_dir);

    // Arguments before the world: a mistyped date gets the same answer on
    // every machine, whatever else is missing.
    let tz_offset = brief_worker::current_tz_offset_secs();
    let now_us: u64 = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX));
    let window = match date {
        Some(d) => {
            if let Some(w) = brief_worker::BriefWindow::for_local_date(d, tz_offset) {
                w
            } else {
                eprintln!(
                    "mci-agent brief: --date wants a real calendar date as YYYY-MM-DD, got '{d}'."
                );
                return Err(2);
            }
        }
        None => brief_worker::BriefWindow::trailing_24h(now_us, tz_offset),
    };

    // Then the gate. Without an author nothing else matters, and a person
    // whose model is missing should hear that instead of a key complaint.
    let gate = brief_worker::brief_gate(&model_dir, brief_worker::briefs_disabled_via_env());
    if gate != brief_worker::BriefGate::Open {
        eprintln!(
            "mci-agent brief: {}",
            brief_worker::gate_block_message(gate, &model_dir)
        );
        return Err(21);
    }

    let lease = acquire_command_writer_lease(WriterCommand::Brief, db_path)?;

    let key_hex = resolve_key_for_command("brief")?;
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent brief: resolved database key is malformed.");
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    // Read-write: this writes a `briefs` row. It never touches `events`.
    let store = open_command_writer(WriterCommand::Brief, db_path, &key, &lease)?;

    let topic = match date {
        Some(d) => format!("Daily brief for {d}"),
        None => "Daily brief".to_owned(),
    };
    let factory = qwen3_author_factory(&model_dir);

    eprintln!(
        "mci-agent brief: summarizing {} into a draft for {}",
        match date {
            Some(_) => "that local day",
            None => "the last 24 hours",
        },
        window.date_local,
    );

    match brief_worker::generate_brief_once(&store, &factory, &topic, &window, now_us) {
        Ok(brief_worker::BriefOutcome::Stored {
            date_local,
            word_count,
            event_count,
            id,
            citation_violations,
        }) => {
            eprintln!(
                "mci-agent brief: wrote draft id={id} for {date_local} \
                 ({event_count} events, {word_count} words)."
            );
            if citation_violations > 0 {
                eprintln!(
                    "mci-agent brief: the tripwire found {citation_violations} citation \
                     violation(s). The draft was still written — that is what review is \
                     for — but approval stays blocked until they clear (ADR-0018 §4.2)."
                );
            }
            eprintln!(
                "mci-agent brief: state = Draft. Approving a brief takes a person, so \
                 nothing here advances it (ADR-0018 §4.1). The row is in the `briefs` \
                 table keyed on {date_local}, which is where the Recall UI's Brief tab \
                 reads it from."
            );
            Ok(())
        }
        Ok(brief_worker::BriefOutcome::SkippedEmpty) => {
            eprintln!(
                "mci-agent brief: no events in {}, so there was nothing to summarize and \
                 no brief was written.\n\
                 \n\
                 If you expected events there, `mci-agent doctor` says why the brain is \
                 empty. If the brain has events from other days, name one with \
                 `--date YYYY-MM-DD`.",
                match date {
                    Some(d) => format!("{d} (local)"),
                    None => "the last 24 hours".to_owned(),
                }
            );
            Err(22)
        }
        Err(e) => {
            eprintln!("mci-agent brief: {e}");
            Err(23)
        }
    }
}

/// Pull every registered MCP server's resources into the brain, once.
///
/// The aggregator that does this was reachable only from
/// `--drain-stdin`, the live-capture ingest path, which ships off. So a
/// user who registered an MCP server in `mcp-servers.toml` got nothing:
/// the connector was built, tested, and never called.
///
/// Opened read-write, like `enrich` and `embed-backfill` and unlike the
/// read surfaces: this writes events.
///
/// Exit codes:
///   0 — a pass ran, or there was nothing configured to sync
///   10 / 11 / 12 — brain key missing, malformed, or the store would not open
///   24 — every registered server failed to connect
///   25 — the config file exists but could not be trusted or parsed
async fn run_mcp_sync_cmd(db_path: &std::path::Path) -> Result<(), u8> {
    use mci_agent::mcp_sync::{
        default_config_path, no_config_guidance, no_servers_guidance, render_stats, run_mcp_sync,
        SyncOutcome,
    };

    let lease = acquire_command_writer_lease(WriterCommand::McpSync, db_path)?;
    let key_hex = resolve_key_for_command("mcp-sync")?;
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent mcp-sync: resolved database key is malformed.");
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    let store = Arc::new(open_command_writer(
        WriterCommand::McpSync,
        db_path,
        &key,
        &lease,
    )?);

    let config_path = default_config_path();
    match run_mcp_sync(&config_path, store).await {
        Ok(SyncOutcome::NoConfig { path }) => {
            eprintln!("{}", no_config_guidance(&path));
            Ok(())
        }
        Ok(SyncOutcome::NoServers { path }) => {
            eprintln!("{}", no_servers_guidance(&path));
            Ok(())
        }
        Ok(SyncOutcome::Ran(stats)) => {
            eprintln!("mci-agent mcp-sync: done. {}", render_stats(&stats));
            if stats.servers_failed > 0 && stats.servers_ok == 0 {
                eprintln!(
                    "mci-agent mcp-sync: every registered server failed to connect. \
                     Check that each one is running and that its url in {} is right.",
                    config_path.display()
                );
                return Err(24);
            }
            if stats.servers_failed > 0 {
                eprintln!(
                    "mci-agent mcp-sync: note — {} of {} server(s) could not be reached; \
                     the rest were synced.",
                    stats.servers_failed, stats.servers_contacted,
                );
            }
            Ok(())
        }
        Err(e) => {
            eprintln!("mci-agent mcp-sync: {e}");
            Err(25)
        }
    }
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
    let key_hex = resolve_key_for_command("embed-backfill")?;
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-agent embed-backfill: resolved database key is malformed.");
        return Err(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    let (embedder, is_real) = load_embedder_backend();
    if !is_real {
        eprintln!(
            "mci-agent embed-backfill: no real embedder available, refusing to run.\n\
             \n\
             Semantic recall needs the ArcticEmbedS Core ML model. It is ~66 MB\n\
             and is not checked into the repository. Build it with:\n\
             \n\
               python3.11 -m venv .venv-ml && source .venv-ml/bin/activate\n\
               pip install -r scripts/requirements-ml.txt\n\
               python scripts/convert_embedder.py \\\n\
                 --output models/ArcticEmbedS_INT8.mlpackage --verify\n\
             \n\
             That writes both a .mlpackage and a .mlmodelc. The loader needs\n\
             the .mlmodelc; a raw .mlpackage cannot be opened at runtime.\n\
             Point at it explicitly if it lives elsewhere:\n\
             \n\
               export MCI_ARCTIC_MODEL_PATH=models/ArcticEmbedS_INT8.mlmodelc\n\
             \n\
             Until then recall works, but keyword-only. Nothing is broken;\n\
             there is just no semantic half to fill in yet."
        );
        return Err(20);
    }

    let lease = acquire_command_writer_lease(WriterCommand::EmbedBackfill, db_path)?;

    let store = open_command_writer(WriterCommand::EmbedBackfill, db_path, &key, &lease)?;

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
            );
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

/// Resolve + load the V2-P5+ SYNC BERT NER backend (`dslim/bert-base-NER`,
/// INT8, `cpu_only`). Returns `None` when no `.mlmodelc` is found on disk
/// (opt-in download — Tier 1 + the async Qwen tier still run regardless) or
/// the load fails. The bundled `WordPiece` tokenizer travels inside
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

/// Build the production brief author: Qwen3-1.7B over Core ML, loaded
/// lazily inside the factory so the ~500 MB working set is resident only
/// while a brief is being written (ADR-0028 §6).
///
/// Path layout matches `ModelDownloadManager`'s unpack convention:
/// `<model_dir>/<modelID>/<basename>/...`. Shared by the scheduled worker
/// and `mci-agent brief` so the two cannot end up on different models.
#[cfg(target_os = "macos")]
fn qwen3_author_factory(model_dir: &std::path::Path) -> brief_worker::AuthorFactory {
    use mci_brief::author::BriefAuthor;
    use mci_brief::llama_author::LlamaBriefAuthor;
    use mci_brief::llama_backend::LlamaBackend;

    let model_subdir = model_dir.join(brief_worker::QWEN3_MODEL_ID);
    let model_path = model_subdir.join(brief_worker::QWEN3_MODEL_BASENAME);
    let tokenizer_dir = model_subdir;
    Arc::new(move || {
        let backend = mci_coreml_bridge::Qwen3CoreMLBackend::open(&model_path, &tokenizer_dir)
            .map_err(|e| {
                brief_worker::BriefWorkerError::Author(format!("Qwen3CoreMLBackend::open: {e}"))
            })?;
        let backend_arc: Arc<dyn LlamaBackend> = Arc::new(backend);
        let author = LlamaBriefAuthor::new(backend_arc);
        let boxed: Box<dyn BriefAuthor> = Box::new(author);
        Ok(boxed)
    })
}

/// Non-macOS: there is no Core ML, so there is no author. The factory
/// exists so the `brief` command compiles everywhere and fails with a
/// reason rather than being absent.
#[cfg(not(target_os = "macos"))]
fn qwen3_author_factory(_model_dir: &std::path::Path) -> brief_worker::AuthorFactory {
    Arc::new(|| {
        Err(brief_worker::BriefWorkerError::Author(
            "brief generation runs Qwen3 through Core ML, which exists only on macOS".to_owned(),
        ))
    })
}

/// Spawn the daily-brief worker (ADR-0028). Selects between the
/// production Qwen3 Core ML backend and the disabled-idle path based on
/// `MCI_BRIEFS_DISABLED`, the presence of the model, and the host OS.
#[cfg(target_os = "macos")]
fn spawn_brief_worker(
    store: Arc<mci_brain::SqlCipherBrainStore>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
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

    let factory = qwen3_author_factory(&model_dir);

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
///   canonical user-allowlist path, and runs the reconcile loop until
///   shutdown.
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
    store: Arc<mci_brain::SqlCipherBrainStore>,
    embedder: Option<Arc<dyn mci_brain::Embedder>>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    let aggregator = mci_agent::mcp_aggregator::McpAggregator::new(
        Arc::clone(&registry),
        Arc::clone(&store) as Arc<dyn mci_brain::BrainStore>,
        embedder,
    );
    eprintln!(
        "mci-agent: MCP aggregator started (reconcile every {}s; materialize cap {} bytes)",
        mci_agent::mcp_aggregator::DEFAULT_RECONCILE_INTERVAL.as_secs(),
        mci_agent::mcp_aggregator::DEFAULT_MATERIALIZE_MAX_BYTES,
    );
    tokio::spawn(async move {
        let registrations = registry.list().await;
        if let Err(error) = mci_agent::mcp_sync::seed_resource_revisions_from_store(
            &registrations,
            &store,
            &aggregator,
        )
        .await
        {
            eprintln!("mci-agent: MCP aggregator revision seed failed: {error}");
            return;
        }
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

#[cfg(test)]
mod capture_consent_tests {
    use super::{capture_ingestion_enabled, development_key_hex_from};
    use std::path::Path;

    #[test]
    fn packaged_app_can_disable_all_observation_ingestion() {
        assert!(!capture_ingestion_enabled(Some("0")));
        assert!(!capture_ingestion_enabled(Some("false")));
        assert!(!capture_ingestion_enabled(Some("unexpected")));
    }

    #[test]
    fn explicit_enable_and_direct_cli_default_allow_ingestion() {
        assert!(capture_ingestion_enabled(Some("1")));
        assert!(capture_ingestion_enabled(Some("true")));
        assert!(capture_ingestion_enabled(None));
    }

    #[test]
    fn explicit_development_marker_prefers_the_fixed_local_key() {
        let key = "ab".repeat(32);
        let root = tempfile::tempdir().expect("temporary home");
        let key_path = root.path().join("Library/Application Support/MCI/dev.key");
        std::fs::create_dir_all(key_path.parent().expect("key parent")).expect("key parent");
        std::fs::write(&key_path, &key).expect("write dev key");

        assert_eq!(
            development_key_hex_from(Some("1"), None, None, Some(root.path())),
            Some(key)
        );
        assert_eq!(
            development_key_hex_from(
                None,
                Some("cd".repeat(32).as_str()),
                None,
                Some(Path::new("/tmp"))
            ),
            None
        );
    }

    #[test]
    fn supervisor_explicit_key_file_is_honored_only_behind_exact_development_marker() {
        let root = tempfile::tempdir().expect("temporary root");
        let key_path = root.path().join("supervisor-selected.key");
        let key = "ef".repeat(32);
        std::fs::write(&key_path, format!("{key}\n")).expect("write explicit dev key");

        assert_eq!(
            development_key_hex_from(Some("1"), None, Some(&key_path), None),
            Some(key.clone())
        );
        assert_eq!(
            development_key_hex_from(Some("true"), None, Some(&key_path), None),
            None
        );
        assert_eq!(
            development_key_hex_from(None, None, Some(&key_path), None),
            None
        );

        std::fs::write(&key_path, format!("{key} ")).expect("write padded key");
        assert_eq!(
            development_key_hex_from(Some("1"), None, Some(&key_path), None),
            None,
            "non-newline whitespace must not be normalized into key material"
        );
        std::fs::write(&key_path, "g0".repeat(32)).expect("write non-hex key");
        assert_eq!(
            development_key_hex_from(Some("1"), None, Some(&key_path), None),
            None
        );
    }
}

#[cfg(test)]
mod writer_command_lease_tests {
    use super::{
        acquire_command_writer_lease, verify_command_writer_integrity, WriterCommand,
        COMMAND_INTEGRITY_FAILURE_EXIT_CODE,
    };
    use mci_agent::crash_recovery::{acquire_lock, lock_path_for_brain, LockError};
    use std::cell::Cell;
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::time::Duration;

    #[test]
    fn one_shot_writer_lease_blocks_daemon_startup_for_its_scope() {
        let root = tempfile::tempdir().expect("temporary root");
        let brain = root.path().join("brain.sqlite");
        let lease =
            acquire_command_writer_lease(WriterCommand::Enrich, &brain).expect("command lease");

        assert!(matches!(
            acquire_lock(&lock_path_for_brain(&brain)),
            Err(LockError::WriterLeaseHeld { .. })
        ));

        drop(lease);
        let (_outcome, daemon) =
            acquire_lock(&lock_path_for_brain(&brain)).expect("lease released at scope end");
        daemon.release().expect("clean daemon release");
    }

    #[test]
    fn unclean_writer_integrity_failure_stops_before_mutation_body() {
        let root = tempfile::tempdir().expect("temporary root");
        let brain = root.path().join("brain.sqlite");
        let marker = lock_path_for_brain(&brain);
        std::fs::create_dir_all(marker.parent().expect("marker parent")).expect("create parent");
        std::fs::write(&marker, "999999999").expect("seed unclean marker");
        let lease = acquire_command_writer_lease(WriterCommand::Enrich, &brain)
            .expect("recover unclean lease");
        let passes = Cell::new(0_u8);
        let body_reached = Cell::new(false);

        let result = (|| {
            verify_command_writer_integrity(WriterCommand::Enrich, &lease, || {
                passes.set(passes.get() + 1);
                Err("injected integrity failure")
            })?;
            body_reached.set(true);
            Ok::<(), u8>(())
        })();

        assert_eq!(result, Err(COMMAND_INTEGRITY_FAILURE_EXIT_CODE));
        assert_eq!(passes.get(), 1, "first failed pass aborts immediately");
        assert!(!body_reached.get(), "mutation body must not be reached");
        drop(lease);
        assert!(
            !marker.exists(),
            "failure releases the command lease cleanly"
        );
    }

    #[test]
    fn unclean_writer_requires_two_successful_integrity_passes() {
        let root = tempfile::tempdir().expect("temporary root");
        let brain = root.path().join("brain.sqlite");
        let marker = lock_path_for_brain(&brain);
        std::fs::create_dir_all(marker.parent().expect("marker parent")).expect("create parent");
        std::fs::write(&marker, "999999999").expect("seed unclean marker");
        let lease = acquire_command_writer_lease(WriterCommand::ImportSessions, &brain)
            .expect("recover unclean lease");
        let passes = Cell::new(0_u8);

        verify_command_writer_integrity(WriterCommand::ImportSessions, &lease, || {
            passes.set(passes.get() + 1);
            Ok::<(), &str>(())
        })
        .expect("two successful passes");

        assert_eq!(passes.get(), 2);
    }

    #[test]
    fn every_one_shot_writer_command_is_explicitly_enumerated() {
        let labels = WriterCommand::ALL.map(WriterCommand::label);
        assert_eq!(
            labels,
            [
                "init",
                "import-sessions",
                "enrich",
                "brief",
                "mcp-sync",
                "embed-backfill",
            ]
        );
    }

    #[test]
    fn direct_store_writer_opens_are_daemon_or_leased_factory_only() {
        let source = include_str!("mci_agent.rs");
        let writer_open_token = ["SqlCipherBrainStore", "::new("].concat();
        let writer_open_lines: Vec<_> = source
            .lines()
            .filter(|line| line.contains(&writer_open_token))
            .collect();
        assert_eq!(
            writer_open_lines.len(),
            2,
            "new writer entry point bypassed the daemon or leased factory: {writer_open_lines:?}"
        );
    }

    #[test]
    fn one_shot_writer_lease_excludes_another_process_until_owner_dies() {
        let root = tempfile::tempdir().expect("temporary root");
        let brain = root.path().join("brain.sqlite");
        let ready = root.path().join("ready");
        let mut child = Command::new(std::env::current_exe().expect("test executable"))
            .args([
                "--exact",
                "writer_command_lease_tests::child_holds_one_shot_writer_lease",
                "--nocapture",
            ])
            .env("MCI_TEST_COMMAND_LEASE_BRAIN", &brain)
            .env("MCI_TEST_COMMAND_LEASE_READY", &ready)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn command lease holder");

        for _ in 0..250 {
            if ready.exists() {
                break;
            }
            assert!(
                child.try_wait().expect("poll child").is_none(),
                "command lease holder exited before readiness"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(ready.exists(), "command lease holder never became ready");
        assert_eq!(
            acquire_command_writer_lease(WriterCommand::McpSync, &brain)
                .expect_err("concurrent one-shot writer must fail closed"),
            26
        );

        child.kill().expect("kill command lease holder");
        child.wait().expect("reap command lease holder");
        let recovered = acquire_command_writer_lease(WriterCommand::McpSync, &brain)
            .expect("kernel releases command lease on process death");
        drop(recovered);
        assert!(
            !lock_path_for_brain(&brain).exists(),
            "clean recovery removes crash marker"
        );
    }

    #[test]
    fn child_holds_one_shot_writer_lease() {
        let Some(brain) = std::env::var_os("MCI_TEST_COMMAND_LEASE_BRAIN") else {
            return;
        };
        let ready =
            std::env::var_os("MCI_TEST_COMMAND_LEASE_READY").expect("command lease ready path");
        let _lease = acquire_command_writer_lease(WriterCommand::ImportSessions, Path::new(&brain))
            .expect("child command lease");
        std::fs::write(ready, b"ready").expect("publish command lease readiness");
        std::thread::sleep(Duration::from_secs(60));
    }
}
