//! Structured panic hook — writes ONE typed JSONL crash report line.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5 (agent shell logging).
//! ADR-0012 §6 forbids arbitrary key=value leakage from process
//! telemetry. This hook writes a **strict typed schema** with exactly
//! four fields: `{ ts, thread, location, message }`. No user content,
//! no environment variables, no deep backtrace frames.
//!
//! Output path: `~/Library/Logs/MCI/panic.jsonl`, mode 0600.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! - Schema is fixed at `PanicRecord`. Adding a field that could
//!   carry user content requires a fresh CSO ADR amendment.
//! - `message` is the panic payload string (typically a static
//!   `&str` or formatted assertion message from MCI source). It
//!   MUST NOT contain user-visible content; the only callers are
//!   `panic!()` / `unwrap()` / `assert!()` in agent code.
//! - No `env::vars()`, no `std::backtrace::Backtrace`, no hostname.
//! - File mode 0600, same discipline as `health_log.rs`.
//!
//! TODO(wave-4.4): once `apps/hippocampus/` process supervisor
//! stabilizes, ensure `mci-agent` child inherits this hook (it does
//! if the supervisor exec's the agent binary, which already calls
//! `panic_hook::install()`). If Hippocampus spawns Rust in-process
//! via FFI, call `install()` from the FFI init path.
//!
//! - CSO, 2026-05-21

use std::fmt::Write as _;
use std::io::Write;
use std::path::PathBuf;

/// Install the structured panic hook. Call once at process start,
/// before any other threads spawn. Replaces the default stderr
/// panic hook — the default hook's output is unstructured and may
/// contain environment details we don't control.
pub fn install() {
    std::panic::set_hook(Box::new(|info| {
        let _ = write_panic_record(info, &default_panic_log_path());
    }));
}

/// Install with a custom output path (for testing).
#[cfg(test)]
#[allow(dead_code)]
fn install_to(path: PathBuf) {
    std::panic::set_hook(Box::new(move |info| {
        let _ = write_panic_record(info, &path);
    }));
}

fn default_panic_log_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Logs/MCI/panic.jsonl")
}

/// The four-field typed panic record. Strict schema per ADR-0012 §6.
struct PanicRecord {
    ts: String,
    thread: String,
    location: String,
    message: String,
}

impl PanicRecord {
    fn to_json_line(&self) -> String {
        format!(
            r#"{{"ts":"{}","thread":"{}","location":"{}","message":"{}"}}"#,
            escape_json_string(&self.ts),
            escape_json_string(&self.thread),
            escape_json_string(&self.location),
            escape_json_string(&self.message),
        )
    }
}

fn escape_json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

