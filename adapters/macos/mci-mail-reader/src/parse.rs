//! emlx → `ParsedMessage` façade over `mail-parser`.
//!
//! Thin facade so the V2-P8b cascade-equivalent code (parsed-header check
//! per ADR-0030 §3(c)(ii)) gets typed access to From / Reply-To / Sender
//! without re-parsing. V2-P8a callers only see strings.

use std::fs;
use std::path::Path;

use mail_parser::{Address, HeaderName, HeaderValue, MessageParser};

use crate::emlx::split_emlx;
use crate::error::MailReaderError;

/// Parsed RFC 5322 address plus optional display name (the `comment` field
/// in `Envelope Index.addresses`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ParsedAddress {
    /// e.g. `alice@example.com`. Lower-cased per RFC 5322 §3.4.1 local-part
    /// is technically case-sensitive but Mail.app + every IMAP server treats
    /// the address as case-insensitive in practice; the redaction-domain
    /// check is eTLD+1 anyway. We preserve original case here and let the
    /// cascade lower-case at compare-time.
    pub address: String,
    /// e.g. `Alice Example`. Empty when only the bare address was present.
    pub name: String,
}

/// Round-tripped emlx → typed message view.
///
/// Fields hold owned `String`s so callers can drop the source buffer.
#[derive(Debug, Clone, Default)]
pub struct ParsedMessage {
    /// `From:` (RFC 5322 §3.6.2). Plural in the RFC; in practice always
    /// length 1 from Mail.app.
    pub from: Vec<ParsedAddress>,
    /// `Reply-To:` (§3.6.2). Important for V2-P8b §3(c)(ii) phishing-shape
    /// check (Mail-spike §11 Q4).
    pub reply_to: Vec<ParsedAddress>,
    /// `Sender:` (§3.6.2). Same rationale.
    pub sender: Vec<ParsedAddress>,
    /// `To:` (§3.6.3).
    pub to: Vec<ParsedAddress>,
    /// `Cc:` (§3.6.3).
    pub cc: Vec<ParsedAddress>,
    /// `Bcc:` (§3.6.3). Present on Sent Messages.
    pub bcc: Vec<ParsedAddress>,
    /// `Subject:` (§3.6.5). `None` when absent.
    pub subject: Option<String>,
    /// `Message-ID:` (§3.6.4). The cross-device dedup key
    /// (Mail-spike §11 Q7).
    pub message_id: Option<String>,
    /// `In-Reply-To:` (§3.6.4).
    pub in_reply_to: Vec<String>,
    /// `References:` (§3.6.4).
    pub references: Vec<String>,
    /// `Date:` raw string. Caller parses if needed; the Envelope Index
    /// already gives `date_sent`/`date_received` Unix-seconds.
    pub date_raw: Option<String>,
    /// All headers as `(name, raw_value)` pairs, in document order.
    /// Useful for V2-P8b ADR-0030 §3(c)(ii) header-of-interest walks.
    pub headers: Vec<(String, String)>,
    /// Best-effort text/plain body. `None` when the message is HTML-only.
    pub body_text: Option<String>,
    /// Best-effort text/html body. `None` when no HTML part.
    pub body_html: Option<String>,
    /// Bytes of the emlx XML `<plist>` trailer (segment 3). The caller
    /// can decode with the `plist` crate. Kept raw so the splitter stays
    /// pure (no `plist` dep at the type boundary).
    pub plist_trailer: Vec<u8>,
}

/// Read an `.emlx` file from disk and return a [`ParsedMessage`].
pub fn read_message(path: &Path) -> Result<ParsedMessage, MailReaderError> {
    let bytes = fs::read(path).map_err(|e| MailReaderError::from_io(path.to_path_buf(), e))?;
    parse_message_bytes(&bytes, path)
}

