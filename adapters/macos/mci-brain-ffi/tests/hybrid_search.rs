#![cfg(target_os = "macos")]

use std::ffi::{CStr, CString};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::arctic_embed_s::ArcticEmbedSEmbedder;
use mci_brain::{BrainStore, Embedder, Event, EventId, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_last_error_message, mci_brain_ffi_open_with_model,
    mci_brain_ffi_search, mci_brain_ffi_string_free, HitJson,
};
use mci_core::crypto::DbKey;
use mci_embed_coreml::CoreMLBackend;

fn model_path() -> Option<PathBuf> {
    std::env::var_os("MCI_ARCTIC_MODEL_PATH")
        .map(PathBuf::from)
        .filter(|path| path.exists())
        .or_else(|| {
            let path = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../models/ArcticEmbedS_FP16.mlmodelc");
            path.exists().then_some(path)
        })
}

fn key_hex(raw: [u8; 32]) -> String {
    raw.iter().fold(String::new(), |mut output, byte| {
        write!(output, "{byte:02x}").expect("write to String");
        output
    })
}

fn last_error() -> String {
    let ptr = unsafe { mci_brain_ffi_last_error_message() };
    if ptr.is_null() {
        return "<none>".into();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

fn event(ts_us: u64, text: &str, embedding: Vec<f32>) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.apple.Terminal".into()),
        window_title: Some("Mercury release notes".into()),
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: Some(embedding),
    }
}

#[test]
fn explicit_missing_model_fails_without_hiding_the_reason() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    let raw_key = [0x4a; 32];
    let key = DbKey::from_bytes(raw_key);
    drop(SqlCipherBrainStore::new(&path, &key).expect("writer open"));

    let path_c = CString::new(path.to_string_lossy().as_bytes()).unwrap();
    let key_c = CString::new(key_hex(raw_key)).unwrap();
    let model_c = CString::new("/definitely/missing/ArcticEmbedS.mlmodelc").unwrap();
    let handle =
        unsafe { mci_brain_ffi_open_with_model(path_c.as_ptr(), key_c.as_ptr(), model_c.as_ptr()) };

    assert!(handle.is_null());
    assert!(
        last_error().contains("model"),
        "unexpected error: {}",
        last_error()
    );
}

#[test]
fn model_backed_search_returns_semantic_related_context() {
    let Some(model_path) = model_path() else {
        eprintln!("skipping model-backed FFI search: Arctic model unavailable");
        return;
    };

    let backend = Arc::new(CoreMLBackend::open(&model_path).expect("load document backend"));
    let document_embedder = ArcticEmbedSEmbedder::new_document(backend);
    let relevant =
        "Priya is accountable for the Mercury payments rollout and final launch approval.";
    let distractor =
        "The design team selected a pale blue navigation background for the settings view.";

    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    let raw_key = [0x5b; 32];
    let key = DbKey::from_bytes(raw_key);
    let now_us = u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_micros(),
    )
    .expect("current timestamp fits u64");
    let relevant_id = {
        let writer = SqlCipherBrainStore::new(&path, &key).expect("writer open");
        let relevant_embedding = document_embedder
            .embed_one(relevant)
            .expect("embed relevant");
        let distractor_embedding = document_embedder
            .embed_one(distractor)
            .expect("embed distractor");
        let relevant_id = writer
            .put_event(&event(now_us - 1_000_000, relevant, relevant_embedding))
            .expect("put relevant");
        writer
            .put_event(&event(now_us - 2_000_000, distractor, distractor_embedding))
            .expect("put distractor");
        relevant_id
    };

    let path_c = CString::new(path.to_string_lossy().as_bytes()).unwrap();
    let key_c = CString::new(key_hex(raw_key)).unwrap();
    let model_c = CString::new(model_path.to_string_lossy().as_bytes()).unwrap();
    let handle =
        unsafe { mci_brain_ffi_open_with_model(path_c.as_ptr(), key_c.as_ptr(), model_c.as_ptr()) };
    assert!(!handle.is_null(), "semantic open failed: {}", last_error());

    let query =
        CString::new(r#"{"text":"Mercury payments rollout launch approval","limit":2}"#).unwrap();
    let json = unsafe { mci_brain_ffi_search(handle, query.as_ptr()) };
    assert!(!json.is_null(), "semantic search failed: {}", last_error());
    let payload = unsafe { CStr::from_ptr(json) }
        .to_string_lossy()
        .into_owned();
    unsafe { mci_brain_ffi_string_free(json) };
    let hits: Vec<HitJson> = serde_json::from_str(&payload).expect("decode hits");

    assert!(
        !hits.is_empty(),
        "semantic search returned no related context"
    );
    assert_eq!(hits[0].event_id, relevant_id.0);
    assert_eq!(hits[0].source, "hybrid-related");
    // A loaded model must not turn literal search into an unrelated feed.
    for (text, aliases, expected) in [
        ("payments", serde_json::json!({}), vec![relevant_id.0]),
        ("unseen_cobalt_8731", serde_json::json!({}), vec![]),
        (
            "payments OR unseen_cobalt_8731",
            serde_json::json!({}),
            vec![],
        ),
        (
            "launchchief",
            serde_json::json!({"Priya": ["launchchief"]}),
            vec![relevant_id.0],
        ),
    ] {
        let query = CString::new(
            serde_json::json!({
                "text": text, "limit": 50, "mode": "text", "user_aliases": aliases,
            })
            .to_string(),
        )
        .unwrap();
        let json = unsafe { mci_brain_ffi_search(handle, query.as_ptr()) };
        assert!(!json.is_null(), "text search failed: {}", last_error());
        let hits: Vec<HitJson> =
            serde_json::from_slice(unsafe { CStr::from_ptr(json) }.to_bytes()).unwrap();
        unsafe { mci_brain_ffi_string_free(json) };
        assert_eq!(
            hits.iter().map(|hit| hit.event_id).collect::<Vec<_>>(),
            expected,
            "{text}"
        );
        assert!(hits.iter().all(|hit| hit.source == "lexical"));
    }
    unsafe { mci_brain_ffi_close(handle) };
}
