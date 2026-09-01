//! `mci-bench` — run the LongMemEval retrieval benchmark against the real
//! brain and print numbers that can be published without hedging.
//!
//! Deliberately a separate binary. The benchmark pulls in the dataset
//! parser and is run by maintainers, not users, so it has no business
//! adding weight to `mci-agent`.

use std::path::PathBuf;
use std::process::ExitCode;

use mci_agent::bench_longmemeval::{
    best_threshold, run_abstention_probe, run_instance, summarize, AbstentionSample, Arm, Instance,
    InstanceResult, Report,
};

fn usage() {
    println!(
        "mci-bench {}\n\
         \n\
         Usage: mci-bench --dataset <longmemeval_s_cleaned.json> [OPTIONS]\n\
         \n\
         Options:\n\
         \x20 --dataset PATH   LongMemEval-S JSON (required)\n\
         \x20 --limit N        only the first N instances (default: all)\n\
         \x20 --arm ARM        lexical | hybrid | both (default: both)\n\
         \x20 --k LIST         cutoffs, comma-separated (default: 1,3,5,10)\n\
         \x20 --out PATH       write the full JSON report here\n\
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

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().collect();
    let mut dataset: Option<PathBuf> = None;
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
                dataset = Some(PathBuf::from(&argv[i + 1]));
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

    let Some(dataset) = dataset else {
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

    eprint!("mci-bench: loading {} ... ", dataset.display());
    let raw = match std::fs::read_to_string(&dataset) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("\nmci-bench: read {}: {e}", dataset.display());
            return ExitCode::from(3);
        }
    };
    let mut instances: Vec<Instance> = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("\nmci-bench: parse {}: {e}", dataset.display());
            return ExitCode::from(3);
        }
    };
    drop(raw);
    if let Some(n) = limit {
        instances.truncate(n);
    }
    eprintln!("{} instances", instances.len());

    if let Some(n) = abstention {
        let n = n.min(instances.len());
        if n < 2 {
            eprintln!("mci-bench: --abstention needs at least 2 instances to cross-pair");
            return ExitCode::from(2);
        }
        let started = std::time::Instant::now();
        let mut samples: Vec<AbstentionSample> = Vec::new();
        for idx in 0..n {
            // Pair with the next instance's question, wrapping. Its haystack
            // is a different person's history, so it is unanswerable here.
            let foreign = instances[(idx + 1) % n].question.clone();
            match run_abstention_probe(&instances[idx], &foreign, &workdir) {
                Ok(mut s) => samples.append(&mut s),
                Err(e) => eprintln!("mci-bench: [abstention] {e}"),
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

        let ans: Vec<f32> = samples
            .iter()
            .filter(|s| s.answerable)
            .map(|s| s.top_cosine)
            .collect();
        let una: Vec<f32> = samples
            .iter()
            .filter(|s| !s.answerable)
            .map(|s| s.top_cosine)
            .collect();
        let stat = |v: &[f32]| -> (f32, f32, f32) {
            if v.is_empty() {
                return (0.0, 0.0, 0.0);
            }
            let mut s = v.to_vec();
            s.sort_by(|a, b| a.partial_cmp(b).expect("no NaN"));
            (s[0], s[s.len() / 2], s[s.len() - 1])
        };
        let (amin, amed, amax) = stat(&ans);
        let (umin, umed, umax) = stat(&una);
        println!(
            "\n=== abstention probe ===  ({} pairs, {:.0}s)",
            ans.len(),
            started.elapsed().as_secs_f64()
        );
        println!("  top raw cosine        min     median     max");
        println!(
            "    answerable      {amin:>7.4}  {amed:>9.4}  {amax:>7.4}   n={}",
            ans.len()
        );
        println!(
            "    unanswerable    {umin:>7.4}  {umed:>9.4}  {umax:>7.4}   n={}",
            una.len()
        );

        match best_threshold(&samples) {
            Some(t) => {
                println!("\n  best cosine floor: {:.4}", t.threshold);
                println!(
                    "    answers kept on answerable questions   {:>6.1}%",
                    100.0 * t.answerable_kept
                );
                println!(
                    "    answers kept on unanswerable questions {:>6.1}%   (want low)",
                    100.0 * t.unanswerable_kept
                );
                println!(
                    "    separation (Youden J)                  {:>6.3}",
                    t.youden_j
                );
                if t.youden_j < 0.5 {
                    println!("\n  NOT separable enough to ship a floor on this signal alone.");
                }
            }
            None => println!("  no samples"),
        }
        return ExitCode::SUCCESS;
    }

    let mut overall = Vec::new();
    let mut by_type: std::collections::BTreeMap<String, Vec<_>> = std::collections::BTreeMap::new();
    let mut all_results: Vec<InstanceResult> = Vec::new();

    for arm in arms {
        let started = std::time::Instant::now();
        let mut results: Vec<InstanceResult> = Vec::new();
        let mut failures = 0usize;

        for (n, inst) in instances.iter().enumerate() {
            match run_instance(inst, arm, &ks, &workdir) {
                Ok(r) => results.push(r),
                Err(e) => {
                    failures += 1;
                    eprintln!("mci-bench: [{}] {e}", arm.label());
                }
            }
            if (n + 1) % 10 == 0 || n + 1 == instances.len() {
                let hit = results
                    .iter()
                    .filter(|r| r.first_hit_rank.is_some_and(|k| k <= 5))
                    .count();
                eprintln!(
                    "mci-bench: [{}] {}/{} done, hit@5 so far {:.1}%, {:.0}s elapsed",
                    arm.label(),
                    n + 1,
                    instances.len(),
                    100.0 * hit as f64 / results.len().max(1) as f64,
                    started.elapsed().as_secs_f64()
                );
            }
        }

        if failures > 0 {
            // Never let a partial run masquerade as a complete one.
            eprintln!(
                "mci-bench: [{}] WARNING {failures} instance(s) failed and are excluded",
                arm.label()
            );
        }

        let s = summarize(&results, arm, &ks);
        println!(
            "\n=== {} ===  ({} instances, {:.0}s)",
            s.arm,
            s.instances,
            started.elapsed().as_secs_f64()
        );
        for &k in &ks {
            println!(
                "  hit@{k:<3} {:>6.1}%      recall@{k:<3} {:>6.1}%",
                100.0 * s.hit_rate_at[&k],
                100.0 * s.recall_at[&k]
            );
        }
        println!(
            "  MRR      {:>6.3}       complete misses {}",
            s.mrr, s.complete_misses
        );

        let mut types: std::collections::BTreeMap<String, Vec<InstanceResult>> =
            std::collections::BTreeMap::new();
        for r in &results {
            types
                .entry(r.question_type.clone())
                .or_default()
                .push(r.clone());
        }
        println!("  by question type:");
        for (t, rs) in &types {
            let ts = summarize(rs, arm, &ks);
            let kmax = *ks.last().expect("ks non-empty");
            println!(
                "    {t:<28} n={:<4} hit@{kmax}={:>5.1}%  MRR={:.3}",
                ts.instances,
                100.0 * ts.hit_rate_at[&kmax],
                ts.mrr
            );
            by_type.entry(t.clone()).or_default().push(ts);
        }

        overall.push(s);
        all_results.extend(results);
    }

    if let Some(path) = out {
        let report = Report {
            dataset: dataset.display().to_string(),
            overall,
            by_type,
            results: all_results,
        };
        match serde_json::to_string_pretty(&report) {
            Ok(j) => {
                if let Err(e) = std::fs::write(&path, j) {
                    eprintln!("mci-bench: write {}: {e}", path.display());
                    return ExitCode::from(3);
                }
                eprintln!("mci-bench: report written to {}", path.display());
            }
            Err(e) => {
                eprintln!("mci-bench: serialize report: {e}");
                return ExitCode::from(3);
            }
        }
    }

    ExitCode::SUCCESS
}