/// Parse already-loaded emlx bytes. Exposed for tests + the watcher path
/// where the file content is loaded by the dispatcher.
pub fn parse_message_bytes(bytes: &[u8], path: &Path) -> Result<ParsedMessage, MailReaderError> {
    let parts = split_emlx(bytes, path)?;

    let parser = MessageParser::default();
    let Some(msg) = parser.parse(parts.rfc5322) else {
        return Err(MailReaderError::Rfc5322 {
            path: path.to_path_buf(),
        });
    };

    let mut out = ParsedMessage {
        plist_trailer: parts.plist_trailer.to_vec(),
        ..ParsedMessage::default()
    };

    out.from = address_field(msg.from());
    out.reply_to = address_field(msg.reply_to());
    out.sender = address_field(msg.sender());
    out.to = address_field(msg.to());
    out.cc = address_field(msg.cc());
    out.bcc = address_field(msg.bcc());
    out.subject = msg.subject().map(str::to_string);
    out.message_id = msg.message_id().map(str::to_string);

    out.in_reply_to = header_value_to_text_list(msg.in_reply_to());
    out.references = header_value_to_text_list(msg.references());

    if let Some(HeaderValue::DateTime(dt)) = msg.header(HeaderName::Date) {
        out.date_raw = Some(dt.to_string());
    }

    for header in msg.headers() {
        let name = header.name.as_str().to_string();
        let raw = header_raw_to_string(&header.value);
        if !raw.is_empty() {
            out.headers.push((name, raw));
        }
    }

    out.body_text = msg.body_text(0).map(|s| s.to_string());
    out.body_html = msg.body_html(0).map(|s| s.to_string());

    Ok(out)
}

fn address_field(value: Option<&Address<'_>>) -> Vec<ParsedAddress> {
    let Some(value) = value else {
        return Vec::new();
    };
    let mut out = Vec::new();
    // `Address::iter()` flattens both `List(Vec<Addr>)` and
    // `Group(Vec<Group>)` shapes to a uniform `&Addr` iterator.
    for a in value.iter() {
        push_addr(&mut out, a);
    }
    out
}

fn push_addr(out: &mut Vec<ParsedAddress>, a: &mail_parser::Addr<'_>) {
    let Some(addr) = a.address() else { return };
    if addr.is_empty() {
        return;
    }
    out.push(ParsedAddress {
        address: addr.to_string(),
        name: a.name().unwrap_or_default().to_string(),
    });
}

fn header_value_to_text_list(v: &HeaderValue<'_>) -> Vec<String> {
    match v {
        HeaderValue::Text(s) => vec![s.to_string()],
        HeaderValue::TextList(list) => list.iter().map(std::string::ToString::to_string).collect(),
        _ => Vec::new(),
    }
}

fn header_raw_to_string(value: &HeaderValue<'_>) -> String {
    match value {
        HeaderValue::Text(s) => s.to_string(),
        HeaderValue::TextList(v) => v
            .iter()
            .map(std::convert::AsRef::as_ref)
            .collect::<Vec<_>>()
            .join(", "),
        HeaderValue::Address(addr) => format_address(addr),
        HeaderValue::DateTime(dt) => dt.to_string(),
        HeaderValue::Received(_) | HeaderValue::ContentType(_) | HeaderValue::Empty => {
            String::new()
        }
    }
}

fn format_address(address: &Address<'_>) -> String {
    let mut acc = Vec::new();
    for a in address.iter() {
        if let Some(addr) = a.address() {
            acc.push(format_pair(a.name().unwrap_or_default(), addr));
        }
    }
    acc.join(", ")
}

fn format_pair(name: &str, addr: &str) -> String {
    if name.is_empty() {
        format!("<{addr}>")
    } else {
        format!("{name} <{addr}>")
    }
}

