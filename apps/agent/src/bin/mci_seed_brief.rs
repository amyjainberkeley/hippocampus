//! `mci-seed-brief` — DEMO / SMOKE-TEST ONLY synthetic-brief inserter.
//!
//! Writes one row into the `briefs` table so the Recall UI's Brief tab
//! has something to render before the Qwen3 brief-author pipeline lands.
//! ADR-0028 + `docs/design/brief-viewer-spec.md` §"manual smoke" — this
//! binary is the test fixture the spec's smoke trace calls.
//!
//! # Why a separate binary (not `mci-brain insert-brief`)
//!
//! `mci-brain` is the READ-ONLY CLI for the encrypted store — it opens
//! through `SqlCipherBrainStore::open_readonly` and surfaces stats /
//! recent / search / show. Adding a write subcommand would muddy the
//! read-only promise printed in its help text. Keep them separate.
//!
//! # CSO note
//!
//! This binary writes to the encrypted brain store (`mci.sqlite`) and
//! is therefore protected-set adjacent. It calls only the new
//! `SqlCipherBrainStore::put_brief` surface (no other write path), and
//! the row it writes carries only synthetic content (the demo title /
//! body the caller supplies). It is never wired into the shipped
//! Hippocampus.app — it lives in `apps/agent/src/bin/` alongside
//! `mci-seed-brain` as a development tool.
//!
//! # Usage
//!
//! ```bash
//! export MCI_DB_KEY_HEX=<64-hex>
//! cargo run --release --bin mci-seed-brief -- \
//!   --date 2026-05-22 \
//!   --title "Friday, May 22" \
//!   --body "$(cat /tmp/sample_brief.md)"
//! ```

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::{BriefRow, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const VERSION: &str = env!("CARGO_PKG_VERSION");

struct Args {
    db_path: PathBuf,
    date_local: String,
    title: String,
    body: String,
    model_id: String,
    model_version: String,
    source_event_count: u32,
    force: bool,
}

enum ParseOutcome {
    Run(Args),
    Help,
    Version,
    Error(String),
}

fn default_db_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/mci.sqlite")
}

fn parse_args(argv: &[String]) -> ParseOutcome {
    let mut db_path: Option<PathBuf> = None;
    let mut date_local: Option<String> = None;
    let mut title: Option<String> = None;
    let mut body: Option<String> = None;
    let mut model_id: String = "qwen3-1.7b-fp16".into();
    let mut model_version: String = "demo".into();
    let mut source_event_count: u32 = 0;
    let mut force = false;

    let mut i = 1;
    while i < argv.len() {
        let arg = &argv[i];
        match arg.as_str() {
            "-h" | "--help" => return ParseOutcome::Help,
            "--version" => return ParseOutcome::Version,
            "--force" => {
                force = true;
            }
            "--db-path" => {
                i += 1;
                if i >= argv.len() {
                    return ParseOutcome::Error("--db-path requires PATH".into());
                }
                db_path = Some(PathBuf::from(&argv[i]));
            }
            "--date" => {
                i += 1;
                if i >= argv.len() {
                    return ParseOutcome::Error("--date requires YYYY-MM-DD".into());
                }
                date_local = Some(argv[i].clone());
            }
            "--title" => {
                i += 1;
                if i >= argv.len() {
                    return ParseOutcome::Error("--title requires STRING".into());
                }
                title = Some(argv[i].clone());
            }
            "--body" => {
                i += 1;
                if i >= argv.len() {
                    return ParseOutcome::Error("--body requires STRING".into());
                }
                body = Some(argv[i].clone());
            }
            "--model-id" => {
                i += 1;
                if i >= argv.len() {
                    return ParseOutcome::Error("--model-id requires STRING".into());
                }
                model_id = argv[i].clone();
            }
            "--model-version" => {
                i += 1;
                if i >= argv.len() {
                    return ParseOutcome::Error("--model-version requires STRING".into());
                }
                model_version = argv[i].clone();
            }
            "--source-events" => {
                i += 1;
                if i >= argv.len() {
                    return ParseOutcome::Error("--source-events requires N".into());
                }
                match argv[i].parse::<u32>() {
                    Ok(n) => source_event_count = n,
                    Err(_) => {
                        return ParseOutcome::Error(
                            "--source-events must be a non-negative integer".into(),
                        )
                    }
                }
            }
            other => {
                return ParseOutcome::Error(format!("unknown argument: {other}"));
            }
        }
        i += 1;
    }

    let db_path = db_path
        .or_else(|| std::env::var_os("MCI_DB_PATH").map(PathBuf::from))
        .unwrap_or_else(default_db_path);

    let date_local = match date_local {
        Some(d) => d,
        None => {
            return ParseOutcome::Error(
                "--date YYYY-MM-DD is required (the brief's local date)".into(),
            )
        }
    };
    let title = title.unwrap_or_else(|| format!("Demo brief for {date_local}"));
    let body = body.unwrap_or_else(|| {
        format!(
            "## Highlights\n\nSynthetic demo brief for {date_local}.\n\n\
             ## Deep work\n\nThis brief was inserted via `mci-seed-brief` \
             so the Recall UI Brief tab has something to render before the \
             Qwen3 author pipeline lands.\n"
        )
    });

    ParseOutcome::Run(Args {
        db_path,
        date_local,
        title,
        body,
        model_id,
        model_version,
        source_event_count,
        force,
    })
}

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

