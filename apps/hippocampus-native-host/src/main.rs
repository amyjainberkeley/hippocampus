//! Native messaging host for the Hippocampus browser extension.
//!
//! The browser spawns this binary and communicates via stdin/stdout
//! using the Chrome native messaging protocol:
//!   - stdin:  4-byte LE length prefix + JSON
//!   - stdout: 4-byte LE length prefix + JSON (for acks)
//!
//! On receipt of a page content message the host:
//!   1. Validates the JSON schema.
//!   2. Checks the URL against the denylist.
//!   3. Runs the §6 secret-pattern filter on the full text.
//!   4. If allowed: encodes a `PageContentEvent` wire frame and writes
//!      it to the MCI agent's page-content UNIX socket.
//!   5. If blocked: drops silently (the content never reaches the brain).
//!
//! CSO INVARIANTS:
//! - Denylist applies at the native messaging boundary (before wire).
//! - Secret-pattern filter runs before any content reaches the socket.
//! - No local cache of page content — strictly forward-and-forget.
//! - Cap at 200 KB; truncated at sentence boundary.

mod secret_filter;

use mci_core::ipc::{wire, Message, MAX_PAGE_CONTENT_TEXT_BYTES};
use serde::Deserialize;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQ: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Deserialize)]
struct BrowserMessage {
    url: String,
    title: String,
    text: String,
    ts_us: u64,
    #[serde(default)]
    tab_id: u32,
    #[serde(default = "default_browser")]
    source_browser: String,
}

fn default_browser() -> String {
    "chrome".to_string()
}

fn socket_path() -> PathBuf {
    let support = dirs_path();
    support.join("page_content.sock")
}

fn dirs_path() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("MCI")
    } else {
        PathBuf::from("/tmp/mci")
    }
}

fn read_native_message(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match reader.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_le_bytes(len_buf) as usize;
    if len > 1 << 22 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "native message too large",
        ));
    }
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    Ok(Some(buf))
}

fn write_native_message(writer: &mut impl Write, msg: &[u8]) -> io::Result<()> {
    let len = (msg.len() as u32).to_le_bytes();
    writer.write_all(&len)?;
    writer.write_all(msg)?;
    writer.flush()
}

fn truncate_at_sentence_boundary(text: &str, max_bytes: usize) -> &str {
    if text.len() <= max_bytes {
        return text;
    }
    let slice = &text[..max_bytes];
    if let Some(pos) = slice.rfind(". ") {
        &text[..pos + 1]
    } else if let Some(pos) = slice.rfind('\n') {
        &text[..pos]
    } else {
        slice
    }
}

fn is_denied_url(url: &str) -> bool {
    let lower = url.to_lowercase();
    lower.contains("password")
        || lower.contains("signin")
        || lower.contains("sign-in")
        || lower.contains("login")
        || lower.starts_with("chrome:")
        || lower.starts_with("chrome-extension:")
        || lower.starts_with("about:")
        || lower.starts_with("data:")
        || lower.starts_with("file:")
}

fn process_message(msg: &BrowserMessage, socket: &mut UnixStream) -> io::Result<()> {
    if is_denied_url(&msg.url) {
        return Ok(());
    }

    if secret_filter::contains_secret(&msg.text) {
        return Ok(());
    }

    let text = truncate_at_sentence_boundary(
        &msg.text,
        MAX_PAGE_CONTENT_TEXT_BYTES as usize,
    );

    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let wire_msg = Message::PageContentEvent {
        seq,
        ts_us: msg.ts_us,
        url: msg.url.clone(),
        title: msg.title.clone(),
        full_text: text.to_string(),
        source_browser: msg.source_browser.clone(),
        tab_id: msg.tab_id,
    };
    let frame = wire::encode(seq, &wire_msg);
    socket.write_all(&frame)?;
    socket.flush()?;
    Ok(())
}

fn main() {
    let sock_path = socket_path();
    let Ok(mut socket) = UnixStream::connect(&sock_path) else {
        let ack = serde_json::json!({"status": "error", "reason": "agent_not_running"});
        let _ = write_native_message(
            &mut io::stdout().lock(),
            ack.to_string().as_bytes(),
        );
        return;
    };

    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();

    while let Some(raw) = read_native_message(&mut stdin).unwrap_or(None) {
        let Ok(msg) = serde_json::from_slice::<BrowserMessage>(&raw) else {
            let ack = serde_json::json!({"status": "error", "reason": "invalid_json"});
            let _ = write_native_message(&mut stdout, ack.to_string().as_bytes());
            continue;
        };

        if process_message(&msg, &mut socket).is_ok() {
            let ack = serde_json::json!({"status": "ok"});
            let _ = write_native_message(&mut stdout, ack.to_string().as_bytes());
        } else {
            let ack = serde_json::json!({"status": "error", "reason": "socket_write"});
            let _ = write_native_message(&mut stdout, ack.to_string().as_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_native_message_roundtrip() {
        let payload = b"{\"test\":true}";
        let mut buf = Vec::new();
        buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        buf.extend_from_slice(payload);

        let result = read_native_message(&mut &buf[..]).unwrap().unwrap();
        assert_eq!(result, payload);
    }

    #[test]
    fn read_native_message_eof() {
        let empty: &[u8] = &[];
        let result = read_native_message(&mut &*empty).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn truncate_at_sentence_boundary_respects_limit() {
        let text = "First sentence. Second sentence. Third sentence.";
        let result = truncate_at_sentence_boundary(text, 30);
        assert_eq!(result, "First sentence.");
    }

    #[test]
    fn truncate_at_sentence_boundary_no_sentence() {
        let text = "no sentence boundary here at all";
        let result = truncate_at_sentence_boundary(text, 15);
        assert_eq!(result, "no sentence bou");
    }

    #[test]
    fn truncate_at_sentence_boundary_under_limit() {
        let text = "short";
        let result = truncate_at_sentence_boundary(text, 1000);
        assert_eq!(result, "short");
    }

    #[test]
    fn is_denied_url_blocks_sensitive() {
        assert!(is_denied_url("https://example.com/login"));
        assert!(is_denied_url("https://accounts.google.com/signin"));
        assert!(is_denied_url("chrome://settings"));
        assert!(is_denied_url("about:blank"));
    }

    #[test]
    fn is_denied_url_allows_normal() {
        assert!(!is_denied_url("https://example.com/pricing"));
        assert!(!is_denied_url("https://docs.rust-lang.org/book/"));
    }

    #[test]
    fn browser_message_deserializes() {
        let json = r#"{
            "url": "https://example.com",
            "title": "Example",
            "text": "Hello",
            "ts_us": 1000000,
            "tab_id": 5,
            "source_browser": "safari"
        }"#;
        let msg: BrowserMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg.url, "https://example.com");
        assert_eq!(msg.source_browser, "safari");
        assert_eq!(msg.tab_id, 5);
    }

    #[test]
    fn browser_message_defaults() {
        let json = r#"{
            "url": "https://example.com",
            "title": "Ex",
            "text": "hi",
            "ts_us": 0
        }"#;
        let msg: BrowserMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg.source_browser, "chrome");
        assert_eq!(msg.tab_id, 0);
    }
}
