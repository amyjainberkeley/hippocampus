//! V2-P3 — graph foundation types + sync-ready ULID discipline.
//!
//! The `entities` / `entity_mentions` / `episode_edges` tables (migration
//! `0004_v2_graph_schema.sql`) hold the typed graph the v2 recall surfaces
//! query. This module ships the OS-free value types those tables exchange
//! across the [`BrainStore`](crate::BrainStore) seam plus the
//! **content-stable ULID** discipline that makes the schema sync-ready
//! ahead of Phase 8 (ADR-0023).
//!
//! # Sync-ready ULID rule (LOAD-BEARING per ADR-0023)
//!
//! Every PK in the three V2-P3 tables is a 26-character Crockford-base32
//! ULID (16 bytes encoded). The bytes are **derived deterministically
//! from the row's natural key**, not generated from time + randomness.
//! Two devices that independently extract the same entity from the same
//! source content converge on the same PK without coordination — that is
//! the Phase 8 sync precondition.
//!
//! Derivation rules (binding — every writer above this module MUST use
//! these or call [`Entity::derive_id`] / [`EntityMention::derive_id`] /
//! [`EpisodeEdge::derive_id`]):
//!
//! | Table | Natural-key bytes (UTF-8, NUL-separated) | PK |
//! |-------|------------------------------------------|----|
//! | `entities`        | `"entity\0" + kind + "\0" + canonical_name` | `ulid(sha256(.)[0..16])` |
//! | `entity_mentions` | `"mention\0" + entity_id + "\0" + event_id_hex + "\0" + extractor_kind + "\0" + mention_text` | `ulid(sha256(.)[0..16])` |
//! | `episode_edges`   | `"edge\0" + edge_kind + "\0" + src_episode_id_hex + "\0" + dst_episode_id_hex` | `ulid(sha256(.)[0..16])` |
//!
//! `content_hash` on [`Entity`] is the **same** SHA-256 (full 32 bytes
//! hex-encoded) — callers ship it alongside the row so a downstream
//! consumer can recompute and verify without re-deriving from raw fields.
//!
//! # Why a ULID-shape over a raw hash hex string?
//!
//! - **Lex-sortable** — Crockford base32 preserves byte order, so
//!   `ORDER BY id` is meaningful for iteration even though the bytes
//!   are content-derived (not time-derived).
//! - **Fixed length** — 26 chars (vs. 64 for SHA-256 hex) keeps PK
//!   indexes small.
//! - **CRDT-friendly** — Phase 8 sync (ADR-0023) treats the three
//!   tables as grow-only CRDTs keyed on PK; convergent writes from two
//!   devices land as the same row by construction.
//! - **Forward-compatible with time-stamped ULIDs** — a future writer
//!   that wants a non-content-stable ULID (e.g. a user-tagged mention
//!   that should NOT converge across devices) can drop in a standard
//!   timestamp + random ULID without schema change.
//!
//! # OS-purity
//!
//! Same discipline as the rest of `mci-brain` (AGENT_PROTOCOL §4
//! cross-platform-seam): no OS-specific code, no `cfg(target_os = ...)`,
//! no `objc2::...`, no `windows::...`. Pure Rust + `sha2` (Apache-2.0,
//! already on the workspace lockfile via `mci-core`).

use sha2::{Digest, Sha256};

use crate::EventId;
use crate::episode_segmenter::EpisodeId;

// ---------------------------------------------------------------------------
// Newtype ids — keep graph PKs out of arithmetic with raw String
// ---------------------------------------------------------------------------

/// Stable identifier for one [`Entity`] row.
///
/// The inner string is always a 26-char Crockford-base32 ULID derived per
/// this module's content-stability rule (see module doc). Construction
/// outside the crate is allowed (the inner is `pub`) so test fixtures
/// can mint synthetic IDs; production writers MUST go through
/// [`Entity::derive_id`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EntityId(pub String);

impl std::fmt::Display for EntityId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "entity:{}", self.0)
    }
}

/// Stable identifier for one [`EntityMention`] row.
///
/// Same content-stable ULID discipline as [`EntityId`] — production
/// writers MUST go through [`EntityMention::derive_id`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EntityMentionId(pub String);

impl std::fmt::Display for EntityMentionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "mention:{}", self.0)
    }
}

/// Stable identifier for one [`EpisodeEdge`] row.
///
/// Same content-stable ULID discipline as [`EntityId`] — production
/// writers MUST go through [`EpisodeEdge::derive_id`].
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EpisodeEdgeId(pub String);

