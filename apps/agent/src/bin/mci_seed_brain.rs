//! `mci-seed-brain` — DEMO-ONLY synthetic-event seeder for the encrypted brain.
//!
//! # Purpose
//!
//! A privacy-safe product demo must not depend on a user's actual capture
//! history. This binary writes 20 current, fictional [`mci_brain::Event`]
//! rows so Recall, briefs, episodes, MCP, and screenshot fixtures can be
//! exercised without copying personal content into development artifacts.
//!
//! # What it is NOT
//!
//! - It is **not** a production code path. The synthetic events carry
//!   `app_bundle_id = "com.mci.demo.seed.*"` so they are trivially
//!   distinguishable from real-capture events in any read pane.
//! - It is **not** a substitute for exercising `ScreenCaptureKit` on a real
//!   Mac. It exists for deterministic downstream product verification.
//! - It does **not** introduce any new write path into the brain store.
//!   It calls [`mci_brain::BrainStore::put_event`] like every other writer
//!   in the system; the same `cascade_reason = 0` invariant
//!   (ADR-0016 §4.3) is enforced by the store itself, so this binary
//!   cannot bypass it.
//!
//! # Privacy / CSO posture
//!
//! - The seed events contain no user content. The OCR `text`, window
//!   titles, and URLs are hand-authored fixture strings.
//! - The binary refuses to write into a non-empty brain unless the
//!   operator passes `--force`. Default behaviour: never overwrite a
//!   real-capture brain.
//! - Raw key input is accepted only when `MCI_DEVELOPMENT_FILE_KEY=1`.
//!   This binary is a development fixture, never a production custody path.
//! - Embeddings are intentionally `None` — lexical FTS5 search still
//!   finds these rows; the idle-batch embedder (P3.8) can fill them
//!   later. This avoids pulling in the Core ML runtime just to seed
//!   demo content.
//! - Encrypted keyframe digests are optional and must name blobs already
//!   written by the real shared codec under the brain's `blobs/` directory.
//!
//! # Usage
//!
//! ```text
//! export MCI_DEVELOPMENT_FILE_KEY=1
//! export MCI_DB_KEY_HEX=$(openssl rand -hex 32)
//! mkdir -p "$HOME/Library/Application Support/MCI"
//! cargo run --release --bin mci-seed-brain
//! # → 20 synthetic events written; brain ready for recall-ui / mcp-serve.
//! ```
//!
//! See `docs/STATE.md` "Path B" for the full demo recipe.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Default path matching `mci-agent mcp-serve`.
fn default_db_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/mci.sqlite")
}

fn print_usage() {
    println!(
        "mci-seed-brain {VERSION}\n\
        \n\
        DEMO-ONLY synthetic-event seeder for the encrypted brain. Writes 20\n\
        hand-authored Events with app_bundle_id = \"com.mci.demo.seed.*\" so\n\
        Recall, briefs, episodes, and `mci-agent mcp-serve` have content to\n\
        read without using a person's actual capture history.\n\
        \n\
        Usage: mci-seed-brain [OPTIONS]\n\
        \n\
        Options:\n\
        \x20 --db-path PATH             default $MCI_DB_PATH or\n\
        \x20                            ~/Library/Application Support/MCI/mci.sqlite\n\
        \x20 --keyframe-digest SHA256   attach an existing encrypted blob to one\n\
        \x20                            newest event; repeat for multiple blobs\n\
        \x20 --force                    overwrite-into a non-empty brain (default: refuse)\n\
        \x20 -h, --help                 print this and exit\n\
        \x20 --version                  print version and exit\n\
        \n\
        Env:\n\
        \x20 MCI_DB_PATH                brain SQLCipher path\n\
        \x20 MCI_DEVELOPMENT_FILE_KEY   REQUIRED. Must be exactly 1.\n\
        \x20 MCI_DB_KEY_HEX             REQUIRED. Development-only 64-char hex key.\n\
        \x20                            Use the same key for `mci-agent mcp-serve`\n\
        \x20                            so reads see the seeded rows.\n"
    );
}