/// Convenience accessor for the eTLD+1-ish domain of a [`ParsedAddress`].
/// Returns everything after the last `@`, lower-cased; bare-address with
/// no `@` returns `None`. The cascade in V2-P8b will replace this with a
/// real eTLD+1 lookup (publicsuffix list).
#[must_use]
pub fn address_domain(a: &ParsedAddress) -> Option<String> {
    let (_, domain) = a.address.split_once('@')?;
    Some(domain.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fake() -> PathBuf {
        PathBuf::from("/tmp/synthetic-fixture-0.emlx")
    }

    fn build_emlx(body: &[u8], trailer: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(11 + body.len() + trailer.len());
        let s = format!("{}", body.len());
        let mut prefix = [b' '; 10];
        prefix[..s.len()].copy_from_slice(s.as_bytes());
        out.extend_from_slice(&prefix);
        out.push(b'\n');
        out.extend_from_slice(body);
        out.extend_from_slice(trailer);
        out
    }

    #[test]
    fn parses_typed_headers_and_body() {
        let body = b"From: \"Alice Example\" <alice@example.com>\r\n\
                     Reply-To: replies@example.com\r\n\
                     To: Bob <bob@example.com>, carol@example.com\r\n\
                     Cc: ops@example.com\r\n\
                     Subject: synthesized fixture\r\n\
                     Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
                     Message-ID: <fixture-1@example.invalid>\r\n\
                     In-Reply-To: <fixture-0@example.invalid>\r\n\
                     References: <fixture-0@example.invalid>\r\n\
                     Mime-Version: 1.0\r\n\
                     Content-Type: text/plain; charset=us-ascii\r\n\
                     \r\nhello body.\r\n";
        let trailer = b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
                        <plist version=\"1.0\"><dict><key>flags</key><integer>1</integer></dict></plist>\n";
        let buf = build_emlx(body, trailer);
        let m = parse_message_bytes(&buf, &fake()).expect("parse ok");

        assert_eq!(m.from.len(), 1);
        assert_eq!(m.from[0].address, "alice@example.com");
        assert_eq!(m.from[0].name, "Alice Example");

        assert_eq!(m.reply_to.len(), 1);
        assert_eq!(m.reply_to[0].address, "replies@example.com");

        assert_eq!(m.to.len(), 2);
        assert_eq!(m.to[0].address, "bob@example.com");
        assert_eq!(m.to[1].address, "carol@example.com");

        assert_eq!(m.cc.len(), 1);
        assert_eq!(m.cc[0].address, "ops@example.com");

        assert_eq!(m.subject.as_deref(), Some("synthesized fixture"));
        assert_eq!(m.message_id.as_deref(), Some("fixture-1@example.invalid"));
        assert_eq!(m.in_reply_to, vec!["fixture-0@example.invalid".to_string()]);
        assert_eq!(m.references, vec!["fixture-0@example.invalid".to_string()]);

        assert!(m
            .headers
            .iter()
            .any(|(n, _)| n.eq_ignore_ascii_case("subject")));
        assert!(m.body_text.as_deref().unwrap().contains("hello body."));
        // mail-parser may surface the same plain body via body_html() too
        // (it materializes a text representation on demand); we do not
        // assert html-emptiness here.
        assert!(!m.plist_trailer.is_empty());
    }

    #[test]
    fn html_only_extracts_html_body() {
        let body = b"From: a@example.com\r\nTo: b@example.com\r\n\
                     Subject: html-only\r\n\
                     Mime-Version: 1.0\r\n\
                     Content-Type: text/html; charset=us-ascii\r\n\
                     \r\n<p>hello</p>\r\n";
        let buf = build_emlx(body, b"");
        let m = parse_message_bytes(&buf, &fake()).unwrap();
        assert!(m.body_html.as_deref().unwrap().contains("<p>hello</p>"));
    }

    #[test]
    fn address_domain_lower_cases() {
        let a = ParsedAddress {
            address: "Sender@Example.COM".into(),
            name: String::new(),
        };
        assert_eq!(address_domain(&a).as_deref(), Some("example.com"));
    }
}