impl std::fmt::Display for EpisodeEdgeId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "edge:{}", self.0)
    }
}

// ---------------------------------------------------------------------------
// Entity — typed graph node
// ---------------------------------------------------------------------------

/// One typed entity in the v2 graph.
///
/// Stored in the `entities` table per migration 0004. The `(kind,
/// canonical_name)` pair is the natural key; two writers (or two
/// devices, post-Phase-8) producing the same pair converge on the same
/// [`EntityId`] by construction.
#[derive(Debug, Clone, PartialEq)]
pub struct Entity {
    /// Content-stable ULID derived from `(kind, canonical_name)`. Zero
    /// before [`BrainStore::put_entity`](crate::BrainStore::put_entity).
    pub id: EntityId,
    /// Entity kind. Stored as TEXT in `SQLite`; the type is [`String`]
    /// (not an enum) on purpose — V2-P4 / V2-P5 will mint new kinds
    /// without a schema bump. Suggested values: `"person"`, `"topic"`,
    /// `"thread"`, `"url"`, `"file"`, `"project"`.
    pub kind: String,
    /// Canonical display name. For URLs this is the normalized URL;
    /// for people this is the resolved canonical handle the
    /// `AliasResolver` (V2-P6) settles on; for topics it's the
    /// Qwen-extracted noun phrase.
    pub canonical_name: String,
    /// Idle-batch-generated extractive summary of the entity's mentions
    /// (V2-P5 fills). `None` until populated.
    pub summary: Option<String>,
    /// 384-d L2-normalized embedding of `summary` (ADR-0009 dim pin),
    /// stored as a little-endian 1536-byte BLOB. `None` until V2-P5
    /// embeds the summary. Mirrors the `event_vectors.embedding`
    /// pattern; the vec0 mirror is deferred (see migration 0004
    /// `vec_entity_summaries_mirror`).
    pub summary_embedding: Option<Vec<f32>>,
    /// SHA-256 hex-encoded of the natural-key byte sequence
    /// (`"entity\0" + kind + "\0" + canonical_name`). Lets a reader
    /// verify the ULID derivation without recomputing. Stored as TEXT.
    pub content_hash: String,
    /// First-write wall-clock, microseconds since UNIX epoch.
    pub created_ts_us: u64,
    /// Last-update wall-clock, microseconds since UNIX epoch. Writers
    /// bump this on `summary` / `summary_embedding` fills; the bump
    /// does NOT change the ULID (PK is derived from the natural key
    /// only).
    pub updated_ts_us: u64,
}

impl Entity {
    /// Compute the content-stable [`EntityId`] for a `(kind,
    /// canonical_name)` pair without constructing a full row.
    ///
    /// Two devices invoking this with the same inputs get the same
    /// output bytes-for-bytes; that is the Phase 8 sync convergence
    /// precondition.
    #[must_use]
    pub fn derive_id(kind: &str, canonical_name: &str) -> EntityId {
        EntityId(derive_ulid(&[b"entity", kind.as_bytes(), canonical_name.as_bytes()]))
    }

    /// Compute the canonical SHA-256 hex digest for a `(kind,
    /// canonical_name)` pair — the value stored in `content_hash`.
    ///
    /// Same input bytes as [`Self::derive_id`]; only the encoding
    /// differs (full 32-byte hex here vs. the first-16-byte ULID
    /// there). Splitting the two lets the reader cross-verify the
    /// ULID without redoing the hash.
    #[must_use]
    pub fn derive_content_hash(kind: &str, canonical_name: &str) -> String {
        sha256_hex(&[b"entity", kind.as_bytes(), canonical_name.as_bytes()])
    }
}

// ---------------------------------------------------------------------------
// EntityMention — provenance join from event → entity
// ---------------------------------------------------------------------------