struct Args {
    db_path: PathBuf,
    force: bool,
    keyframe_digests: Vec<String>,
}

enum ParseOutcome {
    Run(Args),
    Help,
    Version,
}

fn parse_args(argv: &[String]) -> ParseOutcome {
    let mut force = false;
    let mut db_path: Option<PathBuf> = None;
    let mut keyframe_digests = Vec::new();
    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "-h" | "--help" => return ParseOutcome::Help,
            "--version" => return ParseOutcome::Version,
            "--force" => {
                force = true;
                i += 1;
            }
            "--db-path" => {
                if i + 1 >= argv.len() {
                    eprintln!("mci-seed-brain: --db-path requires a PATH");
                    std::process::exit(2);
                }
                db_path = Some(PathBuf::from(&argv[i + 1]));
                i += 2;
            }
            "--keyframe-digest" => {
                if i + 1 >= argv.len() {
                    eprintln!("mci-seed-brain: --keyframe-digest requires a SHA256 digest");
                    std::process::exit(2);
                }
                let Some(digest) = normalize_keyframe_digest(&argv[i + 1]) else {
                    eprintln!(
                        "mci-seed-brain: --keyframe-digest must be exactly 64 hexadecimal characters"
                    );
                    std::process::exit(2);
                };
                keyframe_digests.push(digest);
                i += 2;
            }
            other => {
                eprintln!("mci-seed-brain: unknown argument: {other}");
                std::process::exit(2);
            }
        }
    }
    let db_path = db_path
        .or_else(|| std::env::var_os("MCI_DB_PATH").map(PathBuf::from))
        .unwrap_or_else(default_db_path);
    ParseOutcome::Run(Args {
        db_path,
        force,
        keyframe_digests,
    })
}

fn normalize_keyframe_digest(value: &str) -> Option<String> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    Some(value.to_ascii_lowercase())
}

