//! A second net on the way out: what Hippocampus hands an AI tool or a
//! person's clipboard is scrubbed of secrets even when memory holds one.
//!
//! Nothing with a secret should be in memory: every source passes
//! [`crate::secret_gate`] before it is stored. But a moment stored before a
//! shape was known, or one a check missed, would otherwise go out verbatim.
//! So every exit runs the same checks again and removes what they find:
//!
//! - MCP answers ([`scrub_tool_result`], in `mcp::server`, for every tool);
//! - the context packet (`mcp::live::LiveBrainReader::context`, which the
//!   `context` command and the `mci_context` tool share);
//! - the session-start handoff (`handoff::compile_handoff_with_block`);
//! - send-card, which builds Ask {Tool} and Copy for Your AI, leaves out any
//!   line the checks match (`handoff_card::without_secret_lines`).
//!
//! A secret becomes [`REDACTED`]; an address loses its sign-in parameters
//! first. Clean text is passed through untouched (borrowed, byte for byte).

use std::borrow::Cow;

use mci_brain::redaction::ocr_secrets::redact_secrets;
pub use mci_brain::redaction::ocr_secrets::REDACTED;
use mci_brain::redaction::url_secrets::strip_secret_params;
use mci_brain::Event;
use serde_json::Value;

/// `text` with every secret replaced by [`REDACTED`].
#[must_use]
pub fn scrub_text(text: &str) -> Cow<'_, str> {
    redact_secrets(text)
}

/// An address without its sign-in parameters, then without secrets.
#[must_use]
pub fn scrub_url(url: &str) -> Cow<'_, str> {
    match strip_secret_params(url) {
        Cow::Borrowed(_) => redact_secrets(url),
        Cow::Owned(clean) => Cow::Owned(redact_secrets(&clean).into_owned()),
    }
}

/// Replace `value` with its scrubbed form; true when it changed.
fn scrub_in_place(value: &mut String, address: bool) -> bool {
    let scrubbed = if address {
        scrub_url(value)
    } else {
        scrub_text(value)
    };
    match scrubbed {
        Cow::Borrowed(_) => false,
        Cow::Owned(clean) => {
            *value = clean;
            true
        }
    }
}

/// Scrub an event read for an exit: its title, its address and its text.
///
/// The stored header (`[app=… | title=… | url=… | ts=…]`, and an MCP
/// resource's revision line before it) is never scanned as a whole: its
/// timestamp, session id and line number are digits a one-time-code keyword
/// in a title could reach, and readers parse it. Only the title and address
/// in it are swapped for their scrubbed forms; the body after it is
/// scrubbed as text.
pub fn scrub_event(event: &mut Event) {
    let mut swaps: Vec<(String, String)> = Vec::new();
    if let Some(title) = event.window_title.as_mut() {
        let before = title.clone();
        if scrub_in_place(title, false) {
            swaps.push((before, title.clone()));
        }
    }
    if let Some(url) = event.url.as_mut() {
        let before = url.clone();
        if scrub_in_place(url, true) {
            swaps.push((before, url.clone()));
        }
    }
    let rewritten = {
        let (header, body) = event.text.split_at(header_len(&event.text));
        let mut kept = header.to_owned();
        for (before, after) in swaps.iter().filter(|(before, _)| !before.is_empty()) {
            kept = kept.replace(before.as_str(), after);
        }
        let body = scrub_text(body);
        (kept != header || matches!(body, Cow::Owned(_))).then(|| format!("{kept}{body}"))
    };
    if let Some(text) = rewritten {
        event.text = text;
    }
}

/// How many leading bytes of a stored text are its header lines: an MCP
/// resource's revision line, then the `[app=…]` context line, each with its
/// newline.
fn header_len(text: &str) -> usize {
    const PREFIXES: [&str; 3] = [
        crate::mcp_aggregator::MCP_RESOURCE_REVISION_MARKER,
        crate::mcp_aggregator::CATALOG_ONLY_MARKER,
        "[app=",
    ];
    let mut at = 0;
    for _ in 0..2 {
        let rest = &text[at..];
        if !PREFIXES.iter().any(|prefix| rest.starts_with(prefix)) {
            break;
        }
        let Some(newline) = rest.find('\n') else {
            break;
        };
        if !rest[..newline].ends_with(']') {
            break;
        }
        at += newline + 1;
    }
    at
}

/// Scrub an optional string field in place.
pub fn scrub_option(value: &mut Option<String>, address: bool) {
    if let Some(value) = value.as_mut() {
        scrub_in_place(value, address);
    }
}

/// Scrub a string field in place.
pub fn scrub_string(value: &mut String) {
    scrub_in_place(value, false);
}

/// Whether a JSON key names an address, which loses its sign-in parameters.
fn is_address_key(key: Option<&str>) -> bool {
    matches!(key, Some("url" | "uri" | "link" | "href" | "source_url"))
}

/// Scrub every string in `value`, in place. True when anything changed.
pub fn scrub_json(value: &mut Value) -> bool {
    walk(value, None)
}

fn walk(value: &mut Value, key: Option<&str>) -> bool {
    match value {
        Value::String(text) => scrub_in_place(text, is_address_key(key)),
        Value::Array(items) => items
            .iter_mut()
            .fold(false, |changed, item| walk(item, key) | changed),
        Value::Object(map) => map.iter_mut().fold(false, |changed, (key, item)| {
            walk(item, Some(key)) | changed
        }),
        Value::Null | Value::Bool(_) | Value::Number(_) => false,
    }
}