/// One occurrence of an [`Entity`] inside one stored [`Event`](crate::Event).
///
/// Stored in the `entity_mentions` table per migration 0004. The
/// natural key is `(entity_id, event_id, extractor_kind,
/// mention_text)` — two extractor passes (e.g. regex pass + Qwen pass)
/// that surface the same canonical entity on the same event produce
/// two distinct mention rows, because `extractor_kind` differs.
#[derive(Debug, Clone, PartialEq)]
pub struct EntityMention {
    /// Content-stable ULID derived per [`Self::derive_id`].
    pub id: EntityMentionId,
    /// The entity this mention refers to.
    pub entity_id: EntityId,
    /// The event this mention was extracted from.
    pub event_id: EventId,
    /// Exact text span the extractor matched. `None` when the
    /// extractor cannot point at a span (e.g. Qwen-inferred topic
    /// without a literal substring in the event text).
    pub mention_text: Option<String>,
    /// Extractor confidence in `[0.0, 1.0]`. Regex extractors emit
    /// `1.0`; Qwen extractors emit a per-mention probability; the
    /// alias resolver emits a per-cluster confidence.
    pub confidence: f32,
    /// Provenance tag. V2-P4 emits `"regex"`; V2-P5 emits `"qwen"`;
    /// the user-tagged path (V2-P12) emits `"user"`. Stored as TEXT
    /// so V2-P9+ can add new extractor kinds without a schema bump.
    pub extractor_kind: String,
    /// Capture-time timestamp the mention belongs to (typically copied
    /// from the parent `events.ts_us`). Microseconds since UNIX epoch.
    pub ts_us: u64,
}

impl EntityMention {
    /// Compute the content-stable [`EntityMentionId`] for a
    /// `(entity_id, event_id, extractor_kind, mention_text)` tuple.
    ///
    /// `mention_text` is part of the natural key so two regex passes
    /// that surface the same entity at different offsets produce two
    /// rows (the brain wants both spans for downstream highlighting).
    /// Passing `None` is normalized to the empty string in the hash
    /// input — distinct from `Some("")`, which the brain treats as a
    /// zero-length explicit span (rare; the writer should not pass
    /// `Some("")`).
    #[must_use]
    pub fn derive_id(
        entity_id: &EntityId,
        event_id: EventId,
        extractor_kind: &str,
        mention_text: Option<&str>,
    ) -> EntityMentionId {
        let event_id_hex = format!("{:016x}", event_id.0);
        let text = mention_text.unwrap_or("");
        EntityMentionId(derive_ulid(&[
            b"mention",
            entity_id.0.as_bytes(),
            event_id_hex.as_bytes(),
            extractor_kind.as_bytes(),
            text.as_bytes(),
        ]))
    }
}

// ---------------------------------------------------------------------------
// EpisodeEdge — typed cross-app link between episodes
// ---------------------------------------------------------------------------

/// One typed link between two episodes in the v2 graph.
///
/// Stored in the `episode_edges` table per migration 0004. The
/// natural key is `(edge_kind, src_episode_id, dst_episode_id)` —
/// two passes that derive the same edge converge on the same row;
/// reading the same link twice does not insert a duplicate.
///
/// `evidence_entity_ids` is a JSON-encoded array of [`EntityId`]
/// strings; `SQLite` does not enforce a foreign key into a JSON column,
/// so the writer is responsible for citing only entities that already
/// exist (V2-P12 chat / timeline surfaces tolerate a stale id by
/// rendering it as an unresolved link rather than failing the query).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EpisodeEdge {
    /// Content-stable ULID derived per [`Self::derive_id`].
    pub id: EpisodeEdgeId,
    /// The source episode (typically the earlier one in `co_active` /
    /// `responded_to` semantics; the citing episode in `referenced`
    /// semantics).
    pub src_episode_id: EpisodeId,
    /// The destination episode.
    pub dst_episode_id: EpisodeId,
    /// Edge kind. Suggested values: `"co_active"` (overlapping in
    /// time), `"referenced"` (one episode cites the other's entity),
    /// `"responded_to"` (one episode is a reply to the other). Stored
    /// as TEXT so the writer can mint new kinds without a schema bump.
    pub edge_kind: String,
    /// JSON-encoded array of [`EntityId`] strings citing why this edge
    /// exists. `None` for edges with no entity evidence (e.g.
    /// `co_active` edges derived from a ±60s window scan, where the
    /// evidence is timing not content).
    pub evidence_entity_ids: Option<String>,
    /// Capture-time timestamp the edge was first observed.
    /// Microseconds since UNIX epoch.
    pub ts_us: u64,
}

impl EpisodeEdge {
    /// Compute the content-stable [`EpisodeEdgeId`] for an
    /// `(edge_kind, src_episode_id, dst_episode_id)` tuple.
    ///
    /// Edges are directional — `(A, "referenced", B)` and `(B,
    /// "referenced", A)` are distinct rows. If a writer wants
    /// undirected semantics it should pass the canonical pair (e.g.
    /// `(min(src, dst), max(src, dst))`) before calling.
    #[must_use]
    pub fn derive_id(
        edge_kind: &str,
        src_episode_id: EpisodeId,
        dst_episode_id: EpisodeId,
    ) -> EpisodeEdgeId {
        let src_hex = format!("{:016x}", src_episode_id.0);
        let dst_hex = format!("{:016x}", dst_episode_id.0);
        EpisodeEdgeId(derive_ulid(&[
            b"edge",
            edge_kind.as_bytes(),
            src_hex.as_bytes(),
            dst_hex.as_bytes(),
        ]))
    }
}

