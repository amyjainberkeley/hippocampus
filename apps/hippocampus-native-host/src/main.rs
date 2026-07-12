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
//!   With `all_frames: true` (SH Fork E1, ratified 2026-05-31) the
//!   browser delivers one message per frame; the denylist runs on BOTH
//!   the frame URL AND the parent (top-level) URL — if either matches,
//!   the event is dropped. Newer JS sets `frame_url` + `parent_url`;
//!   older JS (top-frame-only) hits the same code path with
//!   `frame_url == parent_url == url`.
//! - Secret-pattern filter runs before any content reaches the socket.
//! - Incognito exclusion: drop any message with `incognito: true` BEFORE
//!   denylist / filter / socket write. Belt-and-suspenders with the JS
//!   guards in `extensions/chromium/content.js` and `background.js` so a
//!   JS regression cannot reach the brain. Per docs/DESIGN.md, incognito
//!   exclusion ships WITH capture, not as a later phase.
//! - No local cache of page content — strictly forward-and-forget.
//! - Cap at 200 KB; truncated at sentence boundary.
//! - The downstream binary wire format (`mci_core::ipc::wire::PageContentEvent`,
//!   discriminant `0x0050`) is UNCHANGED for SH Fork E1. Sub-frame
//!   attribution is encoded by prefixing the sub-frame's `title` with
//!   `[iframe of <parent-url>] ` before the binary write, so the brain
//!   can attribute iframe content without a wire-format bump.

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
    /// Set true by `background.js` when the tab is incognito. Defaults
    /// to false so the host fails-closed only on an explicit positive
    /// signal — a missing field (older JS) is treated as non-incognito,
    /// consistent with how the field was added.
    #[serde(default)]
    incognito: bool,
    /// The frame's own URL. Set by `background.js` from `sender.url`
    /// (Chromium fills this with the frame URL, even cross-origin).
    /// Older JS that pre-dates SH Fork E1 omits this field — we
    /// default to empty and the denylist falls back to `url`.
    #[serde(default)]
    frame_url: String,
    /// The top-level tab URL. Set by `background.js` from
    /// `sender.tab.url`. Equals `frame_url` for the top frame; differs
    /// for cross-origin iframes. Older JS omits this — we default to
    /// empty and the denylist falls back to `url`.
    #[serde(default)]
    parent_url: String,
    /// True for the top-level frame; false for any sub-frame. Defaults
    /// to true so older JS (top-frame-only) is treated as the top
    /// frame — the sub-frame title-prefix decoration arms only on an
    /// explicit `false` from the SH-Fork-E1 background.js.
    #[serde(default = "default_is_top_frame")]
    is_top_frame: bool,
    /// Chromium frame ID. `0` is the top frame; non-zero is a
    /// sub-frame. Defaults to 0 (top frame) for older JS. Round-tripped
    /// for forward-compat telemetry — `is_top_frame` is the authoritative
    /// signal for the title-prefix branch, so the host doesn't need
    /// `frame_id` in the per-frame code path today.
    #[serde(default)]
    #[allow(dead_code)]
    frame_id: u32,
}

