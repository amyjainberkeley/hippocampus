//! `mci-agent send-card`: the one builder for Ask {Tool} and Copy for Your
//! AI (SPEC 5.3.10), used by the window and the Ask panel alike, so the same
//! moment makes the same message from History, Today and the panel.
//!
//! The request comes on standard input, never in arguments, so a question
//! never shows in the process list. The answer says what goes in the tool's
//! message box, and either a link that opens the tool with it (`open`) or
//! that it is to be copied (`copy: true`). Hippocampus never sends anything:
//! the person presses send in the tool.
//!
//! A seam for now: every request is answered with today's Copy for Your AI,
//! the cited packet `mci-agent context` makes (focused on the question when
//! there is one), to copy. The builder of SPEC 5.3.3 to 5.3.5 and each
//! tool's link land with the handoff.

use std::io::Read;
use std::sync::Arc;

use mci_brain::SqlCipherBrainStore;
use serde::{Deserialize, Serialize};

use crate::context_packet::{
    render_context_packet_markdown, ContextBudget, DEFAULT_CONTEXT_EVIDENCE, DEFAULT_CONTEXT_TOKENS,
};
use crate::mcp::{BrainReader, LiveBrainReader};
use crate::understanding::{ReadCommand, ReadError};

/// The most a request may be, in bytes: a question and moment ids.
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

/// What to hand to which tool.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct CardRequest {
    /// `claude`, `claude-code`, `codex`, `chatgpt`, `cursor`, `vscode` or
    /// `copy`.
    pub to: String,
    /// What the person typed, when they asked something.
    pub question: Option<String>,
    /// Moments the person picked, newest first.
    pub moments: Vec<u64>,
    /// A session, by its own time.
    pub session: Option<SessionSpan>,
    /// A Working On item, by its id.
    pub item: Option<String>,
    /// Include "About me" lines (off at the start of every send).
    pub include_about_me: bool,
    /// Include the newest moment's screenshot (off at the start of every
    /// send).
    pub include_screenshot: bool,
}

/// A session's own time, in microseconds since the epoch.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct SessionSpan {
    /// When it started.
    pub start_us: u64,
    /// When it ended.
    pub end_us: u64,
}

/// What goes in the tool's message box, and how it gets there.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Card {
    /// The message, as Markdown.
    pub message: String,
    /// Its length in characters.
    pub chars: usize,
    /// A link that opens the tool with the message in its box, never sent.
    pub open: Option<String>,
    /// Copy the message instead: the tool has no link, or it didn't fit.
    pub copy: bool,
    /// For a code project, the folder the tool opens in, with `~` for home.
    pub folder: Option<String>,
    /// The moments the message holds.
    pub included: Vec<u64>,
    /// What was left out, counted, never shown.
    pub left_out: LeftOut,
    /// Whether moments were shortened to fit.
    pub shortened: bool,
    /// Whether it holds messages from other people.
    pub people_messages: bool,
    /// The moment whose screenshot goes with it, when one was ticked.
    pub screenshot_moment: Option<u64>,
}

/// What a card left out, by reason.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct LeftOut {
    /// Moments forgotten since the click.
    pub forgotten: u32,
    /// Moments from an app the person has since kept out.
    pub kept_out: u32,
    /// Lines that looked like a password or a code.
    pub secret_lines: u32,
    /// Moments dropped to fit.
    pub trimmed_moments: u32,
}

/// Read one request from `input`, at most [`MAX_REQUEST_BYTES`]. Errors say
/// what was wrong and never repeat what was sent.
///
/// # Errors
/// [`ReadError::Usage`] for a request that can't be read, is too big or is
/// not a request.
pub fn read_request(input: impl Read) -> Result<CardRequest, ReadError> {
    let mut bytes = Vec::new();
    let limit = u64::try_from(MAX_REQUEST_BYTES + 1).unwrap_or(u64::MAX);
    input
        .take(limit)
        .read_to_end(&mut bytes)
        .map_err(|_| ReadError::Usage("send-card could not read its request".into()))?;
    if bytes.len() > MAX_REQUEST_BYTES {
        return Err(ReadError::Usage(
            "send-card's request is over 64 KiB".into(),
        ));
    }
    serde_json::from_slice(&bytes)
        .map_err(|_| ReadError::Usage("send-card's request is not a request".into()))
}

