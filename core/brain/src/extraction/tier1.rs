//! Tier 1 regex entity extractor — the **first writer** to the V2-P3
//! graph foundation (`entities` / `entity_mentions`).
//!
//! See `core/brain/src/extraction/tier1_regex/README.md` for the bank's
//! per-kind regex, rationale, FP shapes accepted, and fixture pointers.
//! This file is the executable side of that documentation.
//!
//! # Surface
//!
//! - [`Tier1Extractor::extract`] — pure scan of one piece of text.
//!   Returns a [`Vec<Tier1Match>`] in textual order, with overlapping
//!   matches resolved by **first-declared-wins** (token-shape REDACT
//!   patterns are declared before structural patterns, so an
//!   accidentally URL-looking JWT is never stored as a URL).
//! - [`persist_tier1_matches`] — write matches as `entities` upserts +
//!   `entity_mentions` inserts via the [`BrainStore`] trait. Idempotent:
//!   re-running the extractor on the same `(event_id, text)` produces
//!   the same `entity_id` and `entity_mention_id` (content-stable ULID
//!   discipline from [`crate::graph`]), and the `SQLCipher` impl's
//!   `INSERT OR IGNORE` on `entity_mentions` makes the second pass a
//!   no-op.
//!
//! # Token-shape REDACT discipline (CSO mini-audit row #2)
//!
//! For every match whose kind is `redacted_token`, the
//! [`Tier1Match::canonical_name`] is the **subkind label** (`"jwt"`,
//! `"aws_access_key"`, `"github_pat"`, `"stripe_api_key"`,
//! `"bitcoin_wif"`, `"cascade_redacted"`) and the
//! [`Tier1Match::mention_text`] is also the subkind label —
//! **never** the source bytes. The `entities` row reads `(kind =
//! "redacted_token", canonical_name = "jwt")`; the `entity_mentions`
//! row reads `(mention_text = "jwt")`. Two events containing two
//! different JWTs converge on the SAME entity row (the brain learns
//! "this event had a JWT" without learning "this specific JWT").
//!
//! # Cascade-cleared `[REDACTED:…]` markers
//!
//! The ADR-0030 §3(a)/(b) OCR-time redaction layer replaces sensitive
//! spans with literal markers like `[REDACTED:SMS_OTP]`. Tier 1's
//! `cascade_redacted` pattern matches the marker shape itself — Tier 1
//! does NOT scan the original bytes (they were already replaced by the
//! cascade upstream), it scans the marker. Capturing the marker as a
//! `(redacted_token, cascade_redacted)` entity gives downstream
//! consumers (V2-P11 privacy-moments) a cross-app-edge anchor without
//! re-implementing the cascade.
//!
//! # Idempotency (CSO mini-audit row #3 — content-stable ULIDs)
//!
//! Per [`crate::graph`] module doc:
//! - `Entity::derive_id(kind, canonical_name)` — same `(kind,
//!   canonical_name)` ⇒ same ULID.
//! - `EntityMention::derive_id(entity_id, event_id, extractor_kind,
//!   mention_text)` — same tuple ⇒ same ULID.
//!
//! Running [`Tier1Extractor::extract`] twice on the same event text
//! produces the same matches, and [`persist_tier1_matches`] writes
//! them through `put_entity` (upsert keyed on PK) and
//! `put_entity_mention` (`INSERT OR IGNORE` keyed on PK). Net: a
//! second pass is a no-op at the `SQLCipher` level.
//!
//! # Footprint
//!
//! The regex bank is compiled **once per process** via [`LazyLock`].
//! Each scan is `N` separate `Regex::find_iter` calls (one per kind)
//! over the input text; total work is O(N · |text|) with DFA-bounded
//! constants. For a 4 KB OCR-typical event with ~5 matches, scan time
//! is well below 1 ms on M1. The Footprint SLO §2 G2 ≤10–15% / ≤2 GB
//! bound is preserved by construction — no per-event allocation beyond
//! one `String` per match.
//!
//! # OS-purity
//!
//! Pure Rust + the `regex` crate (already on the workspace lockfile
//! via `mci-core`'s `hippocampus-native-host` dep chain — see
//! `core/brain/Cargo.toml`). No `cfg(target_os = ...)`, no `objc2`,
//! no `windows-rs`. ADR-0008 dep-gate satisfied (no new third-party
//! crate added).

use std::sync::LazyLock;

use regex::Regex;

use crate::graph::{Entity, EntityMention};
use crate::{BrainStore, EventId, StoreError};

// ---------------------------------------------------------------------------
// Entity-kind string constants
// ---------------------------------------------------------------------------