fn attach_demo_keyframes(events: &mut [Event], digests: &[String]) {
    let first = events.len().saturating_sub(digests.len());
    for (event, digest) in events[first..].iter_mut().zip(digests) {
        event.keyframe_blob = Some(digest.clone());
    }
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

/// 20 hand-authored synthetic events spanning the last ~2 hours.
///
/// Public so the unit test in this file can assert structural invariants
/// without re-running the binary. Every entry uses `cascade_reason = 0`
/// (the ADR-0016 §4.3 wall the store enforces at `put_event`) and an
/// `app_bundle_id` in the `com.mci.demo.seed.*` namespace so demo data
/// is trivially distinguishable from real-capture events.
#[must_use]
#[allow(clippy::too_many_lines)]
pub fn canned_events(now_us: u64) -> Vec<Event> {
    // Anchor the most-recent event one minute before `now_us`; older
    // events step back in ~6-minute increments so the timeline spans
    // ~2 hours. Choosing 6 min × 20 = 120 min keeps the demo window
    // tight enough that a 10-second recall-UI scroll covers it.
    const STEP_US: u64 = 6 * 60 * 1_000_000;
    const LATEST_OFFSET_US: u64 = 60 * 1_000_000;

    let entries: [(&str, &str, &str, &str); 20] = [
        (
            "com.mci.demo.seed.safari",
            "ScreenCaptureKit — Apple Developer Documentation",
            "https://developer.apple.com/documentation/screencapturekit",
            "SCStream provides display frames after the user grants Screen Recording. Hippocampus samples only after opt-in and applies its privacy cascade before an event or encrypted keyframe can reach memory.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "KeyframeBlobCodec.swift — hippocampus",
            "",
            "Selected visual evidence is encoded, sealed with AES-GCM using a per-blob HKDF salt, and named by the SHA-256 digest of the encrypted envelope. Recall authenticates before decoding.",
        ),
        (
            "com.mci.demo.seed.terminal",
            "Terminal — hippocampus — workspace tests",
            "",
            "$ cargo test --workspace\nFinished test profile\nAll memory, privacy, retrieval, MCP, and deletion suites passed with zero failures.",
        ),
        (
            "com.mci.demo.seed.slack",
            "Slack — #desktop-memory — Today",
            "",
            "Maya: Keep only selected visual keyframes after the privacy cascade. Raw screen frames should remain transient, and every retained image must inherit the same deletion policy as its event.",
        ),
        (
            "com.mci.demo.seed.linear",
            "Linear — HIP-121 · Capture soak — Scheduled",
            "https://linear.app/atlas/issue/HIP-121/capture-soak",
            "Run a 30-minute real-machine capture soak. Record frame throughput, OCR latency, retained-keyframe count, memory, CPU, pause behavior, and protected-surface suppression before release qualification.",
        ),
        (
            "com.mci.demo.seed.safari",
            "Long-horizon memory evaluation — research notes",
            "https://example.com/research/long-horizon-memory",
            "A useful retrieval benchmark must measure answerable recall, source provenance, temporal reasoning, and abstention on unanswerable questions. Aggregate hit rate alone hides confident false positives.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "retrieval_outcomes.rs — hippocampus",
            "",
            "Retrieval returns a typed outcome: evidence, no_match, ambiguous, or unavailable. The caller gets event citations and reasons instead of an uncalibrated list of vaguely similar chunks.",
        ),
        (
            "com.mci.demo.seed.notion",
            "Notion — Hippocampus / V1 launch checklist",
            "https://www.notion.so/example/hippocampus-v1",
            "V1 launch checklist: clean-home install, explicit capture opt-in, evidence-backed search, timeline, episodes, daily brief, Claude and Codex registration, local deletion, signed update, and a reproducible retrieval benchmark.",
        ),
        (
            "com.mci.demo.seed.github",
            "PR #141 · Deliver evidence-backed agent context — hippocampus",
            "https://github.com/example/hippocampus/pull/141",
            "Adds mci_context: a bounded context compiler for Claude and Codex with canonical event citations, source priority, typed abstentions, and token budgeting. It never dumps the entire history into a prompt.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "ClaudeCodeRegistrar.swift — hippocampus",
            "",
            "Registration writes only the local mci-agent command, database path, storage model, and Keychain service/account reference. Database key bytes never enter Claude or Codex configuration.",
        ),
        (
            "com.mci.demo.seed.terminal",
            "Terminal — retrieval benchmark",
            "",
            "$ cargo run -p mci-agent -- benchmark-work-memory\n24 cases: 21 answerable, 3 unanswerable\nHybrid recall @3: 100%\nMRR: 0.976\nLaunch qualified: false — all unanswerable cases still returned a result.",
        ),
        (
            "com.mci.demo.seed.safari",
            "Snowflake Arctic Embed S — Hugging Face",
            "https://huggingface.co/Snowflake/snowflake-arctic-embed-s",
            "Arctic Embed S produces 384-dimensional local embeddings. Hippocampus combines them with FTS5 lexical ranking; semantic recall remains explicitly unavailable when the model artifact is absent.",
        ),
        (
            "com.mci.demo.seed.linear",
            "Linear — HIP-142 · Calibrate abstention — In progress",
            "https://linear.app/atlas/issue/HIP-142/calibrate-abstention",
            "Tune retrieval confidence on the synthetic work-memory benchmark. The release gate requires correct abstention on every unanswerable case without materially reducing answerable recall at three.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "docs/STATUS.md — hippocampus",
            "",
            "The canonical status separates working surfaces from unproven release claims. Capture remains opt-in; model-incomplete builds remain development-only; signing, notarization, and a real capture soak are still open gates.",
        ),
        (
            "com.mci.demo.seed.safari",
            "Keychain Services — Apple Developer Documentation",
            "https://developer.apple.com/documentation/security/keychain_services",
            "The brain key lives in a non-synchronizing macOS Keychain item authorized for shipped components. A stable Developer ID identity is required before upgrade continuity can be accepted.",
        ),
        (
            "com.mci.demo.seed.slack",
            "Slack — #desktop-memory — Retrieval decision",
            "",
            "Jon: Do not dump everything into RAG. Compile a small cited packet for the current task, preserve source and time, and abstain when the evidence does not support an answer.",
        ),
        (
            "com.mci.demo.seed.terminal",
            "Terminal — agent context handoff",
            "",
            "$ mci-context --focus \"release readiness\" --max-tokens 600\nOutcome: evidence\n5 cited events selected\nThe packet includes open signing, model, capture-soak, and retrieval-calibration gates without exposing the database key.",
        ),
        (
            "com.mci.demo.seed.notion",
            "Notion — Project Atlas / Daily brief",
            "https://www.notion.so/example/project-atlas-brief",
            "Today: the team fixed the launch lifecycle, proved the app under a disposable home, added encrypted visual evidence to the fixture, and documented the remaining signing and retrieval gates.",
        ),
        (
            "com.mci.demo.seed.github",
            "PR #143 · Fix launch lifecycle and clean-home verification — hippocampus",
            "https://github.com/example/hippocampus/pull/143",
            "The menu-bar visibility action can request application termination without an explicit user quit. A termination-request gate now cancels that lifecycle noise and preserves intentional quit and restart behavior.",
        ),
        (
            "com.mci.demo.seed.safari",
            "Hippocampus — Local memory architecture",
            "https://hippocampus.local/architecture",
            "Hippocampus keeps captured memory in a local SQLCipher database, stores selected screenshots as authenticated encrypted blobs, and serves bounded cited context to local AI clients through stdio MCP.",
        ),
    ];

    let mut out = Vec::with_capacity(entries.len());
    for (idx, (bundle, title, url, text)) in entries.iter().enumerate() {
        // Index 0 = oldest, index 19 = newest → reverse the offset.
        let offset_steps = (entries.len() - 1 - idx) as u64;
        let ts_us = now_us
            .saturating_sub(LATEST_OFFSET_US)
            .saturating_sub(offset_steps.saturating_mul(STEP_US));
        out.push(Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some((*bundle).to_owned()),
            window_title: if title.is_empty() {
                None
            } else {
                Some((*title).to_owned())
            },
            url: if url.is_empty() {
                None
            } else {
                Some((*url).to_owned())
            },
            // Real ingest prepends this per ADR-0010 §1.3, and `events.text`
            // is what Tier-1 extraction and FTS5 actually read. Without it
            // the seed is unfaithful to the pipeline: the URL lives only in
            // the `url` column, so `mci-agent enrich` finds no entities and
            // looks broken on the demo brain. Uses the ingest path's own
            // helper so the two cannot drift.
            text: format!(
                "{}{}",
                mci_agent::brain_ingest::compose_context_header(
                    Some(bundle),
                    if title.is_empty() { None } else { Some(title) },
                    if url.is_empty() { None } else { Some(url) },
                    ts_us,
                ),
                text
            ),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        });
    }
    out
}

fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX))
}

fn main() -> ExitCode {
    mci_agent::panic_hook::install();

    let raw_argv: Vec<String> = std::env::args().collect();
    let args = match parse_args(&raw_argv) {
        ParseOutcome::Help => {
            print_usage();
            return ExitCode::SUCCESS;
        }
        ParseOutcome::Version => {
            println!("mci-seed-brain {VERSION}");
            return ExitCode::SUCCESS;
        }
        ParseOutcome::Run(a) => a,
    };

    if std::env::var("MCI_DEVELOPMENT_FILE_KEY").as_deref() != Ok("1") {
        eprintln!(
            "mci-seed-brain: this development-only tool requires \
             MCI_DEVELOPMENT_FILE_KEY=1."
        );
        return ExitCode::from(9);
    }

    let Ok(key_hex) = std::env::var("MCI_DB_KEY_HEX") else {
        eprintln!(
            "mci-seed-brain: MCI_DB_KEY_HEX not set. Use the same value you \
             pass to `mci-agent mcp-serve` so reads see the seeded rows. \
             See `docs/STATE.md` Path B demo recipe."
        );
        return ExitCode::from(10);
    };
    let Some(key_bytes) = decode_hex32(&key_hex) else {
        eprintln!(
            "mci-seed-brain: MCI_DB_KEY_HEX must be 64 lowercase-or-uppercase \
             hex characters (32 bytes)."
        );
        return ExitCode::from(11);
    };
    let key = DbKey::from_bytes(key_bytes);

    if let Some(parent) = args.db_path.parent() {
        if !parent.exists() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                eprintln!("mci-seed-brain: create_dir_all({}): {e}", parent.display());
                return ExitCode::from(12);
            }
        }
    }

    let store = match SqlCipherBrainStore::new(&args.db_path, &key) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "mci-seed-brain: open brain at {}: {e}",
                args.db_path.display()
            );
            return ExitCode::from(13);
        }
    };

    let existing = match store.recent_events(1) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("mci-seed-brain: probe existing events: {e}");
            return ExitCode::from(14);
        }
    };
    if !existing.is_empty() && !args.force {
        eprintln!(
            "mci-seed-brain: refusing to write into a non-empty brain at {} \
             ({} existing event(s)). Pass --force to override, or delete the \
             file first.",
            args.db_path.display(),
            existing.len()
        );
        return ExitCode::from(15);
    }

    let mut events = canned_events(now_us());
    attach_demo_keyframes(&mut events, &args.keyframe_digests);
    let mut written = 0_usize;
    for event in &events {
        match store.put_event(event) {
            Ok(_id) => written += 1,
            Err(e) => {
                eprintln!("mci-seed-brain: put_event failed: {e}");
                return ExitCode::from(16);
            }
        }
    }

    eprintln!(
        "mci-seed-brain: wrote {written} synthetic event(s) to {} \
         (app_bundle_id = com.mci.demo.seed.*). Use the same MCI_DB_KEY_HEX \
         to read them back via `mci-agent mcp-serve` or the recall UI.",
        args.db_path.display()
    );
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canned_events_are_well_formed() {
        let now = 1_716_240_000_000_000_u64;
        let events = canned_events(now);
        assert_eq!(events.len(), 20, "expected exactly 20 seed events");

        for (i, ev) in events.iter().enumerate() {
            assert_eq!(
                ev.cascade_reason, 0,
                "event {i} cascade_reason must be 0 (ADR-0016 §4.3 wall at put_event)"
            );
            let bundle = ev
                .app_bundle_id
                .as_ref()
                .expect("seed events must carry an app_bundle_id");
            assert!(
                bundle.starts_with("com.mci.demo.seed."),
                "event {i} bundle id {bundle:?} must live in the synthetic namespace"
            );
            assert!(
                !ev.text.is_empty(),
                "event {i} must carry non-empty text for FTS5"
            );
            assert!(ev.embedding.is_none(), "seed events leave embeddings unset");
            assert!(ev.summary.is_none());
            assert!(ev.entities.is_none());
            assert!(ev.episode_id.is_none());
            assert!(ev.keyframe_blob.is_none());
        }
    }

    #[test]
    fn canned_events_timestamps_monotonic_and_within_window() {
        let now = 1_716_240_000_000_000_u64;
        let events = canned_events(now);
        // Oldest first, newest last.
        for pair in events.windows(2) {
            assert!(
                pair[0].ts_us < pair[1].ts_us,
                "timestamps must be strictly increasing"
            );
        }
        let span_us = events.last().unwrap().ts_us - events.first().unwrap().ts_us;
        let two_hours_us = 2 * 60 * 60 * 1_000_000_u64;
        assert!(
            span_us <= two_hours_us,
            "all 20 events should fit inside a 2-hour window, got {span_us} us"
        );
        // Newest event must be strictly older than `now` (we anchor 60 s back).
        assert!(events.last().unwrap().ts_us < now);
    }

    #[test]
    fn canned_events_have_distinct_titles_or_text() {
        // Recall-UI demo value relies on each row reading as a distinct
        // moment. Pin that with a uniqueness check across (title, text).
        let events = canned_events(1_716_240_000_000_000_u64);
        let mut seen: Vec<(Option<String>, String)> = Vec::new();
        for ev in &events {
            let pair = (ev.window_title.clone(), ev.text.clone());
            assert!(!seen.contains(&pair), "duplicate seed event: {pair:?}");
            seen.push(pair);
        }
    }

    #[test]
    fn canned_events_are_current_and_do_not_embed_personal_identifiers() {
        let corpus = canned_events(1_716_240_000_000_000_u64)
            .into_iter()
            .map(|event| {
                format!(
                    "{} {} {}",
                    event.window_title.unwrap_or_default(),
                    event.url.unwrap_or_default(),
                    event.text
                )
            })
            .collect::<Vec<_>>()
            .join("\n");

        for forbidden in [
            "amyjainberkeley",
            "ao@MacBook",
            "Director-Recording",
            "P3.6.7",
            "Phase 3 90%",
        ] {
            assert!(
                !corpus.contains(forbidden),
                "synthetic corpus leaked stale or personal-looking token: {forbidden}"
            );
        }
        assert!(corpus.contains("retrieval benchmark"));
        assert!(corpus.contains("mci_context"));
        assert!(corpus.contains("launch lifecycle"));
    }

    #[test]
    fn decode_hex32_round_trips() {
        let bytes = [0xab_u8; 32];
        let hex: String = bytes.iter().fold(String::new(), |mut s, b| {
            use std::fmt::Write;
            write!(s, "{b:02x}").unwrap();
            s
        });
        assert_eq!(decode_hex32(&hex), Some(bytes));
    }

    #[test]
    fn decode_hex32_rejects_wrong_length() {
        assert!(decode_hex32("").is_none());
        assert!(decode_hex32(&"a".repeat(63)).is_none());
        assert!(decode_hex32(&"a".repeat(65)).is_none());
    }

    #[test]
    fn demo_keyframe_digest_is_validated_and_normalized() {
        let uppercase = "AB".repeat(32);
        assert_eq!(normalize_keyframe_digest(&uppercase), Some("ab".repeat(32)));
        assert!(normalize_keyframe_digest(&"a".repeat(63)).is_none());
        assert!(normalize_keyframe_digest(&"g".repeat(64)).is_none());
    }

    #[test]
    fn demo_keyframes_attach_to_newest_events_in_order() {
        let mut events = canned_events(1_716_240_000_000_000_u64);
        let digests = vec!["11".repeat(32), "22".repeat(32), "33".repeat(32)];

        attach_demo_keyframes(&mut events, &digests);

        assert!(events[..17]
            .iter()
            .all(|event| event.keyframe_blob.is_none()));
        assert_eq!(
            events[17].keyframe_blob.as_deref(),
            Some(digests[0].as_str())
        );
        assert_eq!(
            events[18].keyframe_blob.as_deref(),
            Some(digests[1].as_str())
        );
        assert_eq!(
            events[19].keyframe_blob.as_deref(),
            Some(digests[2].as_str())
        );
    }

    #[test]
    fn decode_hex32_rejects_non_hex() {
        let mut s = "a".repeat(64);
        s.replace_range(0..1, "g");
        assert!(decode_hex32(&s).is_none());
    }
}
