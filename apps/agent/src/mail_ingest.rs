//! V2-P8b — Mail.app emlx → brain ingest pump (cascade-equivalent +
//! header-only audit row + ADR-0030 §3(c)(ii) parsed-header arm).
//!
//! # Where this module sits in the agent
//!
//! - **V2-P8a** (PR #243) shipped `mci-mail-reader` — the READ-ONLY
//!   library that splits emlx files, opens `Envelope Index`
//!   WAL-aware, and streams new-emlx events via FSEvents.
//! - **V2-P8b** (this PR) consumes that watcher inside `mci-agent`,
//!   applies the §3(c)(ii) parsed-header cascade-equivalent
//!   ([`mci_brain::redaction::parsed_mail_header`]), and persists
//!   [`mci_brain::Event`] rows into the brain store.
//!
//! The pump is the structural place ADR-0030 §3(c)(ii)'s
//! drop-before-write contract is enforced: every emlx flowing in is
//! pre-checked by [`cascade_equivalent`] BEFORE any body byte is
//! materialized into the brain. There is no delete-after-write path.
//!
//! # MailEvent shape (per the dispatch)
//!
//! For an `Allow` outcome the persisted [`mci_brain::Event`] has:
//!
//! - `app_bundle_id = "com.apple.mail"` (Mail-spike §1)
//! - `window_title = Some(subject)`
//! - `url = None` (Mail has no tabs and no per-mail URL)
//! - `tab_id = None`
//! - `text = ADR-0010 §1.3 context header + body` (text/plain or
//!    text/html)
//!
//! For a `HeaderOnly` outcome (drop-body-persist-content-free):
//!
//! - `app_bundle_id = "com.apple.mail"`
//! - `window_title = Some("[REDACTED:MAIL_HEADER_MATCH]")` (literal)
//! - `url = None`
//! - `tab_id = None`
//! - `text = "[REDACTED:MAIL_HEADER_MATCH] from=<sender_domain>"` —
//!    the sender eTLD+1 is the categorical match key that fired the
//!    cascade (chase.com, paypal.com, …); it is itself a CSO-curated
//!    public marketing domain, not user-identifying content. Subject
//!    is dropped; body is dropped.
//!
//! For a `Refuse` outcome (fail-safe): NO row reaches `put_event`;
//! [`MailIngestCounters::refused`] is bumped.
//!
//! # Wire / cross-boundary discipline
//!
//! Nothing in this module crosses the helper IPC seam. The pump is
//! an in-process tokio task; it consumes the `mci-mail-reader`
//! FSEvents stream directly. No new wire variant is added (per
//! V2-P2 "no bump" pattern); the cascade outcome enum
//! [`mci_brain::redaction::parsed_mail_header::MailRedactionReason`]
//! is local to the brain crate, not the wire-protected
//! [`mci_core::ipc::RedactionReason`].
//!
//! # TCC posture (per Mail-spike memo §8)
//!
//! Read access to `~/Library/Mail/V<N>/` requires Full Disk Access
//! on macOS. Failures surface as [`mci_mail_reader::MailReaderError::AccessDenied`];
//! the pump propagates them — V2-P10's user-curated allowlist UI is
//! the surface that prompts the user. The pump itself does NOT
//! auto-enable on agent start in V2-P8b (see [`run_account`] — it
//! is only invoked from a CEO-attended dispatch path, not the
//! production supervisor).

#![cfg(target_os = "macos")]

use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use mci_brain::redaction::parsed_mail_header::{
    cascade_equivalent, MailCascadeDecision, MailRedactionReason, ParsedMailHeaders,
    REDACTED_BODY_MARKER, REDACTED_SUBJECT,
};
use mci_brain::redaction::MAIL_BUNDLE_ID;
use mci_brain::{BrainStore, EmbedError, Embedder, Event, EventId, StoreError};
use mci_mail_reader::{MailAccount, MailReaderError, ParsedMessage};

use crate::brain_ingest::compose_context_header;

/// Default `watch_inbox` mpsc channel capacity. Mirrors V2-P8a's
/// 64-slot recommendation in `mci_mail_reader::watch::watch_inbox`.
pub const DEFAULT_WATCH_CHANNEL_CAPACITY: usize = 64;