/// The card for `request`, from the memory in `store`.
///
/// # Errors
/// [`ReadError::Failed`] when the memory can't be read for it.
pub fn build(store: &Arc<SqlCipherBrainStore>, request: &CardRequest) -> Result<Card, ReadError> {
    let reader = LiveBrainReader::from_store_with_embedder(Arc::clone(store), query_embedder());
    let focus = request
        .question
        .as_deref()
        .map(str::trim)
        .filter(|question| !question.is_empty());
    let packet = reader
        .context(
            focus,
            ContextBudget::new(DEFAULT_CONTEXT_TOKENS, DEFAULT_CONTEXT_EVIDENCE),
        )
        .map_err(|_| ReadError::Failed("send-card could not read the memory".into()))?;
    let message = render_context_packet_markdown(&packet);
    Ok(Card {
        chars: message.chars().count(),
        included: packet
            .citations
            .iter()
            .map(|citation| citation.event_id)
            .collect(),
        message,
        copy: true,
        ..Card::default()
    })
}

/// `mci-agent send-card`: the request from standard input, the card as JSON.
/// Words given as arguments are refused, so a question can never be put
/// where the process list shows it.
///
/// # Errors
/// [`ReadError::Usage`] for words in the arguments or a bad request;
/// [`ReadError::Failed`] when the memory can't be read.
pub fn run_cli(command: &ReadCommand<'_>) -> Result<serde_json::Value, ReadError> {
    if command.args.iter().any(|arg| !arg.starts_with("--")) {
        return Err(ReadError::Usage(
            "send-card reads its request from standard input, never from arguments".into(),
        ));
    }
    let request = read_request(std::io::stdin().lock())?;
    let card = build(command.store, &request)?;
    serde_json::to_value(card)
        .map_err(|_| ReadError::Failed("send-card could not be written".into()))
}

/// The embedder `context` searches by meaning with, unless it is turned off
/// (`MCI_EMBEDDER_DISABLED=1`) or not on this Mac; without one, exact words.
fn query_embedder() -> Option<Arc<dyn mci_brain::Embedder>> {
    if std::env::var("MCI_EMBEDDER_DISABLED").as_deref() == Ok("1") {
        return None;
    }
    let (embedder, is_real) = crate::embedder_load::load_query_embedder_backend();
    is_real.then_some(embedder)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_reads_with_every_field_optional() {
        let request = read_request(
            br#"{"to": "claude", "question": "Why does rounding drift?", "moments": [4812],
                 "session": null, "item": null, "include_about_me": false, "include_screenshot": false}"#
                .as_slice(),
        )
        .unwrap();
        assert_eq!(request.to, "claude");
        assert_eq!(
            request.question.as_deref(),
            Some("Why does rounding drift?")
        );
        assert_eq!(request.moments, vec![4812]);
        assert_eq!(
            read_request(b"{}".as_slice()).unwrap(),
            CardRequest::default()
        );
        let session = read_request(
            br#"{"to": "copy", "session": {"start_us": 10, "end_us": 20}}"#.as_slice(),
        )
        .unwrap();
        assert_eq!(
            session.session,
            Some(SessionSpan {
                start_us: 10,
                end_us: 20
            })
        );
    }

    #[test]
    fn a_bad_or_huge_request_is_refused_without_repeating_it() {
        let error = read_request(b"{\"question\": \"secret words\"".as_slice()).unwrap_err();
        assert!(matches!(error, ReadError::Usage(_)));
        assert!(!error.to_string().contains("secret"), "{error}");
        let huge = format!("{{\"question\": \"{}\"}}", "a".repeat(MAX_REQUEST_BYTES));
        let error = read_request(huge.as_bytes()).unwrap_err();
        assert!(error.to_string().contains("64 KiB"), "{error}");
    }

    #[test]
    fn a_card_is_written_with_every_field_the_window_reads() {
        let value = serde_json::to_value(Card::default()).unwrap();
        for key in [
            "message",
            "chars",
            "open",
            "copy",
            "folder",
            "included",
            "left_out",
            "shortened",
            "people_messages",
            "screenshot_moment",
        ] {
            assert!(value.get(key).is_some(), "{key}");
        }
        for key in ["forgotten", "kept_out", "secret_lines", "trimmed_moments"] {
            assert!(value["left_out"].get(key).is_some(), "{key}");
        }
    }
}
