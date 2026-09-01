//! `mci-bench` — run the LongMemEval retrieval benchmark against the real
//! brain and print numbers that can be published without hedging.
//!
//! Deliberately a separate binary. The benchmark pulls in the dataset
//! parser and is run by maintainers, not users, so it has no business
//! adding weight to `mci-agent`.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{ExitCode, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use mci_agent::bench_longmemeval::{
    absolute_quality_targets, best_threshold, compare_against_baseline,
    derive_regression_thresholds, evaluate_quality_gate, load_dataset, run_abstention_probe,
    run_instance, summarize, AbstentionSample, Arm, BaselineFile, Embedders, InstanceResult,
    LoadedDataset, RegressionReport, Report, RunFailure, RunMetadata, ScratchRun, Summary,
};
use mci_agent::child_command_environment::sanitized_command;

const CANONICAL_WORK_MEMORY_DATASET: &str = "eval/work-memory/synthetic-v1.json";
const CANONICAL_WORK_MEMORY_DATASET_ID: &str = "synthetic-work-memory-v1";
const CANONICAL_WORK_MEMORY_INSTANCES: usize = 24;

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
         \x20 --allow-smoke    allow an intentional --limit smoke run to exit zero;\n\
         \x20                  smoke reports remain incomplete and nonpublishable\n\
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

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap_or_else(|_| Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."))
}

fn command_value(program: &str, args: &[&str]) -> String {
    match sanitized_command(program).args(args).output() {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "unknown".to_string(),
    }
}

fn git_value(root: &Path, args: &[&str]) -> String {
    match sanitized_command("git")
        .current_dir(root)
        .args(args)
        .output()
    {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "unknown".to_string(),
    }
}

fn git_dirty(root: &Path) -> bool {
    sanitized_command("git")
        .current_dir(root)
        .args(["status", "--porcelain", "--untracked-files=all"])
        .output()
        .map_or(true, |out| !out.status.success() || !out.stdout.is_empty())
}