/// Content-free counters surfaced for the CRS Telemetry-Gap analyst
/// and the CSO audit. All values are `u64` totals since the pump
/// was constructed; identical discipline to
/// [`crate::brain_ingest::BrainIngestor::events_ingested_count`].
#[derive(Debug, Default)]
pub struct MailIngestCounters {
    /// Emlx files whose cascade returned `Allow` AND whose
    /// `put_event` succeeded. Surfaces as
    /// `mail_events_allowed_count`.
    pub allowed: AtomicU64,
    /// Emlx files whose cascade returned `HeaderOnly` AND whose
    /// header-only audit row was persisted successfully. Surfaces
    /// as `mail_events_header_only_count`.
    pub header_only: AtomicU64,
    /// Emlx files whose cascade returned `Refuse` (no `From:` header
    /// parseable). Surfaces as `mail_events_refused_count`.
    pub refused: AtomicU64,
    /// Emlx files whose `mci_mail_reader::read_message` returned an
    /// error (file vanished mid-FSEvents-deliver, EPERM-without-FDA,
    /// 3-segment-prefix corruption, etc.). Surfaces as
    /// `mail_events_read_errors`.
    pub read_errors: AtomicU64,
}

/// Successful outcome from [`MailIngestPump::ingest_path`].
#[derive(Debug, Clone)]
pub enum MailIngestOutcome {
    /// Cascade allowed; row persisted normally.
    Stored {
        /// Store-assigned event id.
        id: EventId,
        /// `true` when the embedder was wired AND the body was
        /// non-empty.
        embedded: bool,
    },
    /// Cascade returned [`MailCascadeDecision::HeaderOnly`]; the
    /// body was dropped at the pump and only a content-free audit
    /// row was persisted.
    HeaderOnlyStored {
        /// Store-assigned event id for the header-only row.
        id: EventId,
        /// Which §3(c)(ii) sub-rule fired (sensitive sender domain
        /// or subject OTP shape).
        reason: MailRedactionReason,
        /// The eTLD+1 that triggered the redaction. Lowercased.
        sender_domain: String,
    },
    /// Cascade returned [`MailCascadeDecision::Refuse`]; nothing
    /// reached `put_event`.
    Refused {
        /// Which fail-safe condition fired (always
        /// [`MailRedactionReason::UnparseableEnvelope`] in v1).
        reason: MailRedactionReason,
    },
}

