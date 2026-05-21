//! `mci-brain` — read-only CLI for the encrypted brain store.
//!
//! ADR-0016 §6 + ADR-0019 §"Tier 1": "your brain as a file you own —
//! you can move it, back it up, delete it." This CLI lets the user (and
//! Claude-Code-the-developer) interact with that file directly from a
//! terminal.
//!
//! All access goes through `SqlCipherBrainStore::open_readonly` — writes
//! are structurally impossible at the SQLite driver level
//! (`SQLITE_OPEN_READ_ONLY`). Calling `put_event` on a read-only handle
//! returns `SQLITE_READONLY` at the driver level.
//!
//! # Subcommands
//!
//!   mci-brain stats [--json]
//!   mci-brain recent [--limit N] [--json]
//!   mci-brain search <QUERY> [--limit N] [--json]
//!   mci-brain show <EVENT_ID> [--json]
//!   mci-brain export [--format jsonl|csv] [--out PATH] [--since TS_US]
//!
//! # Key resolution
//!
//!   MCI_DB_KEY_HEX env var — 64-char hex SQLCipher key (REQUIRED).
//!   --db-path PATH or MCI_DB_PATH env — brain file path.
//!   Default: ~/Library/Application Support/MCI/mci.sqlite

use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;

use mci_agent::brain_cli;
use mci_brain::{BrainStore, EventId, EventRecord, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const VERSION: &str = env!("CARGO_PKG_VERSION");

// ---------------------------------------------------------------------------
// Arg types
// ---------------------------------------------------------------------------

struct Args {
    db_path: PathBuf,
    command: Command,
}

enum Command {
    Stats {
        json: bool,
    },
    Recent {
        limit: usize,
        json: bool,
    },
    Search {
        query: String,
        limit: usize,
        json: bool,
    },
    Show {
        event_id: u64,
        json: bool,
    },
    Export {
        format: ExportFormat,
        out: Option<PathBuf>,
        since: u64,
    },
    Backup {
        out: PathBuf,
        integrity_check: bool,
    },
    Restore {
        from: PathBuf,
        to: PathBuf,
        force: bool,
    },
}

#[derive(Clone, Copy)]
enum ExportFormat {
    Jsonl,
    Csv,
}

enum ParseOutcome {
    Run(Args),
    Help,
    Version,
    Error(String),
}

// ---------------------------------------------------------------------------
// Arg parsing (hand-rolled; zero new deps per ADR-0008)
// ---------------------------------------------------------------------------

fn default_db_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/mci.sqlite")
}

