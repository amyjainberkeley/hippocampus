//! `mci-bench` — run the LongMemEval retrieval benchmark against the real
//! brain and print numbers that can be published without hedging.
//!
//! Deliberately a separate binary. The benchmark pulls in the dataset
//! parser and is run by maintainers, not users, so it has no business
//! adding weight to `mci-agent`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{SystemTime, UNIX_EPOCH};

use mci_agent::bench_longmemeval::{
    best_threshold, compare_against_baseline, derive_regression_thresholds, load_dataset,
    run_abstention_probe, run_instance, summarize, AbstentionSample, Arm, BaselineFile, Embedders,
    InstanceResult, LoadedDataset, RegressionReport, Report, RunFailure, RunMetadata, Summary,
};

fn usage() {
    println!(
        "mci-bench {}\n\
         \n\
         Usage: mci-bench --dataset <longmemeval_s_cleaned.json|synthetic-v1.json> [OPTIONS]\n\
         \n\
         Options:\n\
         \x20 --dataset PATH   benchmark dataset (legacy LongMemEval array or work-memory envelope)\n\
         \x20 --limit N        only the first N instances (default: all)\n\
         \x20 --arm ARM        lexical | hybrid | both (default: both)\n\
         \x20 --k LIST         cutoffs, comma-separated (default: 1,3,5,10)\n\
         \x20 --out PATH       write the full JSON report here\n\
         \x20 --baseline PATH  compare against committed regression thresholds\n\
         \x20 --workdir PATH   scratch for per-instance databases\n\
         \x20 --abstention N   instead of scoring retrieval, measure whether a\n\
         \x20                  relevance floor is possible: ask each of N brains\n\
         \x20                  its own question and a foreign one, and report the\n\
         \x20                  cosine threshold that best separates them\n\
         \n\
         Measures session-level retrieval, NOT question-answering accuracy.\n\
         Those are different numbers and must not be compared.",
        env!("CARGO_PKG_VERSION")
    );
}

fn dataset_fallback_id(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("dataset")
        .to_string()
}

fn git_value(args: &[&str]) -> String {
    match Command::new("git").args(args).output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "unknown".to_string(),
    }
}

fn captured_at_utc() -> String {
    match Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
    {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| format!("unix:{}", d.as_secs()))
            .unwrap_or_else(|_| "unknown".to_string()),
    }
}

fn run_metadata(ks: &[usize], limit: Option<usize>, workdir: &Path, arms: &[Arm]) -> RunMetadata {
    RunMetadata {
        captured_at_utc: captured_at_utc(),
        git_commit: git_value(&["rev-parse", "HEAD"]),
        branch: git_value(&["branch", "--show-current"]),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        model_path: std::env::var("MCI_ARCTIC_MODEL_PATH").ok(),
        requested_arms: arms.iter().map(|arm| arm.label().to_string()).collect(),
        ks: ks.to_vec(),
        limit,
        workdir: workdir.display().to_string(),
    }
}

fn write_report(path: &Path, report: &Report) -> Result<(), String> {
    let json =
        serde_json::to_string_pretty(report).map_err(|e| format!("serialize report: {e}"))?;
    std::fs::write(path, json).map_err(|e| format!("write {}: {e}", path.display()))
}

fn print_summary(summary: &Summary, ks: &[usize], elapsed_secs: f64) {
    println!(
        "\n=== {} ===  ({} instances, {:.0}s)",
        summary.arm, summary.instances, elapsed_secs
    );
    for &k in ks {
        println!(
            "  hit@{k:<3} {:>6.1}%      recall@{k:<3} {:>6.1}%      provenance@{k:<3} {:>6.1}%      fp@{k:<3} {:>6.1}%",
            100.0 * summary.hit_rate_at.get(&k).copied().unwrap_or(0.0),
            100.0 * summary.recall_at.get(&k).copied().unwrap_or(0.0),
            100.0 * summary.provenance_coverage_at.get(&k).copied().unwrap_or(0.0),
            100.0 * summary.false_positive_rate_at.get(&k).copied().unwrap_or(0.0),
        );
    }
    println!(
        "  MRR      {:>6.3}       misses {}       outcomes matched={} missed={} abstained={} false_positive={}",
        summary.mrr,
        summary.complete_misses,
        summary.outcomes.matched,
        summary.outcomes.missed,
        summary.outcomes.abstained,
        summary.outcomes.false_positive
    );
    println!(
        "  latency  p50={:.1}ms p95={:.1}ms       index p50={:.0}B p95={:.0}B",
        summary.latency_ms.p50,
        summary.latency_ms.p95,
        summary.index_size_bytes.p50,
        summary.index_size_bytes.p95
    );
}