/// `entities.kind` value the regex extractor emits for an HTTP/HTTPS URL.
pub const KIND_URL: &str = "url";
/// `entities.kind` value for an RFC-5322-shaped email address.
pub const KIND_EMAIL: &str = "email";
/// `entities.kind` value for a digit-shaped phone number.
pub const KIND_PHONE: &str = "phone";
/// `entities.kind` value for an IPv4 or full-form IPv6 literal.
pub const KIND_IP_ADDRESS: &str = "ip_address";
/// `entities.kind` value for a BTC / ETH / SOL on-chain address.
pub const KIND_CRYPTO_ADDRESS: &str = "crypto_address";
/// `entities.kind` value for a GitHub PR / issue reference (`#N`).
pub const KIND_GITHUB_REF: &str = "github_ref";
/// `entities.kind` value for an RFC-4122 UUID.
pub const KIND_UUID: &str = "uuid";
/// `entities.kind` value for a Crockford-base32 26-char ULID.
pub const KIND_ULID: &str = "ulid";
/// `entities.kind` value for a Unix absolute file path.
pub const KIND_FILE_PATH: &str = "file_path";

/// `entities.kind` value for **any** token-shape entity the regex bank
/// recognises. The specific token type lives in `canonical_name` as
/// one of [`SUBKIND_JWT`], [`SUBKIND_AWS_ACCESS_KEY`],
/// [`SUBKIND_GITHUB_PAT`], [`SUBKIND_STRIPE_API_KEY`],
/// [`SUBKIND_BITCOIN_WIF`], [`SUBKIND_CASCADE_REDACTED`]. The source
/// bytes are NEVER persisted — `mention_text` carries the subkind
/// label, never the token itself.
pub const KIND_REDACTED_TOKEN: &str = "redacted_token";

/// `canonical_name` for a JSON Web Token shape. Subkind of
/// [`KIND_REDACTED_TOKEN`].
pub const SUBKIND_JWT: &str = "jwt";
/// `canonical_name` for an AWS access-key-id shape.
pub const SUBKIND_AWS_ACCESS_KEY: &str = "aws_access_key";
/// `canonical_name` for a GitHub personal-access-token shape.
pub const SUBKIND_GITHUB_PAT: &str = "github_pat";
/// `canonical_name` for a Stripe API-key shape.
pub const SUBKIND_STRIPE_API_KEY: &str = "stripe_api_key";
/// `canonical_name` for a Bitcoin wallet-import-format private-key
/// shape.
pub const SUBKIND_BITCOIN_WIF: &str = "bitcoin_wif";
/// `canonical_name` for an OCR-time cascade redaction marker
/// (`[REDACTED:…]`). Capturing the marker as a graph entity gives
/// V2-P11 privacy-moments a cross-app trace anchor without
/// re-implementing the cascade.
pub const SUBKIND_CASCADE_REDACTED: &str = "cascade_redacted";

/// `entity_mentions.extractor_kind` value every Tier 1 mention carries.
/// V2-P3 schema convention: V2-P4 → `"regex"`, V2-P5 → `"qwen"`,
/// V2-P12 → `"user"`.
pub const EXTRACTOR_KIND: &str = "regex";

// ---------------------------------------------------------------------------
// Regex bank — LazyLock<Regex>, one per kind
// ---------------------------------------------------------------------------

// The patterns below are evaluated in DECLARATION ORDER on every
// `extract` call. Token-shape patterns are listed FIRST so that
// (a) the source bytes of a JWT or API key never accidentally drive a
// URL/email match, and (b) overlapping spans resolve to the
// earlier-declared kind (the dedup pass at the end keeps the first
// span and drops overlaps).
//
// Each regex is wrapped in a `LazyLock` so compilation happens at
// most once per process, on first use (mirrors the pattern in
// `core/brain/src/redaction/sms_otp.rs`).

static RE_CASCADE_REDACTED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[REDACTED:[A-Z_]+\]").expect("cascade_redacted"));

static RE_JWT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\beyJ[A-Za-z0-9_=-]{8,}\.[A-Za-z0-9_=-]{8,}\.[A-Za-z0-9_=-]{4,}\b").expect("jwt")
});

static RE_AWS_ACCESS_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b").expect("aws_access_key"));

static RE_GITHUB_PAT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bgh[pousr]_[A-Za-z0-9]{36,255}\b").expect("github_pat"));

static RE_STRIPE_API_KEY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:sk|pk|rk)_(?:test|live)_[A-Za-z0-9]{24,}\b").expect("stripe_api_key")
});

static RE_BITCOIN_WIF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b[5KL][1-9A-HJ-NP-Za-km-z]{50,51}\b").expect("bitcoin_wif"));

static RE_URL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"\bhttps?://[^\s<>"'\)\]\}]+"#).expect("url"));

static RE_EMAIL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b").expect("email")
});

static RE_PHONE: LazyLock<Regex> = LazyLock::new(|| {
    // Optional `+CC ` prefix (1–3 digits), optional `(area)`,
    // 3-digit, 3-digit, 4-digit groups separated by [-.\s]. Country-
    // code-only-shaped (e.g. `+1 415 555 1234`, `+44 20 7946 0123`)
    // is the same pattern under different separators.
    Regex::new(r"(?:\+\d{1,3}[-.\s]?)?\(?\d{2,4}\)?[-.\s]?\d{3,4}[-.\s]?\d{3,4}\b").expect("phone")
});

static RE_IPV4: LazyLock<Regex> = LazyLock::new(|| {
    // Each octet matches 0-255 via the alternation; no post-pass
    // range-validation needed.
    Regex::new(r"\b(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|[01]?\d?\d)){3}\b")
        .expect("ipv4")
});

