//! Crash-report receiver — POST `/v1/crash-report`.
//!
//! Accepts the four-field `PanicRecord` schema from the agent's
//! `panic_hook.rs`, validates the body, and appends to a size-rotated
//! JSONL file at `<MCI_SERVER_LOG_DIR>/crash-reports.jsonl`.
//!
//! **WARNING — noted in PR body:** this endpoint has **NO
//! authentication** in the initial skeleton. Production deployment
//! needs auth or rate-limiting; open-internet exposure is a risk.
//! This is a P5 follow-up.
//!
//! Rotation: 10 MB ceiling, 5 retained archives (`.1` … `.5`).

use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::Router;
use serde::Deserialize;
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;

/// The four-field crash-report schema. Must match the agent's
/// `panic_hook::PanicRecord`.
#[derive(Debug, Clone, Deserialize, serde::Serialize)]
pub struct CrashReport {
    /// Epoch-seconds.millis timestamp.
    pub ts: String,
    /// Thread name.
    pub thread: String,
    /// `file:line:col` location.
    pub location: String,
    /// Panic message (already truncated + scrubbed by the uploader).
    pub message: String,
}

/// Configuration for the crash-report JSONL sink.
pub struct CrashReportLogConfig {
    /// Path to the active JSONL file.
    pub path: PathBuf,
    /// Rotation ceiling in bytes.
    pub max_bytes: u64,
    /// Number of rotated archives to retain.
    pub max_rotations: u32,
}

impl CrashReportLogConfig {
    /// Build config from `MCI_SERVER_LOG_DIR` env var (default
    /// `/tmp/mci-server`).
    pub fn from_env() -> Self {
        let dir =
            std::env::var("MCI_SERVER_LOG_DIR").unwrap_or_else(|_| "/tmp/mci-server".to_string());
        Self {
            path: PathBuf::from(dir).join("crash-reports.jsonl"),
            max_bytes: 10 * 1024 * 1024,
            max_rotations: 5,
        }
    }
}

/// Crash-report JSONL writer with size-based rotation.
pub struct CrashReportLog {
    cfg: CrashReportLogConfig,
    lock: Mutex<()>,
}

impl CrashReportLog {
    /// Construct. No I/O until first `append`.
    pub fn new(cfg: CrashReportLogConfig) -> Self {
        Self {
            cfg,
            lock: Mutex::new(()),
        }
    }

    /// Append one report. Creates parent dir + file on first call.
    /// Rotates when the file exceeds `max_bytes`.
    pub async fn append(&self, report: &CrashReport) -> Result<(), std::io::Error> {
        let _guard = self.lock.lock().await;

        if let Some(parent) = self.cfg.path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let mut file = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.cfg.path)
            .await?;

        let line = serde_json::to_string(report).unwrap_or_default();
        file.write_all(line.as_bytes()).await?;
        file.write_all(b"\n").await?;
        file.flush().await?;
        file.sync_all().await?;
        drop(file);

        let metadata = tokio::fs::metadata(&self.cfg.path).await?;
        if metadata.len() > self.cfg.max_bytes {
            self.rotate().await?;
        }
        Ok(())
    }

    async fn rotate(&self) -> Result<(), std::io::Error> {
        let base = &self.cfg.path;
        let max = self.cfg.max_rotations;

        let oldest = rotation_path(base, max);
        let _ = tokio::fs::remove_file(&oldest).await;

        for i in (1..max).rev() {
            let src = rotation_path(base, i);
            let dst = rotation_path(base, i + 1);
            let _ = tokio::fs::rename(&src, &dst).await;
        }

        let archive_1 = rotation_path(base, 1);
        tokio::fs::rename(base, &archive_1).await?;

        let _ = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(base)
            .await?;
        Ok(())
    }
}

fn rotation_path(base: &std::path::Path, n: u32) -> PathBuf {
    let mut s = base.as_os_str().to_os_string();
    s.push(format!(".{n}"));
    PathBuf::from(s)
}

/// Build the crash-report sub-router with its own state.
pub fn crash_report_router(state: Arc<CrashReportLog>) -> Router {
    Router::new()
        .route("/v1/crash-report", post(receive_crash_report))
        .with_state(state)
}

