//! V2-P10 — Messages.app `chat.db` → brain ingest pump (deep-hook
//! plugin path).
//!
//! # Where this module sits
//!
//! - **V2-P7** (PR #248) shipped `mci-messages-reader` (READ-ONLY
//!   chat.db reader + FSEvents watcher) and
//!   `mci_brain::redaction::messages_plugin` (the §3(f)
//!   cascade-equivalent + corpus). Both were inert by design — V2-P7
//!   landed the contract + corpus + library but DID NOT wire the
//!   agent-side ingest.
//! - **V2-P10** (this PR) wires the ingest plumbing: poll
//!   `mci_messages_reader::list_recent_messages` since a watermark on
//!   every FSEvents `chat.db` touch, project each row to a
//!   [`mci_brain::redaction::messages_plugin::MessagesPluginEvent`],
//!   run the cascade-equivalent, and `put_event` on
//!   [`MessagesPluginDecision::drop_event = false`] outcomes.
//!
//! The pump is the structural place ADR-0032 §3 + ADR-0030 §3(f)
//! drop-before-write contract is enforced: every chat.db row flowing
//! in is pre-checked by `redact_messages_plugin_event` BEFORE any
//! body byte is materialized into the brain. There is no
//! delete-after-write path.
//!
//! # MessagesPluginPump shape (per the dispatch + ADR-0030 §3(f))
//!
//! For an `Allow` outcome (cascade `drop_event = false`):
//!
//! - `app_bundle_id = "com.apple.MobileSMS"`
//! - `window_title = "from <handle>"` / `"to <handle>"` — **the WHO.**
//!    The participant handle the cascade just vetted (denylist +
//!    sensitive-domain already drop the event upstream, so anything
//!    here is user-allowed) becomes the window "title", with the
//!    direction word carrying `is_from_me`. `None` for an outgoing row
//!    that carries no resolved recipient (V2-P10 reader limitation; a
//!    `read_thread` thread-cache for the recipient is a V2-P11 job).
//! - `url = None` — Messages has no URL surface
//! - `tab_id = None`
//! - `text = ADR-0010 §1.3 context header + redacted_body` — the header
//!    co-locates the `window_title` (= the handle) into `events.text`, so
//!    the handle is BOTH displayable AND extractable. `redacted_body`
//!    already carries the §3(a) `[REDACTED:SMS_OTP]` /
//!    `[REDACTED:BANK_NOTIFICATION]` substitutions from the cascade. The
//!    pump does NOT re-redact.
//!
//! After `put_event`, the Allow arm runs the **Tier-1 regex extractor**
//! (same as the screen/page `BrainPump`) so the handle — now in
//! `events.text` — is lifted into a `phone`/`email` entity + an
//! `entity_mention`. That is what lets the idle-batch `AliasResolver`
//! anchor a handle-keyed Person identity (even with no saved contact
//! name) and the Consolidator dot-connect it cross-app. Before this the
//! Messages pump wrote `put_event` with NO extraction, so Messages
//! events — and the handle — were invisible to the entity graph.
//!
//! For a `Drop` outcome: NO row reaches `put_event` (and so NO
//! extraction); the matching content-free counter is bumped per
//! [`MessagesPluginDropReason`].
//!
//! # Watermark + cold-start posture
//!
//! On `MessagesPluginPump::new` the watermark is set to `now_unix()` —
//! a fresh agent process does NOT ingest historical Messages content.
//! The user's intent on first-flip-on is "from here forward". V2-P11
//! may layer an explicit "backfill since onboarding" surface; until
//! then, only new messages flow.
//!
//! # Cascade-equivalent contract (driver-CSO audit row 4 + 6)
//!
//! Every poll → for-each-row → builds a
//! [`MessagesPluginEvent`] → invokes
//! [`redact_messages_plugin_event`] with the supervisor-provided
//! [`MessagesPluginConfig`] → branches on `drop_event` → only the
//! `false` branch reaches `put_event`. There is no other code path
//! into `BrainStore` from this module.
//!
//! # TCC posture
//!
//! `~/Library/Messages/chat.db` requires Full Disk Access. The
//! [`PumpSupervisor`](crate::pump_supervisor) probes FDA before
//! starting the pump; the pump itself only sees a
//! [`MessagesReaderError::AccessDenied`] when FDA is revoked
//! mid-session — in that case the per-row error is counted and the
//! watcher continues (the next poll may succeed if the user re-grants).

#![cfg(target_os = "macos")]

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::extraction::tier1::persist_tier1_matches;
use mci_brain::redaction::messages_plugin::{
    redact_messages_plugin_event, MessagesPluginConfig, MessagesPluginDecision,
    MessagesPluginDropReason, MessagesPluginEvent,
};
use mci_brain::redaction::MESSAGES_BUNDLE_ID;
use mci_brain::{BrainStore, EmbedError, Embedder, Event, EventId, StoreError, Tier1Extractor};
use mci_messages_reader::{list_recent_messages, ChatDbLocation, MessageRow, MessagesReaderError};

