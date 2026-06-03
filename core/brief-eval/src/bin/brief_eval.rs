//! `brief-eval` — CLI driver for the MCI brief-author quality eval.
//!
//! Default mode (deterministic, used by CI):
//!
//! ```text
//! cargo run -p mci-brief-eval --bin brief-eval -- --all
//! ```
//!
//! Real-model mode (CEO runs once `OWNER_TASKS` #17 lands the converted
//! `.mlmodelc`; requires building with `--features coreml`):
//!
//! ```text
//! cargo run -p mci-brief-eval --bin brief-eval --features coreml -- \
//!     --all --backend coreml \
//!     --model-path  "$HOME/Library/Application Support/MCI/Models/Qwen3-1.7B-FP16.mlmodelc" \
//!     --tokenizer-dir "$HOME/Library/Application Support/MCI/Models" \
//!     --require-real-model
//! ```

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Instant;

use mci_brief::author::BriefAuthor;
use mci_brief::author::StubBriefAuthor;
use mci_brief::llama_author::LlamaBriefAuthor;
use mci_brief::llama_backend::{LlamaBackend, StubLlamaBackend};

use mci_brief_eval::{
    bundled_fixtures_dir, list_fixture_names, score_brief, EvalReport, FixtureDay, GoldBrief,
    PassThresholds, ScriptedLlamaBackend,
};

const USAGE: &str = "\
brief-eval — MCI brief-author quality eval (ADR-0028 gate)

USAGE:
    brief-eval [OPTIONS]

OPTIONS:
    --all                          Run every fixture under <dir>/days/ (default)
    --fixture NAME                 Run a single fixture by stem (e.g. day_light)
    --fixtures-dir PATH            Override the bundled fixtures directory
    --backend stub|scripted|coreml Pick the BriefAuthor backend (default: scripted)
    --model-path PATH              .mlmodelc path (required for --backend coreml)
    --tokenizer-dir PATH           Tokenizer dir (required for --backend coreml)
    --require-real-model           Fail when the brief contains the stub signature
    --min-fact-coverage FRAC       Override the fact-coverage threshold (default: 0.80)
    --min-citation-validity FRAC   Override the citation-validity threshold (default: 0.90)
    --report-path PATH             Also write the text report to PATH
    -h, --help                     Print this help
";

#[derive(Debug, Clone, Copy)]
enum BackendKind {
    /// `mci_brief::StubBriefAuthor` — no LLM wrapper. Will fail the
    /// eval; useful only to demonstrate the failure mode.
    Stub,
    /// `LlamaBriefAuthor + ScriptedLlamaBackend` — replays
    /// `fixtures/scripted/<name>.md`. CI default.
    Scripted,
    /// `LlamaBriefAuthor + Qwen3CoreMLBackend` — real model. Only
    /// available when built with `--features coreml`. CEO mode.
    CoreML,
}

#[derive(Debug, Clone)]
struct Args {
    target: Target,
    fixtures_dir: PathBuf,
    backend: BackendKind,
    /// Only read by the `#[cfg(feature = "coreml")]` path.
    #[allow(dead_code)]
    model_path: Option<PathBuf>,
    /// Only read by the `#[cfg(feature = "coreml")]` path.
    #[allow(dead_code)]
    tokenizer_dir: Option<PathBuf>,
    thresholds: PassThresholds,
    report_path: Option<PathBuf>,
}

#[derive(Debug, Clone)]
enum Target {
    All,
    One(String),
}

enum ParseOutcome {
    Run(Args),
    Help,
    Error(String),
}

#[allow(clippy::too_many_lines)]
fn parse_args(argv: &[String]) -> ParseOutcome {
    let mut target = Target::All;
    let mut fixtures_dir: Option<PathBuf> = None;
    let mut backend = BackendKind::Scripted;
    let mut model_path: Option<PathBuf> = None;
    let mut tokenizer_dir: Option<PathBuf> = None;
    let mut thresholds = PassThresholds::default();
    let mut report_path: Option<PathBuf> = None;

    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "-h" | "--help" => return ParseOutcome::Help,
            "--all" => {
                target = Target::All;
                i += 1;
            }
            "--fixture" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error("--fixture requires a NAME".into());
                };
                target = Target::One(v.clone());
                i += 2;
            }
            "--fixtures-dir" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error("--fixtures-dir requires a PATH".into());
                };
                fixtures_dir = Some(PathBuf::from(v));
                i += 2;
            }
            "--backend" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error("--backend requires a value".into());
                };
                backend = match v.as_str() {
                    "stub" => BackendKind::Stub,
                    "scripted" => BackendKind::Scripted,
                    "coreml" => BackendKind::CoreML,
                    other => {
                        return ParseOutcome::Error(format!(
                            "--backend: unknown value {other} (expected stub|scripted|coreml)"
                        ));
                    }
                };
                i += 2;
            }
            "--model-path" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error("--model-path requires a PATH".into());
                };
                model_path = Some(PathBuf::from(v));
                i += 2;
            }
            "--tokenizer-dir" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error("--tokenizer-dir requires a PATH".into());
                };
                tokenizer_dir = Some(PathBuf::from(v));
                i += 2;
            }
            "--require-real-model" => {
                thresholds.require_real_model = true;
                i += 1;
            }
            "--min-fact-coverage" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error("--min-fact-coverage requires a value".into());
                };
                match v.parse::<f64>() {
                    Ok(f) => thresholds.min_fact_coverage = f,
                    Err(e) => {
                        return ParseOutcome::Error(format!("--min-fact-coverage: {e}"));
                    }
                }
                i += 2;
            }
            "--min-citation-validity" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error(
                        "--min-citation-validity requires a value".into(),
                    );
                };
                match v.parse::<f64>() {
                    Ok(f) => thresholds.min_citation_validity = f,
                    Err(e) => {
                        return ParseOutcome::Error(format!("--min-citation-validity: {e}"));
                    }
                }
                i += 2;
            }
            "--report-path" => {
                let Some(v) = argv.get(i + 1) else {
                    return ParseOutcome::Error("--report-path requires a PATH".into());
                };
                report_path = Some(PathBuf::from(v));
                i += 2;
            }
            other => {
                return ParseOutcome::Error(format!("unknown argument: {other}"));
            }
        }
    }

    ParseOutcome::Run(Args {
        target,
        fixtures_dir: fixtures_dir.unwrap_or_else(bundled_fixtures_dir),
        backend,
        model_path,
        tokenizer_dir,
        thresholds,
        report_path,
    })
}

