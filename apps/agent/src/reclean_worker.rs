//! The re-clean worker: makes every moment's cleaned text and caption in the
//! background ([`mci_brain::reclean`]), the oldest memories included.
//!
//! It runs only when this Mac is on a power cable, not in Low Power Mode, and
//! nobody has touched it for [`WorkerConfig::min_idle`]; those conditions are
//! read again before every request to the model, and a request is given only
//! the time the batch has left. A batch stops at its deadline, and the worker
//! then rests four times as long as the batch took, so it is busy at most a
//! fifth of the time even while it may run. Captions are written by the
//! on-device model through `hippocampus-mind` when it can (Apple
//! Intelligence, or the person's own model server on this Mac); every line is
//! checked against its moment before it is kept. Nothing leaves the Mac.
//!
//! Power and idleness come from `/usr/bin/pmset` and `/usr/sbin/ioreg`, run
//! with an empty environment; their answers are parsed by the pure functions
//! below. An answer that cannot be read counts as "not now".

use std::sync::Arc;
use std::time::{Duration, Instant};

use mci_brain::reclean::{
    run_batch, BatchLimits, BatchStats, CaptionRequest, Captioner, ModelUnavailable,
};
use mci_brain::{ReadingProgress, SqlCipherBrainStore, READING_VERSION};
use serde::Deserialize;
use tokio::sync::watch;

use crate::errln;
use crate::understanding::mind::{MindCallError, MindClient};

/// How the worker paces itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerConfig {
    /// Nobody has touched the Mac for at least this long.
    pub min_idle: Duration,
    /// How often the conditions are looked at while the worker may not run.
    pub check_every: Duration,
    /// The longest one batch runs.
    pub batch_time: Duration,
    /// Moments read and written per batch.
    pub batch_moments: usize,
    /// Moments offered to the model per batch.
    pub batch_captions: usize,
    /// After a batch, rest this many times as long as it took.
    pub rest_factor: u32,
    /// The shortest rest after a batch.
    pub min_rest: Duration,
    /// The rest once every moment is done.
    pub caught_up_rest: Duration,
}

impl Default for WorkerConfig {
    fn default() -> Self {
        Self {
            min_idle: Duration::from_secs(120),
            check_every: Duration::from_secs(60),
            batch_time: Duration::from_secs(20),
            batch_moments: 40,
            batch_captions: 12,
            rest_factor: 4,
            min_rest: Duration::from_secs(15),
            caught_up_rest: Duration::from_secs(600),
        }
    }
}

/// What the worker knows about the Mac right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Conditions {
    /// On a power cable; `None` when that could not be read.
    pub plugged_in: Option<bool>,
    /// Low Power Mode is on.
    pub low_power: bool,
    /// Time since the last key press, click or pointer move; `None` when it
    /// could not be read.
    pub idle: Option<Duration>,
}

/// Whether a batch may run now, or why not.
///
/// # Errors
/// A short reason, for the log.
pub fn may_run(conditions: &Conditions, config: &WorkerConfig) -> Result<(), &'static str> {
    match conditions.plugged_in {
        None => return Err("power source unknown"),
        Some(false) => return Err("on battery"),
        Some(true) => {}
    }
    if conditions.low_power {
        return Err("low power mode");
    }
    match conditions.idle {
        None => Err("idle time unknown"),
        Some(idle) if idle < config.min_idle => Err("in use"),
        Some(_) => Ok(()),
    }
}

/// How long to rest after a batch that took `took`.
#[must_use]
pub fn rest_after(took: Duration, stats: &BatchStats, config: &WorkerConfig) -> Duration {
    if stats.caught_up {
        return config.caught_up_rest;
    }
    let rest = took.saturating_mul(config.rest_factor).max(config.min_rest);
    if stats.model_unavailable.is_some() && stats.read == 0 {
        // Only captions are waiting, and the model is not there now.
        rest.max(config.check_every.saturating_mul(5))
    } else {
        rest
    }
}

