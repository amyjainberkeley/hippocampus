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

use mci_agent::brain_ingest::{BrainIngestor, BrainPump};
use mci_agent::brief_worker;
use mci_agent::device_id::{load_or_generate, DeviceIdSource};
use mci_agent::health_log::{HealthLog, HealthLogConfig};
use mci_agent::health_summary::summarize_file;
use mci_agent::episode_worker;
use mci_agent::idle_batch;
use mci_agent::mcp::{serve_stdio, LiveBrainReader, Server};
use mci_agent::page_content::PageContentListener;
use mci_agent::retention_worker;
use mci_agent::runner::{drain_to_log, drain_to_log_with_brain};
use mci_agent::panic_uploader::{self, PanicUploader};
use mci_agent::wall_clock::{format_unix_ms, SystemWallClock};
use mci_brain::SqlCipherBrainStore;
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
    /// Register Hippocampus as an MCP server in Claude Code's settings.
    RegisterMcp,
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
            db_path: resolved_db_path,
        },
        ModeKind::RegisterMcp => Mode::RegisterMcp,
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
        \x20 --version                  print version and exit\n\
        \x20 -h, --help                 print this and exit\n\
        \n\
        Options:\n\
        \x20 --device-id-path PATH      default ~/.mci/device-id\n\
        \x20 --log-path PATH            default ~/Library/Logs/MCI/helper-health.jsonl\n\
        \x20 --db-path PATH             default $MCI_DB_PATH or\n\
        \x20                            ~/Library/Application Support/MCI/mci.sqlite\n\
        \x20 --window-seconds N         (with --health-summary) aggregation window. Default 3600.\n\
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

            // P3.10c + P3.8 — open the brain store IFF `MCI_DB_KEY_HEX`
            // is set. The store is shared between:
            //   1. BrainPump (ingest: OCREvent → events table)
            //   2. idle-batch worker (embed: events → event_vectors)
            //
            // Shutdown channel coordinates both halves on SIGINT/SIGTERM.
            let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

            let brain_pump: Option<(BrainPump, Arc<SqlCipherBrainStore>)> =
                match resolve_key_hex() {
                    Some(key_hex) => match decode_hex32(&key_hex) {
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
                            match SqlCipherBrainStore::new(&db_path, &key) {
                                Ok(store) => {
                                    let store = Arc::new(store);
                                    let embedder = load_embedder_backend();
                                    let pump = BrainPump::new(
                                        Arc::clone(&store) as Arc<dyn mci_brain::BrainStore>,
                                        None,
                                    );
                                    eprintln!(
                                        "mci-agent: brain ingest + idle-batch enabled. db={} embedder={}",
                                        db_path.display(),
                                        if embedder.1 { "CoreML" } else { "zero-fallback" },
                                    );

                                    let worker_store = Arc::clone(&store);
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
                                    spawn_brief_worker(
                                        Arc::clone(&store),
                                        shutdown_rx.clone(),
                                    );

                                    Some((pump, store))
                                }
                                Err(e) => {
                                    eprintln!("\n========================================================");
                                    eprintln!("WARNING: BRAIN OPEN FAILED — CAPTURE IS NOT BEING SAVED");
                                    eprintln!("========================================================");
                                    eprintln!("  Error: {e}");
                                    eprintln!("  Path:  {}", db_path.display());
                                    eprintln!();
                                    eprintln!("  Hippocampus is running but your screen activity is NOT");
                                    eprintln!("  being stored in the brain. Possible causes:");
                                    eprintln!("    * Stale brain encrypted with old key");
                                    eprintln!("    * Wrong MCI_DB_KEY_HEX env var");
                                    eprintln!("    * Permissions issue on brain file");
                                    eprintln!();
                                    eprintln!("  To reset: quit Hippocampus.app, delete");
                                    eprintln!("  ~/Library/Application Support/MCI/mci.sqlite + dev.key,");
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
                    },
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

            // Page-content socket listener — accepts PageContentEvent
            // wire frames from the native messaging host (Chromium) and
            // the container-app Safari inbox reader. Shares the store
            // with the main drain loop via a second BrainPump.
            let _pc_listener_task = if let Some((_, store)) = brain_pump.as_ref() {
                let sock = page_content_socket_path();
                match PageContentListener::bind(&sock) {
                    Ok((listener, unix_listener)) => {
                        let pc_pump: Arc<dyn BrainIngestor> = Arc::new(BrainPump::new(
                            Arc::clone(store) as Arc<dyn mci_brain::BrainStore>,
                            None,
                        ));
                        eprintln!(
                            "mci-agent: page-content listener on {}",
                            sock.display(),
                        );
                        Some(tokio::spawn(async move {
                            listener.run(unix_listener, pc_pump).await;
                        }))
                    }
                    Err(e) => {
                        eprintln!(
                            "mci-agent: page-content listener bind failed: {e}"
                        );
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
        Mode::McpServe { db_path } => match run_mcp_serve(db_path).await {
            Ok(()) => ExitCode::SUCCESS,
            Err(code) => ExitCode::from(code),
        },
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
    let exe = std::env::current_exe()
        .map_err(|e| format!("cannot resolve own binary path: {e}"))?;
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
                println!("Hippocampus already registered with Claude Code (path and key unchanged).");
                return Ok(());
            }
        }
        obj.insert("hippocampus".to_owned(), hippocampus_entry);
    }

    let output = serde_json::to_string_pretty(&root)
        .map_err(|e| format!("serialize settings: {e}"))?;
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

    let embedder: Option<Arc<dyn mci_brain::Embedder>> =
        if std::env::var("MCI_EMBEDDER_DISABLED").as_deref() == Ok("1") {
            eprintln!(
                "mci-agent mcp-serve: embedder disabled (MCI_EMBEDDER_DISABLED=1). \
                 Lexical-only recall."
            );
            None
        } else {
            // TODO(P3.8): attempt ArcticEmbedSEmbedder::new_query(CoreMlBackend::new(...))
            // when the .mlpackage is bundled. Until then, fall back gracefully.
            eprintln!(
                "mci-agent mcp-serve: no embedder backend available yet \
                 (ships at P3.8). Lexical-only recall."
            );
            None
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

    let path_refs: Vec<&Path> = candidates.iter().map(|p| p.as_path()).collect();
    let (backend, is_real) = load_backend_or_fallback(&path_refs);
    let embedder = ArcticEmbedSEmbedder::new_document(backend);
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
            let stats = brief_worker::run_disabled_idle(
                "MCI_BRIEFS_DISABLED=1",
                shutdown,
            )
            .await;
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
            let stats = brief_worker::run_disabled_idle(
                "Qwen3 model not installed",
                shutdown,
            )
            .await;
            eprintln!(
                "mci-agent: brief worker exited (no model). generated={} skipped_empty={} errors={}",
                stats.briefs_generated, stats.cycles_skipped_empty, stats.cycle_errors,
            );
        });
        return;
    }

    let model_path = model_dir.join("Qwen3-1.7B-FP16.mlmodelc");
    let tokenizer_dir = model_dir.clone();
    let factory: brief_worker::AuthorFactory = Arc::new(move || {
        let backend = mci_llama_coreml::Qwen3CoreMLBackend::open(&model_path, &tokenizer_dir)
            .map_err(|e| brief_worker::BriefWorkerError::Author(format!(
                "Qwen3CoreMLBackend::open: {e}"
            )))?;
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