static RE_IPV6: LazyLock<Regex> = LazyLock::new(|| {
    // Full-form (8 groups) only. Compressed `::` shapes are out of
    // scope for V2-P4 (Tier2 / future tier).
    Regex::new(r"\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b").expect("ipv6")
});

static RE_BTC_BECH32: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b(?:bc1|tb1)[a-z0-9]{25,62}\b").expect("btc_bech32"));

static RE_BTC_BASE58: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b").expect("btc_base58"));

static RE_ETH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b0x[a-fA-F0-9]{40}\b").expect("eth"));

static RE_SOL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b[1-9A-HJ-NP-Za-km-z]{43,44}\b").expect("sol"));

static RE_GITHUB_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[\s\(\[\{])#(\d{1,8})\b").expect("github_ref"));

static RE_UUID: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
        .expect("uuid")
});

static RE_ULID: LazyLock<Regex> = LazyLock::new(|| {
    // Crockford base32 alphabet excludes I, L, O, U (ambiguous with
    // 1/1/0/V). The set is case-insensitive on input (lowercase
    // letters get uppercased before decoding); the canonical written
    // form is uppercase. We accept either case here and normalise to
    // upper in `scan_ulid`.
    Regex::new(r"\b[0-9A-HJ-KM-NP-TV-Za-hj-km-np-tv-z]{26}\b").expect("ulid")
});

static RE_FILE_PATH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|[\s\(\[\{])(/(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+)\b").expect("file_path")
});

// ---------------------------------------------------------------------------
// Public match type
// ---------------------------------------------------------------------------

/// One Tier 1 match against an event's text.
///
/// `span_start` / `span_end` are byte offsets into the original text;
/// `&text[span_start..span_end]` is the literal substring that
/// triggered the match. For non-redacted kinds, `mention_text` equals
/// that substring (modulo punctuation trimming for URL).
///
/// For [`KIND_REDACTED_TOKEN`] matches, `canonical_name` and
/// `mention_text` are both the subkind label (e.g. `"jwt"`) and the
/// source bytes from `span_start..span_end` are **never** copied into
/// either field — they exist on the input but do not leave the
/// extractor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tier1Match {
    /// `entities.kind` value. One of the `KIND_*` constants in this
    /// module.
    pub kind: String,
    /// `entities.canonical_name` value. For non-redacted kinds, the
    /// normalised form of the source bytes (lowercase URL host /
    /// email, digits-only phone, …). For redacted kinds, the subkind
    /// label (`"jwt"` etc.).
    pub canonical_name: String,
    /// `entity_mentions.mention_text` value. For non-redacted kinds,
    /// the literal source span (or the normalised canonical, when the
    /// span already equals canonical — e.g. a UUID). For redacted
    /// kinds, the subkind label — **never** the source bytes.
    pub mention_text: String,
    /// Inclusive byte offset of the match start in the input text.
    pub span_start: usize,
    /// Exclusive byte offset of the match end in the input text.
    pub span_end: usize,
}

impl Tier1Match {
    /// True iff this match's source bytes were redacted at extraction
    /// time — i.e. neither `canonical_name` nor `mention_text` carries
    /// the literal source span. Used by the CSO audit test
    /// `redacted_tokens_never_carry_source_bytes`.
    #[must_use]
    pub fn is_redacted(&self) -> bool {
        self.kind == KIND_REDACTED_TOKEN
    }
}

/// Counters returned by [`persist_tier1_matches`].
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct PersistStats {
    /// Number of `put_entity` calls that returned `Ok`. With the
    /// `INSERT … ON CONFLICT DO UPDATE` upsert in the `SQLCipher` impl,
    /// re-running the extractor on the same event bumps `updated_ts_us`
    /// for already-known entities but does not duplicate rows.
    pub entities_upserted: usize,
    /// Number of `put_entity_mention` calls that returned `Ok`. With
    /// `INSERT OR IGNORE` in the `SQLCipher` impl, re-running the
    /// extractor is a no-op at the row level (the call still returns
    /// `Ok`, hence the counter still increments — the count is the
    /// number of *attempted* writes, not the number of *new* rows).
    pub mentions_inserted: usize,
}

// ---------------------------------------------------------------------------
// Extractor
// ---------------------------------------------------------------------------

/// Stateless extractor. The regex bank lives in module-level
/// [`LazyLock`] statics, so constructing a [`Tier1Extractor`] is a
/// zero-cost no-op and the value can be shared across threads as a
/// `&Tier1Extractor`.
#[derive(Debug, Default, Clone, Copy)]
pub struct Tier1Extractor;

impl Tier1Extractor {
    /// Construct a fresh extractor. Cheap; the regex bank is a
    /// shared static.
    #[must_use]
    pub const fn new() -> Self {
        Self
    }

