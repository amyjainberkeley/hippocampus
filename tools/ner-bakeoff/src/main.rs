//! V2-P5+ Phase-3 screen-text NER bake-off harness.
//!
//! Picks the sync-hot-path NER model by running each Core ML candidate
//! through the **production inference path** — the P2′ `WordPiece` tokenizer
//! (`mci_brain::extraction::tier2_ner::NerWordPieceTokenizer`, byte
//! offsets) → Core ML via `mci_coreml_bridge` (the generic `CoreMLModel`
//! wrapper) → the P2′ BIO span decoder
//! (`mci_brain::extraction::tier2_ner::decode_bio`) — and emitting
//! predictions in `eval/ner-corpus/tools/score_ner.py`'s format (a list of
//! `{id, entities:[{kind, span_start, span_end}]}` with **UTF-8 byte**
//! offsets). This is deliberately NOT the Python path: it exercises the
//! exact Rust pieces the runtime NER backend (P4) will glue, so the F1 we
//! score is the F1 we will ship.
//!
//! Two modes:
//!   - `--mode predict` (default): run the corpus once under a chosen
//!     compute-unit policy, write predictions, and report per-inference
//!     latency. Run it once per `--compute-units` to attribute the actual
//!     resident compute unit (GPU vs CPU; ANE is RED for the per-token
//!     head, `docs/research` §7.1) by comparing latency across policies.
//!   - `--mode sustained`: drive inference at a fixed cadence for a fixed
//!     duration and sample CPU% (getrusage) + RSS (ps / `ru_maxrss`) to size
//!     the always-on footprint against the G2 SLO.
//!
//! Measurement-only: no brain store write, no `BrainPump` wiring, no
//! sensitive-capture surface. Pure post-capture inference + timing.

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("mci-ner-bakeoff is macOS-only (Core ML). No-op on this platform.");
}

#[cfg(target_os = "macos")]
fn main() {
    std::process::exit(macos::run());
}

#[cfg(target_os = "macos")]
mod macos {
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::time::{Duration, Instant};

    use mci_brain::extraction::tier2_ner::{decode_bio, DecodedSpan, NerWordPieceTokenizer};
    use mci_coreml_bridge::model::{multi_array_i32, multi_array_len, read_f32_slice};
    use mci_coreml_bridge::{ComputeUnits, CoreMLModel};
    use serde::{Deserialize, Serialize};

    // -----------------------------------------------------------------
    // Args
    // -----------------------------------------------------------------

    struct Args {
        model: PathBuf,
        tokenizer: PathBuf,
        labels: PathBuf,
        corpus: PathBuf,
        mode: Mode,
        compute_units: ComputeUnits,
        out: Option<PathBuf>,
        max_len: usize,
        duration_s: u64,
        rate_hz: f64,
        warmup: usize,
        label: String,
    }

    #[derive(PartialEq, Eq)]
    enum Mode {
        Predict,
        Sustained,
    }

    fn parse_units(s: &str) -> ComputeUnits {
        match s {
            "all" => ComputeUnits::All,
            "cpu" | "cpu_only" => ComputeUnits::CpuOnly,
            "gpu" | "cpu_and_gpu" => ComputeUnits::CpuAndGpu,
            "cpu_ne" | "cpu_and_ne" => ComputeUnits::CpuAndNeuralEngine,
            other => {
                eprintln!("unknown --compute-units {other:?} (all|cpu|gpu|cpu_ne)");
                std::process::exit(2);
            }
        }
    }

