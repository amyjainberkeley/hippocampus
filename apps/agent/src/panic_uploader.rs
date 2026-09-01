//! Opt-in crash-report uploader — drains `panic.jsonl` to a remote endpoint.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5 (agent shell telemetry).
//! ADR-0012 §6: content-free telemetry only. The uploader enforces
//! this with two privacy gates:
//!
//! 1. **Path scrubbing** — any `/Users/<path>` substring in the
//!    `message` field is replaced with `<redacted-path>` before upload.
//! 2. **Message truncation** — `message` is truncated to 200 chars
//!    before upload (the panic hook already truncates to 512 at write
//!    time; this is a tighter bound for the network boundary).
//!
//! The uploader is **default OFF**. Both environment variables must
//! be set for any upload to occur:
//!
//! - `MCI_CRASH_REPORT_URL` — the HTTP endpoint (e.g. `http://127.0.0.1:3100/v1/crash-report`)
//! - `MCI_CRASH_REPORT_OPTED_IN=1` — explicit user consent gate
//!
//! This is defense-in-depth: even if the URL is accidentally set
//! (e.g. via a config template), no data leaves without the explicit
//! opt-in flag.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! - Schema validation at boundary: only lines that deserialize to
//!   `CrashReport { ts, thread, location, message }` are uploaded.
//!   Malformed lines are dropped with a stderr warning.
//! - The `message` field is the ONLY field that could carry user
//!   content (if a panic interpolated user data). Path scrubbing +
//!   truncation bound the exposure.
//! - No authentication in this skeleton. PR body notes this as a
//!   P5 follow-up risk.
//!
//! — CSO, 2026-05-21

use std::path::Path;

use thiserror::Error;

/// Errors from the upload drain.
#[derive(Debug, Error)]
pub enum UploadError {
    /// File-system I/O.
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    /// URL could not be parsed into host:port + path.
    #[error("invalid crash-report URL (must be http://host:port/path)")]
    InvalidUrl,
    /// The configured host resolves somewhere other than this machine.
    /// Refused: this transport is cleartext HTTP and the payload is a
    /// panic message, so sending it off-box would leak it in the clear.
    #[error("crash-report host `{0}` is not loopback; refusing to send off-box")]
    NonLoopbackHost(String),
    /// The host resolved to no address at all. Treated as a refusal
    /// rather than a retry: an empty resolution cannot be proven local.
    #[error("crash-report host `{0}` resolved to no address")]
    UnresolvableHost(String),
}

/// Opt-in crash-report uploader configuration.
pub struct PanicUploader {
    url: String,
    enabled: bool,
}

impl PanicUploader {
    /// Construct from environment variables. Returns `None` when either
    /// gate is unset — the caller should simply skip the upload pass.
    pub fn from_env() -> Option<Self> {
        let url = std::env::var("MCI_CRASH_REPORT_URL").ok()?;
        if url.is_empty() {
            return None;
        }
        let opted_in = std::env::var("MCI_CRASH_REPORT_OPTED_IN")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !opted_in {
            return None;
        }
        Some(Self { url, enabled: true })
    }

    /// Construct directly (for tests).
    #[cfg(test)]
    pub fn new(url: String, enabled: bool) -> Self {
        Self { url, enabled }
    }
}

/// Read `panic.jsonl` line-by-line, POST each valid entry to the
/// configured URL, and atomically remove successfully uploaded lines.
///
/// Returns the count of successfully uploaded reports.
///
/// Lines that fail schema validation are **dropped** (not uploaded,
/// not retained). Lines that get a non-2xx response are **retained**
/// for the next drain pass.
pub async fn drain_pending(uploader: &PanicUploader, path: &Path) -> Result<usize, UploadError> {
    if !uploader.enabled {
        return Ok(0);
    }

    let contents = match tokio::fs::read_to_string(path).await {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(e.into()),
    };

    if contents.trim().is_empty() {
        return Ok(0);
    }

    let mut uploaded = 0usize;
    let mut retained: Vec<String> = Vec::new();

    for line in contents.lines() {
        if line.trim().is_empty() {
            continue;
        }

        let report: CrashReport = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(_) => {
                eprintln!("mci-agent: panic_uploader: dropping malformed line");
                continue;
            }
        };

        let scrubbed = report.scrubbed();
        let body = match serde_json::to_string(&scrubbed) {
            Ok(b) => b,
            Err(_) => continue,
        };

        match post_json(&uploader.url, &body).await {
            Ok(status) if (200..300).contains(&status) => {
                uploaded += 1;
            }
            _ => {
                retained.push(line.to_string());
            }
        }
    }

    // Atomic update: write remaining to sibling .tmp, rename over original.
    if retained.is_empty() {
        let _ = tokio::fs::remove_file(path).await;
    } else {
        let tmp_path = path.with_extension("jsonl.tmp");
        let content = retained.join("\n") + "\n";
        tokio::fs::write(&tmp_path, content.as_bytes()).await?;
        tokio::fs::rename(&tmp_path, path).await?;
    }

    Ok(uploaded)
}