fn main() -> ExitCode {
    let raw_argv: Vec<String> = std::env::args().collect();
    let args = match parse_args(&raw_argv) {
        ParseOutcome::Help => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        ParseOutcome::Error(msg) => {
            eprintln!("brief-eval: {msg}\n\n{USAGE}");
            return ExitCode::from(2);
        }
        ParseOutcome::Run(a) => a,
    };

    let backend_label = match args.backend {
        BackendKind::Stub => "stub (StubBriefAuthor)",
        BackendKind::Scripted => "scripted (LlamaBriefAuthor + ScriptedLlamaBackend)",
        BackendKind::CoreML => "coreml (LlamaBriefAuthor + Qwen3CoreMLBackend)",
    };

    let fixtures = match collect_fixtures(&args) {
        Ok(list) => list,
        Err(e) => {
            eprintln!("brief-eval: {e}");
            return ExitCode::from(3);
        }
    };

    let mut report = EvalReport {
        backend_label: backend_label.to_owned(),
        ..Default::default()
    };

    for name in fixtures {
        let fixture = match FixtureDay::load(&args.fixtures_dir, &name) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("brief-eval: load fixture {name}: {e}");
                return ExitCode::from(4);
            }
        };
        let gold = match GoldBrief::load(&args.fixtures_dir, &name) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("brief-eval: load gold {name}: {e}");
                return ExitCode::from(5);
            }
        };

        let author: Box<dyn BriefAuthor> = match build_author(&args, &args.fixtures_dir, &name) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("brief-eval: build author: {e}");
                return ExitCode::from(6);
            }
        };

        let records = fixture.to_event_records();
        let start = Instant::now();
        let brief = match author.author(&records, "Daily brief") {
            Ok(b) => b,
            Err(e) => {
                eprintln!("brief-eval: author failed on {name}: {e}");
                return ExitCode::from(7);
            }
        };
        report.author_time_total += start.elapsed();

        let outcome = score_brief(&brief, &fixture, &gold, args.thresholds);
        report.fixtures.push(outcome);
    }

    let text = report.render_text();
    print!("{text}");

    if let Some(path) = &args.report_path {
        if let Err(e) = std::fs::write(path, &text) {
            eprintln!("brief-eval: write report to {}: {e}", path.display());
            return ExitCode::from(8);
        }
    }

    if report.all_passed() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

fn collect_fixtures(args: &Args) -> Result<Vec<String>, String> {
    match &args.target {
        Target::All => list_fixture_names(&args.fixtures_dir).map_err(|e| {
            format!(
                "list fixtures in {}: {e}",
                args.fixtures_dir.join("days").display()
            )
        }),
        Target::One(name) => Ok(vec![name.clone()]),
    }
}

fn build_author(
    args: &Args,
    fixtures_dir: &Path,
    fixture_name: &str,
) -> Result<Box<dyn BriefAuthor>, String> {
    match args.backend {
        BackendKind::Stub => Ok(Box::new(StubBriefAuthor)),
        BackendKind::Scripted => {
            let path = fixtures_dir
                .join("scripted")
                .join(fixture_name)
                .with_extension("md");
            let response = std::fs::read_to_string(&path)
                .map_err(|e| format!("read scripted output {}: {e}", path.display()))?;
            let backend: Arc<dyn LlamaBackend> = Arc::new(ScriptedLlamaBackend::new(response));
            Ok(Box::new(LlamaBriefAuthor::new(backend)))
        }
        BackendKind::CoreML => build_coreml_author(args),
    }
}

#[cfg(feature = "coreml")]
fn build_coreml_author(args: &Args) -> Result<Box<dyn BriefAuthor>, String> {
    let model_path = args
        .model_path
        .as_ref()
        .ok_or_else(|| "--backend coreml requires --model-path".to_owned())?;
    let tokenizer_dir = args
        .tokenizer_dir
        .as_ref()
        .ok_or_else(|| "--backend coreml requires --tokenizer-dir".to_owned())?;
    let backend = mci_coreml_bridge::Qwen3CoreMLBackend::open(model_path, tokenizer_dir)
        .map_err(|e| format!("open Qwen3CoreMLBackend: {e}"))?;
    let arc: Arc<dyn LlamaBackend> = Arc::new(backend);
    Ok(Box::new(LlamaBriefAuthor::new(arc)))
}

#[cfg(not(feature = "coreml"))]
fn build_coreml_author(_args: &Args) -> Result<Box<dyn BriefAuthor>, String> {
    // Squelch a "stub fallback unused" warning that would fire on
    // non-macOS or no-feature builds — the stub backend is only
    // referenced through the runtime BackendKind selector.
    let _ = StubLlamaBackend::default();
    Err("--backend coreml was not enabled at build time. Rebuild with `--features coreml` (macOS only).".to_owned())
}