    fn units_str(u: ComputeUnits) -> &'static str {
        match u {
            ComputeUnits::All => "all",
            ComputeUnits::CpuOnly => "cpu_only",
            ComputeUnits::CpuAndGpu => "cpu_and_gpu",
            ComputeUnits::CpuAndNeuralEngine => "cpu_and_ne",
        }
    }

    fn usage() -> ! {
        eprintln!(
            "mci-ner-bakeoff --model M.mlmodelc --tokenizer T.json --labels L.json \\
                --corpus test.json [--mode predict|sustained]
                [--compute-units all|cpu|gpu|cpu_ne] [--out preds.json] [--max-len 256]
                [--duration 60] [--rate 1.0] [--warmup 10] [--label NAME]

Modes:
  predict    run the corpus, write predictions (--out), report latency.
  sustained  drive inference at --rate Hz for --duration s, sample footprint.

The single-line result is printed to stdout prefixed `@@RESULT@@ ` (JSON);
Core ML / Espresso diagnostics go to stderr."
        );
        std::process::exit(2);
    }

    #[allow(clippy::too_many_lines)]
    fn parse_args() -> Args {
        let mut model = None;
        let mut tokenizer = None;
        let mut labels = None;
        let mut corpus = None;
        let mut mode = Mode::Predict;
        let mut compute_units = ComputeUnits::All;
        let mut out = None;
        let mut max_len = 256usize;
        let mut duration_s = 60u64;
        let mut rate_hz = 1.0f64;
        let mut warmup = 10usize;
        let mut label = None;

        let argv: Vec<String> = std::env::args().collect();
        let mut i = 1;
        while i < argv.len() {
            let need = |i: usize| -> String { argv.get(i + 1).cloned().unwrap_or_else(|| usage()) };
            match argv[i].as_str() {
                "--model" => {
                    model = Some(PathBuf::from(need(i)));
                    i += 1;
                }
                "--tokenizer" => {
                    tokenizer = Some(PathBuf::from(need(i)));
                    i += 1;
                }
                "--labels" => {
                    labels = Some(PathBuf::from(need(i)));
                    i += 1;
                }
                "--corpus" => {
                    corpus = Some(PathBuf::from(need(i)));
                    i += 1;
                }
                "--mode" => {
                    mode = match need(i).as_str() {
                        "predict" => Mode::Predict,
                        "sustained" => Mode::Sustained,
                        other => {
                            eprintln!("unknown --mode {other:?}");
                            std::process::exit(2);
                        }
                    };
                    i += 1;
                }
                "--compute-units" => {
                    compute_units = parse_units(&need(i));
                    i += 1;
                }
                "--out" => {
                    out = Some(PathBuf::from(need(i)));
                    i += 1;
                }
                "--max-len" => {
                    max_len = need(i).parse().expect("--max-len N");
                    i += 1;
                }
                "--duration" => {
                    duration_s = need(i).parse().expect("--duration S");
                    i += 1;
                }
                "--rate" => {
                    rate_hz = need(i).parse().expect("--rate HZ");
                    i += 1;
                }
                "--warmup" => {
                    warmup = need(i).parse().expect("--warmup N");
                    i += 1;
                }
                "--label" => {
                    label = Some(need(i));
                    i += 1;
                }
                "--help" | "-h" => usage(),
                other => {
                    eprintln!("unknown arg: {other}");
                    usage();
                }
            }
            i += 1;
        }

        let model = model.unwrap_or_else(|| usage());
        let label = label.unwrap_or_else(|| {
            model
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("model")
                .to_string()
        });
        Args {
            model,
            tokenizer: tokenizer.unwrap_or_else(|| usage()),
            labels: labels.unwrap_or_else(|| usage()),
            corpus: corpus.unwrap_or_else(|| usage()),
            mode,
            compute_units,
            out,
            max_len,
            duration_s,
            rate_hz,
            warmup,
            label,
        }
    }

    // -----------------------------------------------------------------
    // Corpus + predictions + labels (score_ner.py schema)
    // -----------------------------------------------------------------

    #[derive(Deserialize)]
    struct CorpusRecord {
        id: String,
        text: String,
    }

    #[derive(Serialize)]
    struct PredEntity {
        kind: String,
        span_start: usize,
        span_end: usize,
    }

    #[derive(Serialize)]
    struct PredRecord {
        id: String,
        entities: Vec<PredEntity>,
    }

    #[derive(Deserialize)]
    struct LabelsFile {
        /// `{"0":"O","1":"B-PER",...}` — string-keyed by id, like the
        /// model `config.json`. Read it; do NOT assume a canonical order
        /// (dslim/bert-base-NER leads with MISC, distilbert with PER).
        id2label: std::collections::BTreeMap<String, String>,
    }

    /// Load `labels.json` into an index-ordered `id2label` vector.
    fn load_id2label(path: &Path) -> Vec<String> {
        let raw = std::fs::read_to_string(path)
            .unwrap_or_else(|e| panic!("read labels {}: {e}", path.display()));
        let lf: LabelsFile = serde_json::from_str(&raw)
            .unwrap_or_else(|e| panic!("parse labels {}: {e}", path.display()));
        let n = lf.id2label.len();
        let mut v = vec![String::new(); n];
        for (k, label) in lf.id2label {
            let idx: usize = k
                .parse()
                .unwrap_or_else(|e| panic!("non-numeric label id {k:?}: {e}"));
            assert!(idx < n, "label id {idx} out of range (n={n})");
            v[idx] = label;
        }
        assert!(
            v.iter().all(|s| !s.is_empty()),
            "labels.json has a gap in id2label"
        );
        v
    }

    // -----------------------------------------------------------------
    // The production inference path: tokenize -> Core ML -> decode_bio
    // -----------------------------------------------------------------

    struct Inference {
        spans: Vec<DecodedSpan>,
        predict_ms: f64,
        e2e_ms: f64,
        truncated: bool,
    }

    #[allow(clippy::cast_precision_loss)]
    fn infer_one(
        model: &CoreMLModel,
        tok: &NerWordPieceTokenizer,
        id2label: &[&str],
        max_len: usize,
        text: &str,
    ) -> Result<Inference, String> {
        let num_labels = id2label.len();
        let t0 = Instant::now();

        // Tokenize (natural length). Only fall back to padded/truncated if
        // the event overflows the model's RangeDim cap — keeps short
        // screen-text snippets at their true length (realistic latency).
        let natural = tok.encode(text).map_err(|e| format!("encode: {e}"))?;
        let (enc, truncated) = if natural.input_ids.len() > max_len {
            (
                tok.encode_padded(text, max_len)
                    .map_err(|e| format!("encode_padded: {e}"))?,
                true,
            )
        } else {
            (natural, false)
        };
        let seq_len = enc.input_ids.len();

        let ids = multi_array_i32(&[1, seq_len], &enc.input_ids).map_err(|e| e.to_string())?;
        let mask =
            multi_array_i32(&[1, seq_len], &enc.attention_mask).map_err(|e| e.to_string())?;

        let tp = Instant::now();
        let pred = model
            .predict(&[("input_ids", &*ids), ("attention_mask", &*mask)])
            .map_err(|e| format!("predict: {e}"))?;
        let logits_arr = pred.multi_array("logits").map_err(|e| e.to_string())?;
        let predict_ms = tp.elapsed().as_secs_f64() * 1000.0;

        // Output is logits [1, seq, num_labels]; recover the real element
        // count rather than trusting a fixed shape.
        let want = seq_len * num_labels;
        let have = multi_array_len(&logits_arr);
        if have < want {
            return Err(format!(
                "logits len {have} < expected {want} (seq={seq_len})"
            ));
        }
        let logits = read_f32_slice(&logits_arr, 0, want).map_err(|e| e.to_string())?;

        let spans = decode_bio(
            text,
            &logits,
            seq_len,
            num_labels,
            &enc.offsets,
            &enc.special_tokens_mask,
            &enc.attention_mask,
            id2label,
        );
        let e2e_ms = t0.elapsed().as_secs_f64() * 1000.0;

        Ok(Inference {
            spans,
            predict_ms,
            e2e_ms,
            truncated,
        })
    }

    // -----------------------------------------------------------------
    // Modes
    // -----------------------------------------------------------------

    pub fn run() -> i32 {
        let args = parse_args();
        let pid = std::process::id();

        let id2label_owned = load_id2label(&args.labels);
        let id2label: Vec<&str> = id2label_owned.iter().map(String::as_str).collect();

        let tok = NerWordPieceTokenizer::load_from_file(&args.tokenizer)
            .unwrap_or_else(|e| panic!("load tokenizer {}: {e}", args.tokenizer.display()));

        let corpus_raw = std::fs::read_to_string(&args.corpus)
            .unwrap_or_else(|e| panic!("read corpus {}: {e}", args.corpus.display()));
        let corpus: Vec<CorpusRecord> = serde_json::from_str(&corpus_raw)
            .unwrap_or_else(|e| panic!("parse corpus {}: {e}", args.corpus.display()));

        eprintln!(
            "mci-ner-bakeoff: label={} mode={} units={} model={} corpus={}rec labels={} max_len={} pid={pid}",
            args.label,
            if args.mode == Mode::Predict { "predict" } else { "sustained" },
            units_str(args.compute_units),
            args.model.display(),
            corpus.len(),
            id2label_owned.len(),
            args.max_len,
        );

        let model = CoreMLModel::load_with_compute_units(&args.model, args.compute_units)
            .unwrap_or_else(|e| panic!("load model {}: {e}", args.model.display()));

        match args.mode {
            Mode::Predict => mode_predict(&args, &model, &tok, &id2label, &corpus),
            Mode::Sustained => mode_sustained(&args, &model, &tok, &id2label, &corpus, pid),
        }
    }

    #[allow(clippy::cast_precision_loss)]
    fn mode_predict(
        args: &Args,
        model: &CoreMLModel,
        tok: &NerWordPieceTokenizer,
        id2label: &[&str],
        corpus: &[CorpusRecord],
    ) -> i32 {
        let mut preds: Vec<PredRecord> = Vec::with_capacity(corpus.len());
        let mut predict_ms: Vec<f64> = Vec::with_capacity(corpus.len());
        let mut e2e_ms: Vec<f64> = Vec::with_capacity(corpus.len());
        let mut n_truncated = 0usize;
        let mut n_err = 0usize;
        let mut n_spans = 0usize;

        for rec in corpus {
            match infer_one(model, tok, id2label, args.max_len, &rec.text) {
                Ok(inf) => {
                    predict_ms.push(inf.predict_ms);
                    e2e_ms.push(inf.e2e_ms);
                    if inf.truncated {
                        n_truncated += 1;
                    }
                    n_spans += inf.spans.len();
                    let entities = inf
                        .spans
                        .into_iter()
                        .map(|s| PredEntity {
                            kind: s.kind,
                            span_start: s.span_start,
                            span_end: s.span_end,
                        })
                        .collect();
                    preds.push(PredRecord {
                        id: rec.id.clone(),
                        entities,
                    });
                }
                Err(e) => {
                    n_err += 1;
                    eprintln!("  infer error on {}: {e}", rec.id);
                    // Emit an empty prediction so the id is explicitly present
                    // and n_errors stays attributable. (The scorer treats a
                    // missing id as empty anyway, so this does not change F1 —
                    // it just keeps the failure visible rather than silent.)
                    preds.push(PredRecord {
                        id: rec.id.clone(),
                        entities: Vec::new(),
                    });
                }
            }
        }

        if let Some(out) = &args.out {
            let json = serde_json::to_string(&preds).expect("serialize preds");
            std::fs::write(out, json).unwrap_or_else(|e| panic!("write {}: {e}", out.display()));
            eprintln!("wrote {} predictions -> {}", preds.len(), out.display());
        }

        let result = serde_json::json!({
            "label": args.label,
            "mode": "predict",
            "compute_units": units_str(args.compute_units),
            "model": args.model.display().to_string(),
            "n_records": corpus.len(),
            "n_truncated": n_truncated,
            "n_errors": n_err,
            "n_pred_spans": n_spans,
            "predict_ms": latency_summary(&predict_ms),
            "e2e_ms": latency_summary(&e2e_ms),
        });
        println!("@@RESULT@@ {result}");
        i32::from(n_err > 0)
    }

    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        clippy::similar_names
    )]
    fn mode_sustained(
        args: &Args,
        model: &CoreMLModel,
        tok: &NerWordPieceTokenizer,
        id2label: &[&str],
        corpus: &[CorpusRecord],
        pid: u32,
    ) -> i32 {
        assert!(!corpus.is_empty(), "empty corpus");
        // Warm up (first-inference / shape-compile costs excluded).
        for k in 0..args.warmup {
            let text = &corpus[k % corpus.len()].text;
            let _ = infer_one(model, tok, id2label, args.max_len, text);
        }

        let target_period = Duration::from_secs_f64(1.0 / args.rate_hz.max(0.001));
        let run_start = Instant::now();
        let cpu_start = cpu_time_us();

        let mut infer_ms: Vec<f64> = Vec::new();
        let mut burst_cpu_pct: Vec<f64> = Vec::new();
        let mut peak_rss_kb_ps = 0u64;
        let mut n_infer = 0usize;
        let mut i = 0usize;

        while run_start.elapsed() < Duration::from_secs(args.duration_s) {
            let iter_start = Instant::now();
            let text = &corpus[i % corpus.len()].text;
            i += 1;

            // CPU time consumed by THIS inference (all threads) -> burst
            // cost as a % of one core (can exceed 100 on multithreaded CPU
            // inference; near-0 if the work is offloaded to GPU/ANE).
            let cpu_before = cpu_time_us();
            let wall_before = Instant::now();
            let inf = infer_one(model, tok, id2label, args.max_len, text);
            let wall_us = wall_before.elapsed().as_micros() as u64;
            let cpu_us = cpu_time_us().saturating_sub(cpu_before);
            if let Ok(inf) = inf {
                infer_ms.push(inf.predict_ms);
                n_infer += 1;
                if wall_us > 0 {
                    burst_cpu_pct.push((cpu_us as f64 / wall_us as f64) * 100.0);
                }
            }

            let rss = rss_kb_via_ps(pid);
            peak_rss_kb_ps = peak_rss_kb_ps.max(rss);

            // Pace to the target cadence.
            if let Some(rem) = target_period.checked_sub(iter_start.elapsed()) {
                std::thread::sleep(rem);
            }
        }

        let total_wall_us = run_start.elapsed().as_micros() as f64;
        let total_cpu_us = cpu_time_us().saturating_sub(cpu_start) as f64;
        let sustained_mean_cpu_pct = if total_wall_us > 0.0 {
            (total_cpu_us / total_wall_us) * 100.0
        } else {
            0.0
        };
        let peak_rss_mb_maxrss = max_rss_bytes() as f64 / 1.0e6;
        let peak_rss_mb_ps = peak_rss_kb_ps as f64 / 1000.0;

        let result = serde_json::json!({
            "label": args.label,
            "mode": "sustained",
            "compute_units": units_str(args.compute_units),
            "model": args.model.display().to_string(),
            "duration_s": args.duration_s,
            "rate_hz": args.rate_hz,
            "n_infer": n_infer,
            "infer_ms": latency_summary(&infer_ms),
            "burst_cpu_pct_of_one_core": latency_summary(&burst_cpu_pct),
            "sustained_mean_cpu_pct_of_one_core": round3(sustained_mean_cpu_pct),
            "peak_rss_mb_ps": round3(peak_rss_mb_ps),
            "peak_rss_mb_maxrss": round3(peak_rss_mb_maxrss),
        });
        println!("@@RESULT@@ {result}");
        0
    }

    // -----------------------------------------------------------------
    // Measurement helpers (getrusage CPU-time + ps RSS, per perf-soak)
    // -----------------------------------------------------------------

    fn latency_summary(v: &[f64]) -> serde_json::Value {
        if v.is_empty() {
            return serde_json::json!({ "n": 0 });
        }
        let mut s = v.to_vec();
        s.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        #[allow(clippy::cast_precision_loss)]
        let mean = v.iter().sum::<f64>() / v.len() as f64;
        serde_json::json!({
            "n": v.len(),
            "p50": round3(pct(&s, 50)),
            "p95": round3(pct(&s, 95)),
            "min": round3(s[0]),
            "max": round3(s[s.len() - 1]),
            "mean": round3(mean),
        })
    }

    fn pct(sorted: &[f64], p: usize) -> f64 {
        if sorted.is_empty() {
            return 0.0;
        }
        sorted[(sorted.len() * p / 100).min(sorted.len() - 1)]
    }

    fn round3(x: f64) -> f64 {
        (x * 1000.0).round() / 1000.0
    }

    #[allow(clippy::cast_sign_loss)]
    fn cpu_time_us() -> u64 {
        // SAFETY: getrusage writes into a caller-provided rusage struct;
        // zeroed memory is a valid initial state for the C struct.
        unsafe {
            let mut usage: libc::rusage = std::mem::zeroed();
            if libc::getrusage(libc::RUSAGE_SELF, &raw mut usage) != 0 {
                return 0;
            }
            let user = usage.ru_utime.tv_sec as u64 * 1_000_000 + usage.ru_utime.tv_usec as u64;
            let sys = usage.ru_stime.tv_sec as u64 * 1_000_000 + usage.ru_stime.tv_usec as u64;
            user + sys
        }
    }

    #[allow(clippy::cast_sign_loss)]
    fn max_rss_bytes() -> u64 {
        // ru_maxrss is the lifetime peak resident set size. macOS reports
        // it in BYTES (Linux reports KB) — this harness is macOS-gated.
        // SAFETY: as cpu_time_us.
        unsafe {
            let mut usage: libc::rusage = std::mem::zeroed();
            if libc::getrusage(libc::RUSAGE_SELF, &raw mut usage) != 0 {
                return 0;
            }
            usage.ru_maxrss as u64
        }
    }

    fn rss_kb_via_ps(pid: u32) -> u64 {
        Command::new("ps")
            .args(["-o", "rss=", "-p", &pid.to_string()])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|s| s.trim().parse::<u64>().ok())
            .unwrap_or(0)
    }
}
