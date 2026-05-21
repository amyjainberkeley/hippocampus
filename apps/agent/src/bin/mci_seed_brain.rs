//! `mci-seed-brain` — DEMO-ONLY synthetic-event seeder for the encrypted brain.
//!
//! # Purpose
//!
//! Phase 3 capture-side helper bugs (see `docs/STATE.md` EOD 2026-05-20 §
//! "Two known bugs") currently leave the brain store empty even after a
//! live capture session, which blocks demoing the **read** side of the
//! pipeline (the recall UI in `apps/recall-ui/`, the localhost MCP server
//! `mci-agent mcp-serve`, the agent-API loopback in general). Until
//! Director-Recording's P3.6.7 PR fixes the `.allow` → OCREvent emission
//! gap, this binary writes 20 synthetic [`mci_brain::Event`] rows so the
//! downstream surfaces have something to read against.
//!
//! # What it is NOT
//!
//! - It is **not** a production code path. The synthetic events carry
//!   `app_bundle_id = "com.mci.demo.seed.*"` so they are trivially
//!   distinguishable from real-capture events in any read pane.
//! - It is **not** a substitute for fixing the helper. The capture-side
//!   bug fix (P3.6.7) is the real solution; this binary only unblocks
//!   demo-time work in parallel.
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
//! - The SQLCipher key comes from `MCI_DB_KEY_HEX` (matches the
//!   `mci-agent mcp-serve` convention so the same key reads back what
//!   this binary writes).
//! - Embeddings are intentionally `None` — lexical FTS5 search still
//!   finds these rows; the idle-batch embedder (P3.8) can fill them
//!   later. This avoids pulling in the Core ML runtime just to seed
//!   demo content.
//!
//! # Usage
//!
//! ```text
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
        the recall UI and `mci-agent mcp-serve` have content to read while\n\
        the P3.6.7 helper fix is in flight.\n\
        \n\
        Usage: mci-seed-brain [OPTIONS]\n\
        \n\
        Options:\n\
        \x20 --db-path PATH             default $MCI_DB_PATH or\n\
        \x20                            ~/Library/Application Support/MCI/mci.sqlite\n\
        \x20 --force                    overwrite-into a non-empty brain (default: refuse)\n\
        \x20 -h, --help                 print this and exit\n\
        \x20 --version                  print version and exit\n\
        \n\
        Env:\n\
        \x20 MCI_DB_PATH                brain SQLCipher path\n\
        \x20 MCI_DB_KEY_HEX             REQUIRED. 64-char hex SQLCipher key.\n\
        \x20                            Use the same key for `mci-agent mcp-serve`\n\
        \x20                            so reads see the seeded rows.\n"
    );
}

struct Args {
    db_path: PathBuf,
    force: bool,
}

enum ParseOutcome {
    Run(Args),
    Help,
    Version,
}