async fn receive_crash_report(State(log): State<Arc<CrashReportLog>>, body: String) -> StatusCode {
    let report: CrashReport = match serde_json::from_str(&body) {
        Ok(r) => r,
        Err(_) => return StatusCode::BAD_REQUEST,
    };
    match log.append(&report).await {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::error!(error = %e, "crash-report write failed");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use axum::body::Body;
    use tower::ServiceExt;

    fn test_config(dir: &std::path::Path) -> CrashReportLogConfig {
        CrashReportLogConfig {
            path: dir.join("crash-reports.jsonl"),
            max_bytes: 10 * 1024 * 1024,
            max_rotations: 5,
        }
    }

    fn valid_body() -> String {
        r#"{"ts":"1.001","thread":"main","location":"src/main.rs:1:1","message":"boom"}"#
            .to_string()
    }

    // ── Handler tests ────────────────────────────────────────────

    #[tokio::test]
    async fn accepts_valid_crash_report() {
        let tmp = tempfile::tempdir().unwrap();
        let log = Arc::new(CrashReportLog::new(test_config(tmp.path())));
        let app = crash_report_router(log);

        let resp = app
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri("/v1/crash-report")
                    .header("content-type", "application/json")
                    .body(Body::from(valid_body()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        let contents = tokio::fs::read_to_string(tmp.path().join("crash-reports.jsonl"))
            .await
            .unwrap();
        assert_eq!(contents.lines().count(), 1);
        assert!(contents.contains("\"ts\":\"1.001\""));
    }

    #[tokio::test]
    async fn rejects_malformed_json() {
        let tmp = tempfile::tempdir().unwrap();
        let log = Arc::new(CrashReportLog::new(test_config(tmp.path())));
        let app = crash_report_router(log);

        let resp = app
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri("/v1/crash-report")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"not":"valid"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn rejects_empty_body() {
        let tmp = tempfile::tempdir().unwrap();
        let log = Arc::new(CrashReportLog::new(test_config(tmp.path())));
        let app = crash_report_router(log);

        let resp = app
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri("/v1/crash-report")
                    .header("content-type", "application/json")
                    .body(Body::from(""))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    // ── Log writer tests ─────────────────────────────────────────

    #[tokio::test]
    async fn append_writes_jsonl() {
        let tmp = tempfile::tempdir().unwrap();
        let log = CrashReportLog::new(test_config(tmp.path()));
        let report = CrashReport {
            ts: "1.001".into(),
            thread: "main".into(),
            location: "src/main.rs:1:1".into(),
            message: "boom".into(),
        };

        log.append(&report).await.unwrap();
        log.append(&report).await.unwrap();

        let contents = tokio::fs::read_to_string(tmp.path().join("crash-reports.jsonl"))
            .await
            .unwrap();
        assert_eq!(contents.lines().count(), 2);
    }

    #[tokio::test]
    async fn rotation_at_size_threshold() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = CrashReportLogConfig {
            path: tmp.path().join("crash-reports.jsonl"),
            max_bytes: 1, // rotate after every write
            max_rotations: 5,
        };
        let log = CrashReportLog::new(cfg);
        let report = CrashReport {
            ts: "1".into(),
            thread: "t".into(),
            location: "l".into(),
            message: "m".into(),
        };

        log.append(&report).await.unwrap();
        log.append(&report).await.unwrap();

        let archive_1 = tmp.path().join("crash-reports.jsonl.1");
        assert!(archive_1.exists(), ".1 archive must exist");

        let active = tokio::fs::read_to_string(tmp.path().join("crash-reports.jsonl"))
            .await
            .unwrap();
        assert_eq!(
            active.lines().count(),
            0,
            "active file empty after rotation"
        );
    }

    #[tokio::test]
    async fn rotation_retains_max_5() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = CrashReportLogConfig {
            path: tmp.path().join("crash-reports.jsonl"),
            max_bytes: 1,
            max_rotations: 5,
        };
        let log = CrashReportLog::new(cfg);
        let report = CrashReport {
            ts: "1".into(),
            thread: "t".into(),
            location: "l".into(),
            message: "m".into(),
        };

        for _ in 0..8 {
            log.append(&report).await.unwrap();
        }

        for i in 1..=5 {
            let archive = rotation_path(&tmp.path().join("crash-reports.jsonl"), i);
            assert!(archive.exists(), ".{i} archive must exist");
        }
        let archive_6 = rotation_path(&tmp.path().join("crash-reports.jsonl"), 6);
        assert!(!archive_6.exists(), ".6 must NOT exist");
    }
}