fn captured_at_utc() -> String {
    match sanitized_command("date")
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

fn sysctl_value(name: &str) -> Option<String> {
    let value = command_value("sysctl", &["-n", name]);
    (value != "unknown" && !value.is_empty()).then_some(value)
}

fn sha256_bytes(bytes: &[u8]) -> Result<String, String> {
    let mut child = sanitized_command("shasum")
        .args(["-a", "256"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn shasum: {e}"))?;
    child
        .stdin
        .as_mut()
        .ok_or_else(|| "shasum stdin unavailable".to_string())?
        .write_all(bytes)
        .map_err(|e| format!("write shasum input: {e}"))?;
    let output = child
        .wait_with_output()
        .map_err(|e| format!("wait for shasum: {e}"))?;
    if !output.status.success() {
        return Err("shasum failed".to_string());
    }
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .map(str::to_string)
        .ok_or_else(|| "shasum returned no digest".to_string())
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    sha256_bytes(&bytes)
}

fn collect_files(root: &Path, dir: &Path, files: &mut Vec<PathBuf>) -> Result<(), String> {
    for entry in std::fs::read_dir(dir).map_err(|e| format!("read {}: {e}", dir.display()))? {
        let entry = entry.map_err(|e| format!("read directory entry: {e}"))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|e| format!("inspect {}: {e}", path.display()))?;
        if file_type.is_dir() {
            collect_files(root, &path, files)?;
        } else if file_type.is_file() {
            files.push(
                path.strip_prefix(root)
                    .map_err(|e| format!("relative model path: {e}"))?
                    .to_path_buf(),
            );
        }
    }
    Ok(())
}

fn sha256_path(path: &Path) -> Result<String, String> {
    if path.is_file() {
        return sha256_file(path);
    }
    if !path.is_dir() {
        return Err(format!(
            "checksum target does not exist: {}",
            path.display()
        ));
    }
    let mut files = Vec::new();
    collect_files(path, path, &mut files)?;
    files.sort();
    let mut manifest = Vec::new();
    for relative in files {
        let digest = sha256_file(&path.join(&relative))?;
        manifest.extend_from_slice(relative.to_string_lossy().as_bytes());
        manifest.push(0);
        manifest.extend_from_slice(digest.as_bytes());
        manifest.push(b'\n');
    }
    sha256_bytes(&manifest)
}

fn logical_path(path: &Path, root: &Path, role: &str) -> String {
    let rooted = if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    };
    let absolute = rooted.canonicalize().unwrap_or(rooted);
    if let Ok(relative) = absolute.strip_prefix(root) {
        return relative.to_string_lossy().to_string();
    }
    let basename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("unnamed");
    if role == "model" && absolute.starts_with("/Applications/Hippocampus.app/") {
        return format!("installed-model://{basename}");
    }
    format!("external-{role}://{basename}")
}

fn normalized_arguments(argv: &[String], root: &Path) -> Vec<String> {
    let mut normalized = Vec::new();
    let mut index = 1usize;
    while index < argv.len() {
        let argument = &argv[index];
        normalized.push(argument.clone());
        let role = match argument.as_str() {
            "--dataset" => Some("dataset"),
            "--baseline" => Some("baseline"),
            "--out" => Some("report"),
            "--workdir" => Some("scratch"),
            _ => None,
        };
        if let Some(role) = role {
            if let Some(value) = argv.get(index + 1) {
                normalized.push(logical_path(Path::new(value), root, role));
                index += 2;
                continue;
            }
        }
        index += 1;
    }
    normalized
}

fn report_path(path: &Path, root: &Path) -> String {
    logical_path(path, root, "dataset")
}

fn canonical_work_memory_scope(
    dataset_path: &str,
    dataset_id: &str,
    original_instances: usize,
    evaluated_instances: usize,
    arms: &[Arm],
    ks: &[usize],
    limited: bool,
) -> bool {
    dataset_path == CANONICAL_WORK_MEMORY_DATASET
        && dataset_id == CANONICAL_WORK_MEMORY_DATASET_ID
        && original_instances == CANONICAL_WORK_MEMORY_INSTANCES
        && evaluated_instances == CANONICAL_WORK_MEMORY_INSTANCES
        && arms == [Arm::Lexical, Arm::Hybrid]
        && ks == [1, 3, 5, 10]
        && !limited
}

fn run_metadata(
    argv: &[String],
    ks: &[usize],
    limit: Option<usize>,
    arms: &[Arm],
    original_instances: usize,
    evaluated_instances: usize,
) -> RunMetadata {
    let root = repo_root();
    let uses_hybrid = arms.contains(&Arm::Hybrid);
    let os_name = command_value("sw_vers", &["-productName"]);
    RunMetadata {
        captured_at_utc: captured_at_utc(),
        git_commit: git_value(&root, &["rev-parse", "HEAD"]),
        git_dirty_at_start: git_dirty(&root),
        branch: git_value(&root, &["branch", "--show-current"]),
        command: std::env::var("MCI_BENCH_COMMAND").unwrap_or_else(|_| "mci-bench".into()),
        arguments: normalized_arguments(argv, &root),
        rustc_version: command_value("rustc", &["--version"]),
        cargo_version: command_value("cargo", &["--version"]),
        os_name: if os_name == "unknown" {
            std::env::consts::OS.to_string()
        } else {
            os_name
        },
        os_version: command_value("sw_vers", &["-productVersion"]),
        os_build: command_value("sw_vers", &["-buildVersion"]),
        architecture: command_value("uname", &["-m"]),
        hardware_model: sysctl_value("hw.model"),
        hardware_chip: sysctl_value("machdep.cpu.brand_string"),
        ram_bytes: sysctl_value("hw.memsize").and_then(|value| value.parse().ok()),
        compute_mode: if uses_hybrid {
            "coreml_cpu_only".into()
        } else {
            "not_used".into()
        },
        model_family: uses_hybrid.then(|| "snowflake-arctic-embed-s-int8".into()),
        model_path: None,
        model_checksum_sha256: None,
        requested_arms: arms.iter().map(|arm| arm.label().to_string()).collect(),
        ks: ks.to_vec(),
        limit,
        original_instances,
        evaluated_instances,
    }
}

fn write_report(path: &Path, report: &Report) -> Result<(), String> {
    let json =
        serde_json::to_string_pretty(report).map_err(|e| format!("serialize report: {e}"))?;
    std::fs::write(path, json).map_err(|e| format!("write {}: {e}", path.display()))
}

fn percent(value: Option<f64>) -> String {
    value.map_or_else(
        || "   n/a".to_string(),
        |value| format!("{:>6.1}%", 100.0 * value),
    )
}

fn decimal(value: Option<f64>) -> String {
    value.map_or_else(|| "n/a".to_string(), |value| format!("{value:.3}"))
}

fn print_summary(summary: &Summary, ks: &[usize], elapsed_secs: f64) {
    println!(
        "\n=== {} ===  ({} instances, {:.0}s)",
        summary.arm, summary.instances, elapsed_secs
    );
    println!(
        "  denominators answerable={} unanswerable={}",
        summary.answerable_instances, summary.unanswerable_instances
    );
    println!("  hit/recall/MRR/provenance: answerable-only; fp: unanswerable-only");
    println!("  abstention separation: answerable hit-rate - unanswerable FPR (TPR - FPR)");
    for &k in ks {
        println!(
            "  hit@{k:<3} {}      recall@{k:<3} {}      provenance@{k:<3} {}      fp@{k:<3} {}      separation@{k:<3} {}",
            percent(summary.hit_rate_at.get(&k).copied().flatten()),
            percent(summary.recall_at.get(&k).copied().flatten()),
            percent(summary.provenance_coverage_at.get(&k).copied().flatten()),
            percent(summary.false_positive_rate_at.get(&k).copied().flatten()),
            decimal(summary.abstention_separation_at.get(&k).copied().flatten()),
        );
    }
    println!(
        "  MRR      {:>6}       misses {}       outcomes matched={} missed={} abstained={} false_positive={}",
        decimal(summary.mrr),
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
    let mut allow_smoke = false;

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
            "--allow-smoke" => allow_smoke = true,
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

    let scratch_run = match ScratchRun::create(&workdir) {
        Ok(run) => run,
        Err(error) => {
            eprintln!("mci-bench: {error}");
            return ExitCode::from(3);
        }
    };
    let workdir = scratch_run.path();

    eprint!("mci-bench: loading {} ... ", dataset_path.display());
    let raw = match std::fs::read_to_string(&dataset_path) {
        Ok(raw) => raw,
        Err(e) => {
            eprintln!("\nmci-bench: read {}: {e}", dataset_path.display());
            return ExitCode::from(3);
        }
    };
    let dataset_checksum_sha256 = match sha256_bytes(raw.as_bytes()) {
        Ok(checksum) => checksum,
        Err(error) => {
            eprintln!("\nmci-bench: dataset checksum: {error}");
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
    let original_instances = dataset.instances.len();
    if let Some(n) = limit {
        dataset.instances.truncate(n);
    }
    let evaluated_instances = dataset.instances.len();
    let limited = evaluated_instances < original_instances;
    eprintln!("{} instances", dataset.instances.len());

    let mut metadata = run_metadata(
        &argv,
        &ks,
        limit,
        &arms,
        original_instances,
        evaluated_instances,
    );
    let dataset_report_path = report_path(&dataset_path, &repo_root());
    let needs_embedder = abstention.is_some() || arms.contains(&Arm::Hybrid);
    let embedders = if needs_embedder {
        match Embedders::load() {
            Ok(embedders) => {
                metadata.model_path =
                    Some(logical_path(&embedders.model_path, &repo_root(), "model"));
                metadata.model_checksum_sha256 = match sha256_path(&embedders.model_path) {
                    Ok(checksum) => Some(checksum),
                    Err(error) => {
                        eprintln!("mci-bench: model checksum: {error}");
                        None
                    }
                };
                if metadata.model_checksum_sha256.is_none() {
                    let error = "resolved Core ML model could not be checksummed".to_string();
                    let quality_targets = absolute_quality_targets();
                    let report = Report {
                        complete: false,
                        publishable: false,
                        launch_qualified: false,
                        dataset: dataset_report_path.clone(),
                        dataset_id: dataset.dataset_id,
                        dataset_checksum_sha256: dataset_checksum_sha256.clone(),
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
                        absolute_quality_targets: quality_targets,
                        quality_gate: RegressionReport {
                            passed: false,
                            failures: vec![error.clone()],
                        },
                        regression: None,
                        run: Some(metadata),
                    };
                    if let Some(path) = out.as_deref() {
                        if let Err(write_error) = write_report(path, &report) {
                            eprintln!("mci-bench: {write_error}");
                            return ExitCode::from(3);
                        }
                    }
                    return ExitCode::from(4);
                }
                Some(embedders)
            }
            Err(error) => {
                let quality_targets = absolute_quality_targets();
                let report = Report {
                    complete: false,
                    publishable: false,
                    launch_qualified: false,
                    dataset: dataset_report_path.clone(),
                    dataset_id: dataset.dataset_id,
                    dataset_checksum_sha256: dataset_checksum_sha256.clone(),
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
                    absolute_quality_targets: quality_targets,
                    quality_gate: RegressionReport {
                        passed: false,
                        failures: vec![error.clone()],
                    },
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
                workdir,
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

    for arm in arms.iter().copied() {
        let started = std::time::Instant::now();
        let mut results = Vec::new();
        let mut arm_failures = 0usize;

        for (n, instance) in dataset.instances.iter().enumerate() {
            match run_instance(instance, arm, &ks, workdir, embedders.as_ref()) {
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
                "    {kind:<28} n={:<4} answerable={:<3} unanswerable={:<3} hit@{kmax}={}  MRR={}",
                typed_summary.instances,
                typed_summary.answerable_instances,
                typed_summary.unanswerable_instances,
                percent(typed_summary.hit_rate_at.get(&kmax).copied().flatten()),
                decimal(typed_summary.mrr),
            );
            by_type.entry(kind).or_default().push(typed_summary);
        }

        let tag_summaries = summarize_by_tag(&results, arm, &ks);
        if !tag_summaries.is_empty() {
            println!("  by tag:");
            for (tag, tag_summary) in tag_summaries {
                let kmax = *ks.last().expect("ks non-empty");
                println!(
                    "    {tag:<28} n={:<4} answerable={:<3} unanswerable={:<3} hit@{kmax}={}  MRR={}",
                    tag_summary.instances,
                    tag_summary.answerable_instances,
                    tag_summary.unanswerable_instances,
                    percent(tag_summary.hit_rate_at.get(&kmax).copied().flatten()),
                    decimal(tag_summary.mrr),
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
                &baseline,
                &dataset.dataset_id,
                &dataset_checksum_sha256,
                &metadata,
            )),
            Err(error) => Some(RegressionReport {
                passed: false,
                failures: vec![error],
            }),
        },
        None => None,
    };
    let regression_failed = regression.as_ref().is_some_and(|r| !r.passed);
    let complete = failures.is_empty() && !limited;
    let canonical_scope = canonical_work_memory_scope(
        &dataset_report_path,
        &dataset.dataset_id,
        original_instances,
        evaluated_instances,
        &arms,
        &ks,
        limited,
    );
    let publishable = complete
        && canonical_scope
        && !metadata.git_dirty_at_start
        && metadata.model_checksum_sha256.is_some();
    let absolute_quality_targets = absolute_quality_targets();
    let quality_gate = evaluate_quality_gate(&overall, &absolute_quality_targets);
    let launch_qualified = publishable && quality_gate.passed;

    let report = Report {
        complete,
        publishable,
        launch_qualified,
        dataset: dataset_report_path,
        dataset_id: dataset.dataset_id,
        dataset_checksum_sha256,
        dataset_description: dataset.description,
        overall,
        by_type,
        by_tag,
        results: all_results,
        failures,
        regression_thresholds,
        absolute_quality_targets,
        quality_gate,
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

    if !complete {
        if allow_smoke && limited && report.failures.is_empty() && !regression_failed {
            ExitCode::SUCCESS
        } else {
            ExitCode::from(5)
        }
    } else if regression_failed {
        ExitCode::from(6)
    } else if canonical_scope && !report.quality_gate.passed {
        ExitCode::from(7)
    } else {
        ExitCode::SUCCESS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_publication_scope_requires_path_identity_and_24_cases() {
        let arms = [Arm::Lexical, Arm::Hybrid];
        let ks = [1, 3, 5, 10];
        assert!(canonical_work_memory_scope(
            "eval/work-memory/synthetic-v1.json",
            "synthetic-work-memory-v1",
            24,
            24,
            &arms,
            &ks,
            false,
        ));

        for (label, path, dataset_id, original, evaluated, limited) in [
            (
                "external path",
                "external-dataset://synthetic-v1.json",
                "synthetic-work-memory-v1",
                24,
                24,
                false,
            ),
            (
                "unrelated id",
                "eval/work-memory/synthetic-v1.json",
                "not-the-work-memory-corpus",
                24,
                24,
                false,
            ),
            (
                "empty original corpus",
                "eval/work-memory/synthetic-v1.json",
                "synthetic-work-memory-v1",
                0,
                0,
                false,
            ),
            (
                "partial evaluation",
                "eval/work-memory/synthetic-v1.json",
                "synthetic-work-memory-v1",
                24,
                23,
                true,
            ),
        ] {
            assert!(
                !canonical_work_memory_scope(
                    path, dataset_id, original, evaluated, &arms, &ks, limited,
                ),
                "{label} must not be publishable"
            );
        }
        assert!(
            !canonical_work_memory_scope(
                "eval/work-memory/synthetic-v1.json",
                "synthetic-work-memory-v1",
                24,
                24,
                &[Arm::Lexical],
                &ks,
                false,
            ),
            "single-arm reports are not canonical"
        );
        assert!(
            !canonical_work_memory_scope(
                "eval/work-memory/synthetic-v1.json",
                "synthetic-work-memory-v1",
                24,
                24,
                &arms,
                &[1, 3, 5],
                false,
            ),
            "noncanonical cutoffs are not publishable"
        );
    }

    #[test]
    fn logical_paths_redact_external_model_and_user_paths() {
        let root = Path::new("/checkout/hippocampus");
        assert_eq!(
            logical_path(
                Path::new("/Users/alice/Models/ArcticEmbedS_INT8.mlmodelc"),
                root,
                "model"
            ),
            "external-model://ArcticEmbedS_INT8.mlmodelc"
        );
        assert_eq!(
            logical_path(
                Path::new(
                    "/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc"
                ),
                root,
                "model"
            ),
            "installed-model://ArcticEmbedS_INT8.mlmodelc"
        );
        assert_eq!(
            logical_path(Path::new("/Users/alice/tmp/report.json"), root, "report"),
            "external-report://report.json"
        );
    }
}