/// The four-field crash report. Must match `panic_hook::PanicRecord`.
#[derive(Debug, serde::Deserialize, serde::Serialize)]
struct CrashReport {
    ts: String,
    thread: String,
    location: String,
    message: String,
}

impl CrashReport {
    fn scrubbed(&self) -> Self {
        let mut msg = scrub_user_paths(&self.message);

        if msg.len() > 200 {
            msg.truncate(200);
            msg.push_str("...");
        }

        Self {
            ts: self.ts.clone(),
            thread: self.thread.clone(),
            location: self.location.clone(),
            message: msg,
        }
    }
}

/// Replace `/Users/<path-chars>` with `<redacted-path>`. Path ends at
/// whitespace, double-quote, single-quote, or end of string.
fn scrub_user_paths(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut remaining = s;

    while let Some(idx) = remaining.find("/Users/") {
        result.push_str(&remaining[..idx]);
        result.push_str("<redacted-path>");
        let rest = &remaining[idx + 7..];
        match rest.find(|c: char| c.is_whitespace() || c == '"' || c == '\'') {
            Some(end) => remaining = &rest[end..],
            None => {
                remaining = "";
                break;
            }
        }
    }
    result.push_str(remaining);
    result
}

/// Accept a resolution only if **every** address is loopback.
///
/// Split out from `post_json` so the rule can be tested without opening a
/// socket: the interesting cases are a public address (must refuse) and an
/// address elsewhere in `127.0.0.0/8` (must accept), and connecting to the
/// latter would just hang until the OS gives up.
///
/// All-or-nothing is deliberate. A name that resolves to both `127.0.0.1`
/// and a public address is the classic DNS-rebinding shape, and picking the
/// loopback one would let the other be reached on a later resolution.
fn vet_loopback(
    host_port: &str,
    resolved: Vec<std::net::SocketAddr>,
) -> Result<Vec<std::net::SocketAddr>, UploadError> {
    if resolved.is_empty() {
        return Err(UploadError::UnresolvableHost(host_port.to_string()));
    }
    if resolved.iter().any(|a| !a.ip().is_loopback()) {
        return Err(UploadError::NonLoopbackHost(host_port.to_string()));
    }
    Ok(resolved)
}