fn parse_args(argv: &[String]) -> ParseOutcome {
    let mut db_path: Option<PathBuf> = None;
    let mut json = false;
    let mut limit: Option<usize> = None;
    let mut format: Option<ExportFormat> = None;
    let mut out: Option<PathBuf> = None;
    let mut since: u64 = 0;
    let mut subcmd: Option<String> = None;
    let mut positionals: Vec<String> = Vec::new();

    let mut i = 1;
    while i < argv.len() {
        let arg = &argv[i];
        if arg.starts_with('-') {
            match arg.as_str() {
                "-h" | "--help" => return ParseOutcome::Help,
                "--version" => return ParseOutcome::Version,
                "--json" => json = true,
                "--db-path" => {
                    i += 1;
                    if i >= argv.len() {
                        return ParseOutcome::Error("--db-path requires PATH".into());
                    }
                    db_path = Some(PathBuf::from(&argv[i]));
                }
                "--limit" => {
                    i += 1;
                    if i >= argv.len() {
                        return ParseOutcome::Error("--limit requires N".into());
                    }
                    match argv[i].parse::<usize>() {
                        Ok(n) if n > 0 => limit = Some(n),
                        _ => {
                            return ParseOutcome::Error("--limit must be a positive integer".into())
                        }
                    }
                }
                "--format" => {
                    i += 1;
                    if i >= argv.len() {
                        return ParseOutcome::Error("--format requires jsonl|csv".into());
                    }
                    format = Some(match argv[i].as_str() {
                        "jsonl" => ExportFormat::Jsonl,
                        "csv" => ExportFormat::Csv,
                        other => {
                            return ParseOutcome::Error(format!(
                                "unknown format: {other} (expected jsonl|csv)"
                            ))
                        }
                    });
                }
                "--out" => {
                    i += 1;
                    if i >= argv.len() {
                        return ParseOutcome::Error("--out requires PATH".into());
                    }
                    out = Some(PathBuf::from(&argv[i]));
                }
                "--since" => {
                    i += 1;
                    if i >= argv.len() {
                        return ParseOutcome::Error("--since requires TS_US".into());
                    }
                    match argv[i].parse::<u64>() {
                        Ok(v) => since = v,
                        Err(_) => {
                            return ParseOutcome::Error(
                                "--since must be a non-negative integer (µs since epoch)".into(),
                            )
                        }
                    }
                }
                _ => {
                    // Subcommand-specific flags (e.g. --integrity-check, --force) get
                    // routed to the subcommand parser via positionals.
                    if subcmd.is_some() {
                        positionals.push(arg.clone());
                    } else {
                        return ParseOutcome::Error(format!("unknown flag: {arg}"));
                    }
                }
            }
        } else if subcmd.is_none() {
            subcmd = Some(arg.clone());
        } else {
            positionals.push(arg.clone());
        }
        i += 1;
    }

    let db_path = db_path
        .or_else(|| std::env::var_os("MCI_DB_PATH").map(PathBuf::from))
        .unwrap_or_else(default_db_path);

    let command = match subcmd.as_deref() {
        Some("stats") => Command::Stats { json },
        Some("recent") => Command::Recent {
            limit: limit.unwrap_or(20),
            json,
        },
        Some("search") => {
            if positionals.is_empty() {
                return ParseOutcome::Error("search requires a QUERY argument".into());
            }
            Command::Search {
                query: positionals.join(" "),
                limit: limit.unwrap_or(10),
                json,
            }
        }
        Some("show") => {
            if positionals.is_empty() {
                return ParseOutcome::Error("show requires an EVENT_ID argument".into());
            }
            match positionals[0].parse::<u64>() {
                Ok(v) => Command::Show { event_id: v, json },
                Err(_) => {
                    return ParseOutcome::Error("EVENT_ID must be a non-negative integer".into())
                }
            }
        }
        Some("export") => Command::Export {
            format: format.unwrap_or(ExportFormat::Jsonl),
            out,
            since,
        },
        Some("backup") => {
            let mut integrity_check = false;
            for arg in positionals.iter() {
                match arg.as_str() {
                    "--integrity-check" => integrity_check = true,
                    other => return ParseOutcome::Error(format!("backup: unknown arg: {other}")),
                }
            }
            let out = match out.clone() {
                Some(p) => p,
                None => return ParseOutcome::Error("backup: --out PATH is required".into()),
            };
            Command::Backup { out, integrity_check }
        }
        Some("restore") => {
            let mut from: Option<PathBuf> = None;
            let mut to: Option<PathBuf> = None;
            let mut force = false;
            let mut i = 0;
            while i < positionals.len() {
                match positionals[i].as_str() {
                    "--from" => {
                        if i + 1 >= positionals.len() {
                            return ParseOutcome::Error("restore: --from requires a PATH".into());
                        }
                        from = Some(PathBuf::from(&positionals[i + 1]));
                        i += 2;
                    }
                    "--to" => {
                        if i + 1 >= positionals.len() {
                            return ParseOutcome::Error("restore: --to requires a PATH".into());
                        }
                        to = Some(PathBuf::from(&positionals[i + 1]));
                        i += 2;
                    }
                    "--force" => { force = true; i += 1; }
                    other => return ParseOutcome::Error(format!("restore: unknown arg: {other}")),
                }
            }
            match (from, to) {
                (Some(from), Some(to)) => Command::Restore { from, to, force },
                _ => return ParseOutcome::Error("restore: --from and --to are required".into()),
            }
        }
        Some(other) => return ParseOutcome::Error(format!("unknown command: {other}")),
        None => return ParseOutcome::Help,
    };

    ParseOutcome::Run(Args { db_path, command })
}

// ---------------------------------------------------------------------------
// Hex decode (same routine as mcp-serve + seed-brain — ADR-0008 key custody)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