/// Whether `pmset -g batt` says the Mac draws from a power cable.
#[must_use]
pub fn parse_power_source(pmset_batt: &str) -> Option<bool> {
    let line = pmset_batt
        .lines()
        .find(|line| line.contains("Now drawing from"))?;
    if line.contains("'AC Power'") {
        Some(true)
    } else if line.contains("'Battery Power'") || line.contains("'UPS Power'") {
        Some(false)
    } else {
        None
    }
}

/// Whether `pmset -g` says Low Power Mode is on.
#[must_use]
pub fn parse_low_power_mode(pmset: &str) -> bool {
    pmset.lines().any(|line| {
        let mut words = line.split_whitespace();
        words.next() == Some("lowpowermode") && words.next() == Some("1")
    })
}

/// The time since the last input, from `ioreg -c IOHIDSystem`'s
/// `"HIDIdleTime" = <nanoseconds>`.
#[must_use]
pub fn parse_idle_time(ioreg: &str) -> Option<Duration> {
    let line = ioreg
        .lines()
        .find(|line| line.contains("\"HIDIdleTime\""))?;
    let value = line.split('=').nth(1)?.trim();
    let digits: String = value.chars().take_while(char::is_ascii_digit).collect();
    digits.parse::<u64>().ok().map(Duration::from_nanos)
}

fn run_tool(path: &str, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new(path)
        .args(args)
        .env_clear()
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Read the conditions from this Mac.
#[must_use]
pub fn read_conditions() -> Conditions {
    Conditions {
        plugged_in: run_tool("/usr/bin/pmset", &["-g", "batt"])
            .as_deref()
            .and_then(parse_power_source),
        low_power: run_tool("/usr/bin/pmset", &["-g"])
            .as_deref()
            .is_some_and(parse_low_power_mode),
        idle: run_tool(
            "/usr/sbin/ioreg",
            &["-c", "IOHIDSystem", "-d", "4", "-r", "-k", "HIDIdleTime"],
        )
        .as_deref()
        .and_then(parse_idle_time),
    }
}

/// The longest one request to the model may take.
pub const CAPTION_CALL_TIMEOUT: Duration = Duration::from_secs(60);

/// Less time than this left in a batch is not worth a request.
pub const MIN_CALL_TIME: Duration = Duration::from_secs(2);

/// Whether a request to the model may start now, or why not.
pub type ConditionCheck = Box<dyn Fn() -> Result<(), &'static str> + Send + Sync>;

/// Captions from `hippocampus-mind`'s `caption` task.
pub struct MindCaptioner {
    mind: Arc<MindClient>,
    check: Option<ConditionCheck>,
}

impl MindCaptioner {
    /// Over a shared mind client: its calls take turns with the
    /// understanding worker's.
    #[must_use]
    pub fn new(mind: Arc<MindClient>) -> Self {
        Self { mind, check: None }
    }

    /// With the conditions read again before each request: when the Mac is
    /// in use or off its power cable again, the request does not start and
    /// the moments wait.
    #[must_use]
    pub fn checking(mut self, check: ConditionCheck) -> Self {
        self.check = Some(check);
        self
    }
}

#[derive(Deserialize)]
struct CaptionReply {
    captions: Vec<CaptionLine>,
}

#[derive(Deserialize)]
struct CaptionLine {
    n: usize,
    caption: String,
}

impl Captioner for MindCaptioner {
    fn label(&self) -> String {
        self.mind.engine_label()
    }

    fn captions(
        &self,
        requests: &[CaptionRequest],
        within: Option<Duration>,
    ) -> Result<Vec<Option<String>>, ModelUnavailable> {
        if let Some(check) = &self.check {
            check().map_err(|reason| ModelUnavailable(reason.to_owned()))?;
        }
        let timeout = within.map_or(CAPTION_CALL_TIMEOUT, |left| left.min(CAPTION_CALL_TIMEOUT));
        if timeout < MIN_CALL_TIME {
            return Err(ModelUnavailable("no time left in this batch".into()));
        }
        let moments: Vec<serde_json::Value> = requests
            .iter()
            .enumerate()
            .map(|(index, request)| {
                serde_json::json!({
                    "n": index + 1, "app": request.app, "title": request.title, "text": request.text,
                })
            })
            .collect();
        let reply = self.mind.call::<_, CaptionReply>(
            "caption",
            &serde_json::json!({ "moments": moments }),
            timeout,
        );
        match reply {
            Ok(reply) => {
                let mut lines = vec![None; requests.len()];
                for line in reply.captions {
                    if let Some(slot) = line.n.checked_sub(1).and_then(|at| lines.get_mut(at)) {
                        if slot.is_none() {
                            *slot = Some(line.caption);
                        }
                    }
                }
                Ok(lines)
            }
            Err(MindCallError::Unavailable(reason)) => Err(ModelUnavailable(reason)),
            Err(MindCallError::Failed(reason)) if reason == "on_battery" => {
                Err(ModelUnavailable(reason))
            }
            // Cut short by the batch's own time, not slow on its own: these
            // moments wait for the next batch.
            Err(MindCallError::Timeout) if timeout < CAPTION_CALL_TIMEOUT => {
                Err(ModelUnavailable("the batch's time ran out".into()))
            }
            // Declined, too long, too slow or failed: these moments keep the
            // captions made from their titles and are not offered again, so
            // one hard moment never holds up the rest.
            Err(_) => Ok(vec![None; requests.len()]),
        }
    }
}

/// Batches between two counts of how far the job has got.
const PROGRESS_EVERY: u32 = 10;

/// What the worker did, for its last log line.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorkerStats {
    /// Batches run.
    pub batches: u64,
    /// Moments given a current reading.
    pub read: u64,
    /// Captions the model wrote that were kept.
    pub captions_by_model: u64,
    /// Batches that failed on the store.
    pub errors: u64,
}