/// Errors the mail-ingest pump surfaces.
#[derive(Debug, thiserror::Error)]
pub enum MailIngestError {
    /// Failure reading an emlx file or its surrounding store
    /// (FDA / EPERM, on-disk corruption, vanished file).
    #[error("mail-ingest: read: {0}")]
    Read(#[from] MailReaderError),
    /// The embedder rejected the headered body (e.g. invalid input,
    /// Core ML backend failure).
    #[error("mail-ingest: embed: {0}")]
    Embed(#[from] EmbedError),
    /// The brain store rejected the row.
    #[error("mail-ingest: store: {0}")]
    Store(#[from] StoreError),
}

/// Mail-ingest pump.
///
/// Holds the brain store + optional embedder + content-free
/// counters. Construct once per agent process; share via
/// `Arc<MailIngestPump>` across the spawned watcher task and any
/// test fixtures.
pub struct MailIngestPump {
    store: Arc<dyn BrainStore>,
    embedder: Option<Arc<dyn Embedder>>,
    counter: MailIngestCounters,
}

impl MailIngestPump {
    /// Construct a fresh pump.
    #[must_use]
    pub fn new(store: Arc<dyn BrainStore>, embedder: Option<Arc<dyn Embedder>>) -> Self {
        Self {
            store,
            embedder,
            counter: MailIngestCounters::default(),
        }
    }

    /// Ingest one emlx file by absolute path.
    ///
    /// This is the function the watcher task calls per
    /// `NewMessageEvent`. It reads + parses the emlx, runs
    /// [`cascade_equivalent`], and persists the appropriate row
    /// (or none for `Refuse`).
    ///
    /// # Errors
    /// [`MailIngestError`] when the emlx cannot be read, the
    /// embedder rejects the input, or the brain store rejects the
    /// row. Each error variant bumps the matching content-free
    /// counter via [`Self::counters`].
    pub fn ingest_path(&self, path: &Path) -> Result<MailIngestOutcome, MailIngestError> {
        let ts_us = file_mtime_us(path);
        let parsed = match mci_mail_reader::read_message(path) {
            Ok(p) => p,
            Err(e) => {
                self.counter.read_errors.fetch_add(1, Ordering::Relaxed);
                return Err(MailIngestError::Read(e));
            }
        };
        let headers = to_parsed_headers(&parsed);
        match cascade_equivalent(&headers) {
            MailCascadeDecision::Allow => self.persist_allow(ts_us, &parsed, &headers),
            MailCascadeDecision::HeaderOnly {
                sender_domain,
                reason,
            } => self.persist_header_only(ts_us, sender_domain, reason),
            MailCascadeDecision::Refuse { reason } => {
                self.counter.refused.fetch_add(1, Ordering::Relaxed);
                Ok(MailIngestOutcome::Refused { reason })
            }
        }
    }

    fn persist_allow(
        &self,
        ts_us: u64,
        parsed: &ParsedMessage,
        headers: &ParsedMailHeaders,
    ) -> Result<MailIngestOutcome, MailIngestError> {
        let body = parsed
            .body_text
            .clone()
            .or_else(|| parsed.body_html.clone())
            .unwrap_or_default();
        let subject = if headers.subject.is_empty() {
            None
        } else {
            Some(headers.subject.clone())
        };
        // ADR-0010 §1.3 context header prepend. Mail has no URL —
        // the `url=?` placeholder is the documented missing-field
        // convention from `compose_context_header`.
        let headered = if body.is_empty() {
            String::new()
        } else {
            let header = compose_context_header(
                Some(MAIL_BUNDLE_ID),
                subject.as_deref(),
                None,
                ts_us,
            );
            let mut s = String::with_capacity(header.len() + body.len());
            s.push_str(&header);
            s.push_str(&body);
            s
        };

        let embedding = match (&self.embedder, headered.is_empty()) {
            (Some(e), false) => Some(e.embed_one(&headered)?),
            _ => None,
        };
        let embedded = embedding.is_some();

        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(MAIL_BUNDLE_ID.to_string()),
            window_title: subject,
            url: None,
            text: headered,
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding,
        };
        let id = self.store.put_event(&event)?;
        self.counter.allowed.fetch_add(1, Ordering::Relaxed);
        Ok(MailIngestOutcome::Stored { id, embedded })
    }

    fn persist_header_only(
        &self,
        ts_us: u64,
        sender_domain: String,
        reason: MailRedactionReason,
    ) -> Result<MailIngestOutcome, MailIngestError> {
        // Content-free audit row. `sender_domain` is the categorical
        // eTLD+1 that matched a CSO-curated public marketing domain;
        // it is NOT the full sender address. Subject + body bytes
        // from the emlx never reach this code path.
        let text = format!("{REDACTED_BODY_MARKER} from={sender_domain}");
        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(MAIL_BUNDLE_ID.to_string()),
            window_title: Some(REDACTED_SUBJECT.to_string()),
            url: None,
            text,
            summary: None,
            entities: None,
            episode_id: None,
            // The store rejects non-zero cascade_reason (ADR-0016
            // §4.3 defence-in-depth). The row is content-free by
            // construction; the redaction reason surfaces via the
            // [`MailIngestCounters::header_only`] counter +
            // [`MailRedactionReason::tombstone_reason`] string in
            // audit-log output, not via a brain-row column.
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        };
        let id = self.store.put_event(&event)?;
        self.counter.header_only.fetch_add(1, Ordering::Relaxed);
        Ok(MailIngestOutcome::HeaderOnlyStored {
            id,
            reason,
            sender_domain,
        })
    }

    /// Read-only access to the content-free counters.
    #[must_use]
    pub fn counters(&self) -> &MailIngestCounters {
        &self.counter
    }
}

/// Translate `mci-mail-reader`'s typed `ParsedMessage` into the
/// brain crate's [`ParsedMailHeaders`] shape.
///
/// Domain extraction:
/// - `from_domain` / `reply_to_domain` / `sender_domain` use the
///    bare-address `domain` portion (everything after the last `@`).
///    Lowercased so the cascade's domain-table lookup hits the
///    pre-lowercased entries without extra normalization.
/// - `list_id_domain` is RFC 2919 — typical value
///    `<list-name.example.com>` or `Plain Text <list-name.example.com>`.
///    The bracketed host (if present) is the eTLD+1; otherwise the
///    bare value is used as-is.
#[must_use]
pub fn to_parsed_headers(parsed: &ParsedMessage) -> ParsedMailHeaders {
    let from_domain = first_address_domain(&parsed.from);
    let reply_to_domain = first_address_domain_opt(&parsed.reply_to);
    let sender_domain = first_address_domain_opt(&parsed.sender);
    let list_id_domain = parsed
        .headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("List-ID"))
        .map(|(_, value)| extract_list_id_domain(value));
    let subject = parsed.subject.clone().unwrap_or_default();
    ParsedMailHeaders {
        from_domain,
        reply_to_domain,
        sender_domain,
        list_id_domain,
        subject,
    }
}

