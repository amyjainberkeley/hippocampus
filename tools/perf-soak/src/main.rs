use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, process, thread};

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const SLO_RSS_KB: u64 = 256_000;
const SLO_CPU_PCT: f64 = 5.0;
const EMBEDDING_DIM: usize = 384;

struct Args {
    writers: usize,
    readers: usize,
    duration_secs: u64,
    sample_interval_secs: u64,
}

impl Args {
    fn from_env() -> Self {
        let mut a = Self {
            writers: 4,
            readers: 2,
            duration_secs: 60,
            sample_interval_secs: 5,
        };
        let argv: Vec<String> = env::args().collect();
        let mut i = 1;
        while i < argv.len() {
            match argv[i].as_str() {
                "--writers" | "-w" => {
                    i += 1;
                    a.writers = argv[i].parse().expect("--writers N");
                }
                "--readers" | "-r" => {
                    i += 1;
                    a.readers = argv[i].parse().expect("--readers N");
                }
                "--duration" | "-d" => {
                    i += 1;
                    a.duration_secs = argv[i].parse().expect("--duration T");
                }
                "--sample-interval" | "-s" => {
                    i += 1;
                    a.sample_interval_secs = argv[i].parse().expect("--sample-interval S");
                }
                "--help" | "-h" => {
                    eprintln!("mci-perf-soak -- sustained-load footprint regression harness");
                    eprintln!();
                    eprintln!("Drives N concurrent put_event + recall queries against a");
                    eprintln!("tempfile SqlCipherBrainStore for T seconds. Samples RSS +");
                    eprintln!("CPU every S seconds. Writes JSONL to stdout. Exits 1 if");
                    eprintln!("any sample exceeds the SLO (250 MB RSS, <5% one core).");
                    eprintln!();
                    eprintln!("Options:");
                    eprintln!("  -w, --writers N           writer threads [4]");
                    eprintln!("  -r, --readers N           reader threads [2]");
                    eprintln!("  -d, --duration T          seconds to run [60]");
                    eprintln!("  -s, --sample-interval S   sample period [5]");
                    process::exit(0);
                }
                other => {
                    eprintln!("unknown arg: {other}");
                    process::exit(2);
                }
            }
            i += 1;
        }
        a
    }
}

fn main() {
    let args = Args::from_env();
    let pid = process::id();
    eprintln!(
        "mci-perf-soak: writers={} readers={} duration={}s sample={}s pid={pid}",
        args.writers, args.readers, args.duration_secs, args.sample_interval_secs,
    );

    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("soak.sqlite");
    let key = DbKey::generate().expect("csprng");
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).expect("open brain store"));

    let stop = Arc::new(AtomicBool::new(false));
    let ops_count = Arc::new(AtomicU64::new(0));
    let error_count = Arc::new(AtomicU64::new(0));

    let mut handles = Vec::new();
    for id in 0..args.writers {
        let s = Arc::clone(&store);
        let st = Arc::clone(&stop);
        let ops = Arc::clone(&ops_count);
        let errs = Arc::clone(&error_count);
        handles.push(thread::spawn(move || writer_loop(id, &s, &st, &ops, &errs)));
    }
    for id in 0..args.readers {
        let s = Arc::clone(&store);
        let st = Arc::clone(&stop);
        let ops = Arc::clone(&ops_count);
        let errs = Arc::clone(&error_count);
        handles.push(thread::spawn(move || reader_loop(id, &s, &st, &ops, &errs)));
    }

    let start = Instant::now();
    let mut max_rss_kb: u64 = 0;
    let mut max_cpu_pct: f64 = 0.0;
    let mut samples: Vec<(u64, f64)> = Vec::new();
    let mut prev_cpu_us = cpu_time_us();
    let mut prev_wall = Instant::now();

    while start.elapsed() < Duration::from_secs(args.duration_secs) {
        thread::sleep(Duration::from_secs(args.sample_interval_secs));

        let now = Instant::now();
        let wall_us = now.duration_since(prev_wall).as_micros();
        let cpu_now = cpu_time_us();
        let cpu_delta = cpu_now.saturating_sub(prev_cpu_us);
        #[allow(clippy::cast_precision_loss)]
        let cpu_pct = if wall_us > 0 {
            (cpu_delta as f64 / wall_us as f64) * 100.0
        } else {
            0.0
        };
        prev_cpu_us = cpu_now;
        prev_wall = now;

        let rss_kb = rss_kb_via_ps(pid);
        let elapsed_s = start.elapsed().as_secs_f64();
        let ops = ops_count.load(Ordering::Relaxed);
        let errs = error_count.load(Ordering::Relaxed);

        max_rss_kb = max_rss_kb.max(rss_kb);
        if cpu_pct > max_cpu_pct {
            max_cpu_pct = cpu_pct;
        }

        println!(
            r#"{{"elapsed_s":{elapsed_s:.1},"rss_kb":{rss_kb},"cpu_pct":{cpu_pct:.2},"ops_total":{ops},"errors_total":{errs}}}"#,
        );
        samples.push((rss_kb, cpu_pct));
    }

    stop.store(true, Ordering::SeqCst);
    for h in handles {
        let _ = h.join();
    }

    let n = samples.len();
    let mut rss_sorted: Vec<u64> = samples.iter().map(|s| s.0).collect();
    let mut cpu_sorted: Vec<f64> = samples.iter().map(|s| s.1).collect();
    rss_sorted.sort_unstable();
    cpu_sorted.sort_unstable_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    let rss_med = pct_u64(&rss_sorted, 50);
    let rss_p95 = pct_u64(&rss_sorted, 95);
    let cpu_med = pct_f64(&cpu_sorted, 50);
    let cpu_p95 = pct_f64(&cpu_sorted, 95);

    eprintln!("--- perf-soak summary ---");
    eprintln!("duration:     {:.0}s", start.elapsed().as_secs_f64());
    eprintln!("samples:      {n}");
    eprintln!("ops_total:    {}", ops_count.load(Ordering::Relaxed));
    eprintln!("errors_total: {}", error_count.load(Ordering::Relaxed));
    eprintln!(
        "rss_kb   median={rss_med:>8}  p95={rss_p95:>8}  max={max_rss_kb:>8}  (budget <= {SLO_RSS_KB})"
    );
    eprintln!(
        "cpu_pct  median={cpu_med:>8.2}  p95={cpu_p95:>8.2}  max={max_cpu_pct:>8.2}  (budget <= {SLO_CPU_PCT}%)"
    );

    let mut fail = false;
    if max_rss_kb > SLO_RSS_KB {
        eprintln!("FAIL: max RSS {max_rss_kb} KB > {SLO_RSS_KB} KB SLO");
        fail = true;
    }
    if cpu_p95 > SLO_CPU_PCT {
        eprintln!("FAIL: p95 CPU {cpu_p95:.2}% > {SLO_CPU_PCT}% SLO");
        fail = true;
    }
    if fail {
        process::exit(1);
    }
    eprintln!("PASS: within SLO");
}