/// Minimal HTTP/1.1 POST over TCP. No TLS, and therefore **loopback
/// only** — a non-loopback host is refused before any bytes are sent.
/// Returns the HTTP status code.
async fn post_json(url: &str, body: &str) -> Result<u16, UploadError> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;

    let stripped = url.strip_prefix("http://").ok_or(UploadError::InvalidUrl)?;
    let (host_port, path) = stripped
        .split_once('/')
        .map(|(h, p)| (h, format!("/{p}")))
        .unwrap_or((stripped, "/".to_string()));

    // Enforce what the comment above has always claimed. `post_json`
    // speaks cleartext HTTP and its body is a panic message, so a
    // non-loopback host would put user data on the wire unencrypted.
    // Resolution happens here, immediately before connect, and the
    // connection is made to a vetted address rather than to the name —
    // re-resolving between check and connect is how this kind of guard
    // usually gets bypassed.
    let resolved: Vec<std::net::SocketAddr> = tokio::net::lookup_host(host_port).await?.collect();
    let vetted = vet_loopback(host_port, resolved)?;

    let mut stream = TcpStream::connect(&vetted[..]).await?;

    let request = format!(
        "POST {path} HTTP/1.1\r\n\
         Host: {host_port}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {body}",
        body.len()
    );

    stream.write_all(request.as_bytes()).await?;

    let mut response = vec![0u8; 1024];
    let n = stream.read(&mut response).await?;
    let response_str = String::from_utf8_lossy(&response[..n]);
    let status_line = response_str.lines().next().ok_or(UploadError::InvalidUrl)?;
    let status = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse::<u16>().ok())
        .ok_or(UploadError::InvalidUrl)?;

    Ok(status)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Path scrubbing pins ──────────────────────────────────────

    #[test]
    fn scrub_single_path() {
        assert_eq!(scrub_user_paths("/Users/ao/src/main.rs"), "<redacted-path>");
    }

    #[test]
    fn scrub_path_in_context() {
        assert_eq!(
            scrub_user_paths("file at /Users/john/doc.txt is bad"),
            "file at <redacted-path> is bad"
        );
    }

    #[test]
    fn scrub_multiple_paths() {
        assert_eq!(
            scrub_user_paths("a /Users/x/f b /Users/y/g c"),
            "a <redacted-path> b <redacted-path> c"
        );
    }

    #[test]
    fn scrub_no_path() {
        assert_eq!(scrub_user_paths("no user path here"), "no user path here");
    }

    #[test]
    fn scrub_path_at_end() {
        assert_eq!(
            scrub_user_paths("crashed at /Users/ao/proj/mod.rs:42"),
            "crashed at <redacted-path>"
        );
    }

    #[test]
    fn scrub_path_in_quotes() {
        assert_eq!(
            scrub_user_paths(r#"path="/Users/ao/secret""#),
            r#"path="<redacted-path>""#
        );
    }

    // ── Message truncation pins ──────────────────────────────────

    #[test]
    fn message_at_200_not_truncated() {
        let report = CrashReport {
            ts: "0.0".into(),
            thread: "main".into(),
            location: "t:1:1".into(),
            message: "x".repeat(200),
        };
        let scrubbed = report.scrubbed();
        assert_eq!(scrubbed.message.len(), 200);
        assert!(!scrubbed.message.ends_with("..."));
    }

    #[test]
    fn message_at_201_truncated() {
        let report = CrashReport {
            ts: "0.0".into(),
            thread: "main".into(),
            location: "t:1:1".into(),
            message: "x".repeat(201),
        };
        let scrubbed = report.scrubbed();
        assert_eq!(scrubbed.message.len(), 203); // 200 + "..."
        assert!(scrubbed.message.ends_with("..."));
    }

    #[test]
    fn scrub_and_truncate_combined() {
        let report = CrashReport {
            ts: "0.0".into(),
            thread: "main".into(),
            location: "t:1:1".into(),
            message: format!(
                "panicked at /Users/ao/secret/module.rs:42: {}",
                "a".repeat(300)
            ),
        };
        let scrubbed = report.scrubbed();
        assert!(!scrubbed.message.contains("/Users/"));
        assert!(scrubbed.message.contains("<redacted-path>"));
        assert!(scrubbed.message.len() <= 203);
    }

    // ── Schema validation ────────────────────────────────────────

    #[test]
    fn valid_line_deserializes() {
        let line =
            r#"{"ts":"1.001","thread":"main","location":"src/main.rs:1:1","message":"boom"}"#;
        let r: CrashReport = serde_json::from_str(line).unwrap();
        assert_eq!(r.ts, "1.001");
        assert_eq!(r.message, "boom");
    }

    #[test]
    fn malformed_line_rejected() {
        let line = r#"{"ts":"1.001","not_a_field":42}"#;
        // `message` is required — missing field → error
        assert!(serde_json::from_str::<CrashReport>(line).is_err());
    }

    #[test]
    fn extra_fields_ignored() {
        let line = r#"{"ts":"1","thread":"t","location":"l","message":"m","extra":"ignored"}"#;
        let r: CrashReport = serde_json::from_str(line).unwrap();
        assert_eq!(r.message, "m");
    }

    // ── Drain integration (mock HTTP server) ─────────────────────

    #[tokio::test]
    async fn drain_nonexistent_file_returns_zero() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("does-not-exist.jsonl");
        let uploader = PanicUploader::new("http://127.0.0.1:1/unused".into(), true);
        let count = drain_pending(&uploader, &path).await.unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn drain_disabled_returns_zero() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("panic.jsonl");
        tokio::fs::write(&path, "not read\n").await.unwrap();
        let uploader = PanicUploader::new("http://127.0.0.1:1/unused".into(), false);
        let count = drain_pending(&uploader, &path).await.unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn drain_uploads_on_2xx_and_removes_file() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let url = format!("http://127.0.0.1:{port}/v1/crash-report");

        let server = tokio::spawn(async move {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut buf = vec![0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                stream.write_all(resp.as_bytes()).await.unwrap();
            }
        });

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("panic.jsonl");
        let line1 =
            r#"{"ts":"1.001","thread":"main","location":"src/main.rs:1:1","message":"boom"}"#;
        let line2 =
            r#"{"ts":"2.002","thread":"tokio","location":"src/lib.rs:2:2","message":"crash"}"#;
        tokio::fs::write(&path, format!("{line1}\n{line2}\n"))
            .await
            .unwrap();

        let uploader = PanicUploader::new(url, true);
        let count = drain_pending(&uploader, &path).await.unwrap();
        assert_eq!(count, 2);
        assert!(!path.exists(), "file should be removed after full drain");

        server.await.unwrap();
    }

    #[tokio::test]
    async fn drain_retains_on_5xx() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let url = format!("http://127.0.0.1:{port}/v1/crash-report");

        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let _ = stream.read(&mut buf).await;
            let resp =
                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            stream.write_all(resp.as_bytes()).await.unwrap();
        });

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("panic.jsonl");
        let line =
            r#"{"ts":"1.001","thread":"main","location":"src/main.rs:1:1","message":"boom"}"#;
        tokio::fs::write(&path, format!("{line}\n")).await.unwrap();

        let uploader = PanicUploader::new(url, true);
        let count = drain_pending(&uploader, &path).await.unwrap();
        assert_eq!(count, 0);

        let contents = tokio::fs::read_to_string(&path).await.unwrap();
        assert_eq!(contents.lines().count(), 1, "line retained on 5xx");

        server.await.unwrap();
    }

    #[tokio::test]
    async fn drain_drops_malformed_lines() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let url = format!("http://127.0.0.1:{port}/v1/crash-report");

        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let _ = stream.read(&mut buf).await;
            let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            stream.write_all(resp.as_bytes()).await.unwrap();
        });

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("panic.jsonl");
        let valid = r#"{"ts":"1.001","thread":"main","location":"src/main.rs:1:1","message":"ok"}"#;
        let malformed = r#"{"garbage": true}"#;
        tokio::fs::write(&path, format!("{malformed}\n{valid}\n"))
            .await
            .unwrap();

        let uploader = PanicUploader::new(url, true);
        let count = drain_pending(&uploader, &path).await.unwrap();
        assert_eq!(count, 1, "only valid line uploaded");
        assert!(
            !path.exists(),
            "file removed: malformed dropped, valid uploaded"
        );

        server.await.unwrap();
    }

    #[tokio::test]
    async fn drain_scrubs_paths_before_upload() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let url = format!("http://127.0.0.1:{port}/v1/crash-report");

        let received = std::sync::Arc::new(tokio::sync::Mutex::new(String::new()));
        let received_clone = received.clone();

        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let n = stream.read(&mut buf).await.unwrap();
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            *received_clone.lock().await = request;
            let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            stream.write_all(resp.as_bytes()).await.unwrap();
        });

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("panic.jsonl");
        let line =
            r#"{"ts":"1","thread":"t","location":"l","message":"err at /Users/ao/secret.rs:42"}"#;
        tokio::fs::write(&path, format!("{line}\n")).await.unwrap();

        let uploader = PanicUploader::new(url, true);
        drain_pending(&uploader, &path).await.unwrap();

        let body = received.lock().await.clone();
        assert!(
            body.contains("<redacted-path>"),
            "uploaded body must contain redacted path"
        );
        assert!(
            !body.contains("/Users/ao"),
            "uploaded body must NOT contain original path"
        );

        server.await.unwrap();
    }

    /// The guard that makes "nothing leaves your machine" true for this
    /// code path rather than merely intended.
    #[test]
    fn vet_loopback_refuses_a_public_address() {
        let addrs = vec!["93.184.216.34:80".parse().unwrap()];
        let err = vet_loopback("example.test:80", addrs).expect_err("must refuse");
        assert!(
            matches!(err, UploadError::NonLoopbackHost(_)),
            "got {err:?}"
        );
    }

    #[test]
    fn vet_loopback_refuses_a_public_ipv6_address() {
        let addrs = vec!["[2606:2800:220:1:248:1893:25c8:1946]:80".parse().unwrap()];
        let err = vet_loopback("example.test:80", addrs).expect_err("must refuse");
        assert!(
            matches!(err, UploadError::NonLoopbackHost(_)),
            "got {err:?}"
        );
    }

    /// A name resolving to both loopback and a public address is the
    /// DNS-rebinding shape. Refuse the whole set, not just the bad entry.
    #[test]
    fn vet_loopback_refuses_a_mixed_resolution() {
        let addrs = vec![
            "127.0.0.1:80".parse().unwrap(),
            "93.184.216.34:80".parse().unwrap(),
        ];
        let err = vet_loopback("split.test:80", addrs).expect_err("must refuse");
        assert!(
            matches!(err, UploadError::NonLoopbackHost(_)),
            "got {err:?}"
        );
    }

    /// `127.0.0.0/8` is loopback in its entirety, not just `127.0.0.1`.
    /// Rejecting the rest would break local reverse-proxy setups.
    #[test]
    fn vet_loopback_accepts_the_whole_v4_range_and_v6() {
        for a in ["127.0.0.1:80", "127.9.9.9:80", "[::1]:80"] {
            let addrs = vec![a.parse().unwrap()];
            assert!(
                vet_loopback("local.test:80", addrs).is_ok(),
                "{a} is loopback and must be accepted"
            );
        }
    }

    #[test]
    fn vet_loopback_refuses_an_empty_resolution() {
        let err = vet_loopback("nowhere.test:80", vec![]).expect_err("must refuse");
        assert!(
            matches!(err, UploadError::UnresolvableHost(_)),
            "got {err:?}"
        );
    }
}