fn first_address_domain(addrs: &[mci_mail_reader::ParsedAddress]) -> String {
    addrs
        .first()
        .and_then(|a| a.address.split_once('@'))
        .map(|(_, d)| d.to_ascii_lowercase())
        .unwrap_or_default()
}

fn first_address_domain_opt(
    addrs: &[mci_mail_reader::ParsedAddress],
) -> Option<String> {
    let d = first_address_domain(addrs);
    if d.is_empty() {
        None
    } else {
        Some(d)
    }
}

/// Pull the host out of an RFC 2919 `List-ID:` value.
///
/// Accepts the common shapes:
/// - `<list.example.com>` → `list.example.com`
/// - `Display Name <list.example.com>` → `list.example.com`
/// - `list.example.com` → `list.example.com`
///
/// Lowercased on return.
fn extract_list_id_domain(value: &str) -> String {
    let trimmed = value.trim();
    if let (Some(open), Some(close)) = (trimmed.rfind('<'), trimmed.rfind('>')) {
        if open < close {
            return trimmed[open + 1..close]
                .trim()
                .to_ascii_lowercase();
        }
    }
    trimmed.to_ascii_lowercase()
}

/// Read the file mtime (Unix microseconds since epoch).
///
/// Returns `0` on any error (vanished file, no mtime, time before
/// epoch) — the watcher path treats that as `ingest_at_unknown_ts`
/// rather than failing; the brain accepts `ts_us = 0` as a valid
/// (though unusual) timestamp.
fn file_mtime_us(path: &Path) -> u64 {
    fs::metadata(path)
        .ok()
        .and_then(|md| md.modified().ok())
        .and_then(|mt| mt.duration_since(UNIX_EPOCH).ok())
        .map(|d| u64::try_from(d.as_micros()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Run the FSEvents watcher for one [`MailAccount`] until the
/// watcher closes.
///
/// Each new emlx event is fed to [`MailIngestPump::ingest_path`].
/// Errors are logged via `tracing::warn!` (so the supervisor sees
/// the surface) and counted into [`MailIngestCounters`]; the loop
/// continues — one corrupt emlx does not stall the pump.
///
/// # Errors
/// [`MailReaderError`] only on initial `watch_inbox` setup failure
/// (the per-emlx errors are logged, not propagated).
///
/// # Cancellation
/// The future completes when the `InboxWatcher` channel closes,
/// which happens when its watcher handle is dropped. Spawn this via
/// `tokio::spawn` and drop the returned `JoinHandle` to stop.
pub async fn run_account(
    account: MailAccount,
    pump: Arc<MailIngestPump>,
) -> Result<(), MailReaderError> {
    let mut watcher = mci_mail_reader::watch_inbox(&account, DEFAULT_WATCH_CHANNEL_CAPACITY)?;
    while let Some(ev) = watcher.next().await {
        match pump.ingest_path(&ev.path) {
            Ok(_) => {}
            Err(err) => {
                tracing::warn!(target: "mci_agent::mail_ingest", path = %ev.path.display(), error = %err, "mail-ingest error");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::stubs::{FixedDimEmbedder, InMemoryBrainStore};
    use std::fs;
    use std::io::Write;
    use tempfile::tempdir;

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

    fn write_emlx(dir: &std::path::Path, name: &str, body: &[u8]) -> std::path::PathBuf {
        let p = dir.join(name);
        let mut f = fs::File::create(&p).unwrap();
        f.write_all(&build_emlx(body, b"")).unwrap();
        p
    }

    #[test]
    fn list_id_extracts_bracketed_host() {
        assert_eq!(extract_list_id_domain("<list.example.com>"), "list.example.com");
        assert_eq!(
            extract_list_id_domain("Friendly Name <list.example.com>"),
            "list.example.com"
        );
        assert_eq!(extract_list_id_domain("bare.example.com"), "bare.example.com");
        assert_eq!(extract_list_id_domain("<Mixed.CASE.example.com>"), "mixed.case.example.com");
    }

    #[test]
    fn file_mtime_us_is_non_zero_for_existing_file() {
        let tmp = tempdir().unwrap();
        let p = tmp.path().join("x.emlx");
        fs::write(&p, b"hi").unwrap();
        assert!(file_mtime_us(&p) > 0);
    }

    #[test]
    fn file_mtime_us_returns_zero_for_missing_path() {
        assert_eq!(
            file_mtime_us(std::path::Path::new("/this/should/not/exist/blob.emlx")),
            0
        );
    }

    #[test]
    fn ingest_allow_persists_normal_event_row() {
        let store = Arc::new(InMemoryBrainStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump = MailIngestPump::new(store.clone(), Some(embedder));

        let tmp = tempdir().unwrap();
        let body = b"From: alice@personal.example.com\r\n\
                     To: bob@example.com\r\n\
                     Subject: Sprint kickoff notes\r\n\
                     Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
                     Message-ID: <h2-1@personal.invalid>\r\n\
                     Mime-Version: 1.0\r\n\
                     Content-Type: text/plain; charset=us-ascii\r\n\
                     \r\nMeeting at 10. Notes attached.\r\n";
        let path = write_emlx(tmp.path(), "1.emlx", body);

        let outcome = pump.ingest_path(&path).expect("allow ingest ok");
        let MailIngestOutcome::Stored { id, embedded } = outcome else {
            panic!("expected Stored; got {outcome:?}");
        };
        assert!(embedded, "embedder + non-empty body ⇒ embedded");
        let ev = store.get_event(id).unwrap().unwrap();
        assert_eq!(ev.app_bundle_id.as_deref(), Some("com.apple.mail"));
        assert_eq!(ev.window_title.as_deref(), Some("Sprint kickoff notes"));
        assert!(ev.url.is_none());
        assert!(ev.tab_id.is_none());
        assert!(
            ev.text.starts_with("[app=com.apple.mail | title=Sprint kickoff notes |"),
            "ADR-0010 §1.3 header prefix; got: {}",
            &ev.text[..ev.text.len().min(160)]
        );
        assert!(ev.text.contains("Meeting at 10."));
        assert_eq!(pump.counters().allowed.load(Ordering::Relaxed), 1);
        assert_eq!(pump.counters().header_only.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ingest_header_only_drops_body_and_subject_for_bank_sender() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MailIngestPump::new(store.clone(), None);

        let tmp = tempdir().unwrap();
        let body = b"From: secure@chase.com\r\n\
                     To: bob@example.com\r\n\
                     Subject: Statement is available\r\n\
                     Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
                     Message-ID: <h1-1@chase.invalid>\r\n\
                     Mime-Version: 1.0\r\n\
                     Content-Type: text/plain; charset=us-ascii\r\n\
                     \r\nYour balance is $9,999.99. Click https://chase.com/login to view.\r\n";
        let path = write_emlx(tmp.path(), "1.emlx", body);

        let outcome = pump.ingest_path(&path).expect("ingest ok");
        let MailIngestOutcome::HeaderOnlyStored {
            id,
            reason,
            sender_domain,
        } = outcome
        else {
            panic!("expected HeaderOnlyStored; got {outcome:?}");
        };
        assert_eq!(sender_domain, "chase.com");
        assert_eq!(reason, MailRedactionReason::SensitiveSenderDomain);
        let ev = store.get_event(id).unwrap().unwrap();
        // Subject + body bytes did NOT survive in the persisted row.
        assert!(
            !ev.text.contains("Statement is available"),
            "subject must not appear in header-only row"
        );
        assert!(
            !ev.text.contains("$9,999.99"),
            "body bytes must not appear in header-only row"
        );
        assert!(
            !ev.text.contains("chase.com/login"),
            "body URLs must not appear in header-only row"
        );
        // The audit marker + categorical sender domain ARE persisted.
        assert!(ev.text.starts_with("[REDACTED:MAIL_HEADER_MATCH] from=chase.com"));
        assert_eq!(ev.window_title.as_deref(), Some("[REDACTED:MAIL_HEADER_MATCH]"));
        assert!(ev.embedding.is_none(), "no embedding for content-free audit row");
        assert_eq!(pump.counters().header_only.load(Ordering::Relaxed), 1);
        assert_eq!(pump.counters().allowed.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ingest_refuse_persists_no_row_when_from_missing() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MailIngestPump::new(store.clone(), None);

        let tmp = tempdir().unwrap();
        // Synthesized emlx with no From: header at all.
        let body = b"To: bob@example.com\r\n\
                     Subject: anonymous source\r\n\
                     Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
                     Message-ID: <h4-1@anonymous.invalid>\r\n\
                     Mime-Version: 1.0\r\n\
                     Content-Type: text/plain; charset=us-ascii\r\n\
                     \r\nWhistleblower note.\r\n";
        let path = write_emlx(tmp.path(), "1.emlx", body);

        let outcome = pump.ingest_path(&path).expect("ingest ok");
        let MailIngestOutcome::Refused { reason } = outcome else {
            panic!("expected Refused; got {outcome:?}");
        };
        assert_eq!(reason, MailRedactionReason::UnparseableEnvelope);
        assert_eq!(pump.counters().refused.load(Ordering::Relaxed), 1);
        assert_eq!(pump.counters().allowed.load(Ordering::Relaxed), 0);
        assert_eq!(pump.counters().header_only.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn ingest_subject_otp_drops_body_with_categorical_sender_preserved() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MailIngestPump::new(store.clone(), None);

        let tmp = tempdir().unwrap();
        let body = b"From: notify@unknownnews.example.com\r\n\
                     To: bob@example.com\r\n\
                     Subject: Your verification code is 482917\r\n\
                     Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
                     Message-ID: <h3-1@unknownnews.invalid>\r\n\
                     Mime-Version: 1.0\r\n\
                     Content-Type: text/plain; charset=us-ascii\r\n\
                     \r\nTap to confirm.\r\n";
        let path = write_emlx(tmp.path(), "1.emlx", body);

        let outcome = pump.ingest_path(&path).expect("ingest ok");
        let MailIngestOutcome::HeaderOnlyStored {
            id,
            reason,
            sender_domain,
        } = outcome
        else {
            panic!("expected HeaderOnlyStored; got {outcome:?}");
        };
        assert_eq!(sender_domain, "unknownnews.example.com");
        assert_eq!(reason, MailRedactionReason::SubjectOtpShape);
        let ev = store.get_event(id).unwrap().unwrap();
        // OTP digits and "Tap to confirm" must not survive in the row.
        assert!(!ev.text.contains("482917"));
        assert!(!ev.text.contains("Tap to confirm"));
        assert!(ev.text.starts_with("[REDACTED:MAIL_HEADER_MATCH] from="));
    }

    #[test]
    fn ingest_list_id_match_drops_body_to_header_only() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MailIngestPump::new(store.clone(), None);

        let tmp = tempdir().unwrap();
        // Friendly From: domain, but the mailing-list List-ID:
        // points at chase.com (the sensitive table entry).
        let body = b"From: digest@partners.example.com\r\n\
                     To: bob@example.com\r\n\
                     Subject: Weekly partner digest\r\n\
                     Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n\
                     Message-ID: <h5-1@partners.invalid>\r\n\
                     List-ID: <chase.com>\r\n\
                     Mime-Version: 1.0\r\n\
                     Content-Type: text/plain; charset=us-ascii\r\n\
                     \r\nThis week's partner digest content.\r\n";
        let path = write_emlx(tmp.path(), "1.emlx", body);

        let outcome = pump.ingest_path(&path).expect("ingest ok");
        let MailIngestOutcome::HeaderOnlyStored {
            sender_domain,
            reason,
            ..
        } = outcome
        else {
            panic!("expected HeaderOnlyStored; got {outcome:?}");
        };
        assert_eq!(sender_domain, "chase.com");
        assert_eq!(reason, MailRedactionReason::SensitiveSenderDomain);
    }

    #[test]
    fn to_parsed_headers_extracts_from_domain_and_list_id() {
        let parser = mail_parser::MessageParser::default();
        let raw = b"From: \"Alice\" <alice@example.com>\r\n\
                    Reply-To: replies@example.org\r\n\
                    Subject: Hi\r\n\
                    List-ID: <my-list.example.net>\r\n\
                    \r\nbody\r\n";
        let msg = parser.parse(raw).unwrap();

        // Convert via the same path mci-mail-reader uses internally —
        // construct a ParsedMessage by re-using the public parse_message_bytes
        // surface so the test exercises the production translator.
        let emlx = build_emlx(raw, b"");
        let parsed = mci_mail_reader::parse::parse_message_bytes(
            &emlx,
            std::path::Path::new("/tmp/fixture.emlx"),
        )
        .unwrap();
        let headers = to_parsed_headers(&parsed);
        assert_eq!(headers.from_domain, "example.com");
        assert_eq!(headers.reply_to_domain.as_deref(), Some("example.org"));
        assert_eq!(headers.list_id_domain.as_deref(), Some("my-list.example.net"));
        assert_eq!(headers.subject, "Hi");
        // Silence unused-binding for mail-parser's parser ref above.
        let _ = msg;
    }
}