fn print_usage() {
    println!(
        "mci-brain {VERSION}\n\
        \n\
        Read-only CLI for the encrypted brain store.\n\
        Your brain as a file you own.\n\
        \n\
        Usage: mci-brain <COMMAND> [OPTIONS]\n\
        \n\
        Commands:\n\
        \x20 stats                      content-free aggregate (event count + timestamps)\n\
        \x20 recent [--limit N]          most recent events (default 20)\n\
        \x20 search <QUERY> [--limit N]  FTS5 lexical search (default 10 results)\n\
        \x20 show <EVENT_ID>             full event by id\n\
        \x20 export                      export all events\n\
        \n\
        Options:\n\
        \x20 --db-path PATH             default $MCI_DB_PATH or\n\
        \x20                            ~/Library/Application Support/MCI/mci.sqlite\n\
        \x20 --json                     machine-readable JSON output (stats/recent/search/show)\n\
        \x20 --limit N                  cap results (recent default 20, search default 10)\n\
        \x20 --format jsonl|csv         export format (default jsonl)\n\
        \x20 --out PATH                 write export to file (default stdout)\n\
        \x20 --since TS_US              export events newer than TS_US (µs since epoch)\n\
        \x20 --version                  print version and exit\n\
        \x20 -h, --help                 print this and exit\n\
        \n\
        Env:\n\
        \x20 MCI_DB_PATH                brain SQLCipher path\n\
        \x20 MCI_DB_KEY_HEX             REQUIRED. 64-char hex SQLCipher key.\n\
        \x20                            Same value used by `mci-agent mcp-serve`.\n"
    );
}

// ---------------------------------------------------------------------------
// Subcommand runners
// ---------------------------------------------------------------------------