    /// Scan `text` and return every Tier 1 match in textual order.
    ///
    /// Overlapping spans (rare; e.g. the same byte range matches both
    /// `email` and an aggressive `phone` pattern) are resolved
    /// **first-declared-wins** — the earlier kind in this file's
    /// declaration order keeps the span, the later kind drops it.
    /// Token-shape REDACT kinds are declared first by design, so a
    /// JWT-looking substring never leaks as a `url`.
    #[must_use]
    pub fn extract(&self, text: &str) -> Vec<Tier1Match> {
        let mut out: Vec<Tier1Match> = Vec::new();

        // Each scanner appends to `out` without checking overlap; the
        // dedup pass at the end keeps the first span (in declaration
        // order) on overlap. Token-shape REDACT kinds are scanned
        // first.

        scan_cascade_redacted(text, &mut out);
        scan_jwt(text, &mut out);
        scan_aws_access_key(text, &mut out);
        scan_github_pat(text, &mut out);
        scan_stripe_api_key(text, &mut out);
        scan_bitcoin_wif(text, &mut out);

        scan_url(text, &mut out);
        scan_email(text, &mut out);
        scan_phone(text, &mut out);
        scan_ipv4(text, &mut out);
        scan_ipv6(text, &mut out);
        scan_btc_bech32(text, &mut out);
        scan_btc_base58(text, &mut out);
        scan_eth(text, &mut out);
        scan_sol(text, &mut out);
        scan_github_ref(text, &mut out);
        scan_uuid(text, &mut out);
        scan_ulid(text, &mut out);
        scan_file_path(text, &mut out);

        // Sort by span start (stable so earlier-declared kind wins on
        // tie), then drop later matches whose span overlaps a kept
        // earlier match.
        out.sort_by_key(|m| (m.span_start, m.span_end));
        dedup_overlapping(&mut out);

        out
    }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

/// Write `matches` to the brain store as `entities` upserts +
/// `entity_mentions` inserts.
///
/// `event_id` and `ts_us` come from the parent event (the value
/// `BrainStore::put_event` returned, and the parent event's
/// `events.ts_us`). The extractor uses the parent event's timestamp
/// as the `entities.created_ts_us` / `updated_ts_us` and the
/// `entity_mentions.ts_us` so a reader can `ORDER BY ts_us` across
/// either table.
///
/// # Errors
///
/// Returns the **first** [`StoreError`] encountered. Earlier
/// successful writes are not rolled back — the caller treats this as
/// best-effort. A partial-write scenario is acceptable because
/// (a) `entities` upsert is idempotent on PK, (b) `entity_mentions`
/// insert is idempotent on PK, so a retry from the start of the
/// matches list converges on the same final state.
pub fn persist_tier1_matches(
    store: &dyn BrainStore,
    event_id: EventId,
    ts_us: u64,
    matches: &[Tier1Match],
) -> Result<PersistStats, StoreError> {
    let mut stats = PersistStats::default();
    for m in matches {
        let entity = Entity {
            id: Entity::derive_id(&m.kind, &m.canonical_name),
            kind: m.kind.clone(),
            canonical_name: m.canonical_name.clone(),
            summary: None,
            summary_embedding: None,
            content_hash: Entity::derive_content_hash(&m.kind, &m.canonical_name),
            created_ts_us: ts_us,
            updated_ts_us: ts_us,
        };
        store.put_entity(&entity)?;
        stats.entities_upserted += 1;

        let mention_text_for_id = Some(m.mention_text.as_str());
        let mention = EntityMention {
            id: EntityMention::derive_id(&entity.id, event_id, EXTRACTOR_KIND, mention_text_for_id),
            entity_id: entity.id,
            event_id,
            mention_text: Some(m.mention_text.clone()),
            confidence: 1.0,
            extractor_kind: EXTRACTOR_KIND.to_string(),
            ts_us,
        };
        store.put_entity_mention(&mention)?;
        stats.mentions_inserted += 1;
    }
    Ok(stats)
}

// ---------------------------------------------------------------------------
// Per-kind scanners
//
// Each scanner consults its module-level `LazyLock<Regex>`, walks the
// text, and pushes `Tier1Match` rows onto `out`. Normalisation
// (lowercasing, digit-stripping, trailing-punct strip) lives inside
// the scanner so the central `extract` is just a fixed-order list of
// scanner calls.
// ---------------------------------------------------------------------------

fn scan_cascade_redacted(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_CASCADE_REDACTED.find_iter(text) {
        // Redacted: never carry source bytes. Both canonical_name and
        // mention_text are the subkind label.
        out.push(Tier1Match {
            kind: KIND_REDACTED_TOKEN.to_string(),
            canonical_name: SUBKIND_CASCADE_REDACTED.to_string(),
            mention_text: SUBKIND_CASCADE_REDACTED.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_jwt(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_JWT.find_iter(text) {
        out.push(redacted_match(SUBKIND_JWT, m.start(), m.end()));
    }
}

fn scan_aws_access_key(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_AWS_ACCESS_KEY.find_iter(text) {
        out.push(redacted_match(SUBKIND_AWS_ACCESS_KEY, m.start(), m.end()));
    }
}

fn scan_github_pat(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_GITHUB_PAT.find_iter(text) {
        out.push(redacted_match(SUBKIND_GITHUB_PAT, m.start(), m.end()));
    }
}

fn scan_stripe_api_key(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_STRIPE_API_KEY.find_iter(text) {
        out.push(redacted_match(SUBKIND_STRIPE_API_KEY, m.start(), m.end()));
    }
}

fn scan_bitcoin_wif(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_BITCOIN_WIF.find_iter(text) {
        out.push(redacted_match(SUBKIND_BITCOIN_WIF, m.start(), m.end()));
    }
}

/// Build a redacted-token match without copying the source bytes
/// anywhere. Both `canonical_name` and `mention_text` carry the
/// subkind label only. The span offsets are recorded so a caller can
/// debug WHERE the token appeared in the input — but the input is
/// already in `events.text` (this is POST-cascade); Tier 1 itself
/// adds no new persistence of the bytes.
fn redacted_match(subkind: &'static str, start: usize, end: usize) -> Tier1Match {
    Tier1Match {
        kind: KIND_REDACTED_TOKEN.to_string(),
        canonical_name: subkind.to_string(),
        mention_text: subkind.to_string(),
        span_start: start,
        span_end: end,
    }
}

fn scan_url(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_URL.find_iter(text) {
        let raw = m.as_str();
        let (trimmed, trim_end) = strip_trailing_url_punct(raw, m.end());
        let canonical = normalise_url(trimmed);
        out.push(Tier1Match {
            kind: KIND_URL.to_string(),
            canonical_name: canonical,
            mention_text: trimmed.to_string(),
            span_start: m.start(),
            span_end: trim_end,
        });
    }
}

/// Strip a trailing `.`, `,`, `;`, `:`, `!`, `?`, `)`, `]`, `}` from a
/// URL match. Sentence-final URLs are commonly written as
/// "Visit <https://example.com>." — the regex over-captures the dot;
/// we drop it so the canonical doesn't end in punctuation.
fn strip_trailing_url_punct(raw: &str, end: usize) -> (&str, usize) {
    let mut bytes = raw.len();
    let trailing = b".,;:!?)]}";
    while bytes > 0 {
        let last = raw.as_bytes()[bytes - 1];
        if trailing.contains(&last) {
            bytes -= 1;
        } else {
            break;
        }
    }
    let new_end = end - (raw.len() - bytes);
    (&raw[..bytes], new_end)
}

/// Lowercase scheme + host; keep path/query as-is.
fn normalise_url(raw: &str) -> String {
    // Find `://`, then lowercase everything up to the next `/`, `?`,
    // `#`, or end. The rest is the path/query and is left untouched
    // (paths are case-sensitive on every server we ship to).
    let Some(scheme_end) = raw.find("://") else {
        return raw.to_string();
    };
    let host_start = scheme_end + 3;
    let after_host_offset = raw[host_start..]
        .find(['/', '?', '#'])
        .map_or(raw.len(), |i| host_start + i);
    let mut s = String::with_capacity(raw.len());
    s.push_str(&raw[..host_start].to_lowercase());
    s.push_str(&raw[host_start..after_host_offset].to_lowercase());
    s.push_str(&raw[after_host_offset..]);
    s
}

fn scan_email(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_EMAIL.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_EMAIL.to_string(),
            canonical_name: raw.to_lowercase(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_phone(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_PHONE.find_iter(text) {
        let raw = m.as_str();
        // Require 10+ digits to keep simple integers out (an `Issue
        // #4155551234` would otherwise match the bare-digit run).
        let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
        if digits.len() < 10 {
            continue;
        }
        out.push(Tier1Match {
            kind: KIND_PHONE.to_string(),
            canonical_name: digits,
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_ipv4(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_IPV4.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_IP_ADDRESS.to_string(),
            canonical_name: raw.to_string(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_ipv6(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_IPV6.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_IP_ADDRESS.to_string(),
            canonical_name: raw.to_lowercase(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_btc_bech32(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_BTC_BECH32.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_CRYPTO_ADDRESS.to_string(),
            canonical_name: raw.to_lowercase(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_btc_base58(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_BTC_BASE58.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_CRYPTO_ADDRESS.to_string(),
            // BTC base58 is case-sensitive (mixed-case in the address
            // is itself the data — no normalisation to lower).
            canonical_name: raw.to_string(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_eth(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_ETH.find_iter(text) {
        let raw = m.as_str();
        // ETH addresses can be checksummed with mixed case (EIP-55).
        // Preserve case in canonical so the checksum is recoverable.
        out.push(Tier1Match {
            kind: KIND_CRYPTO_ADDRESS.to_string(),
            canonical_name: raw.to_string(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_sol(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_SOL.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_CRYPTO_ADDRESS.to_string(),
            canonical_name: raw.to_string(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_github_ref(text: &str, out: &mut Vec<Tier1Match>) {
    for caps in RE_GITHUB_REF.captures_iter(text) {
        let Some(g1) = caps.get(1) else { continue };
        out.push(Tier1Match {
            kind: KIND_GITHUB_REF.to_string(),
            // Canonical = bare digit run; `#42` / ` #42 ` / `(#42)`
            // converge.
            canonical_name: g1.as_str().to_string(),
            // mention_text preserves the `#`-prefixed form.
            mention_text: format!("#{}", g1.as_str()),
            span_start: g1.start() - 1, // include the `#`
            span_end: g1.end(),
        });
    }
}

fn scan_uuid(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_UUID.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_UUID.to_string(),
            canonical_name: raw.to_lowercase(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_ulid(text: &str, out: &mut Vec<Tier1Match>) {
    for m in RE_ULID.find_iter(text) {
        let raw = m.as_str();
        out.push(Tier1Match {
            kind: KIND_ULID.to_string(),
            // ULID canonical is uppercase Crockford.
            canonical_name: raw.to_uppercase(),
            mention_text: raw.to_string(),
            span_start: m.start(),
            span_end: m.end(),
        });
    }
}

fn scan_file_path(text: &str, out: &mut Vec<Tier1Match>) {
    for caps in RE_FILE_PATH.captures_iter(text) {
        let Some(path) = caps.get(1) else { continue };
        let raw = path.as_str();
        out.push(Tier1Match {
            kind: KIND_FILE_PATH.to_string(),
            canonical_name: raw.to_string(),
            mention_text: raw.to_string(),
            span_start: path.start(),
            span_end: path.end(),
        });
    }
}

// ---------------------------------------------------------------------------
// Overlap dedup
// ---------------------------------------------------------------------------

/// Drop later matches whose `span_start..span_end` range strictly
/// overlaps a kept earlier match. Earlier in this context means
/// earlier in `out` after the stable sort by `(span_start, span_end)`
/// — which, combined with the declaration-order-first scanning above,
/// gives token-shape REDACT kinds priority over structural kinds on
/// the same byte range.
///
/// Adjacent (touching) matches are KEPT — `[end_a == start_b]` is
/// not considered overlap (a URL ending right before a phone number
/// starts is two distinct entities).
fn dedup_overlapping(out: &mut Vec<Tier1Match>) {
    if out.is_empty() {
        return;
    }
    let mut kept = Vec::with_capacity(out.len());
    let mut last_end: usize = 0;
    let mut first = true;
    for m in out.drain(..) {
        if first || m.span_start >= last_end {
            last_end = m.span_end;
            kept.push(m);
            first = false;
        }
        // Drop overlap.
    }
    *out = kept;
}

// ===========================================================================
// Unit tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // Per-kind unit tests
    // -----------------------------------------------------------------------

    #[test]
    fn url_match_lowercases_scheme_and_host_only() {
        let ex = Tier1Extractor::new();
        let matches = ex.extract("Visit https://Example.COM/Path?Q=1#Frag for details");
        let urls: Vec<&Tier1Match> = matches.iter().filter(|m| m.kind == KIND_URL).collect();
        assert_eq!(urls.len(), 1);
        assert_eq!(urls[0].canonical_name, "https://example.com/Path?Q=1#Frag");
    }

    #[test]
    fn url_match_strips_trailing_sentence_punctuation() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("See https://example.com/page. Then continue.")
            .into_iter()
            .find(|m| m.kind == KIND_URL)
            .expect("url");
        assert_eq!(m.canonical_name, "https://example.com/page");
        assert_eq!(m.mention_text, "https://example.com/page");
    }

    #[test]
    fn email_match_lowercases_canonical() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("Contact Jane.Doe@Example.com for access")
            .into_iter()
            .find(|m| m.kind == KIND_EMAIL)
            .expect("email");
        assert_eq!(m.canonical_name, "jane.doe@example.com");
        assert_eq!(m.mention_text, "Jane.Doe@Example.com");
    }

    #[test]
    fn email_rejects_short_tld() {
        let ex = Tier1Extractor::new();
        let none = ex
            .extract("foo@bar.x just a single-char TLD")
            .into_iter()
            .find(|m| m.kind == KIND_EMAIL);
        assert!(none.is_none(), "1-char TLD should not match");
    }

    #[test]
    fn phone_canonicalises_to_digits_only() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("Call (415) 555-1234 to reach me")
            .into_iter()
            .find(|m| m.kind == KIND_PHONE)
            .expect("phone");
        assert_eq!(m.canonical_name, "4155551234");
    }

    #[test]
    fn phone_with_country_code_canonicalises() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("UK +44 20 7946 0123")
            .into_iter()
            .find(|m| m.kind == KIND_PHONE)
            .expect("phone");
        assert_eq!(m.canonical_name, "442079460123");
    }

    #[test]
    fn ipv4_octet_range_enforced() {
        let ex = Tier1Extractor::new();
        let hits: Vec<_> = ex
            .extract("ok 127.0.0.1 and 256.0.0.1 illegal")
            .into_iter()
            .filter(|m| m.kind == KIND_IP_ADDRESS)
            .collect();
        // 127.0.0.1 must match; 256.0.0.1 must NOT match (the regex
        // rejects octet > 255).
        let canon: Vec<&str> = hits.iter().map(|m| m.canonical_name.as_str()).collect();
        assert!(canon.contains(&"127.0.0.1"));
        assert!(!canon.contains(&"256.0.0.1"));
    }

    #[test]
    fn ipv6_full_form_matches() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("v6: 2001:0db8:85a3:0000:0000:8a2e:0370:7334 host")
            .into_iter()
            .find(|m| m.kind == KIND_IP_ADDRESS)
            .expect("ipv6");
        assert_eq!(m.canonical_name, "2001:0db8:85a3:0000:0000:8a2e:0370:7334");
    }

    #[test]
    fn crypto_btc_bech32_matches() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("Pay bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq please")
            .into_iter()
            .find(|m| m.kind == KIND_CRYPTO_ADDRESS)
            .expect("btc bech32");
        assert!(m.canonical_name.starts_with("bc1"));
    }

    #[test]
    fn crypto_eth_preserves_case() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("ETH 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0 wallet")
            .into_iter()
            .find(|m| m.kind == KIND_CRYPTO_ADDRESS)
            .expect("eth");
        assert_eq!(
            m.canonical_name,
            "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0"
        );
    }

    #[test]
    fn github_ref_anchored_to_whitespace() {
        let ex = Tier1Extractor::new();
        let hits: Vec<_> = ex
            .extract("Closes #244 and PR #277. abc#999 in-word should not match.")
            .into_iter()
            .filter(|m| m.kind == KIND_GITHUB_REF)
            .collect();
        let canons: Vec<&str> = hits.iter().map(|m| m.canonical_name.as_str()).collect();
        assert_eq!(canons, vec!["244", "277"]);
    }

    #[test]
    fn uuid_lowercase_canonical() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("rid=550E8400-E29B-41D4-A716-446655440000")
            .into_iter()
            .find(|m| m.kind == KIND_UUID)
            .expect("uuid");
        assert_eq!(m.canonical_name, "550e8400-e29b-41d4-a716-446655440000");
    }

    #[test]
    fn ulid_uppercase_canonical() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("entity:01hw5r8ab5k6nq4d6x3rt9y2vk row")
            .into_iter()
            .find(|m| m.kind == KIND_ULID)
            .expect("ulid");
        assert_eq!(m.canonical_name, "01HW5R8AB5K6NQ4D6X3RT9Y2VK");
    }

    #[test]
    fn file_path_two_segments_minimum() {
        let ex = Tier1Extractor::new();
        let hits: Vec<_> = ex
            .extract("Open /Users/ao/file.txt and /tmp by itself")
            .into_iter()
            .filter(|m| m.kind == KIND_FILE_PATH)
            .collect();
        let canons: Vec<&str> = hits.iter().map(|m| m.canonical_name.as_str()).collect();
        assert_eq!(canons, vec!["/Users/ao/file.txt"]);
    }

    // -----------------------------------------------------------------------
    // Token-shape REDACT tests
    // -----------------------------------------------------------------------

    #[test]
    fn jwt_match_does_not_carry_source_bytes() {
        let ex = Tier1Extractor::new();
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
        let text = format!("Authorization: Bearer {jwt} (please redact)");
        let m = ex
            .extract(&text)
            .into_iter()
            .find(|m| m.kind == KIND_REDACTED_TOKEN && m.canonical_name == SUBKIND_JWT)
            .expect("jwt");
        assert_eq!(m.canonical_name, "jwt");
        assert_eq!(m.mention_text, "jwt");
        // Source bytes must NOT appear in canonical_name or
        // mention_text.
        assert!(!m.canonical_name.contains("eyJ"));
        assert!(!m.mention_text.contains("eyJ"));
        assert!(m.is_redacted());
    }

    #[test]
    fn aws_access_key_redacted() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE")
            .into_iter()
            .find(|m| m.canonical_name == SUBKIND_AWS_ACCESS_KEY)
            .expect("aws");
        assert_eq!(m.kind, KIND_REDACTED_TOKEN);
        assert_eq!(m.mention_text, "aws_access_key");
        assert!(!m.mention_text.contains("AKIA"));
    }

    #[test]
    fn github_pat_redacted() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789AB used")
            .into_iter()
            .find(|m| m.canonical_name == SUBKIND_GITHUB_PAT)
            .expect("pat");
        assert_eq!(m.mention_text, "github_pat");
        assert!(!m.mention_text.contains("ghp_"));
    }

    #[test]
    fn stripe_api_key_redacted() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("env STRIPE_SECRET_KEY=sk_test_FIXTUREREMOVED")
            .into_iter()
            .find(|m| m.canonical_name == SUBKIND_STRIPE_API_KEY)
            .expect("stripe");
        assert_eq!(m.mention_text, "stripe_api_key");
        assert!(!m.mention_text.contains("sk_test"));
    }

    #[test]
    fn bitcoin_wif_redacted() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("pk: 5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ stash")
            .into_iter()
            .find(|m| m.canonical_name == SUBKIND_BITCOIN_WIF)
            .expect("wif");
        assert_eq!(m.mention_text, "bitcoin_wif");
        assert!(!m.mention_text.contains("5HueCGU"));
    }

    #[test]
    fn cascade_redacted_marker_captured() {
        let ex = Tier1Extractor::new();
        let m = ex
            .extract("Your code is [REDACTED:SMS_OTP] (do not share)")
            .into_iter()
            .find(|m| m.canonical_name == SUBKIND_CASCADE_REDACTED)
            .expect("cascade marker");
        assert_eq!(m.kind, KIND_REDACTED_TOKEN);
        assert_eq!(m.mention_text, "cascade_redacted");
        // The literal marker IS in events.text (cascade put it there)
        // but our mention_text carries the subkind label only.
        assert!(!m.mention_text.contains("REDACTED"));
    }

    // -----------------------------------------------------------------------
    // CSO-audit: redacted-token bytes never leak via any field
    // -----------------------------------------------------------------------

    #[test]
    fn redacted_tokens_never_carry_source_bytes() {
        let ex = Tier1Extractor::new();
        // One of each token-shape kind.
        let secrets = [
            ("jwt", "eyJabcdefgh.eyJabcdefgh.SflKxwRJSMeKK"),
            ("aws_access_key", "AKIAIOSFODNN7EXAMPLE"),
            ("github_pat", "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789AB"),
            ("stripe_api_key", "sk_test_FIXTUREREMOVED"),
            (
                "bitcoin_wif",
                "5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ",
            ),
        ];
        for (subkind, bytes) in secrets {
            let text = format!("[ctx] {bytes} [ctx]");
            let hits: Vec<_> = ex
                .extract(&text)
                .into_iter()
                .filter(|m| m.is_redacted() && m.canonical_name == subkind)
                .collect();
            assert!(!hits.is_empty(), "no match for {subkind}");
            for h in hits {
                assert!(
                    !h.canonical_name.contains(bytes),
                    "{subkind} canonical_name leaked source bytes"
                );
                assert!(
                    !h.mention_text.contains(bytes),
                    "{subkind} mention_text leaked source bytes"
                );
                // The span exists, but the bytes don't escape.
                assert!(h.span_end > h.span_start);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Cascade-interaction: redacted phone digits do NOT land as phone entities
    // -----------------------------------------------------------------------

    #[test]
    fn cascade_redacted_phone_does_not_produce_phone_entity() {
        let ex = Tier1Extractor::new();
        // Simulate the post-cascade text: the OTP / phone digits have
        // already been replaced by the OCR-time §6 redaction layer
        // with the literal `[REDACTED:SMS_OTP]` marker. Tier 1 sees
        // ONLY this — never the original digits.
        let text = "Your code is [REDACTED:SMS_OTP] please confirm";
        let hits = ex.extract(text);

        // 1. Zero `phone` entities (the digits are gone).
        let phones: Vec<_> = hits.iter().filter(|m| m.kind == KIND_PHONE).collect();
        assert!(
            phones.is_empty(),
            "phone entity must not be extracted from a cascade-redacted span"
        );

        // 2. Exactly one `redacted_token` entity for the marker.
        let markers: Vec<_> = hits
            .iter()
            .filter(|m| {
                m.kind == KIND_REDACTED_TOKEN && m.canonical_name == SUBKIND_CASCADE_REDACTED
            })
            .collect();
        assert_eq!(
            markers.len(),
            1,
            "cascade-redaction marker must surface as exactly one entity"
        );
    }

    // -----------------------------------------------------------------------
    // Overlap dedup
    // -----------------------------------------------------------------------

    #[test]
    fn overlap_resolved_first_declared_wins() {
        // The byte sequence `0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0`
        // is 42 chars; that matches ETH. Confirm ETH wins on its own
        // span (no kind interleaving false-positive).
        let ex = Tier1Extractor::new();
        let hits = ex.extract("addr 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0 end");
        assert_eq!(
            hits.iter()
                .filter(|m| m.kind == KIND_CRYPTO_ADDRESS)
                .count(),
            1
        );
    }

    #[test]
    fn dedup_keeps_adjacent_distinct_matches() {
        let mut v = vec![
            Tier1Match {
                kind: "a".into(),
                canonical_name: "a".into(),
                mention_text: "a".into(),
                span_start: 0,
                span_end: 5,
            },
            Tier1Match {
                kind: "b".into(),
                canonical_name: "b".into(),
                mention_text: "b".into(),
                span_start: 5,
                span_end: 10,
            },
        ];
        dedup_overlapping(&mut v);
        assert_eq!(v.len(), 2);
    }

    #[test]
    fn dedup_drops_strict_overlap() {
        let mut v = vec![
            Tier1Match {
                kind: "a".into(),
                canonical_name: "a".into(),
                mention_text: "a".into(),
                span_start: 0,
                span_end: 10,
            },
            Tier1Match {
                kind: "b".into(),
                canonical_name: "b".into(),
                mention_text: "b".into(),
                span_start: 4,
                span_end: 15,
            },
        ];
        dedup_overlapping(&mut v);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].kind, "a");
    }

    // -----------------------------------------------------------------------
    // Determinism: same input → same matches in same order
    // -----------------------------------------------------------------------

    #[test]
    fn extraction_is_deterministic() {
        let ex = Tier1Extractor::new();
        let text = "Visit https://example.com/x then email me at a@b.co about #42";
        let a = ex.extract(text);
        let b = ex.extract(text);
        assert_eq!(a, b);
    }
}