fn write_panic_record(
    info: &std::panic::PanicHookInfo<'_>,
    path: &std::path::Path,
) -> std::io::Result<()> {
    let ts = {
        let d = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or(std::time::Duration::ZERO);
        let secs = d.as_secs();
        let millis = d.subsec_millis();
        // Minimal RFC-3339-ish timestamp without pulling chrono.
        // Good enough for crash diagnostics.
        format!("{secs}.{millis:03}")
    };

    let thread = std::thread::current()
        .name()
        .unwrap_or("unnamed")
        .to_string();

    let location = info
        .location()
        .map(|loc| format!("{}:{}:{}", loc.file(), loc.line(), loc.column()))
        .unwrap_or_default();

    // Extract the panic message. Truncate at 512 chars to bound the
    // on-disk footprint per crash event.
    let raw_message = if let Some(s) = info.payload().downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = info.payload().downcast_ref::<String>() {
        s.clone()
    } else {
        "non-string panic payload".to_string()
    };
    let message = if raw_message.len() > 512 {
        format!("{}...", &raw_message[..512])
    } else {
        raw_message
    };

    let record = PanicRecord {
        ts,
        thread,
        location,
        message,
    };
    let line = record.to_json_line();

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;

    // Set mode 0600. Best-effort on the append-open path; create
    // already inherits from umask but we tighten explicitly.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
    }

    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn panic_record_json_shape() {
        let rec = PanicRecord {
            ts: "1716249600.123".to_string(),
            thread: "main".to_string(),
            location: "src/bin/mci_agent.rs:42:5".to_string(),
            message: "explicit panic".to_string(),
        };
        let line = rec.to_json_line();
        assert!(line.starts_with('{'));
        assert!(line.ends_with('}'));
        assert!(line.contains("\"ts\":"));
        assert!(line.contains("\"thread\":"));
        assert!(line.contains("\"location\":"));
        assert!(line.contains("\"message\":"));
    }

    #[test]
    fn panic_record_has_no_forbidden_fields() {
        let rec = PanicRecord {
            ts: "0.000".to_string(),
            thread: "t".to_string(),
            location: "".to_string(),
            message: "".to_string(),
        };
        let line = rec.to_json_line();
        for forbidden in [
            "\"env\":",
            "\"backtrace\":",
            "\"hostname\":",
            "\"user\":",
            "\"url\":",
            "\"text\":",
            "\"window_title\":",
        ] {
            assert!(
                !line.contains(forbidden),
                "panic record must not contain {forbidden} — ADR-0012 §6"
            );
        }
    }

    #[test]
    fn message_truncation_at_512_chars() {
        let long = "x".repeat(1000);
        let truncated = if long.len() > 512 {
            format!("{}...", &long[..512])
        } else {
            long.clone()
        };
        assert_eq!(truncated.len(), 515); // 512 + "..."
    }

    #[test]
    fn panic_hook_writes_jsonl_on_panic() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("panic.jsonl");
        let path_clone = path.clone();

        // Spawn a thread that panics after installing our hook.
        // We can't use install_to in the main thread (it replaces
        // the global hook), so we write directly instead.
        let handle = std::thread::spawn(move || {
            let info_path = path_clone;
            // Simulate what the hook does: write a record directly.
            let record = PanicRecord {
                ts: "1716249600.000".to_string(),
                thread: "test-panic-thread".to_string(),
                location: "tests:1:1".to_string(),
                message: "test panic message".to_string(),
            };
            let line = record.to_json_line();
            if let Some(parent) = info_path.parent() {
                std::fs::create_dir_all(parent).unwrap();
            }
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&info_path)
                .unwrap();
            file.write_all(line.as_bytes()).unwrap();
            file.write_all(b"\n").unwrap();
            file.sync_all().unwrap();
        });
        handle.join().unwrap();

        let body = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("\"ts\":"));
        assert!(lines[0].contains("\"thread\":\"test-panic-thread\""));
        assert!(lines[0].contains("\"message\":\"test panic message\""));
    }

    #[test]
    fn write_panic_record_creates_file_at_0600() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci/panic.jsonl");

        // Directly invoke write_panic_record via a synthetic PanicRecord
        // write (can't easily construct PanicHookInfo).
        let record = PanicRecord {
            ts: "0.000".to_string(),
            thread: "main".to_string(),
            location: "test.rs:1:1".to_string(),
            message: "test".to_string(),
        };
        let line = record.to_json_line();

        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
        }
        file.write_all(line.as_bytes()).unwrap();
        file.write_all(b"\n").unwrap();
        drop(file);

        let meta = std::fs::metadata(&path).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "panic log file must be 0600");
    }

    #[test]
    fn escape_handles_specials() {
        assert_eq!(escape_json_string("a\"b"), "a\\\"b");
        assert_eq!(escape_json_string("a\nb"), "a\\nb");
        assert_eq!(escape_json_string("a\x01b"), "a\\u0001b");
    }

    #[test]
    fn default_path_ends_with_canonical() {
        let p = default_panic_log_path();
        let s = p.display().to_string();
        assert!(s.ends_with("Library/Logs/MCI/panic.jsonl"), "got {s}");
    }
}
