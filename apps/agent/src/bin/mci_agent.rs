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

use mci_agent::device_id::{load_or_generate, DeviceIdSource};
use mci_agent::health_log::{HealthLog, HealthLogConfig};
use mci_agent::health_summary::summarize_file;
use mci_agent::mcp::{serve_stdio, LiveBrainReader, Server};
use mci_agent::runner::drain_to_log;
use mci_agent::wall_clock::{format_unix_ms, SystemWallClock};
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
    DrainStdin,
    HealthSummary { window_seconds: u64 },
    /// P3.10b — localhost MCP server over stdio JSON-RPC 2.0.
    /// Resolves `db_path` and the DB key from env at start-up.
    McpServe { db_path: PathBuf },
}

fn default_device_id_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join(".mci/device-id")
}

fn default_log_path() -> PathBuf {
    HealthLogConfig::default_for_user().path
}

fn default_db_path() -> PathBuf {
    // ~/Library/Application Support/MCI/mci.sqlite per ADR-0008 §1.4.
    // Expand $HOME at run-time (no glob-style ~ expansion in env vars).
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/mci.sqlite")
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
            "--health-summary" => mode_kind = ModeKind::HealthSummary,
            "mcp-serve" => mode_kind = ModeKind::McpServe,
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

    let mode = match mode_kind {
        ModeKind::Help => Mode::Help,
        ModeKind::Version => Mode::Version,
        ModeKind::DrainStdin => Mode::DrainStdin,
        ModeKind::HealthSummary => Mode::HealthSummary { window_seconds },
        ModeKind::McpServe => Mode::McpServe {
            db_path: db_path
                .or_else(|| std::env::var_os("MCI_DB_PATH").map(PathBuf::from))
                .unwrap_or_else(default_db_path),
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
        \x20 --version                  print version and exit\n\
        \x20 -h, --help                 print this and exit\n\
        \n\
        Options:\n\
        \x20 --device-id-path PATH      default ~/.mci/device-id\n\
        \x20 --log-path PATH            default ~/Library/Logs/MCI/helper-health.jsonl\n\
        \x20 --db-path PATH             default $MCI_DB_PATH or\n\
        \x20                            ~/Library/Application Support/MCI/mci.sqlite\n\
        \x20 --window-seconds N         (with --health-summary) aggregation window. Default 3600.\n\
        \n\
        Env:\n\
        \x20 MCI_DB_PATH                (mcp-serve) brain SQLCipher path\n\
        \x20 MCI_DB_KEY_HEX             (mcp-serve) 64-char hex SQLCipher key (TEMP — see\n\
        \x20                            docs/claude-code-mcp-setup.md; Keychain integration\n\
        \x20                            lands in Phase 4 onboarding)\n"
    );
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
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
        Mode::DrainStdin => {
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
            match drain_to_log(&mut stdin, &log, &clock, &device_id).await {
                Ok(stats) => {
                    eprintln!(
                        "mci-agent: drained {} frame(s); {} logged, {} non-health",
                        stats.frames_seen, stats.frames_logged, stats.frames_non_health
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

/// Resolve the `SQLCipher` key from `MCI_DB_KEY_HEX`, open the brain
/// read-only, build the [`Server`], and run [`serve_stdio`].
///
/// `MCI_DB_KEY_HEX` is the **interim** key-resolution mechanism for
/// P3.10b. Phase-4 onboarding wires the Keychain-backed `KeyWrap`
/// surface; the env-var path stays as a developer / CI fallback. See
/// `docs/claude-code-mcp-setup.md` for the full operator note.
async fn run_mcp_serve(db_path: PathBuf) -> Result<(), u8> {
    let Ok(key_hex) = std::env::var("MCI_DB_KEY_HEX") else {
        eprintln!(
            "mci-agent mcp-serve: MCI_DB_KEY_HEX not set. \
             See docs/claude-code-mcp-setup.md."
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
    let reader = match LiveBrainReader::open(&db_path, &key) {
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
        "mci-agent mcp-serve: ready on stdio. db={} (read-only via SqlCipherBrainStore)",
        db_path.display()
    );
    let stdout = tokio::io::stdout();
    if let Err(e) = serve_stdio(server, stdout).await {
        eprintln!("mci-agent mcp-serve: stdio loop error: {e}");
        return Err(13);
    }
    Ok(())
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