// ---------------------------------------------------------------------------
// Worker loops
// ---------------------------------------------------------------------------

fn writer_loop(
    id: usize,
    store: &SqlCipherBrainStore,
    stop: &AtomicBool,
    ops: &AtomicU64,
    errs: &AtomicU64,
) {
    let mut seq: u64 = 0;
    while !stop.load(Ordering::Relaxed) {
        let ts_us = now_us();
        let embedding = if seq % 3 == 0 {
            Some(pseudo_embedding(id, seq))
        } else {
            None
        };
        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(format!("com.soak.app{id}")),
            window_title: Some(format!("Soak Window {seq}")),
            url: if seq % 2 == 0 {
                Some(format!("https://example.com/{id}/{seq}"))
            } else {
                None
            },
            text: synthetic_text(id, seq),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding,
        };
        match store.put_event(&event) {
            Ok(_) => {
                ops.fetch_add(1, Ordering::Relaxed);
            }
            Err(_) => {
                errs.fetch_add(1, Ordering::Relaxed);
            }
        }
        seq += 1;
        thread::sleep(Duration::from_millis(20));
    }
}

fn reader_loop(
    id: usize,
    store: &SqlCipherBrainStore,
    stop: &AtomicBool,
    ops: &AtomicU64,
    errs: &AtomicU64,
) {
    const QUERIES: &[&str] = &["soak", "document", "workflow", "capture", "memory"];
    let mut seq: usize = 0;
    while !stop.load(Ordering::Relaxed) {
        let ok = if seq % 2 == 0 {
            let q = QUERIES[seq % QUERIES.len()];
            store.fts5_search(q, 10).is_ok()
        } else {
            let qvec = pseudo_embedding(id, seq as u64);
            store.vec_search(&qvec, 10).is_ok()
        };
        if ok {
            ops.fetch_add(1, Ordering::Relaxed);
        } else {
            errs.fetch_add(1, Ordering::Relaxed);
        }
        seq += 1;
        thread::sleep(Duration::from_millis(100));
    }
}

// ---------------------------------------------------------------------------
// Synthetic data
// ---------------------------------------------------------------------------

fn synthetic_text(writer_id: usize, seq: u64) -> String {
    let mut text = format!(
        "[app=com.soak.app{writer_id} | title=Soak Window {seq} | ts={ts}]\n\
         Synthetic document for soak testing the MCI brain store. \
         Writer {writer_id} sequence {seq}. The memory context interface captures \
         workflow context including frontmost app, focused window, active browser \
         tab URL, and page content for recall.",
        ts = seq * 1000,
    );
    let repeats = (seq % 5) as usize + 1;
    for _ in 0..repeats {
        text.push_str(
            " Additional soak payload to exercise the FTS5 indexer and \
             storage layer under sustained write pressure with document \
             text of varying length.",
        );
    }
    text
}

fn pseudo_embedding(seed_a: usize, seed_b: u64) -> Vec<f32> {
    let mut v = vec![0.0_f32; EMBEDDING_DIM];
    let mut s = (seed_a as u64)
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(seed_b);
    for x in &mut v {
        s = s
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        #[allow(clippy::cast_precision_loss)]
        let raw = (s >> 33) as f32 / u32::MAX as f32 - 0.5;
        *x = raw;
    }
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in &mut v {
            *x /= norm;
        }
    }
    v
}

// ---------------------------------------------------------------------------
// Measurement helpers
// ---------------------------------------------------------------------------

fn rss_kb_via_ps(pid: u32) -> u64 {
    Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0)
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

fn now_us() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros()
            .min(u128::from(u64::MAX)),
    )
    .unwrap_or(u64::MAX)
}

fn pct_u64(sorted: &[u64], p: usize) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    sorted[(sorted.len() * p / 100).min(sorted.len() - 1)]
}

fn pct_f64(sorted: &[f64], p: usize) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[(sorted.len() * p / 100).min(sorted.len() - 1)]
}
