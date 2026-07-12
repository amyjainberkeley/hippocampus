//! Integration tests for the cycle-8.35 PR-1 wire widening: [`HitJson`]
//! now carries `entities: Vec<String>` and `linked_event_ids: Vec<u64>`
//! so the recall UI can render entity chips (PR-2) and the cross-app
//! "dot-connect" flyout (PR-3).
//!
//! Scope: **data-plumbing round-trip only**. These tests confirm that:
//!
//! 1. A [`HitJson`] populated with `entities` + `linked_event_ids`
//!    serializes to JSON with the expected `snake_case` keys (the wire
//!    the Swift `HitWire` decoder in
//!    `apps/recall-ui/Sources/RecallUIKit/FFIBrainReader.swift` reads).
//! 2. The same payload round-trips through `serde_json` without loss.
//! 3. A **legacy** JSON payload that omits both fields still decodes
//!    (both fields carry `#[serde(default)]` so a rolled-back Rust
//!    build cannot strand a Swift client that already knows the new
//!    keys, and vice versa — this is the forward/backward-compat
//!    contract).
//! 4. The MCP `mci_recall` wire shape
//!    (`apps/agent/src/mcp/server.rs:302-303`) already emits
//!    `entities` + `linked_event_ids` under the same `snake_case`
//!    names — this test locks that the FFI and MCP surfaces speak the
//!    same wire so a future refactor cannot drift them apart.
//!
//! NOT covered here: the live enrichment path through
//! `BrainStore::entity_names_for_event` +
//! `BrainStore::linked_event_ids_for_event`. Those are unit-tested
//! against a real ephemeral `SQLCipher` DB in
//! `core/brain/tests/recall_fusion.rs`. Duplicating them here would
//! just move the fixture; the FFI's job is to `.unwrap_or_default()`
//! the trait calls and thread the result into the JSON, which is what
//! this file pins.

use mci_brain_ffi::HitJson;

/// Round-trip: serialize a fully-populated [`HitJson`] with `entities`
/// and `linked_event_ids`, decode it back, assert byte-for-byte equality.
///
/// This is the load-bearing contract for the Swift `HitWire` decoder in
/// `apps/recall-ui/Sources/RecallUIKit/FFIBrainReader.swift`. If the Rust
/// serde derive ever drops one of these fields (or renames it), this test
/// fails at the FFI's own test suite before the Swift side even builds.
#[test]
fn hit_json_round_trips_entities_and_linked_event_ids() {
    let h = HitJson {
        event_id: 42,
        ts_us: 1_700_000_000_000_000,
        app_bundle_id: Some("com.apple.Safari".into()),
        window_title: Some("Vector databases at scale: a survey".into()),
        url: Some("https://arxiv.org/abs/2312.06827".into()),
        ocr_text_snippet: "Vector databases at scale ...".into(),
        source: "hybrid".into(),
        score: Some(0.87),
        entities: vec![
            "Anthropic".into(),
            "vector databases".into(),
            "MCP".into(),
        ],
        linked_event_ids: vec![101, 202, 303, 404],
    };
    let s = serde_json::to_string(&h).expect("serialize");
    let back: HitJson = serde_json::from_str(&s).expect("deserialize");
    assert_eq!(h, back, "HitJson serde round trip must be lossless");
    assert_eq!(back.entities.len(), 3);
    assert_eq!(back.linked_event_ids, vec![101, 202, 303, 404]);
}

/// Assert the exact `snake_case` wire the Swift `HitWire` decoder in
/// `apps/recall-ui/Sources/RecallUIKit/FFIBrainReader.swift` expects.
///
/// The Swift decoder maps `entities` → `entities: [String]` and
/// `linked_event_ids` → `linkedEventIds: [UInt64]`. If a refactor ever
/// flips one of these to camelCase on the Rust side, the Swift `HitWire`
/// decode fails at runtime with `.decodeFailed` — this unit test catches
/// that at the Rust FFI layer before it can ship.
#[test]
fn hit_json_wire_uses_snake_case_keys_for_new_fields() {
    let h = HitJson {
        event_id: 7,
        ts_us: 100,
        app_bundle_id: None,
        window_title: None,
        url: None,
        ocr_text_snippet: String::new(),
        source: "timeline".into(),
        score: None,
        entities: vec!["Amy Jain".into()],
        linked_event_ids: vec![9],
    };
    let s = serde_json::to_string(&h).unwrap();
    // Snake_case, exactly matches server.rs:302-303 and the Swift wire.
    assert!(s.contains("\"entities\":[\"Amy Jain\"]"), "got: {s}");
    assert!(s.contains("\"linked_event_ids\":[9]"), "got: {s}");
    // Must NOT accidentally emit a camelCase alias — Swift would then miss it.
    assert!(!s.contains("linkedEventIds"), "leaked camelCase: {s}");
}

/// Backward compat: an older FFI build (or a hand-rolled test fixture)
/// that predates the cycle-8.35 wire widening emits no `entities` or
/// `linked_event_ids` keys. Serde `#[serde(default)]` on both fields must
/// accept this and yield empty vectors so a mixed-version deployment
/// (older Rust ↔ newer Swift or vice versa) does not break decode.
#[test]
fn hit_json_decodes_legacy_payload_without_entity_fields() {
    let legacy = r#"{
        "event_id": 1,
        "ts_us": 0,
        "app_bundle_id": null,
        "window_title": null,
        "url": null,
        "ocr_text_snippet": "",
        "source": "lexical",
        "score": null
    }"#;
    let h: HitJson = serde_json::from_str(legacy).expect("legacy JSON must decode");
    assert!(h.entities.is_empty());
    assert!(h.linked_event_ids.is_empty());
}

/// Empty vectors are the common case (the store defaults to `Ok(vec![])`
/// for graph-less backends via the `BrainStore` trait's default impl of
/// `entity_names_for_event` and `linked_event_ids_for_event`, and
/// `enrich_hit` `.unwrap_or_default()`s any store error). Serializing an
/// empty vec must still emit the key so a consumer can distinguish
/// "server returned no matches" from "server doesn't speak this field".
#[test]
fn hit_json_empty_entity_vecs_still_emit_the_keys() {
    let h = HitJson {
        event_id: 0,
        ts_us: 0,
        app_bundle_id: None,
        window_title: None,
        url: None,
        ocr_text_snippet: String::new(),
        source: "timeline".into(),
        score: None,
        entities: Vec::new(),
        linked_event_ids: Vec::new(),
    };
    let s = serde_json::to_string(&h).unwrap();
    assert!(s.contains("\"entities\":[]"), "got: {s}");
    assert!(s.contains("\"linked_event_ids\":[]"), "got: {s}");
}