fn parse_baseline(path: &Path) -> Result<BaselineFile, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| format!("read baseline {}: {e}", path.display()))?;
    serde_json::from_str::<BaselineFile>(&raw)
        .map_err(|e| format!("parse baseline {}: {e}", path.display()))
}

fn summarize_by_type(
    results: &[InstanceResult],
    arm: Arm,
    ks: &[usize],
) -> BTreeMap<String, Summary> {
    let mut buckets: BTreeMap<String, Vec<InstanceResult>> = BTreeMap::new();
    for result in results {
        buckets
            .entry(result.question_type.clone())
            .or_default()
            .push(result.clone());
    }
    buckets
        .into_iter()
        .map(|(kind, values)| (kind, summarize(&values, arm, ks)))
        .collect()
}

fn summarize_by_tag(
    results: &[InstanceResult],
    arm: Arm,
    ks: &[usize],
) -> BTreeMap<String, Summary> {
    let mut buckets: BTreeMap<String, Vec<InstanceResult>> = BTreeMap::new();
    for result in results {
        let mut seen = BTreeSet::new();
        for tag in &result.tags {
            if seen.insert(tag.clone()) {
                buckets.entry(tag.clone()).or_default().push(result.clone());
            }
        }
    }
    buckets
        .into_iter()
        .map(|(tag, values)| (tag, summarize(&values, arm, ks)))
        .collect()
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().collect();
    let mut dataset_path: Option<PathBuf> = None;
    let mut baseline_path: Option<PathBuf> = None;
    let mut limit: Option<usize> = None;
    let mut arms = vec![Arm::Lexical, Arm::Hybrid];
    let mut ks: Vec<usize> = vec![1, 3, 5, 10];
    let mut out: Option<PathBuf> = None;
    let mut workdir = std::env::temp_dir().join("mci-bench");
    let mut abstention: Option<usize> = None;

    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--dataset" if i + 1 < argv.len() => {
                dataset_path = Some(PathBuf::from(&argv[i + 1]));
                i += 1;
            }
            "--baseline" if i + 1 < argv.len() => {
                baseline_path = Some(PathBuf::from(&argv[i + 1]));
                i += 1;
            }
            "--limit" if i + 1 < argv.len() => {
                limit = argv[i + 1].parse().ok();
                i += 1;
            }
            "--arm" if i + 1 < argv.len() => {
                arms = match argv[i + 1].as_str() {
                    "lexical" => vec![Arm::Lexical],
                    "hybrid" => vec![Arm::Hybrid],
                    "both" => vec![Arm::Lexical, Arm::Hybrid],
                    other => {
                        eprintln!("mci-bench: unknown arm `{other}` (lexical|hybrid|both)");
                        return ExitCode::from(2);
                    }
                };
                i += 1;
            }
            "--k" if i + 1 < argv.len() => {
                ks = argv[i + 1]
                    .split(',')
                    .filter_map(|s| s.trim().parse().ok())
                    .collect();
                i += 1;
            }
            "--out" if i + 1 < argv.len() => {
                out = Some(PathBuf::from(&argv[i + 1]));
                i += 1;
            }
            "--abstention" if i + 1 < argv.len() => {
                abstention = argv[i + 1].parse().ok();
                i += 1;
            }
            "--workdir" if i + 1 < argv.len() => {
                workdir = PathBuf::from(&argv[i + 1]);
                i += 1;
            }
            "-h" | "--help" => {
                usage();
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("mci-bench: unknown argument `{other}`\n");
                usage();
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let Some(dataset_path) = dataset_path else {
        usage();
        return ExitCode::from(2);
    };
    if ks.is_empty() {
        eprintln!("mci-bench: --k must name at least one cutoff");
        return ExitCode::from(2);
    }
    ks.sort_unstable();

    if let Err(e) = std::fs::create_dir_all(&workdir) {
        eprintln!(
            "mci-bench: cannot create workdir {}: {e}",
            workdir.display()
        );
        return ExitCode::from(3);
    }

    eprint!("mci-bench: loading {} ... ", dataset_path.display());
    let raw = match std::fs::read_to_string(&dataset_path) {
        Ok(raw) => raw,
        Err(e) => {
            eprintln!("\nmci-bench: read {}: {e}", dataset_path.display());
            return ExitCode::from(3);
        }
    };
    let fallback_id = dataset_fallback_id(&dataset_path);
    let mut dataset: LoadedDataset = match load_dataset(&raw, &fallback_id) {
        Ok(dataset) => dataset,
        Err(e) => {
            eprintln!("\nmci-bench: parse {}: {e}", dataset_path.display());
            return ExitCode::from(3);
        }
    };
    if let Some(n) = limit {
        dataset.instances.truncate(n);
    }
    eprintln!("{} instances", dataset.instances.len());

    let metadata = run_metadata(&ks, limit, &workdir, &arms);
    let needs_embedder = abstention.is_some() || arms.contains(&Arm::Hybrid);
    let embedders = if needs_embedder {
        match Embedders::load() {
            Ok(embedders) => Some(embedders),
            Err(error) => {
                let report = Report {
                    complete: false,
                    dataset: dataset_path.display().to_string(),
                    dataset_id: dataset.dataset_id,
                    dataset_description: dataset.description,
                    overall: Vec::new(),
                    by_type: BTreeMap::new(),
                    by_tag: BTreeMap::new(),
                    results: Vec::new(),
                    failures: vec![RunFailure {
                        arm: "hybrid".to_string(),
                        question_id: None,
                        error: error.clone(),
                    }],
                    regression_thresholds: BTreeMap::new(),
                    regression: None,
                    run: Some(metadata),
                };
                if let Some(path) = out.as_deref() {
                    if let Err(write_error) = write_report(path, &report) {
                        eprintln!("mci-bench: {write_error}");
                        return ExitCode::from(3);
                    }
                }
                eprintln!("mci-bench: {error}");
                return ExitCode::from(4);
            }
        }
    } else {
        None
    };

    if let Some(n) = abstention {
        let n = n.min(dataset.instances.len());
        if n < 2 {
            eprintln!("mci-bench: --abstention needs at least 2 instances to cross-pair");
            return ExitCode::from(2);
        }
        let started = std::time::Instant::now();
        let mut samples: Vec<AbstentionSample> = Vec::new();
        for idx in 0..n {
            let foreign = dataset.instances[(idx + 1) % n].question.clone();
            match run_abstention_probe(
                &dataset.instances[idx],
                &foreign,
                &workdir,
                embedders.as_ref().expect("abstention requires an embedder"),
            ) {
                Ok(mut sample) => samples.append(&mut sample),
                Err(error) => eprintln!("mci-bench: [abstention] {error}"),
            }
            if (idx + 1) % 5 == 0 || idx + 1 == n {
                eprintln!(
                    "mci-bench: [abstention] {}/{} done, {:.0}s elapsed",
                    idx + 1,
                    n,
                    started.elapsed().as_secs_f64()
                );
            }
        }

        let answerable: Vec<f32> = samples
            .iter()
            .filter(|s| s.answerable)
            .map(|s| s.top_cosine)
            .collect();
        let unanswerable: Vec<f32> = samples
            .iter()
            .filter(|s| !s.answerable)
            .map(|s| s.top_cosine)
            .collect();
        let stat = |v: &[f32]| -> (f32, f32, f32) {
            if v.is_empty() {
                return (0.0, 0.0, 0.0);
            }
            let mut sorted = v.to_vec();
            sorted.sort_by(|a, b| a.partial_cmp(b).expect("no NaN"));
            (
                sorted[0],
                sorted[sorted.len() / 2],
                sorted[sorted.len() - 1],
            )
        };
        let (amin, amed, amax) = stat(&answerable);
        let (umin, umed, umax) = stat(&unanswerable);
        println!(
            "\n=== abstention probe ===  ({} pairs, {:.0}s)",
            answerable.len(),
            started.elapsed().as_secs_f64()
        );
        println!("  top raw cosine        min     median     max");
        println!(
            "    answerable      {amin:>7.4}  {amed:>9.4}  {amax:>7.4}   n={}",
            answerable.len()
        );
        println!(
            "    unanswerable    {umin:>7.4}  {umed:>9.4}  {umax:>7.4}   n={}",
            unanswerable.len()
        );
        match best_threshold(&samples) {
            Some(report) => {
                println!("\n  best cosine floor: {:.4}", report.threshold);
                println!(
                    "    answers kept on answerable questions   {:>6.1}%",
                    100.0 * report.answerable_kept
                );
                println!(
                    "    answers kept on unanswerable questions {:>6.1}%   (want low)",
                    100.0 * report.unanswerable_kept
                );
                println!(
                    "    separation (Youden J)                  {:>6.3}",
                    report.youden_j
                );
                if report.youden_j < 0.5 {
                    println!("\n  NOT separable enough to ship a floor on this signal alone.");
                }
            }
            None => println!("  no samples"),
        }
        return ExitCode::SUCCESS;
    }

    let mut overall = Vec::new();
    let mut by_type: BTreeMap<String, Vec<Summary>> = BTreeMap::new();
    let mut by_tag: BTreeMap<String, Vec<Summary>> = BTreeMap::new();
    let mut all_results = Vec::new();
    let mut failures = Vec::new();

    for arm in arms {
        let started = std::time::Instant::now();
        let mut results = Vec::new();
        let mut arm_failures = 0usize;

        for (n, instance) in dataset.instances.iter().enumerate() {
            match run_instance(instance, arm, &ks, &workdir, embedders.as_ref()) {
                Ok(result) => results.push(result),
                Err(error) => {
                    arm_failures += 1;
                    eprintln!("mci-bench: [{}] {error}", arm.label());
                    failures.push(RunFailure {
                        arm: arm.label().to_string(),
                        question_id: Some(instance.question_id.clone()),
                        error,
                    });
                }
            }
            if (n + 1) % 10 == 0 || n + 1 == dataset.instances.len() {
                let hit = results
                    .iter()
                    .filter(|r| r.first_hit_rank.is_some_and(|rank| rank <= 5))
                    .count();
                eprintln!(
                    "mci-bench: [{}] {}/{} done, hit@5 so far {:.1}%, {:.0}s elapsed",
                    arm.label(),
                    n + 1,
                    dataset.instances.len(),
                    100.0 * hit as f64 / results.len().max(1) as f64,
                    started.elapsed().as_secs_f64()
                );
            }
        }

        if arm_failures > 0 {
            eprintln!(
                "mci-bench: [{}] WARNING {arm_failures} instance(s) failed",
                arm.label()
            );
        }

        let summary = summarize(&results, arm, &ks);
        print_summary(&summary, &ks, started.elapsed().as_secs_f64());

        println!("  by question type:");
        for (kind, typed_summary) in summarize_by_type(&results, arm, &ks) {
            let kmax = *ks.last().expect("ks non-empty");
            println!(
                "    {kind:<28} n={:<4} hit@{kmax}={:>5.1}%  MRR={:.3}",
                typed_summary.instances,
                100.0 * typed_summary.hit_rate_at.get(&kmax).copied().unwrap_or(0.0),
                typed_summary.mrr
            );
            by_type.entry(kind).or_default().push(typed_summary);
        }

        let tag_summaries = summarize_by_tag(&results, arm, &ks);
        if !tag_summaries.is_empty() {
            println!("  by tag:");
            for (tag, tag_summary) in tag_summaries {
                let kmax = *ks.last().expect("ks non-empty");
                println!(
                    "    {tag:<28} n={:<4} hit@{kmax}={:>5.1}%  MRR={:.3}",
                    tag_summary.instances,
                    100.0 * tag_summary.hit_rate_at.get(&kmax).copied().unwrap_or(0.0),
                    tag_summary.mrr
                );
                by_tag.entry(tag).or_default().push(tag_summary);
            }
        }

        all_results.extend(results);
        overall.push(summary);
    }

    let regression_thresholds = overall
        .iter()
        .map(|summary| (summary.arm.clone(), derive_regression_thresholds(summary)))
        .collect::<BTreeMap<_, _>>();
    let regression = match baseline_path.as_deref() {
        Some(path) => match parse_baseline(path) {
            Ok(baseline) => Some(compare_against_baseline(
                &overall,
                &baseline.regression_thresholds,
            )),
            Err(error) => {
                failures.push(RunFailure {
                    arm: "baseline".to_string(),
                    question_id: None,
                    error: error.clone(),
                });
                Some(RegressionReport {
                    passed: false,
                    failures: vec![error],
                })
            }
        },
        None => None,
    };
    let regression_failed = regression.as_ref().is_some_and(|r| !r.passed);
    let complete = failures.is_empty() && !regression_failed;

    let report = Report {
        complete,
        dataset: dataset_path.display().to_string(),
        dataset_id: dataset.dataset_id,
        dataset_description: dataset.description,
        overall,
        by_type,
        by_tag,
        results: all_results,
        failures,
        regression_thresholds,
        regression,
        run: Some(metadata),
    };

    if let Some(path) = out.as_deref() {
        if let Err(error) = write_report(path, &report) {
            eprintln!("mci-bench: {error}");
            return ExitCode::from(3);
        }
        eprintln!("mci-bench: report written to {}", path.display());
    }

    if complete {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(5)
    }
}