fn run_stats(store: &SqlCipherBrainStore, json: bool) -> ExitCode {
    match store.stats() {
        Ok(s) => {
            if json {
                println!("{}", brain_cli::format_stats_json(&s));
            } else {
                print!("{}", brain_cli::format_stats_human(&s));
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mci-brain stats: {e}");
            ExitCode::from(20)
        }
    }
}

fn run_recent(store: &SqlCipherBrainStore, limit: usize, json: bool) -> ExitCode {
    match store.recent_events(limit) {
        Ok(events) => {
            for event in &events {
                let rec = EventRecord {
                    event_id: event.id,
                    ts_us: event.ts_us,
                    app_bundle_id: event.app_bundle_id.clone(),
                    window_title: event.window_title.clone(),
                    url: event.url.clone(),
                    text_snippet: EventRecord::truncate_snippet(&event.text),
                };
                if json {
                    println!("{}", brain_cli::format_event_record_jsonl(&rec));
                } else {
                    println!("{}", brain_cli::format_event_record_human(&rec));
                }
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("mci-brain recent: {e}");
            ExitCode::from(21)
        }
    }
}

fn run_search(store: &SqlCipherBrainStore, query: &str, limit: usize, json: bool) -> ExitCode {
    let sanitized = brain_cli::sanitize_fts5_query(query);
    if sanitized.is_empty() {
        eprintln!("mci-brain search: empty query");
        return ExitCode::from(22);
    }
    let hits = match store.fts5_search(&sanitized, limit) {
        Ok(h) => h,
        Err(e) => {
            eprintln!("mci-brain search: {e}");
            return ExitCode::from(22);
        }
    };
    for (event_id, _score) in &hits {
        let event = match store.get_event(*event_id) {
            Ok(Some(ev)) => ev,
            Ok(None) => continue,
            Err(e) => {
                eprintln!("mci-brain search: get_event({event_id}): {e}");
                continue;
            }
        };
        let rec = EventRecord {
            event_id: *event_id,
            ts_us: event.ts_us,
            app_bundle_id: event.app_bundle_id,
            window_title: event.window_title,
            url: event.url,
            text_snippet: EventRecord::truncate_snippet(&event.text),
        };
        if json {
            println!("{}", brain_cli::format_event_record_jsonl(&rec));
        } else {
            println!("{}", brain_cli::format_event_record_human(&rec));
        }
    }
    ExitCode::SUCCESS
}

fn run_show(store: &SqlCipherBrainStore, event_id: u64, json: bool) -> ExitCode {
    match store.get_event(EventId(event_id)) {
        Ok(Some(event)) => {
            if json {
                println!("{}", brain_cli::format_event_jsonl(&event));
            } else {
                print!("{}", brain_cli::format_event_human(&event));
            }
            ExitCode::SUCCESS
        }
        Ok(None) => {
            eprintln!("mci-brain show: event {event_id} not found");
            ExitCode::from(23)
        }
        Err(e) => {
            eprintln!("mci-brain show: {e}");
            ExitCode::from(23)
        }
    }
}

fn run_export(
    store: &SqlCipherBrainStore,
    format: ExportFormat,
    out: Option<PathBuf>,
    since: u64,
) -> ExitCode {
    const BATCH: usize = 500;
    let mut writer: Box<dyn Write> = match &out {
        Some(path) => match std::fs::File::create(path) {
            Ok(f) => Box::new(std::io::BufWriter::new(f)),
            Err(e) => {
                eprintln!("mci-brain export: create {}: {e}", path.display());
                return ExitCode::from(24);
            }
        },
        None => Box::new(std::io::BufWriter::new(std::io::stdout().lock())),
    };

    if matches!(format, ExportFormat::Csv) {
        if let Err(e) = writeln!(writer, "{}", brain_cli::format_event_csv_header()) {
            eprintln!("mci-brain export: write: {e}");
            return ExitCode::from(24);
        }
    }

    let mut cursor_ts = since;
    let mut cursor_id: Option<EventId> = None;
    let mut total = 0_u64;
    loop {
        let batch = match store.paged_events_since(cursor_ts, cursor_id, BATCH) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("mci-brain export: {e}");
                return ExitCode::from(24);
            }
        };
        if batch.is_empty() {
            break;
        }
        for event in &batch {
            cursor_ts = event.ts_us;
            cursor_id = Some(event.id);
            let line = match format {
                ExportFormat::Jsonl => brain_cli::format_event_jsonl(event),
                ExportFormat::Csv => brain_cli::format_event_csv_row(event),
            };
            if let Err(e) = writeln!(writer, "{line}") {
                eprintln!("mci-brain export: write: {e}");
                return ExitCode::from(24);
            }
            total += 1;
        }
        if batch.len() < BATCH {
            break;
        }
    }
    if let Err(e) = writer.flush() {
        eprintln!("mci-brain export: flush: {e}");
        return ExitCode::from(24);
    }
    eprintln!("mci-brain export: wrote {total} event(s)");
    ExitCode::SUCCESS
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

fn main() -> ExitCode {
    mci_agent::panic_hook::install();

    let argv: Vec<String> = std::env::args().collect();
    let args = match parse_args(&argv) {
        ParseOutcome::Help => {
            print_usage();
            return ExitCode::SUCCESS;
        }
        ParseOutcome::Version => {
            println!("mci-brain {VERSION}");
            return ExitCode::SUCCESS;
        }
        ParseOutcome::Error(msg) => {
            eprintln!("mci-brain: {msg}");
            return ExitCode::from(2);
        }
        ParseOutcome::Run(a) => a,
    };

    let Ok(key_hex) = std::env::var("MCI_DB_KEY_HEX") else {
        eprintln!(
            "mci-brain: MCI_DB_KEY_HEX not set. \
             See docs/claude-code-mcp-setup.md."
        );
        return ExitCode::from(10);
    };
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!(
            "mci-brain: MCI_DB_KEY_HEX must be 64 lowercase-or-uppercase \
             hex characters (32 bytes)."
        );
        return ExitCode::from(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    // Restore doesn't need the global store — it operates on --from/--to.
    if let Command::Restore { from, to, force } = &args.command {
        return run_restore(from, to, *force, &key);
    }

    let store = match SqlCipherBrainStore::open_readonly(&args.db_path, &key) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("mci-brain: open brain at {}: {e}", args.db_path.display());
            return ExitCode::from(12);
        }
    };

    match args.command {
        Command::Stats { json } => run_stats(&store, json),
        Command::Recent { limit, json } => run_recent(&store, limit, json),
        Command::Search { query, limit, json } => run_search(&store, &query, limit, json),
        Command::Show { event_id, json } => run_show(&store, event_id, json),
        Command::Export { format, out, since } => run_export(&store, format, out, since),
        Command::Backup { out, integrity_check } => run_backup(&store, &out, integrity_check),
        Command::Restore { .. } => unreachable!("handled above"),
    }
}