fn default_is_top_frame() -> bool {
    true
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

/// Cap on the parent URL embedded in a decorated sub-frame title. The
/// downstream binary wire encodes `title` with a u16 length prefix, so
/// the whole field must fit in 65535 bytes. The parent URL portion is
/// capped low so it can't crowd out the iframe's own title.
const MAX_PARENT_URL_IN_TITLE: usize = 512;

/// Title-prefix decoration for a sub-frame's `title`, so the brain can
/// attribute iframe content to its parent page without a binary-wire
/// schema bump. Format: `[iframe of <parent-url>] <original-title>`.
/// Pure function for ease of testing.
fn decorate_iframe_title(parent_url: &str, original_title: &str) -> String {
    let trimmed = if parent_url.len() > MAX_PARENT_URL_IN_TITLE {
        &parent_url[..MAX_PARENT_URL_IN_TITLE]
    } else {
        parent_url
    };
    format!("[iframe of {trimmed}] {original_title}")
}

fn process_message(msg: &BrowserMessage, socket: &mut UnixStream) -> io::Result<()> {
    // CSO invariant: incognito tabs never reach the wire. Checked here
    // BEFORE denylist / secret filter / socket write so a JS regression
    // (background.js stops forwarding `incognito: true`, content.js
    // stops bailing) still cannot leak content as long as the host is
    // up-to-date. Pair with the JS guards in extensions/chromium/.
    if msg.incognito {
        return Ok(());
    }

    // Per-frame denylist (SH Fork E1). Resolve effective URLs:
    //   - `effective_frame_url`  = the frame's own URL (iframe URL for
    //     sub-frames, page URL for the top frame). Falls back to `url`
    //     when older JS doesn't set `frame_url`.
    //   - `effective_parent_url` = the top-level tab URL. Falls back to
    //     `url` when older JS doesn't set `parent_url`.
    // The denylist runs on BOTH so a Stripe iframe inside a `/login`
    // parent is blocked, and a `/login` iframe inside a benign parent
    // is also blocked. For a single-URL top-frame-only payload these
    // collapse to one check, preserving prior behavior.
    let effective_frame_url = if msg.frame_url.is_empty() {
        msg.url.as_str()
    } else {
        msg.frame_url.as_str()
    };
    let effective_parent_url = if msg.parent_url.is_empty() {
        msg.url.as_str()
    } else {
        msg.parent_url.as_str()
    };
    if is_denied_url(effective_frame_url) || is_denied_url(effective_parent_url) {
        return Ok(());
    }

    if secret_filter::contains_secret(&msg.text) {
        return Ok(());
    }

    let text = truncate_at_sentence_boundary(&msg.text, MAX_PAGE_CONTENT_TEXT_BYTES as usize);

    // The `url` field on the binary wire is the frame's own URL — for
    // top frames this matches today's behavior (page URL); for sub-
    // frames it's the iframe URL so the brain can key on it for
    // denylist/dedupe. Parent attribution rides in the title prefix.
    let wire_url = effective_frame_url.to_string();
    let wire_title = if msg.is_top_frame {
        msg.title.clone()
    } else {
        decorate_iframe_title(effective_parent_url, &msg.title)
    };

    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let wire_msg = Message::PageContentEvent {
        seq,
        ts_us: msg.ts_us,
        url: wire_url,
        title: wire_title,
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
        let _ = write_native_message(&mut io::stdout().lock(), ack.to_string().as_bytes());
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
        // CSO invariant: a missing `incognito` field defaults to false.
        // An older JS client that does not forward the flag must NOT be
        // treated as incognito (would suppress everything). The block
        // arms only on an explicit positive signal.
        assert!(!msg.incognito);
    }

    #[test]
    fn browser_message_parses_incognito_flag() {
        let json = r#"{
            "url": "https://example.com",
            "title": "Ex",
            "text": "hi",
            "ts_us": 0,
            "incognito": true
        }"#;
        let msg: BrowserMessage = serde_json::from_str(json).unwrap();
        assert!(msg.incognito);
    }

    /// Synthetic incoming message with `incognito: true`. `process_message`
    /// must early-return BEFORE attempting to write to the socket. We
    /// pass a closed `UnixStream` pair where the read side is dropped —
    /// any socket write would surface as `io::Error::BrokenPipe`. A
    /// successful `Ok(())` proves no socket write happened, satisfying
    /// the CSO defense-in-depth requirement.
    #[test]
    fn process_message_drops_incognito_before_socket_write() {
        use std::os::unix::net::UnixStream;

        let (mut a, b) = UnixStream::pair().expect("socket pair");
        drop(b); // close the read side — any write would now error.

        let msg = top_frame_msg(
            "https://example.com",
            "Ex",
            "should never reach the wire",
            /*incognito=*/ true,
        );

        let result = process_message(&msg, &mut a);
        assert!(
            result.is_ok(),
            "incognito message must early-return Ok(()) — no socket write attempted"
        );
    }

    /// Sibling test for the non-incognito case: the same broken-pipe
    /// fixture MUST error, proving `process_message` does try the write
    /// when the message is non-incognito. This guards against a bug
    /// where the early-return is too broad and suppresses everything.
    #[test]
    fn process_message_writes_socket_when_not_incognito() {
        use std::os::unix::net::UnixStream;

        let (mut a, b) = UnixStream::pair().expect("socket pair");
        drop(b);

        let msg = top_frame_msg(
            "https://example.com/pricing",
            "Ex",
            "hello world",
            /*incognito=*/ false,
        );

        let result = process_message(&msg, &mut a);
        assert!(
            result.is_err(),
            "non-incognito message must attempt the socket write (broken pipe expected)"
        );
    }

    // ---- SH Fork E1 (all_frames:true) per-frame coverage --------------

    /// Builder for an SH-Fork-E1-era top-frame message. Use this in
    /// tests so adding more fields to BrowserMessage doesn't churn the
    /// suite.
    fn top_frame_msg(url: &str, title: &str, text: &str, incognito: bool) -> BrowserMessage {
        BrowserMessage {
            url: url.into(),
            title: title.into(),
            text: text.into(),
            ts_us: 0,
            tab_id: 0,
            source_browser: "chrome".into(),
            incognito,
            frame_url: url.into(),
            parent_url: url.into(),
            is_top_frame: true,
            frame_id: 0,
        }
    }

    /// Builder for an SH-Fork-E1-era sub-frame message. `frame_url` is
    /// the iframe's own URL; `parent_url` is the top-level tab URL.
    fn sub_frame_msg(parent_url: &str, frame_url: &str, title: &str, text: &str) -> BrowserMessage {
        BrowserMessage {
            // background.js sends `url = parent_url` for sub-frames so
            // the brain's per-page index stays anchored to the page the
            // user is actually looking at. The native host uses
            // `frame_url` for denylist matching + binary-wire `url`.
            url: parent_url.into(),
            title: title.into(),
            text: text.into(),
            ts_us: 0,
            tab_id: 0,
            source_browser: "chrome".into(),
            incognito: false,
            frame_url: frame_url.into(),
            parent_url: parent_url.into(),
            is_top_frame: false,
            frame_id: 1,
        }
    }

    #[test]
    fn browser_message_per_frame_fields_default_to_top_frame() {
        let json = r#"{
            "url": "https://example.com",
            "title": "Ex",
            "text": "hi",
            "ts_us": 0
        }"#;
        let msg: BrowserMessage = serde_json::from_str(json).unwrap();
        // CSO invariant: an older background.js (no per-frame fields)
        // must NOT be treated as a sub-frame — that would prefix every
        // title with "[iframe of ] " and corrupt the brain. Defaults
        // are: is_top_frame=true, frame_id=0, frame_url="", parent_url="".
        assert!(msg.is_top_frame);
        assert_eq!(msg.frame_id, 0);
        assert_eq!(msg.frame_url, "");
        assert_eq!(msg.parent_url, "");
    }

    #[test]
    fn browser_message_per_frame_fields_parse() {
        let json = r#"{
            "url": "https://merchant.example.com/checkout",
            "title": "Card form",
            "text": "$42.00",
            "ts_us": 0,
            "frame_url": "https://js.stripe.com/v3/elements-inner-payment.html",
            "parent_url": "https://merchant.example.com/checkout",
            "is_top_frame": false,
            "frame_id": 3
        }"#;
        let msg: BrowserMessage = serde_json::from_str(json).unwrap();
        assert!(!msg.is_top_frame);
        assert_eq!(msg.frame_id, 3);
        assert_eq!(
            msg.frame_url,
            "https://js.stripe.com/v3/elements-inner-payment.html"
        );
        assert_eq!(msg.parent_url, "https://merchant.example.com/checkout");
    }

    #[test]
    fn decorate_iframe_title_prefix() {
        let decorated = decorate_iframe_title("https://merchant.example.com/checkout", "Card form");
        assert_eq!(
            decorated,
            "[iframe of https://merchant.example.com/checkout] Card form"
        );
    }

    #[test]
    fn decorate_iframe_title_caps_parent_url() {
        let huge = "https://example.com/".to_string() + &"a".repeat(10_000);
        let decorated = decorate_iframe_title(&huge, "T");
        // Prefix structure: "[iframe of " (11) + url (≤512) + "] " (2) + title.
        assert!(decorated.starts_with("[iframe of https://example.com/"));
        assert!(decorated.ends_with("] T"));
        assert!(decorated.len() <= 11 + MAX_PARENT_URL_IN_TITLE + 2 + 1);
    }

    /// SH Fork E1 denylist parity: a sub-frame whose PARENT URL is
    /// denied must drop, even if the iframe URL is benign. Mirrors
    /// "Stripe iframe inside a /login parent page".
    #[test]
    fn process_message_drops_when_parent_url_denied() {
        use std::os::unix::net::UnixStream;

        let (mut a, b) = UnixStream::pair().expect("socket pair");
        drop(b);

        let msg = sub_frame_msg(
            "https://accounts.example.com/login",
            "https://js.stripe.com/v3/elements-inner-payment.html",
            "Card form",
            "$42.00",
        );
        let result = process_message(&msg, &mut a);
        assert!(
            result.is_ok(),
            "sub-frame must drop when parent URL is denied — no socket write attempted"
        );
    }

    /// SH Fork E1 denylist parity: a sub-frame whose FRAME URL is
    /// denied must drop, even if the parent is benign. Mirrors a
    /// `/login`-style iframe embedded in a normal page.
    #[test]
    fn process_message_drops_when_frame_url_denied() {
        use std::os::unix::net::UnixStream;

        let (mut a, b) = UnixStream::pair().expect("socket pair");
        drop(b);

        let msg = sub_frame_msg(
            "https://merchant.example.com/pricing",
            "https://merchant.example.com/login-widget",
            "Sign in",
            "username field",
        );
        let result = process_message(&msg, &mut a);
        assert!(
            result.is_ok(),
            "sub-frame must drop when frame URL is denied — no socket write attempted"
        );
    }

    /// SH Fork E1: secret filter still applies to per-frame text. The
    /// existing top-frame secret-filter test guards the top path; this
    /// test guards the sub-frame path so the secret-filter coverage is
    /// uniform across frame depth.
    #[test]
    fn process_message_drops_subframe_when_secret_in_text() {
        use std::os::unix::net::UnixStream;

        let (mut a, b) = UnixStream::pair().expect("socket pair");
        drop(b);

        // Secret-filter triggers on `password|api_key|token|bearer = …`
        // patterns (see `secret_filter.rs`). The sub-frame fixture is a
        // benign-looking iframe inside a benign parent so the denylist
        // alone won't catch it — only the secret filter does.
        let msg = sub_frame_msg(
            "https://merchant.example.com/dashboard",
            "https://embed.example.com/widget",
            "Embedded widget",
            "Auth header: token=sk-stripe-test-please-suppress",
        );
        let result = process_message(&msg, &mut a);
        assert!(
            result.is_ok(),
            "sub-frame with bearer-token text must be dropped by secret filter"
        );
    }

    /// SH Fork E1: a benign sub-frame must attempt the socket write
    /// (proves the sub-frame code path actually reaches the wire when
    /// nothing in the chain denies it). Pairs with the denylist drop
    /// tests above.
    #[test]
    fn process_message_writes_socket_for_benign_subframe() {
        use std::os::unix::net::UnixStream;

        let (mut a, b) = UnixStream::pair().expect("socket pair");
        drop(b);

        let msg = sub_frame_msg(
            "https://merchant.example.com/product",
            "https://player.vimeo.com/video/12345",
            "Vimeo Player",
            "Product demo. Two-minute walkthrough.",
        );
        let result = process_message(&msg, &mut a);
        assert!(
            result.is_err(),
            "benign sub-frame must attempt the socket write (broken pipe expected)"
        );
    }
}