use crate::brain_ingest::compose_context_header;

/// Default `watch_inbox` mpsc channel capacity. Same shape as
/// [`crate::mail_ingest::DEFAULT_WATCH_CHANNEL_CAPACITY`].
pub const DEFAULT_WATCH_CHANNEL_CAPACITY: usize = 64;

/// Content-free counters surfaced for the CRS Telemetry-Gap analyst
/// and the CSO audit. The per-drop-reason counters split the cascade
/// outcome distribution so silent-no-events is distinguishable from
/// silent-all-dropped-by-cascade.
#[derive(Debug, Default)]
pub struct MessagesIngestCounters {
    /// Rows whose cascade returned `drop_event = false` AND whose
    /// `put_event` succeeded. Surfaces as
    /// `messages_events_allowed_count`.
    pub allowed: AtomicU64,
    /// Cascade dropped because `plugin_enabled = false`. Counts only
    /// when the pump is invoked at all (which the supervisor avoids
    /// when the master switch is off); the increment surfaces a
    /// misconfiguration (e.g. supervisor started the pump but cfg
    /// has plugin_enabled=false).
    pub plugin_disabled: AtomicU64,
    /// Cascade dropped because `body = None` (attachment-only /
    /// system rows).
    pub plugin_no_body: AtomicU64,
    /// Cascade dropped because a participant is on the user-curated
    /// participant denylist.
    pub participant_denylisted: AtomicU64,
    /// Cascade dropped because the participant allowlist is active
    /// (`allow_all_participants = false`) AND no participant matched
    /// it.
    pub participant_not_allowlisted: AtomicU64,
    /// Cascade dropped because a participant address matched the
    /// sensitive-domain table (e.g. `alerts@chase.com`).
    pub sensitive_participant_domain: AtomicU64,
    /// Cascade dropped because the body contained a sensitive URL or
    /// host.
    pub sensitive_url_in_body: AtomicU64,
    /// Errors during `list_recent_messages` (FDA revoked mid-session,
    /// chat.db corruption, etc.).
    pub read_errors: AtomicU64,
    /// `put_event` rejected the row.
    pub store_errors: AtomicU64,
    /// Embedder failures on a non-empty body.
    pub embed_errors: AtomicU64,
}

/// Per-row outcome from [`MessagesPluginPump::ingest_row`].
#[derive(Debug, Clone)]
pub enum MessagesIngestOutcome {
    /// Cascade allowed; row persisted normally.
    Stored {
        /// Store-assigned event id.
        id: EventId,
        /// Whether the embedder produced a vector for the headered
        /// body.
        embedded: bool,
        /// Which cascade rules fired during the §3(a) regex pass.
        /// Content-free; mirrors
        /// [`MessagesPluginDecision::fired_rules`].
        fired_rules: Vec<&'static str>,
    },
    /// Cascade dropped the row. No `put_event` call.
    Dropped {
        /// Which §3(f) predicate fired first.
        reason: MessagesPluginDropReason,
    },
}

