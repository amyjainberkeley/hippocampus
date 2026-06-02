//! V2-P4 — entity extraction layer.
//!
//! The first writer to the V2-P3 graph foundation (`entities` /
//! `entity_mentions`; migration `0004_v2_graph_schema.sql`). Two tiers
//! are planned:
//!
//! - **Tier 1 (this module — [`tier1`])** — focused regex bank for
//!   cheap structural entities (URLs, emails, phone numbers, IPs,
//!   crypto addresses, UUIDs, ULIDs, GitHub PR refs, file paths) and
//!   for **token-shape REDACT** (JWT, AWS access key, GitHub PAT,
//!   Stripe API key, Bitcoin WIF private key). Token-shape matches
//!   never have their bytes persisted — only a `redacted_token`
//!   placeholder lands in `entities`, so the brain knows a credential
//!   was present without storing it.
//!
//! - **Tier 2 (V2-P5, follow-on PR)** — Qwen NER for person names,
//!   project names, free-form topics. Reads the events written by
//!   the Tier 1 path and adds richer `qwen`-tagged mentions alongside
//!   the existing `regex`-tagged ones (`entity_mentions.extractor_kind`
//!   discriminates).
//!
//! # Cascade discipline (POST-cascade, LOAD-BEARING)
//!
//! Tier 1 runs **after** the ADR-0016 cascade. The pixel-time §1–§5/§7
//! arms have already dropped suppressed frames (`BrainStore::put_event`
//! rejects `cascade_reason != 0`), and the OCR-time §6 redaction has
//! replaced sensitive byte ranges with `[REDACTED:…]` markers
//! (`core/brain/src/redaction/sms_otp.rs`,
//! `core/brain/src/redaction/sensitive_domains.rs`). So a frame
//! containing an SMS OTP has the digits replaced with
//! `[REDACTED:SMS_OTP]` *before* Tier 1 sees it; the phone-number
//! regex does not scan the suppressed digits at all.
//!
//! The `[REDACTED:…]` marker itself is a recognisable shape — Tier 1
//! emits a `redacted_token` entity for it so the V2-P11 privacy-moments
//! surface has a cross-app trace anchor without re-deriving the
//! cascade rule.

pub mod tier1;

pub use tier1::{persist_tier1_matches, PersistStats, Tier1Extractor, Tier1Match};