fn print_usage() {
    println!(
        "mci-seed-brief {VERSION}\n\
        \n\
        DEMO / smoke-test inserter for the daily-briefs surface (Recall UI Brief tab).\n\
        \n\
        Usage: mci-seed-brief --date YYYY-MM-DD [OPTIONS]\n\
        \n\
        Options:\n\
        \x20 --date YYYY-MM-DD          REQUIRED. Local date the brief is for.\n\
        \x20 --title STRING             Header title (default: \"Demo brief for <date>\").\n\
        \x20 --body STRING              Markdown body (default: a synthetic stub).\n\
        \x20 --model-id STRING          Model id for the header (default: qwen3-1.7b-fp16).\n\
        \x20 --model-version STRING     Model version string (default: \"demo\").\n\
        \x20 --source-events N          Source-event count for the footer (default: 0).\n\
        \x20 --db-path PATH             default $MCI_DB_PATH or\n\
        \x20                            ~/Library/Application Support/MCI/mci.sqlite\n\
        \x20 --force                    overwrite an existing brief for this date\n\
        \n\
        Required env:\n\
        \x20 MCI_DB_KEY_HEX             64-hex (32-byte) SQLCipher key — same value\n\
        \x20                            you pass to mci-agent / the recall UI.\n"
    );
}

fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX))
}

fn main() -> ExitCode {
    mci_agent::panic_hook::install();

    let argv: Vec<String> = std::env::args().collect();
    let args = match parse_args(&argv) {
        ParseOutcome::Help => {
            print_usage();
            return ExitCode::SUCCESS;
        }
        ParseOutcome::Version => {
            println!("mci-seed-brief {VERSION}");
            return ExitCode::SUCCESS;
        }
        ParseOutcome::Error(msg) => {
            eprintln!("mci-seed-brief: {msg}");
            return ExitCode::from(2);
        }
        ParseOutcome::Run(a) => a,
    };

    let Ok(key_hex) = std::env::var("MCI_DB_KEY_HEX") else {
        eprintln!(
            "mci-seed-brief: MCI_DB_KEY_HEX not set. Use the same value you \
             pass to `mci-agent` so the recall UI can read the brief back."
        );
        return ExitCode::from(10);
    };
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!("mci-seed-brief: MCI_DB_KEY_HEX must be 64 hex characters (32 bytes).");
        return ExitCode::from(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    if let Some(parent) = args.db_path.parent() {
        if !parent.exists() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                eprintln!("mci-seed-brief: create_dir_all({}): {e}", parent.display());
                return ExitCode::from(12);
            }
        }
    }

    let store = match SqlCipherBrainStore::new(&args.db_path, &key) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "mci-seed-brief: open brain at {}: {e}",
                args.db_path.display()
            );
            return ExitCode::from(13);
        }
    };

    // Refuse to clobber an existing brief unless --force.
    match store.brief_for_date(&args.date_local) {
        Ok(Some(_)) if !args.force => {
            eprintln!(
                "mci-seed-brief: a brief already exists for {} (pass --force to overwrite).",
                args.date_local
            );
            return ExitCode::from(15);
        }
        Ok(_) => {}
        Err(e) => {
            eprintln!("mci-seed-brief: probe existing brief: {e}");
            return ExitCode::from(14);
        }
    }

    let word_count = u32::try_from(args.body.split_whitespace().count()).unwrap_or(0);
    let row = BriefRow {
        id: 0,
        date_local: args.date_local.clone(),
        generated_ts_us: now_us(),
        model_id: args.model_id,
        model_version: args.model_version,
        title: args.title,
        body: args.body,
        word_count,
        source_event_count: args.source_event_count,
    };

    match store.put_brief(&row) {
        Ok(id) => {
            eprintln!(
                "mci-seed-brief: wrote brief id={id} date_local={} word_count={} to {}",
                args.date_local,
                word_count,
                args.db_path.display()
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mci-seed-brief: put_brief failed: {e}");
            ExitCode::from(16)
        }
    }
}