fn parse_args(argv: &[String]) -> ParseOutcome {
    let mut force = false;
    let mut db_path: Option<PathBuf> = None;
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
            other => {
                eprintln!("mci-seed-brain: unknown argument: {other}");
                std::process::exit(2);
            }
        }
    }
    let db_path = db_path
        .or_else(|| std::env::var_os("MCI_DB_PATH").map(PathBuf::from))
        .unwrap_or_else(default_db_path);
    ParseOutcome::Run(Args { db_path, force })
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
            "Snowflake Arctic Embed S — Hugging Face",
            "https://huggingface.co/Snowflake/snowflake-arctic-embed-s",
            "Snowflake's Arctic Embed S is a 384-dim sentence-transformer optimized for retrieval. Apache-2.0; the MCI brain pins it per ADR-0011 because the size/quality tradeoff lands inside the on-device CPU+ANE budget.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "core/brain/src/sqlcipher_brain_store.rs — mci",
            "",
            "fn put_event(&self, event: &Event) -> Result<EventId, StoreError> { if event.cascade_reason != 0 { return Err(StoreError::InvalidInput(\"cascade_reason must be 0\".into())); } ... }",
        ),
        (
            "com.mci.demo.seed.terminal",
            "ao@MacBook-Pro-4 — zsh — 120x36",
            "",
            "$ cargo test --workspace --release\n   Compiling mci-brain v0.0.1\n   Compiling mci-agent v0.0.1\n    Finished test [optimized] target(s) in 41.20s\n     Running unittests src/lib.rs (target/release/deps/mci_brain-...)\nrunning 196 tests\ntest result: ok. 196 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out",
        ),
        (
            "com.mci.demo.seed.slack",
            "Slack — #mci-team — Today",
            "",
            "ao: P3.6.7 should fix the .allow → OCREvent gap. Director-Recording is on it in worktree phase-3-p3.6.7-fix-helper-bugs. ETA ~45 min.",
        ),
        (
            "com.mci.demo.seed.linear",
            "Linear — MCI · P3.6.7 — In Progress",
            "https://linear.app/mci/issue/MCI-37/p367-fix-allow-ocrevent-emission-from-mainswift",
            "P3.6.7 — Fix `.allow` → OCREvent emission from main.swift. SCStreamCaptureSession constructor is missing the `ocrPostAllowEmitter:` argument; the default `nil` makes the cascade-twice path inert at runtime. ADR-0016 §4.2.",
        ),
        (
            "com.mci.demo.seed.safari",
            "ScreenCaptureKit | Apple Developer Documentation",
            "https://developer.apple.com/documentation/screencapturekit",
            "SCStream delivers frames via SCStreamOutput. The MCI helper uses the SCStream path on macOS 14+; cascade runs synchronously in the callback. SCFrameInfo's status field (Complete vs Idle vs Blank) gates the dedupe ladder.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/OCRPostAllowEmitter.swift — mci",
            "",
            "// Cascade-twice invariant (ADR-0016 §4.2): an `OCREvent` reaches the wire ONLY if BOTH cascade passes returned `.allow`. The IPC seam structurally cannot deliver a `PrivacyTombstone` to the brain ingestor.",
        ),
        (
            "com.mci.demo.seed.notion",
            "Notion — MCI / Recall UI Spec",
            "https://www.notion.so/mci/recall-ui-v1",
            "Recall UI v1 surfaces the last 200 events in a left rail and renders OCR text + window title + URL in the detail pane. Lexical search uses FTS5 BM25 ranking; semantic comes online when the idle-batch embedder fills event_vectors.",
        ),
        (
            "com.mci.demo.seed.github",
            "PR #84 · docs(state+log): EOD 2026-05-20 handoff — mci",
            "https://github.com/amyjainberkeley/hippocampus/pull/84",
            "EOD 2026-05-20 handoff documenting the 30+ PR sprint, Phase 3 90% complete, and the two helper-side bugs (`.allow`→OCREvent silent emission + Bundle.module nil from .app install) blocking the working demo.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "adapters/macos/MCICaptureHelper/Sources/MCICaptureHelper/main.swift — mci",
            "",
            "let captureSession = SCStreamCaptureSession( pipeline: SCStreamPipeline(cascade: cascade, encoder: DeferredVideoToolboxEncoder(), counters: loop.counters, sink: ..., floorIntervalMs: ...), denylist: ..., policy: ..., blackedRegionProbe: ..., contextSnapshot: ..., urlProvider: ... )  // BUG: missing ocrPostAllowEmitter: arg → cascade-twice path inert.",
        ),
        (
            "com.mci.demo.seed.terminal",
            "ao@MacBook-Pro-4 — zsh — wire decoder",
            "",
            "$ python3 tools/wire_decode.py < /tmp/mci-g2.bin | head -40\nseq=1 type=tombstone reason=4 app_bundle=\"\" ts_us=1716185...\nseq=2 type=tombstone reason=7 app_bundle=\"\" ts_us=1716185...\nseq=3 type=tombstone reason=4 app_bundle=\"\" ts_us=1716185...\n... (54 tombstones, 0 OCREvents, 23 seq gaps consistent with .allow decisions)",
        ),
        (
            "com.mci.demo.seed.safari",
            "Cure53 — Source Code & Penetration Testing",
            "https://cure53.de/",
            "Cure53 offers cryptography review, penetration testing, and source-code audits. The COO GTM doc recommends a $50K–$100K v1 audit ahead of the 2026-09 launch — the third-party signal that backs MCI's zero-knowledge / local-first claims.",
        ),
        (
            "com.mci.demo.seed.linear",
            "Linear — MCI · F-STRAT-002 — Done",
            "https://linear.app/mci/issue/MCI-31/dual-market-commit-hippocampus-mci-engineering-codename",
            "F-STRAT-002 dual-market commit. Hippocampus is the external/pitch-deck name; MCI is the engineering codename (no repo rebrand). B2C free (Personal tier) + B2B per-seat (Teams tier). Tier 1 (raw+cascade+brain) strictly local; Tier 2 (approved briefs only) syncs to vendor-blind workspace server.",
        ),
        (
            "com.mci.demo.seed.vscode",
            "docs/decisions/0019-company-workspace-server-tier-2-store.md — mci",
            "",
            "ADR-0019 — Company workspace server + Tier 2 store. Vendor-blind by construction: server holds only ciphertext + opaque key-wraps. Per-workspace E2E key. Existing-member-vouches enrollment. NO BACKDOOR KEY. LOAD-BEARING §4.",
        ),
        (
            "com.mci.demo.seed.safari",
            "sqlite-vec — A vector search SQLite extension",
            "https://github.com/asg017/sqlite-vec",
            "sqlite-vec is a SQLite extension that provides vector search via the vec0 virtual table. MCI uses sqlite-vec for semantic recall over 384-d embeddings (ADR-0009 pins the dimension). The vec0 mirror lands at P3.8.",
        ),
        (
            "com.mci.demo.seed.slack",
            "Slack — DMs — Claude Code orchestrator",
            "",
            "Director-Recording reports back: P3.6.7 PR opened. Two-file diff: main.swift now constructs CascadeTwiceOCREmitter and passes it to SCStreamCaptureSession; AllowlistTOMLLoader.loadBundled() falls back through Bundle.main + sibling-of-executable paths.",
        ),
        (
            "com.mci.demo.seed.terminal",
            "ao@MacBook-Pro-4 — zsh — gh pr list",
            "",
            "$ gh pr list --state open\nshowing 0 of 0 open pull requests in amyjainberkeley/hippocampus\n$ git log --oneline -5\n3abb9de docs(state+log): EOD 2026-05-20 handoff — 30+ PRs merged; Phase 3 90%; helper-side demo bugs documented\n120b895 feat(agent): P3.10b — localhost MCP server (mci-agent mcp-serve)",
        ),
        (
            "com.mci.demo.seed.notion",
            "Notion — MCI / Demo Script — Cycle 5",
            "https://www.notion.so/mci/demo-script-cycle-5",
            "Demo script for the Phase 3 cycle: (1) Boot helper in .app bundle. (2) Use Mac normally for 5 min. (3) Open Recall UI — show timeline. (4) Search 'sqlite-vec' — show ranked results. (5) Connect Claude Code via mcp-serve — show agent-readable brain.",
        ),
        (
            "com.mci.demo.seed.github",
            "Issue #37 · Capture-time §1 allowlist not firing in .app install — mci",
            "https://github.com/amyjainberkeley/hippocampus/issues/37",
            "Root cause: `Bundle.module` returns nil when the binary is hand-copied into `.app/Contents/MacOS/` without the SwiftPM resource-bundle dir alongside. Loader needs a Bundle.main + sibling-of-executable fallback before returning the empty-allowlist default.",
        ),
        (
            "com.mci.demo.seed.safari",
            "MCI — About the brain (local-first, zero-knowledge)",
            "https://mci.local/about",
            "MCI keeps your full screen-and-context memory on your device. Capture, OCR, embedding, search — all local. The encrypted SQLite file IS your brain; you can move it, back it up, delete it. No third party can decrypt it; no vendor (including us) holds the key.",
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
            text: (*text).to_owned(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: None,
        });
    }
    out
}

fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().collect();
    let args = match parse_args(&argv) {
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
                eprintln!(
                    "mci-seed-brain: create_dir_all({}): {e}",
                    parent.display()
                );
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

    let events = canned_events(now_us());
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
    fn decode_hex32_round_trips() {
        let bytes = [0xab_u8; 32];
        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(decode_hex32(&hex), Some(bytes));
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
}