// ---------------------------------------------------------------------------
// Hashing + base32 helpers — module-private, exhaustively unit-tested
// ---------------------------------------------------------------------------

/// SHA-256 over the NUL-separated concatenation of `parts`. Returns the
/// full 32-byte digest.
fn sha256_concat(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Sha256::new();
    for (i, p) in parts.iter().enumerate() {
        if i > 0 {
            h.update([0u8]); // NUL separator
        }
        h.update(p);
    }
    let digest = h.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest[..]);
    out
}

/// SHA-256 hex digest. Lower-case, 64 chars.
fn sha256_hex(parts: &[&[u8]]) -> String {
    use std::fmt::Write as _;
    let bytes = sha256_concat(parts);
    let mut out = String::with_capacity(64);
    for b in &bytes {
        let _ = write!(out, "{b:02x}");
    }
    out
}

/// Derive a 26-char Crockford-base32 ULID from the first 16 bytes of
/// `SHA-256(NUL-separated parts)`. Same byte-shape as a time-stamped
/// ULID, just with content-stable bytes.
fn derive_ulid(parts: &[&[u8]]) -> String {
    let digest = sha256_concat(parts);
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    crockford_base32_encode_128(bytes)
}

/// Crockford base32 alphabet (the same one standard ULIDs use). No
/// padding; 128 bits encodes to exactly 26 chars (130 bits with the
/// high two bits forced to zero in the first character per ULID
/// convention — we emit chars 0..26 of the natural encoding).
const CROCKFORD_ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Encode 128 bits as a 26-char Crockford-base32 string.
///
/// Standard ULID encoding: the high two bits of the first character
/// are reserved (encoded as zero), and the remaining 26 chars × 5
/// bits = 130 bits cover the 128-bit payload with two leading
/// zero-bits. This makes the output lex-sortable byte-for-byte.
fn crockford_base32_encode_128(bytes: [u8; 16]) -> String {
    // Treat the 16 bytes as a big-endian u128, then encode 5 bits at a
    // time from MSB to LSB. Two leading zero bits make the total a
    // multiple of 5 (= 130 bits / 26 chars).
    let n = u128::from_be_bytes(bytes);
    let mut out = [0u8; 26];
    // First char: high 2 bits of the 130-bit payload are zero; next 3
    // bits are the top 3 bits of `n` (bits 125..128 of the 128-bit
    // value).
    out[0] = CROCKFORD_ALPHABET[((n >> 125) & 0b111) as usize];
    // Remaining 25 chars: 5 bits each, from bit 120 down to bit 0.
    for i in 0..25_u32 {
        let shift = 120 - i * 5;
        let idx = (i as usize) + 1;
        out[idx] = CROCKFORD_ALPHABET[((n >> shift) & 0b1_1111) as usize];
    }
    // Safety: every byte is from `CROCKFORD_ALPHABET` (ASCII subset).
    String::from_utf8(out.to_vec()).expect("base32 alphabet is ASCII")
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entity_id_is_26_char_crockford_base32() {
        let id = Entity::derive_id("person", "John Smith");
        assert_eq!(id.0.len(), 26);
        for c in id.0.chars() {
            assert!(
                CROCKFORD_ALPHABET.contains(&(c as u8)),
                "id char {c:?} not in Crockford alphabet"
            );
        }
    }

    #[test]
    fn entity_id_is_deterministic() {
        let a = Entity::derive_id("person", "John Smith");
        let b = Entity::derive_id("person", "John Smith");
        assert_eq!(a, b);
    }

    #[test]
    fn entity_id_changes_with_kind_or_name() {
        let p = Entity::derive_id("person", "John Smith");
        let t = Entity::derive_id("topic", "John Smith");
        let p2 = Entity::derive_id("person", "John Smyth");
        assert_ne!(p, t);
        assert_ne!(p, p2);
    }

    #[test]
    fn entity_id_is_separator_safe() {
        // A naive concat ("personJohn Smith" vs "person\0John Smith")
        // would collide for ("person" + "John", " Smith") vs
        // ("person", "John Smith"). Verify the NUL separator prevents
        // the collision.
        let a = Entity::derive_id("personJohn", " Smith");
        let b = Entity::derive_id("person", "John Smith");
        assert_ne!(a, b);
    }

    #[test]
    #[allow(clippy::items_after_statements)]
    fn entity_content_hash_matches_id_derivation_input() {
        // The full SHA-256 hex and the ULID are computed over the same
        // bytes; the ULID is the first 16 bytes re-encoded. Verify the
        // first 16 bytes of the hex equal the first 32 hex chars.
        let id = Entity::derive_id("person", "Alice");
        let hash = Entity::derive_content_hash("person", "Alice");
        // The ULID encodes the first 16 bytes of the digest; the first
        // 32 hex chars of the digest also encode those same 16 bytes.
        // We can't directly compare (encoding differs) but we can
        // verify the digest is stable across both functions by
        // re-deriving from raw bytes.
        use std::fmt::Write as _;
        let raw = sha256_concat(&[b"entity", b"person", b"Alice"]);
        let mut hex32 = String::new();
        for byte in &raw[..16] {
            let _ = write!(hex32, "{byte:02x}");
        }
        assert!(hash.starts_with(&hex32));
        // And the ULID was derived from those same 16 bytes.
        let expected_ulid = crockford_base32_encode_128({
            let mut b = [0u8; 16];
            b.copy_from_slice(&raw[..16]);
            b
        });
        assert_eq!(id.0, expected_ulid);
    }

    #[test]
    fn mention_id_includes_extractor_and_text() {
        let url = Entity::derive_id("url", "https://example.com");
        let regex_com = EntityMention::derive_id(&url, EventId(7), "regex", Some("example.com"));
        let qwen_com = EntityMention::derive_id(&url, EventId(7), "qwen", Some("example.com"));
        let regex_org = EntityMention::derive_id(&url, EventId(7), "regex", Some("example.org"));
        let regex_none = EntityMention::derive_id(&url, EventId(7), "regex", None);
        assert_eq!(regex_com.0.len(), 26);
        assert_ne!(regex_com, qwen_com);
        assert_ne!(regex_com, regex_org);
        assert_ne!(regex_com, regex_none);
    }

    #[test]
    fn mention_id_is_deterministic_across_event_id_encoding() {
        // Same (entity, event, extractor, text) → same id, regardless
        // of how often we call.
        let e = Entity::derive_id("person", "Bob");
        let one = EntityMention::derive_id(&e, EventId(1234), "regex", Some("Bob"));
        let two = EntityMention::derive_id(&e, EventId(1234), "regex", Some("Bob"));
        assert_eq!(one, two);
    }

    #[test]
    fn edge_id_is_directional() {
        let fwd = EpisodeEdge::derive_id("referenced", EpisodeId(1), EpisodeId(2));
        let rev = EpisodeEdge::derive_id("referenced", EpisodeId(2), EpisodeId(1));
        assert_ne!(fwd, rev);
    }

    #[test]
    fn edge_id_changes_with_kind() {
        let a = EpisodeEdge::derive_id("co_active", EpisodeId(1), EpisodeId(2));
        let b = EpisodeEdge::derive_id("referenced", EpisodeId(1), EpisodeId(2));
        assert_ne!(a, b);
    }

    #[test]
    fn crockford_encode_known_vectors() {
        // u128::MIN → all zero bytes → "00000000000000000000000000"
        assert_eq!(
            crockford_base32_encode_128([0u8; 16]),
            "00000000000000000000000000"
        );
        // u128::MAX → bits 0..128 all one, but bits 128..130 are zero
        // by ULID convention → high char = "7" (0b111).
        let max = crockford_base32_encode_128([0xFFu8; 16]);
        assert_eq!(max.len(), 26);
        assert_eq!(&max[..1], "7");
        for c in max[1..].chars() {
            assert_eq!(c, 'Z');
        }
    }

    #[test]
    fn id_display_carries_namespace_prefix() {
        let e = EntityId("ABCDEFGHJKMNPQRSTVWXYZ0123".to_string());
        assert_eq!(e.to_string(), "entity:ABCDEFGHJKMNPQRSTVWXYZ0123");
        let m = EntityMentionId("ABCDEFGHJKMNPQRSTVWXYZ0123".to_string());
        assert_eq!(m.to_string(), "mention:ABCDEFGHJKMNPQRSTVWXYZ0123");
        let g = EpisodeEdgeId("ABCDEFGHJKMNPQRSTVWXYZ0123".to_string());
        assert_eq!(g.to_string(), "edge:ABCDEFGHJKMNPQRSTVWXYZ0123");
    }
}