/// Errors the messages-ingest pump surfaces.
#[derive(Debug, thiserror::Error)]
pub enum MessagesIngestError {
    /// Failure reading chat.db.
    #[error("messages-ingest: read: {0}")]
    Read(#[from] MessagesReaderError),
    /// Embedder rejected the headered body.
    #[error("messages-ingest: embed: {0}")]
    Embed(#[from] EmbedError),
    /// Brain store rejected the row.
    #[error("messages-ingest: store: {0}")]
    Store(#[from] StoreError),
}

/// Messages-ingest pump.
///
/// Holds the brain store + optional embedder + the live cascade
/// config + the watermark + content-free counters. Construct once
/// per agent process; share via `Arc<MessagesPluginPump>` across the
/// spawned watcher task and any test fixtures.
///
/// The cascade config is supplied by the supervisor at construction
/// time (the supervisor materializes `plugin_enabled = true` from
/// the user-allowlist row's `deep_hook_enabled = true`). The pump
/// does NOT mutate the config — if the user toggles the allowlist
/// off, the supervisor drops the pump task and creates a fresh
/// instance on the next flip-on.
pub struct MessagesPluginPump {
    store: Arc<dyn BrainStore>,
    embedder: Option<Arc<dyn Embedder>>,
    cfg: MessagesPluginConfig,
    watermark_unix_seconds: AtomicI64,
    counter: MessagesIngestCounters,
    /// V2-P4 Tier 1 regex entity extractor, run synchronously on the Allow
    /// arm after `put_event` — mirrors the screen/page `BrainPump`
    /// (`apps/agent/src/brain_ingest.rs`). Zero-sized (the regex bank lives
    /// in module-level `LazyLock` statics), so holding it by value costs
    /// nothing. This is what turns the persisted participant handle (folded
    /// into `events.text` via the context header) into a `phone`/`email`
    /// entity + `entity_mention`, so the `AliasResolver` can anchor a
    /// handle-keyed Person identity and the Consolidator can dot-connect it
    /// cross-app. Before V2-P? the Messages pump wrote `put_event` with no
    /// extraction at all, so Messages events yielded zero entities.
    tier1: Tier1Extractor,
    /// Cumulative `entity_mentions` rows Tier 1 has inserted on the Allow
    /// arm. Content-free `u64` CRS Telemetry-Gap counter, identical
    /// discipline to `BrainPump::tier1_mentions_persisted`.
    tier1_mentions_persisted: AtomicU64,
}

impl MessagesPluginPump {
    /// Construct a fresh pump.
    ///
    /// The watermark is initialized to the current wall-clock time —
    /// only messages written by Messages.app AFTER the pump comes up
    /// are ingested. This matches the user's mental model on first
    /// toggling V2-P10 on: "I want my Messages from now forward."
    #[must_use]
    pub fn new(
        store: Arc<dyn BrainStore>,
        embedder: Option<Arc<dyn Embedder>>,
        cfg: MessagesPluginConfig,
    ) -> Self {
        let now = now_unix_seconds();
        Self::with_watermark(store, embedder, cfg, now)
    }

    /// Construct with an explicit watermark. Tests use this to inject
    /// a known starting point against a fixture chat.db; production
    /// uses [`Self::new`] which seeds from wall-clock.
    #[must_use]
    pub fn with_watermark(
        store: Arc<dyn BrainStore>,
        embedder: Option<Arc<dyn Embedder>>,
        cfg: MessagesPluginConfig,
        initial_watermark_unix: i64,
    ) -> Self {
        Self {
            store,
            embedder,
            cfg,
            watermark_unix_seconds: AtomicI64::new(initial_watermark_unix),
            counter: MessagesIngestCounters::default(),
            tier1: Tier1Extractor::new(),
            tier1_mentions_persisted: AtomicU64::new(0),
        }
    }

    /// Cumulative `entity_mentions` rows the Tier 1 extractor has inserted
    /// on the Allow arm. Content-free counter for the CRS Telemetry-Gap
    /// analyst (a regression in Messages "who" yield is visible here).
    #[must_use]
    pub fn tier1_mentions_persisted_count(&self) -> u64 {
        self.tier1_mentions_persisted.load(Ordering::Relaxed)
    }

    /// Read-only access to the live config — exposed for tests +
    /// supervisor introspection.
    #[must_use]
    pub fn cfg(&self) -> &MessagesPluginConfig {
        &self.cfg
    }

    /// Read the current watermark. Tests use this to assert progress.
    #[must_use]
    pub fn watermark_unix_seconds(&self) -> i64 {
        self.watermark_unix_seconds.load(Ordering::Relaxed)
    }

    /// Read-only access to the content-free counters.
    #[must_use]
    pub fn counters(&self) -> &MessagesIngestCounters {
        &self.counter
    }

    /// Poll `chat.db` for rows since the current watermark, ingest
    /// each one, and advance the watermark. Returns the number of
    /// rows that reached `put_event` (Stored outcomes).
    ///
    /// # Errors
    /// [`MessagesIngestError::Read`] only on
    /// `list_recent_messages` failure — per-row errors are logged +
    /// counted but do NOT stop the loop.
    pub fn ingest_since_watermark(
        &self,
        loc: &ChatDbLocation,
    ) -> Result<usize, MessagesIngestError> {
        let since = self.watermark_unix_seconds.load(Ordering::Relaxed);
        let rows = match list_recent_messages(loc, since) {
            Ok(r) => r,
            Err(e) => {
                self.counter.read_errors.fetch_add(1, Ordering::Relaxed);
                return Err(MessagesIngestError::Read(e));
            }
        };
        let mut stored = 0usize;
        let mut highwater = since;
        for row in rows {
            // Watermark moves whether the row stores or drops — the
            // cascade decision is final at the boundary and we do
            // NOT want to keep re-evaluating the same row.
            if row.date_unix > highwater {
                highwater = row.date_unix;
            }
            match self.ingest_row(&row) {
                Ok(MessagesIngestOutcome::Stored { .. }) => stored += 1,
                Ok(MessagesIngestOutcome::Dropped { .. }) => {}
                Err(err) => {
                    tracing::warn!(
                        target: "mci_agent::messages_ingest",
                        rowid = row.rowid,
                        error = %err,
                        "messages-ingest error on row",
                    );
                }
            }
        }
        // `list_recent_messages` uses `date_unix >= since`. Advance
        // the watermark to `highwater + 1` so the next poll does not
        // re-read the last row we just processed.
        if highwater >= since {
            self.watermark_unix_seconds
                .store(highwater + 1, Ordering::Relaxed);
        }
        Ok(stored)
    }

    /// Ingest one `chat.db` row. Used by
    /// [`Self::ingest_since_watermark`] but also exposed for tests
    /// that synthesize rows without a chat.db fixture.
    ///
    /// # Errors
    /// [`MessagesIngestError::Embed`] / [`MessagesIngestError::Store`]
    /// on embedder / store rejection of an Allow outcome.
    pub fn ingest_row(
        &self,
        row: &MessageRow,
    ) -> Result<MessagesIngestOutcome, MessagesIngestError> {
        let evt = project_row_to_event(row);
        let decision = redact_messages_plugin_event(&evt, &self.cfg);
        self.dispatch_decision(row, decision)
    }

    /// Drive a single pre-built cascade decision. Lets tests assert
    /// the integration shape without re-deriving the cascade from a
    /// row (useful for negative tests that pre-stage a `Dropped`
    /// outcome).
    pub fn dispatch_decision(
        &self,
        row: &MessageRow,
        decision: MessagesPluginDecision,
    ) -> Result<MessagesIngestOutcome, MessagesIngestError> {
        if decision.drop_event {
            self.bump_drop_counter(decision.drop_reason);
            return Ok(MessagesIngestOutcome::Dropped {
                reason: decision
                    .drop_reason
                    .unwrap_or(MessagesPluginDropReason::PluginDisabled),
            });
        }
        // Allow path — cascade has already rewritten OTP / banking
        // spans in place via `redacted_body`.
        let ts_us = unix_seconds_to_us(row.date_unix);

        // Persist the WHO. The cascade has already DROPPED the event if any
        // participant was denylisted or matched a sensitive domain (steps 3
        // + 5 of `redact_messages_plugin_event`), so any handle still here is
        // user-allowed. We fold it into the per-event context header as the
        // window "title" — `compose_context_header` co-locates the title into
        // `events.text`, so the handle is BOTH human-readable on the recall
        // surface ("who") AND a clean span the Tier-1 phone/email regex lifts
        // below. The direction word (`from` received / `to` sent) carries
        // `is_from_me` so "what did I send <friend>" is answerable. The handle
        // is the user's own contact id, persisted ONLY in the local
        // SQLCipher-encrypted brain; it is never a secret and is never
        // redacted (the body redaction is a separate path, unchanged).
        let participants = participant_handles(row);
        let who = participant_label(&participants, row.is_from_me);

        let header = compose_context_header(Some(MESSAGES_BUNDLE_ID), who.as_deref(), None, ts_us);
        let mut text = String::with_capacity(header.len() + decision.redacted_body.len());
        text.push_str(&header);
        text.push_str(&decision.redacted_body);

        let embedding = if decision.redacted_body.is_empty() {
            None
        } else {
            match &self.embedder {
                Some(e) => match e.embed_one(&text) {
                    Ok(v) => Some(v),
                    Err(err) => {
                        self.counter.embed_errors.fetch_add(1, Ordering::Relaxed);
                        return Err(MessagesIngestError::Embed(err));
                    }
                },
                None => None,
            }
        };
        let embedded = embedding.is_some();

        let event = Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some(MESSAGES_BUNDLE_ID.to_string()),
            // The "who" display field — `from <handle>` / `to <handle>` /
            // `None` (outgoing rows the V2-P10 reader leaves participant-less).
            window_title: who,
            url: None,
            text,
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding,
        };
        let id = match self.store.put_event(&event) {
            Ok(id) => id,
            Err(err) => {
                self.counter.store_errors.fetch_add(1, Ordering::Relaxed);
                return Err(MessagesIngestError::Store(err));
            }
        };
        self.counter.allowed.fetch_add(1, Ordering::Relaxed);

        // V2-P? — synchronous Allow-arm Tier 1 extraction (mirrors
        // `BrainPump::ingest_ocr_event`). Lifts the participant handle (now
        // in `event.text` via the header) — and any phone/email in the body
        // — into `entities` + `entity_mentions` so the AliasResolver can
        // anchor a handle-keyed Person identity and the Consolidator can
        // dot-connect it cross-app. Best-effort: the event is already
        // persisted, so an extractor/store failure is logged-and-continued,
        // never returned (a later pass can backfill — the writer is
        // idempotent on content-stable PKs). Token-shape REDACT discipline +
        // cascade-marker SKIP are enforced inside `Tier1Extractor::extract`.
        let matches = self.tier1.extract(&event.text);
        if !matches.is_empty() {
            match persist_tier1_matches(&*self.store, id, event.ts_us, &matches) {
                Ok(stats) => {
                    self.tier1_mentions_persisted
                        .fetch_add(stats.mentions_inserted as u64, Ordering::Relaxed);
                }
                Err(err) => {
                    tracing::warn!(
                        target: "mci_agent::messages_ingest",
                        error = %err,
                        "tier1 extraction failed on Messages event; event persisted, mentions can be backfilled",
                    );
                }
            }
        }

        Ok(MessagesIngestOutcome::Stored {
            id,
            embedded,
            fired_rules: decision.fired_rules,
        })
    }

    fn bump_drop_counter(&self, reason: Option<MessagesPluginDropReason>) {
        let counter = match reason {
            Some(MessagesPluginDropReason::PluginDisabled) => &self.counter.plugin_disabled,
            Some(MessagesPluginDropReason::PluginNoBody) => &self.counter.plugin_no_body,
            Some(MessagesPluginDropReason::ParticipantDenylisted) => {
                &self.counter.participant_denylisted
            }
            Some(MessagesPluginDropReason::ParticipantNotAllowlisted) => {
                &self.counter.participant_not_allowlisted
            }
            Some(MessagesPluginDropReason::SensitiveParticipantDomain) => {
                &self.counter.sensitive_participant_domain
            }
            Some(MessagesPluginDropReason::SensitiveUrlInBody) => {
                &self.counter.sensitive_url_in_body
            }
            None => &self.counter.plugin_disabled,
        };
        counter.fetch_add(1, Ordering::Relaxed);
    }
}

/// Project one `MessageRow` to the cascade-equivalent's input shape.
///
/// **Participants strategy.** V2-P10 passes the sender's `handle.id`
/// as the single participant when present. For outgoing messages
/// (`is_from_me = true`) the row carries no participant id (the
/// user has no row in `handle`); we pass an empty participants vec.
/// The cascade's participant-denylist + sensitive-participant-domain
/// checks fire on the sender alone — sufficient for the incoming
/// banking-SMS shape that is the dominant V2-P10 leak surface. The
/// outgoing-to-sensitive-recipient shape is left to V2-P11 + a
/// per-thread cache; the cascade's body-level checks (predicates
/// 6 + 7) still catch OTP-leak shapes regardless of direction.
fn project_row_to_event(row: &MessageRow) -> MessagesPluginEvent {
    MessagesPluginEvent {
        participants: participant_handles(row),
        body: row.body.clone(),
        service: row.service.as_str().to_owned(),
        is_from_me: row.is_from_me,
    }
}

/// The non-empty participant handle(s) carried on a chat.db row, in the
/// same projection the cascade vetted. V2-P10 surfaces the sender's
/// `handle.id` for an incoming message; an outgoing row (`is_from_me`)
/// carries none — the user has no `handle` row, and resolving the
/// recipient is the V2-P11 thread-cache job (see `project_row_to_event`'s
/// "Participants strategy" note). Single source of truth for the
/// projection so the cascade's denylist/sensitive-domain gates and the
/// persisted "who" never diverge.
fn participant_handles(row: &MessageRow) -> Vec<String> {
    match (row.is_from_me, row.sender_handle.as_deref()) {
        (false, Some(handle)) if !handle.is_empty() => vec![handle.to_owned()],
        _ => Vec::new(),
    }
}

/// A human-readable, Tier-1-extractable "who" label for the event's window
/// title. `from <handle>` for a received message, `to <handle>` for a sent
/// one — so the direction (`is_from_me`) is recoverable AND the raw handle
/// is a clean span the phone/email regex can lift out of `events.text`.
/// `None` when the row carries no participant (e.g. an outgoing message
/// whose recipient the V2-P10 reader does not yet resolve), preserving the
/// pre-change `window_title = None` for those rows.
fn participant_label(participants: &[String], is_from_me: bool) -> Option<String> {
    if participants.is_empty() {
        return None;
    }
    let who = participants.join(", ");
    Some(if is_from_me {
        format!("to {who}")
    } else {
        format!("from {who}")
    })
}

fn now_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

fn unix_seconds_to_us(unix_seconds: i64) -> u64 {
    let s = unix_seconds.max(0) as u64;
    s.saturating_mul(1_000_000)
}

/// Run the FSEvents watcher for one [`ChatDbLocation`] until the
/// watcher closes.
///
/// On every `chat.db` touch the pump re-polls `list_recent_messages`
/// since the watermark and ingests each row. FSEvents fires a burst
/// of touches for the WAL + chat.db itself per inbound message; the
/// watermark-based polling collapses the burst into a single read.
///
/// # Errors
/// [`MessagesReaderError`] only on initial `watch_inbox` setup
/// failure (per-row errors are counted, not propagated).
///
/// # Cancellation
/// The future completes when the watcher channel closes (the
/// `InboxWatcher` handle is dropped by the spawning supervisor).
pub async fn run_messages_pump(
    loc: ChatDbLocation,
    pump: Arc<MessagesPluginPump>,
) -> Result<(), MessagesReaderError> {
    let mut watcher = mci_messages_reader::watch_inbox(&loc, DEFAULT_WATCH_CHANNEL_CAPACITY)?;

    // Drain anything already on disk that landed since the pump's
    // initial watermark (covers the case where Messages.app wrote a
    // row in the gap between supervisor reconcile and watcher arm).
    if let Err(err) = pump.ingest_since_watermark(&loc) {
        tracing::warn!(
            target: "mci_agent::messages_ingest",
            error = %err,
            "initial drain failed; FSEvents loop will retry",
        );
    }

    while let Some(_ev) = watcher.next().await {
        match pump.ingest_since_watermark(&loc) {
            Ok(_n) => {}
            Err(err) => {
                tracing::warn!(
                    target: "mci_agent::messages_ingest",
                    error = %err,
                    "messages-ingest poll error",
                );
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::stubs::{FixedDimEmbedder, InMemoryBrainStore};
    use mci_messages_reader::ChatService;

    fn row(rowid: i64, body: Option<&str>, sender: Option<&str>, is_from_me: bool) -> MessageRow {
        MessageRow {
            rowid,
            guid: format!("M-{rowid}"),
            date_unix: 1_900_000_000 + rowid,
            is_from_me,
            service: ChatService::IMessage,
            body: body.map(str::to_owned),
            handle_rowid: if is_from_me { 0 } else { 1 },
            sender_handle: sender.map(str::to_owned),
            has_attachments: false,
        }
    }

    fn enabled_cfg() -> MessagesPluginConfig {
        MessagesPluginConfig {
            plugin_enabled: true,
            ..MessagesPluginConfig::DEFAULT
        }
    }

    // ----- Decision routing (driver-CSO audit rows 4 + 6) -----

    #[test]
    fn allow_outcome_persists_row_with_messages_bundle_id() {
        let store = Arc::new(InMemoryBrainStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump =
            MessagesPluginPump::with_watermark(store.clone(), Some(embedder), enabled_cfg(), 0);

        let r = row(
            100,
            Some("Pick up milk on the way home?"),
            Some("+15551234567"),
            false,
        );
        let outcome = pump.ingest_row(&r).expect("allow ok");
        let MessagesIngestOutcome::Stored { id, embedded, .. } = outcome else {
            panic!("expected Stored");
        };
        assert!(embedded, "embedder + non-empty body ⇒ embedded");
        let ev = store.get_event(id).unwrap().unwrap();
        assert_eq!(ev.app_bundle_id.as_deref(), Some("com.apple.MobileSMS"));
        assert!(ev.text.starts_with("[app=com.apple.MobileSMS"));
        assert!(ev.text.contains("Pick up milk on the way home?"));
        // V2-P? — the WHO is now persisted: the incoming sender handle is the
        // window title (display) AND folded into events.text (extractable).
        assert_eq!(
            ev.window_title.as_deref(),
            Some("from +15551234567"),
            "incoming sender handle persisted as the window 'who' title"
        );
        assert!(
            ev.text.contains("from +15551234567"),
            "handle is folded into events.text via the context header: {}",
            ev.text
        );
        assert_eq!(pump.counters().allowed.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn outgoing_message_persists_with_no_who_today() {
        // An outgoing row carries no participant (V2-P10 reader limitation),
        // so the window title stays None — same as before this change.
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MessagesPluginPump::with_watermark(store.clone(), None, enabled_cfg(), 0);
        let r = row(120, Some("on my way"), None, true);
        let MessagesIngestOutcome::Stored { id, .. } = pump.ingest_row(&r).expect("allow ok")
        else {
            panic!("expected Stored");
        };
        let ev = store.get_event(id).unwrap().unwrap();
        assert_eq!(
            ev.window_title, None,
            "outgoing has no resolved recipient yet"
        );
        assert!(ev.text.contains("on my way"));
    }

    #[test]
    fn participant_label_encodes_direction_and_handle() {
        assert_eq!(
            participant_label(&["+15551234567".to_owned()], false).as_deref(),
            Some("from +15551234567"),
            "received ⇒ from <handle>"
        );
        assert_eq!(
            participant_label(&["friend@example.com".to_owned()], true).as_deref(),
            Some("to friend@example.com"),
            "sent ⇒ to <handle>"
        );
        assert_eq!(
            participant_label(&[], false),
            None,
            "no participant ⇒ no who label"
        );
        assert_eq!(
            participant_label(&["a@x.com".to_owned(), "+15550000000".to_owned()], false).as_deref(),
            Some("from a@x.com, +15550000000"),
            "group: handles joined"
        );
    }

    #[test]
    fn cascade_routes_otp_through_in_place_redaction_before_brain() {
        // Driver-CSO audit row 4: every persisted Event.text MUST
        // carry the §3(a) regex substitutions BEFORE BrainStore sees
        // it. We assert: the raw OTP digits do NOT survive in the
        // persisted row.
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MessagesPluginPump::with_watermark(store.clone(), None, enabled_cfg(), 0);

        let r = row(
            101,
            Some("482917 is your verification code. Don't share it."),
            Some("+15551234567"),
            false,
        );
        let outcome = pump.ingest_row(&r).expect("ingest ok");
        let MessagesIngestOutcome::Stored {
            id, fired_rules, ..
        } = outcome
        else {
            panic!("expected Stored (OTP is in-place redacted, not dropped)");
        };
        assert!(!fired_rules.is_empty(), "the §3(a) regex must have fired");
        let ev = store.get_event(id).unwrap().unwrap();
        assert!(
            !ev.text.contains("482917"),
            "raw OTP digits must not survive: {}",
            ev.text
        );
        assert!(ev.text.contains("[REDACTED:SMS_OTP]"));
    }

    #[test]
    fn plugin_disabled_drops_with_no_put_event() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MessagesPluginPump::with_watermark(
            store.clone(),
            None,
            MessagesPluginConfig::DEFAULT,
            0,
        );
        let r = row(102, Some("hello"), Some("+15551234567"), false);
        let outcome = pump.ingest_row(&r).expect("drop ok");
        match outcome {
            MessagesIngestOutcome::Dropped {
                reason: MessagesPluginDropReason::PluginDisabled,
            } => {}
            other => panic!("expected PluginDisabled drop; got {other:?}"),
        }
        // No store side-effects.
        assert!(store.get_event(EventId(1)).unwrap().is_none());
        assert_eq!(pump.counters().allowed.load(Ordering::Relaxed), 0);
        assert_eq!(pump.counters().plugin_disabled.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn attachment_only_drops_with_no_body_reason() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MessagesPluginPump::with_watermark(store.clone(), None, enabled_cfg(), 0);
        let mut r = row(103, None, Some("+15551234567"), false);
        r.has_attachments = true;
        let outcome = pump.ingest_row(&r).expect("drop ok");
        assert!(matches!(
            outcome,
            MessagesIngestOutcome::Dropped {
                reason: MessagesPluginDropReason::PluginNoBody
            }
        ));
        assert_eq!(pump.counters().plugin_no_body.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn sensitive_sender_handle_drops_with_no_put_event() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MessagesPluginPump::with_watermark(store.clone(), None, enabled_cfg(), 0);
        let r = row(
            104,
            Some("Statement available"),
            Some("alerts@chase.com"),
            false,
        );
        let outcome = pump.ingest_row(&r).expect("drop ok");
        assert!(matches!(
            outcome,
            MessagesIngestOutcome::Dropped {
                reason: MessagesPluginDropReason::SensitiveParticipantDomain
            }
        ));
        assert_eq!(
            pump.counters()
                .sensitive_participant_domain
                .load(Ordering::Relaxed),
            1
        );
        // No store side-effects.
        assert!(store.get_event(EventId(1)).unwrap().is_none());
    }

    #[test]
    fn sensitive_url_in_body_drops() {
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MessagesPluginPump::with_watermark(store.clone(), None, enabled_cfg(), 0);
        let r = row(
            105,
            Some("Reset link: https://secure.chase.com/login"),
            Some("+15551234567"),
            false,
        );
        let outcome = pump.ingest_row(&r).expect("drop ok");
        assert!(matches!(
            outcome,
            MessagesIngestOutcome::Dropped {
                reason: MessagesPluginDropReason::SensitiveUrlInBody
            }
        ));
        assert_eq!(
            pump.counters()
                .sensitive_url_in_body
                .load(Ordering::Relaxed),
            1
        );
    }

    // ----- Watermark + integration with chat.db fixture (row 12) -----

    #[test]
    fn ingest_since_watermark_uses_chat_db_fixture_to_ingest_redacted_otp() {
        // Driver-CSO audit row 12: end-to-end check from a fixture
        // chat.db through the cascade to a persisted Event with
        // §3(a) substitutions visible. This is the test that "kills
        // the cascade is dead-code" scenario at unit-level — pair
        // with the live-Mac smoke for the production path.
        use rusqlite::Connection;
        use tempfile::tempdir;

        let tmp = tempdir().unwrap();
        let messages_root = tmp.path().join("Library").join("Messages");
        std::fs::create_dir_all(&messages_root).unwrap();
        let db_path = messages_root.join("chat.db");

        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE handle (
                ROWID INTEGER PRIMARY KEY,
                id TEXT,
                service TEXT,
                country TEXT
            );
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                style INTEGER,
                service_name TEXT,
                display_name TEXT,
                chat_identifier TEXT
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                handle_id INTEGER,
                service TEXT,
                date INTEGER,
                is_from_me INTEGER,
                is_sent INTEGER,
                is_delivered INTEGER,
                is_read INTEGER,
                cache_has_attachments INTEGER,
                item_type INTEGER
            );
            CREATE TABLE chat_handle_join (
                chat_id INTEGER,
                handle_id INTEGER
            );
            CREATE TABLE chat_message_join (
                chat_id INTEGER,
                message_id INTEGER,
                message_date INTEGER
            );
            INSERT INTO handle (ROWID, id, service, country)
                VALUES (1, '+15551234567', 'SMS', 'US');
            -- Apple-ns for unix_seconds 1_900_000_500 (above watermark 1_900_000_000)
            -- = (1_900_000_500 - 978_307_200) * 1e9
            -- = 921_693_300_000_000_000
            INSERT INTO message (
                ROWID, guid, text, handle_id, service, date, is_from_me,
                is_sent, is_delivered, is_read, cache_has_attachments, item_type
            ) VALUES (
                500, 'M-OTP',
                '482917 is your verification code. Don''t share it.',
                1, 'SMS',
                921693300000000000, 0,
                0, 1, 1, 0, 0
            );",
        )
        .unwrap();
        drop(conn);

        let loc = ChatDbLocation {
            path: db_path,
            root: messages_root,
        };
        let store = Arc::new(InMemoryBrainStore::new());
        let pump =
            MessagesPluginPump::with_watermark(store.clone(), None, enabled_cfg(), 1_900_000_000);

        let stored = pump.ingest_since_watermark(&loc).expect("ingest ok");
        assert_eq!(stored, 1, "exactly one row should pass the cascade");
        assert_eq!(pump.counters().allowed.load(Ordering::Relaxed), 1);
        // The watermark moved past the row's date_unix.
        assert!(pump.watermark_unix_seconds() > 1_900_000_500);

        // The persisted Event row carries the redacted body, not the
        // raw OTP digits. `put_event` assigns sequential ids from 1.
        let ev = store
            .get_event(EventId(1))
            .unwrap()
            .expect("event was persisted");
        assert_eq!(ev.app_bundle_id.as_deref(), Some("com.apple.MobileSMS"));
        assert!(
            !ev.text.contains("482917"),
            "raw OTP must not survive: {}",
            ev.text
        );
        assert!(ev.text.contains("[REDACTED:SMS_OTP]"));
    }

    #[test]
    fn ingest_since_watermark_with_no_new_rows_returns_zero() {
        // Driver-CSO audit row 11 — fresh install / no new content:
        // the pump can be running but emit zero events.
        use tempfile::tempdir;
        let tmp = tempdir().unwrap();
        let messages_root = tmp.path().join("Library").join("Messages");
        std::fs::create_dir_all(&messages_root).unwrap();
        let db_path = messages_root.join("chat.db");
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE handle (
                ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT, country TEXT
            );
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER,
                service_name TEXT, display_name TEXT, chat_identifier TEXT
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
                handle_id INTEGER, service TEXT, date INTEGER,
                is_from_me INTEGER, is_sent INTEGER, is_delivered INTEGER,
                is_read INTEGER, cache_has_attachments INTEGER, item_type INTEGER
            );
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (
                chat_id INTEGER, message_id INTEGER, message_date INTEGER
            );",
        )
        .unwrap();
        drop(conn);
        let loc = ChatDbLocation {
            path: db_path,
            root: messages_root,
        };
        let store = Arc::new(InMemoryBrainStore::new());
        let pump = MessagesPluginPump::with_watermark(
            store.clone(),
            None,
            enabled_cfg(),
            now_unix_seconds(),
        );
        let stored = pump.ingest_since_watermark(&loc).expect("poll ok");
        assert_eq!(stored, 0);
        assert_eq!(pump.counters().allowed.load(Ordering::Relaxed), 0);
        assert_eq!(pump.counters().read_errors.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn project_row_strips_sender_for_outgoing_messages() {
        // Outgoing rows carry no participant (the user has no row in
        // handle), so the cascade's participant-denylist + sensitive-
        // domain checks see an empty participants vec.
        let r = row(110, Some("hi"), None, true);
        let evt = project_row_to_event(&r);
        assert!(evt.participants.is_empty(), "outgoing → no participants");
        assert!(evt.is_from_me);
    }

    #[test]
    fn project_row_uses_sender_handle_for_incoming() {
        let r = row(111, Some("hi"), Some("+15551234567"), false);
        let evt = project_row_to_event(&r);
        assert_eq!(evt.participants, vec!["+15551234567".to_owned()]);
    }

    #[test]
    fn unix_seconds_to_us_returns_microseconds() {
        assert_eq!(unix_seconds_to_us(1), 1_000_000);
        assert_eq!(unix_seconds_to_us(0), 0);
        assert_eq!(unix_seconds_to_us(-5), 0);
    }
}