/// One batch, on a blocking thread: the Mac's local days, the conditions
/// read again before each request to the model, and how far the job has got
/// when `count_progress` or the batch caught up.
fn one_batch(
    store: &SqlCipherBrainStore,
    mind: Option<Arc<MindClient>>,
    config: WorkerConfig,
    started: Instant,
    count_progress: bool,
) -> (
    Result<BatchStats, mci_brain::StoreError>,
    Option<ReadingProgress>,
) {
    let limits = BatchLimits {
        moments: config.batch_moments,
        captions: config.batch_captions,
        deadline: Some(started + config.batch_time),
        utc_offset_s: crate::brief_worker::current_tz_offset_secs(),
    };
    let captioner = mind.map(|mind| {
        MindCaptioner::new(mind).checking(Box::new(move || may_run(&read_conditions(), &config)))
    });
    let now_us = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros(),
    )
    .unwrap_or(u64::MAX);
    let batch = run_batch(
        store,
        captioner.as_ref().map(|c| c as &dyn Captioner),
        limits,
        now_us,
    );
    let caught_up = batch.as_ref().is_ok_and(|batch| batch.caught_up);
    let progress = (count_progress || caught_up)
        .then(|| store.moment_reading_progress(READING_VERSION).ok())
        .flatten();
    (batch, progress)
}