fn run_backup(store: &SqlCipherBrainStore, out: &std::path::Path, integrity_check: bool) -> ExitCode {
    if integrity_check {
        match store.integrity_check() {
            Ok(v) if v == vec!["ok".to_string()] => {}
            Ok(v) => {
                eprintln!("mci-brain backup: integrity_check failed: {v:?}");
                return ExitCode::from(31);
            }
            Err(e) => {
                eprintln!("mci-brain backup: integrity_check error: {e}");
                return ExitCode::from(32);
            }
        }
    }
    if out.exists() {
        eprintln!("mci-brain backup: --out path already exists: {}", out.display());
        return ExitCode::from(33);
    }
    if let Err(e) = store.vacuum_into(out) {
        eprintln!("mci-brain backup: vacuum_into failed: {e}");
        return ExitCode::from(34);
    }
    eprintln!("mci-brain backup: wrote {} (encrypted with same key)", out.display());
    ExitCode::SUCCESS
}

fn run_restore(from: &std::path::Path, to: &std::path::Path, force: bool, key: &DbKey) -> ExitCode {
    if !from.exists() {
        eprintln!("mci-brain restore: --from does not exist: {}", from.display());
        return ExitCode::from(40);
    }
    // Validate source decrypts with current key (read-only probe + stats).
    match SqlCipherBrainStore::open_readonly(from, key) {
        Ok(s) => match s.stats() {
            Ok(_) => {}
            Err(e) => {
                eprintln!("mci-brain restore: source open OK but stats failed: {e}");
                return ExitCode::from(41);
            }
        },
        Err(e) => {
            eprintln!("mci-brain restore: source not decryptable with current key: {e}");
            return ExitCode::from(42);
        }
    }
    if to.exists() && !force {
        eprintln!("mci-brain restore: --to already exists. Pass --force to overwrite.");
        return ExitCode::from(43);
    }
    if let Err(e) = std::fs::copy(from, to) {
        eprintln!("mci-brain restore: copy failed: {e}");
        return ExitCode::from(44);
    }
    eprintln!("mci-brain restore: restored {} → {}", from.display(), to.display());
    ExitCode::SUCCESS
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::{BrainStats, Event, EventId, EventRecord};

    fn argv(args: &[&str]) -> Vec<String> {
        std::iter::once("mci-brain")
            .chain(args.iter().copied())
            .map(String::from)
            .collect()
    }

    // -- arg parsing --

    #[test]
    fn parse_args_recent_default_limit_is_20() {
        let args = match parse_args(&argv(&["recent"])) {
            ParseOutcome::Run(a) => a,
            other => panic!("expected Run, got {:?}", variant_name(&other)),
        };
        match args.command {
            Command::Recent { limit, json } => {
                assert_eq!(limit, 20);
                assert!(!json);
            }
            _ => panic!("expected Recent"),
        }
    }

    #[test]
    fn parse_args_recent_custom_limit() {
        let args = match parse_args(&argv(&["recent", "--limit", "5", "--json"])) {
            ParseOutcome::Run(a) => a,
            other => panic!("expected Run, got {:?}", variant_name(&other)),
        };
        match args.command {
            Command::Recent { limit, json } => {
                assert_eq!(limit, 5);
                assert!(json);
            }
            _ => panic!("expected Recent"),
        }
    }

    #[test]
    fn parse_args_search_requires_query() {
        match parse_args(&argv(&["search"])) {
            ParseOutcome::Error(msg) => {
                assert!(msg.contains("QUERY"), "error should mention QUERY: {msg}");
            }
            _ => panic!("expected Error for search without query"),
        }
    }

    #[test]
    fn parse_args_search_multi_word_query() {
        let args = match parse_args(&argv(&["search", "hello", "world", "--limit", "5"])) {
            ParseOutcome::Run(a) => a,
            other => panic!("expected Run, got {:?}", variant_name(&other)),
        };
        match args.command {
            Command::Search { query, limit, .. } => {
                assert_eq!(query, "hello world");
                assert_eq!(limit, 5);
            }
            _ => panic!("expected Search"),
        }
    }

    #[test]
    fn parse_args_show_requires_event_id() {
        match parse_args(&argv(&["show"])) {
            ParseOutcome::Error(msg) => {
                assert!(
                    msg.contains("EVENT_ID"),
                    "error should mention EVENT_ID: {msg}"
                );
            }
            _ => panic!("expected Error for show without event_id"),
        }
    }

    #[test]
    fn parse_args_show_rejects_non_integer() {
        match parse_args(&argv(&["show", "abc"])) {
            ParseOutcome::Error(msg) => {
                assert!(
                    msg.contains("integer"),
                    "error should mention integer: {msg}"
                );
            }
            _ => panic!("expected Error for non-integer event_id"),
        }
    }

    #[test]
    fn parse_args_export_defaults() {
        let args = match parse_args(&argv(&["export"])) {
            ParseOutcome::Run(a) => a,
            other => panic!("expected Run, got {:?}", variant_name(&other)),
        };
        match args.command {
            Command::Export { format, out, since } => {
                assert!(matches!(format, ExportFormat::Jsonl));
                assert!(out.is_none());
                assert_eq!(since, 0);
            }
            _ => panic!("expected Export"),
        }
    }

    #[test]
    fn parse_args_no_subcommand_is_help() {
        assert!(matches!(parse_args(&argv(&[])), ParseOutcome::Help));
    }

    // -- format_event_record_human --

    #[test]
    fn format_event_record_human() {
        let rec = EventRecord {
            event_id: EventId(42),
            ts_us: 1_716_240_000_000_000,
            app_bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Hacker News".into()),
            url: Some("https://news.ycombinator.com".into()),
            text_snippet: "Top stories\nSecond line".into(),
        };
        let out = brain_cli::format_event_record_human(&rec);
        assert!(out.contains("event:42"));
        assert!(out.contains("com.apple.Safari"));
        assert!(out.contains("Hacker News"));
        assert!(out.contains("https://news.ycombinator.com"));
        assert!(
            out.contains("Top stories Second line"),
            "newlines should be collapsed: {out}"
        );
        assert_eq!(out.matches('|').count(), 5, "should have 5 pipe separators");
    }

    #[test]
    fn format_event_record_human_missing_fields() {
        let rec = EventRecord {
            event_id: EventId(1),
            ts_us: 1_000_000,
            app_bundle_id: None,
            window_title: None,
            url: None,
            text_snippet: "text".into(),
        };
        let out = brain_cli::format_event_record_human(&rec);
        assert_eq!(out.matches(" - ").count(), 3, "None fields render as '-'");
    }

    // -- format_event_record_jsonl --

    #[test]
    fn format_event_record_jsonl() {
        let rec = EventRecord {
            event_id: EventId(7),
            ts_us: 1_000_000,
            app_bundle_id: Some("com.test".into()),
            window_title: Some("Win".into()),
            url: None,
            text_snippet: "snippet".into(),
        };
        let out = brain_cli::format_event_record_jsonl(&rec);
        let v: serde_json::Value = serde_json::from_str(&out).expect("valid JSON");
        assert_eq!(v["event_id"], 7);
        assert_eq!(v["ts_us"], 1_000_000);
        assert_eq!(v["app_bundle_id"], "com.test");
        assert_eq!(v["window_title"], "Win");
        assert!(v["url"].is_null());
        assert_eq!(v["text_snippet"], "snippet");
    }

    // -- format_event_human (show) --

    #[test]
    fn format_event_human_includes_full_text() {
        let event = Event {
            id: EventId(99),
            ts_us: 2_000_000,
            app_bundle_id: Some("com.test".into()),
            window_title: Some("W".into()),
            url: Some("https://x.com".into()),
            text: "Full event text here".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: None,
        };
        let out = brain_cli::format_event_human(&event);
        assert!(out.contains("event:99"));
        assert!(out.contains("Full event text here"));
        assert!(out.contains("Text:\n"));
    }

    // -- format_event_jsonl (show --json / export) --

    #[test]
    fn format_event_jsonl_shape() {
        let event = Event {
            id: EventId(5),
            ts_us: 3_000_000,
            app_bundle_id: None,
            window_title: None,
            url: None,
            text: "hello".into(),
            summary: Some("sum".into()),
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: None,
        };
        let out = brain_cli::format_event_jsonl(&event);
        let v: serde_json::Value = serde_json::from_str(&out).expect("valid JSON");
        assert_eq!(v["event_id"], 5);
        assert_eq!(v["ts_us"], 3_000_000);
        assert_eq!(v["text"], "hello");
        assert_eq!(v["summary"], "sum");
        assert_eq!(v["cascade_reason"], 0);
        assert!(v["app_bundle_id"].is_null());
    }

    // -- format_stats --

    #[test]
    fn format_stats_human_empty() {
        let s = BrainStats {
            event_count: 0,
            oldest_ts_us: None,
            newest_ts_us: None,
        };
        let out = brain_cli::format_stats_human(&s);
        assert!(out.contains("Events: 0"));
        assert!(out.contains("Oldest: (none)"));
        assert!(out.contains("Newest: (none)"));
    }

    #[test]
    fn format_stats_json_populated() {
        let s = BrainStats {
            event_count: 42,
            oldest_ts_us: Some(1_000_000),
            newest_ts_us: Some(2_000_000),
        };
        let out = brain_cli::format_stats_json(&s);
        let v: serde_json::Value = serde_json::from_str(&out).expect("valid JSON");
        assert_eq!(v["event_count"], 42);
        assert_eq!(v["oldest_ts_us"], 1_000_000);
        assert_eq!(v["newest_ts_us"], 2_000_000);
    }

    // -- sanitize_fts5_query --

    #[test]
    fn sanitize_fts5_query_wraps_hyphen_tokens() {
        assert_eq!(
            brain_cli::sanitize_fts5_query("sqlite-vec"),
            "\"sqlite-vec\""
        );
    }

    #[test]
    fn sanitize_fts5_query_strips_quotes() {
        assert_eq!(
            brain_cli::sanitize_fts5_query("\"hello\" world"),
            "\"hello\" \"world\""
        );
    }

    #[test]
    fn sanitize_fts5_query_empty() {
        assert_eq!(brain_cli::sanitize_fts5_query(""), "");
        assert_eq!(brain_cli::sanitize_fts5_query("   "), "");
    }

    // -- decode_hex32 --

    #[test]
    fn decode_hex32_round_trip() {
        let bytes = [0xAB_u8; 32];
        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(decode_hex32(&hex), Some(bytes));
    }

    #[test]
    fn decode_hex32_uppercase() {
        let hex = "AB".repeat(32);
        let expected = [0xAB_u8; 32];
        assert_eq!(decode_hex32(&hex), Some(expected));
    }

    #[test]
    fn decode_hex32_rejects_wrong_length() {
        assert!(decode_hex32("").is_none());
        assert!(decode_hex32(&"a".repeat(63)).is_none());
        assert!(decode_hex32(&"a".repeat(65)).is_none());
    }

    #[test]
    fn decode_hex32_rejects_non_hex() {
        let mut s = "a".repeat(64);
        s.replace_range(0..1, "g");
        assert!(decode_hex32(&s).is_none());
    }

    // -- integration: round-trip through SqlCipherBrainStore --

    #[test]
    fn integration_readonly_stats_matches_written_count() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("test.sqlite");
        let key_bytes = [0xAB_u8; 32];
        let key = DbKey::from_bytes(key_bytes);

        {
            let writer = SqlCipherBrainStore::new(&db_path, &key).unwrap();
            for i in 0..5_u64 {
                let event = Event {
                    id: EventId(0),
                    ts_us: 1_000_000 + i * 1_000_000,
                    app_bundle_id: Some("com.test.app".into()),
                    window_title: Some(format!("Window {i}")),
                    url: None,
                    text: format!("Test event {i} with some searchable text"),
                    summary: None,
                    entities: None,
                    episode_id: None,
                    cascade_reason: 0,
                    keyframe_blob: None,
                    embedding: None,
                };
                writer.put_event(&event).unwrap();
            }
        }

        let reader = SqlCipherBrainStore::open_readonly(&db_path, &key).unwrap();
        let stats = reader.stats().unwrap();
        assert_eq!(stats.event_count, 5);
        assert_eq!(stats.oldest_ts_us, Some(1_000_000));
        assert_eq!(stats.newest_ts_us, Some(5_000_000));
    }

    fn variant_name(o: &ParseOutcome) -> &'static str {
        match o {
            ParseOutcome::Run(_) => "Run",
            ParseOutcome::Help => "Help",
            ParseOutcome::Version => "Version",
            ParseOutcome::Error(_) => "Error",
        }
    }
}