/// Scrub an MCP `tools/call` result in place: every structured part, and
/// each `content[].text`. That text is the payload serialized; it is parsed,
/// scrubbed and written back only when something changed, so a clean answer
/// leaves byte for byte as it came. Text that is not JSON is scrubbed as text.
pub fn scrub_tool_result(result: &mut Value) {
    let Some(object) = result.as_object_mut() else {
        scrub_json(result);
        return;
    };
    for (key, item) in object.iter_mut() {
        if key == "content" {
            scrub_content(item);
        } else {
            walk(item, Some(key));
        }
    }
}

fn scrub_content(content: &mut Value) {
    let Some(items) = content.as_array_mut() else {
        scrub_json(content);
        return;
    };
    for item in items {
        let Some(Value::String(text)) = item.get_mut("text") else {
            scrub_json(item);
            continue;
        };
        match serde_json::from_str::<Value>(text) {
            Ok(mut parsed) if parsed.is_object() || parsed.is_array() => {
                if scrub_json(&mut parsed) {
                    *text = serde_json::to_string(&parsed).unwrap_or_else(|_| REDACTED.to_owned());
                }
            }
            _ => {
                scrub_in_place(text, false);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::redaction::ocr_secrets::contains_secret;

    fn key() -> String {
        [
            "sk-",
            "ant-",
            "api03-",
            "Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0Ya8Ue4Wi2R",
        ]
        .concat()
    }

    #[test]
    fn a_clean_tool_result_leaves_byte_for_byte() {
        let payload = serde_json::json!({"hits": [{"text_snippet": "Send the Quillfeather draft", "url": "https://example.com/a?b=1"}]});
        let text = serde_json::to_string(&payload).unwrap();
        let mut result = serde_json::json!({
            "content": [{"type": "text", "text": text.clone()}],
            "hits": payload["hits"].clone(),
            "isError": false,
        });
        let before = result.clone();
        scrub_tool_result(&mut result);
        assert_eq!(result, before);
    }

    #[test]
    fn every_part_of_a_tool_result_loses_its_secrets() {
        let key = key();
        let payload = serde_json::json!({
            "hits": [{
                "text_snippet": format!("Bramble agent setup\n{key}"),
                "window_title": "card 4111 1111 1111 1111",
                "url": "https://app.example/cb?access_token=SYNTHtoken&lang=en",
            }]
        });
        let mut result = serde_json::json!({
            "content": [{"type": "text", "text": serde_json::to_string(&payload).unwrap()}],
            "hits": payload["hits"].clone(),
            "isError": false,
        });
        scrub_tool_result(&mut result);
        let all = result.to_string();
        assert!(!all.contains(&key), "{all}");
        assert!(!all.contains("4111"), "{all}");
        assert!(!all.contains("SYNTHtoken"), "{all}");
        assert!(all.contains("Bramble agent setup"), "the rest stays");
        let text = result["content"][0]["text"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(text).expect("still JSON");
        assert_eq!(parsed["hits"][0]["url"], "https://app.example/cb?lang=en");
        assert!(!contains_secret(text));
    }

    #[test]
    fn plain_text_content_is_scrubbed_as_text() {
        let mut result = serde_json::json!({
            "content": [{"type": "text", "text": format!("The answer: {}", key())}],
        });
        scrub_tool_result(&mut result);
        assert_eq!(
            result["content"][0]["text"],
            format!("The answer: {REDACTED}")
        );
    }

    #[test]
    fn a_header_is_never_scanned_whole_and_keeps_its_shape() {
        // "Verification code" in the title and the year in the timestamp
        // would make a one-time code if the header were scanned as text.
        let text = "[app=com.apple.Safari | title=Verification code settings | url=? | ts=2026-10-20T09:00:00.000Z]\nTurn on two-step sign-in.";
        let mut event = Event {
            id: mci_brain::EventId(1),
            ts_us: 1,
            app_bundle_id: Some("com.apple.Safari".into()),
            window_title: Some("Verification code settings".into()),
            url: None,
            text: text.into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        };
        assert!(
            contains_secret(text),
            "scanned whole, the header would be redacted"
        );
        scrub_event(&mut event);
        assert_eq!(event.text, text);
    }

    #[test]
    fn an_event_read_for_an_exit_loses_its_secrets() {
        let mut event = Event {
            id: mci_brain::EventId(1),
            ts_us: 1,
            app_bundle_id: Some("com.apple.Terminal".into()),
            window_title: Some(format!("zsh {}", key())),
            url: Some("https://x.example/?token=SYNTH".into()),
            text: format!(
                "[app=com.apple.Terminal | title=zsh | url=? | ts=?]\nexport K={}",
                key()
            ),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        };
        scrub_event(&mut event);
        assert!(!contains_secret(&event.text), "{}", event.text);
        assert!(!contains_secret(event.window_title.as_deref().unwrap()));
        assert_eq!(event.url.as_deref(), Some("https://x.example/"));
        assert!(event
            .text
            .starts_with("[app=com.apple.Terminal | title=zsh | url=? | ts=?]\n"));
    }

    #[test]
    fn a_secret_title_and_address_are_swapped_out_of_the_header_too() {
        let key = key();
        let title = format!("zsh {key}");
        let url = "https://x.example/cb?token=SYNTHtoken&a=1";
        let mut event = Event {
            id: mci_brain::EventId(1),
            ts_us: 1,
            app_bundle_id: Some("com.apple.Safari".into()),
            window_title: Some(title.clone()),
            url: Some(url.into()),
            text: format!("[app=com.apple.Safari | title={title} | url={url} | ts=2026-10-20T09:00:00.000Z]\nhello"),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        };
        scrub_event(&mut event);
        assert_eq!(
            event.text,
            format!("[app=com.apple.Safari | title=zsh {REDACTED} | url=https://x.example/cb?a=1 | ts=2026-10-20T09:00:00.000Z]\nhello")
        );
    }
}