/// Run until `shutdown` flips. `mind` is `None` when no model process is
/// installed: captions are then made from titles only.
pub async fn run_reclean_worker(
    store: Arc<SqlCipherBrainStore>,
    mind: Option<Arc<MindClient>>,
    mut shutdown: watch::Receiver<bool>,
    config: WorkerConfig,
) -> WorkerStats {
    let mut stats = WorkerStats::default();
    let mut wait = config.check_every;
    let mut last_reason: Option<&'static str> = None;
    let mut since_progress = 0u32;
    loop {
        tokio::select! {
            () = tokio::time::sleep(wait) => {}
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return stats;
                }
                continue;
            }
        }
        if *shutdown.borrow() {
            return stats;
        }
        let conditions = tokio::task::spawn_blocking(read_conditions)
            .await
            .unwrap_or(Conditions {
                plugged_in: None,
                low_power: false,
                idle: None,
            });
        if let Err(reason) = may_run(&conditions, &config) {
            if last_reason != Some(reason) {
                errln!("mci-agent: re-clean waits: {reason}");
                last_reason = Some(reason);
            }
            wait = config.check_every;
            continue;
        }
        last_reason = None;
        let worker_store = Arc::clone(&store);
        let worker_mind = mind.clone();
        let started = Instant::now();
        // How far the job has got is counted only for the log, now and then:
        // the count reads every moment.
        since_progress += 1;
        let count_progress = since_progress >= PROGRESS_EVERY;
        let outcome = tokio::task::spawn_blocking(move || {
            one_batch(&worker_store, worker_mind, config, started, count_progress)
        })
        .await;
        let took = started.elapsed();
        match outcome {
            Ok((Ok(batch), progress)) => {
                stats.batches += 1;
                stats.read += batch.read as u64;
                stats.captions_by_model += batch.captions_by_model as u64;
                if let Some(progress) = progress {
                    since_progress = 0;
                    errln!(
                        "mci-agent: re-clean: read={} cleaned={} captions_by_model={} not_used={} done={}/{} waiting_for_model={} model={}",
                        batch.read,
                        batch.cleaned,
                        batch.captions_by_model,
                        batch.model_lines_not_used,
                        progress.done,
                        progress.total,
                        progress.awaiting_model,
                        batch.model_unavailable.as_deref().unwrap_or("available"),
                    );
                }
                wait = rest_after(took, &batch, &config);
            }
            Ok((Err(error), _)) => {
                stats.errors += 1;
                errln!("mci-agent: re-clean batch failed: {error}");
                wait = config.check_every.saturating_mul(5);
            }
            Err(_) => {
                stats.errors += 1;
                wait = config.check_every.saturating_mul(5);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    fn config() -> WorkerConfig {
        WorkerConfig::default()
    }

    fn conditions(plugged_in: Option<bool>, low_power: bool, idle_secs: Option<u64>) -> Conditions {
        Conditions {
            plugged_in,
            low_power,
            idle: idle_secs.map(Duration::from_secs),
        }
    }

    #[test]
    fn it_runs_only_plugged_in_idle_and_not_in_low_power_mode() {
        let config = config();
        assert_eq!(
            may_run(&conditions(Some(true), false, Some(300)), &config),
            Ok(())
        );
        assert_eq!(
            may_run(&conditions(Some(false), false, Some(300)), &config),
            Err("on battery")
        );
        assert_eq!(
            may_run(&conditions(None, false, Some(300)), &config),
            Err("power source unknown")
        );
        assert_eq!(
            may_run(&conditions(Some(true), true, Some(300)), &config),
            Err("low power mode")
        );
        assert_eq!(
            may_run(&conditions(Some(true), false, Some(30)), &config),
            Err("in use")
        );
        assert_eq!(
            may_run(&conditions(Some(true), false, None), &config),
            Err("idle time unknown")
        );
    }

    #[test]
    fn it_rests_four_times_as_long_as_a_batch_took() {
        let config = config();
        let busy = BatchStats {
            read: 40,
            ..BatchStats::default()
        };
        assert_eq!(
            rest_after(Duration::from_secs(10), &busy, &config),
            Duration::from_secs(40)
        );
        assert_eq!(
            rest_after(Duration::from_secs(1), &busy, &config),
            config.min_rest
        );
        let done = BatchStats {
            caught_up: true,
            ..BatchStats::default()
        };
        assert_eq!(
            rest_after(Duration::from_secs(1), &done, &config),
            config.caught_up_rest
        );
        let waiting = BatchStats {
            model_unavailable: Some("on_battery".into()),
            ..BatchStats::default()
        };
        assert_eq!(
            rest_after(Duration::from_secs(1), &waiting, &config),
            Duration::from_secs(300)
        );
    }

    #[test]
    fn power_and_idleness_are_read_from_the_tools_answers() {
        assert_eq!(
            parse_power_source(
                "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged;"
            ),
            Some(true)
        );
        assert_eq!(
            parse_power_source(
                "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging;"
            ),
            Some(false)
        );
        assert_eq!(parse_power_source(""), None);
        assert!(parse_low_power_mode(
            "System-wide power settings:\n lowpowermode         1\n"
        ));
        assert!(!parse_low_power_mode(
            " lowpowermode         0\n powernap 1\n"
        ));
        assert!(!parse_low_power_mode(""));
        assert_eq!(
            parse_idle_time("  | |   \"HIDIdleTime\" = 125000000000\n"),
            Some(Duration::from_secs(125))
        );
        assert_eq!(parse_idle_time("nothing here"), None);
    }

    fn fake_mind(dir: &Path, body: &str) -> PathBuf {
        let path = dir.join("fake-mind");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn requests(count: usize) -> Vec<CaptionRequest> {
        (0..count)
            .map(|n| CaptionRequest {
                app: "Chrome".into(),
                title: format!("Page {n}"),
                text: "Text".into(),
            })
            .collect()
    }

    #[test]
    fn the_mind_answers_by_number_and_unknown_numbers_are_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let path = fake_mind(
            dir.path(),
            r#"echo '{"ready":true,"available":true,"engine":"local:test"}'
read line; echo '{"id":1,"ok":true,"output":{"captions":[{"n":2,"caption":"Reading Page 1"},{"n":9,"caption":"x"},{"n":1,"caption":"Reading Page 0"},{"n":1,"caption":"again"}]}}'
read line; sleep 5"#,
        );
        let captioner = MindCaptioner::new(Arc::new(MindClient::new(Some(path))));
        let lines = captioner.captions(&requests(3), None).unwrap();
        assert_eq!(
            lines,
            vec![
                Some("Reading Page 0".into()),
                Some("Reading Page 1".into()),
                None
            ]
        );
        assert_eq!(captioner.label(), "local:test");
    }

    #[test]
    fn without_the_model_or_on_battery_the_moments_wait() {
        let captioner = MindCaptioner::new(Arc::new(MindClient::new(None)));
        assert_eq!(
            captioner.captions(&requests(1), None),
            Err(ModelUnavailable("not_installed".into()))
        );
        let dir = tempfile::tempdir().unwrap();
        let path = fake_mind(
            dir.path(),
            r#"echo '{"ready":true,"available":true}'
read line; echo '{"id":1,"ok":false,"error":"on_battery"}'
read line; echo '{"id":2,"ok":false,"error":"refused"}'
read line; sleep 5"#,
        );
        let captioner = MindCaptioner::new(Arc::new(MindClient::new(Some(path))));
        assert_eq!(
            captioner.captions(&requests(2), None),
            Err(ModelUnavailable("on_battery".into()))
        );
        // A refusal is not a reason to wait: those moments keep their
        // captions made from titles.
        assert_eq!(captioner.captions(&requests(2), None), Ok(vec![None, None]));
    }

    #[tokio::test]
    async fn the_worker_stops_when_asked() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(
            SqlCipherBrainStore::new(
                &dir.path().join("brain.sqlite"),
                &mci_core::crypto::DbKey::from_bytes([3; 32]),
            )
            .unwrap(),
        );
        let (tx, rx) = watch::channel(false);
        let config = WorkerConfig {
            check_every: Duration::from_secs(3_600),
            ..WorkerConfig::default()
        };
        let task = tokio::spawn(run_reclean_worker(store, None, rx, config));
        tx.send(true).unwrap();
        let stats = tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .expect("stops promptly")
            .unwrap();
        assert_eq!(stats, WorkerStats::default());
    }
}
