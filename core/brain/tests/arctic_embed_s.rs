//! Integration tests for the `ArcticEmbedSEmbedder` wrapper.
//!
//! These tests pin the ADR-0011 §3 contract that every PR P3.x in the
//! Phase 3 sequence inherits:
//!
//! - Dimension is 384 (ADR-0009 + ADR-0011).
//! - Query-side calls receive the model-card prefix
//!   `"Represent this sentence for searching relevant passages: "`.
//! - Document-side calls receive the empty document prefix (per the
//!   `snowflake-arctic-embed-s` model card the document side has no
//!   prefix; the wrapper still exposes it as a constant so a future
//!   model swap can change one place).
//! - Output is L2-normalized (`||v||₂ ≈ 1.0`) — required for the
//!   sqlite-vec cosine = dot fast path.
//! - Backend output of the wrong dimension surfaces as
//!   `EmbedError::Backend`, not silent corruption.
//! - Same input → same output, given a deterministic backend
//!   (the wrapper itself adds no stochasticity).
//!
//! The OS-bound Core ML backend (`mci-embed-coreml`) is exercised at
//! P3.11 live-Mac audit per ADR-0016 §7; these tests substitute a
//! deterministic in-memory backend so the brain wrapper's contract
//! can be pinned in a headless CI run.

use std::sync::{Arc, Mutex};

use mci_brain::{
    arctic_embed_s::{
        ArcticEmbedSEmbedder, EmbedderBackend, PrefixMode, ARCTIC_EMBED_S_DIMENSION,
        ARCTIC_EMBED_S_DOCUMENT_PREFIX, ARCTIC_EMBED_S_QUERY_PREFIX,
    },
    EmbedError, Embedder,
};

// ---------------------------------------------------------------------------
// Test backends
// ---------------------------------------------------------------------------

/// Backend that records every text it was asked to forward + returns a
/// deterministic non-unit-norm vector so the wrapper's L2 step has work
/// to do.
struct RecordingBackend {
    calls: Mutex<Vec<String>>,
    out_dim: usize,
}

impl RecordingBackend {
    fn new(out_dim: usize) -> Self {
        Self {
            calls: Mutex::new(Vec::new()),
            out_dim,
        }
    }
    fn last_call(&self) -> Option<String> {
        self.calls.lock().unwrap().last().cloned()
    }
    fn call_count(&self) -> usize {
        self.calls.lock().unwrap().len()
    }
}

impl EmbedderBackend for RecordingBackend {
    fn forward(&self, text: &str) -> Result<Vec<f32>, EmbedError> {
        self.calls.lock().unwrap().push(text.to_owned());
        // Use a stable hash of the text as the seed so the same text
        // produces the same vector across calls (determinism test).
        let seed = fnv1a(text.as_bytes());
        let mut state = if seed == 0 { 0x9E37_79B9 } else { seed };
        let mut v = vec![0.0_f32; self.out_dim];
        for slot in &mut v {
            state = state
                .wrapping_mul(2_862_933_555_777_941_757)
                .wrapping_add(3_037_000_493);
            #[allow(clippy::cast_precision_loss)]
            let u = (((state >> 33) & 0x00FF_FFFF) as f32) / 16_777_216.0;
            *slot = u.mul_add(2.0, -1.0);
        }
        // Multiply by 7.5 so the magnitude is not ≈ 1 by accident — the
        // L2-norm step must produce a unit vector regardless of input
        // scale.
        for x in &mut v {
            *x *= 7.5;
        }
        Ok(v)
    }
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// Backend that returns a fixed-length vector of the *wrong* dimension.
struct WrongDimBackend(usize);

impl EmbedderBackend for WrongDimBackend {
    fn forward(&self, _: &str) -> Result<Vec<f32>, EmbedError> {
        Ok(vec![0.5_f32; self.0])
    }
}

/// Backend that always errors.
struct ErroringBackend(&'static str);

impl EmbedderBackend for ErroringBackend {
    fn forward(&self, _: &str) -> Result<Vec<f32>, EmbedError> {
        Err(EmbedError::Backend(self.0.into()))
    }
}

// ---------------------------------------------------------------------------
// 1. Dimension contract
// ---------------------------------------------------------------------------

#[test]
fn dimension_is_384() {
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let q = ArcticEmbedSEmbedder::new_query(Arc::clone(&b) as Arc<dyn EmbedderBackend>);
    let d = ArcticEmbedSEmbedder::new_document(b as Arc<dyn EmbedderBackend>);
    assert_eq!(q.dimension(), 384);
    assert_eq!(d.dimension(), 384);
}

// ---------------------------------------------------------------------------
// 2. Prefix discipline — ADR-0011 §3 binding
// ---------------------------------------------------------------------------

#[test]
fn query_embed_prepends_model_card_prefix() {
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::new_query(Arc::clone(&b) as Arc<dyn EmbedderBackend>);
    let _ = e.embed_one("what time is it").expect("embed");
    let seen = b.last_call().expect("backend called");
    assert!(
        seen.starts_with(ARCTIC_EMBED_S_QUERY_PREFIX),
        "query embed must prepend {ARCTIC_EMBED_S_QUERY_PREFIX:?}, saw {seen:?}",
    );
    assert!(seen.ends_with("what time is it"));
    // exact byte length: prefix + payload, nothing else.
    assert_eq!(
        seen.len(),
        ARCTIC_EMBED_S_QUERY_PREFIX.len() + "what time is it".len()
    );
}

#[test]
fn document_embed_has_no_prefix_per_model_card() {
    // arctic-embed-s model card: no document prefix.
    assert_eq!(ARCTIC_EMBED_S_DOCUMENT_PREFIX, "");
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::new_document(Arc::clone(&b) as Arc<dyn EmbedderBackend>);
    let _ = e
        .embed_one("the user opened a Safari tab on huggingface.co")
        .expect("embed");
    let seen = b.last_call().expect("backend called");
    assert_eq!(seen, "the user opened a Safari tab on huggingface.co");
}

#[test]
fn none_mode_opts_out_of_prefix_for_diagnostics() {
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::with_mode(
        Arc::clone(&b) as Arc<dyn EmbedderBackend>,
        PrefixMode::None,
    );
    let _ = e.embed_one("already prefixed upstream").expect("embed");
    let seen = b.last_call().expect("backend called");
    assert_eq!(seen, "already prefixed upstream");
    assert_eq!(e.prefix(), "");
    assert_eq!(e.mode(), PrefixMode::None);
}

// ---------------------------------------------------------------------------
// 3. L2-normalization — ADR-0009 + ADR-0011 §3 binding
// ---------------------------------------------------------------------------

#[test]
fn output_is_l2_normalized() {
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::new_query(b as Arc<dyn EmbedderBackend>);
    let v = e
        .embed_one("the quick brown fox jumps over the lazy dog")
        .expect("embed");
    assert_eq!(v.len(), ARCTIC_EMBED_S_DIMENSION);
    let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!((mag - 1.0).abs() < 1e-6, "expected ||v|| ≈ 1.0, got {mag}");
}

#[test]
fn l2_norm_robust_to_backend_scale() {
    // RecordingBackend multiplies by 7.5 — the wrapper must still
    // produce a unit-norm vector. This catches a regression where the
    // wrapper forgets the divide-by-magnitude step.
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::new_document(b as Arc<dyn EmbedderBackend>);
    for text in [
        "short",
        "a much longer passage with more words to push the magnitude up further",
        "another distinct passage entirely",
    ] {
        let v = e.embed_one(text).expect("embed");
        let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!(
            (mag - 1.0).abs() < 1e-6,
            "{text:?} produced ||v|| = {mag}, expected ≈ 1.0"
        );
    }
}

// ---------------------------------------------------------------------------
// 4. Determinism — same text → same output (given deterministic backend)
// ---------------------------------------------------------------------------

#[test]
fn same_text_yields_same_vector() {
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::new_query(b as Arc<dyn EmbedderBackend>);
    let a = e.embed_one("how do I tune sqlite-vec").expect("embed a");
    let c = e.embed_one("how do I tune sqlite-vec").expect("embed c");
    assert_eq!(a, c, "wrapper must not inject any per-call randomness");
}

// ---------------------------------------------------------------------------
// 5. Backend dim-mismatch surfaces as a clear EmbedError::Backend
// ---------------------------------------------------------------------------

#[test]
fn wrong_dim_backend_returns_backend_error() {
    let b = Arc::new(WrongDimBackend(256));
    let e = ArcticEmbedSEmbedder::new_query(b as Arc<dyn EmbedderBackend>);
    let err = e.embed_one("anything").unwrap_err();
    match err {
        EmbedError::Backend(msg) => {
            assert!(
                msg.contains("256") && msg.contains("384"),
                "error must name both observed and expected dim, saw {msg:?}"
            );
        }
        other => panic!("expected Backend, got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// 6. Empty input rejected before reaching the backend
// ---------------------------------------------------------------------------

#[test]
fn empty_text_is_rejected_before_backend_call() {
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::new_query(Arc::clone(&b) as Arc<dyn EmbedderBackend>);
    let err = e.embed_one("").unwrap_err();
    assert!(matches!(err, EmbedError::InvalidInput(_)));
    assert_eq!(b.call_count(), 0, "backend must not be called on empty");
}

// ---------------------------------------------------------------------------
// 7. Backend error is propagated verbatim (no swallowing)
// ---------------------------------------------------------------------------

#[test]
fn backend_error_propagates() {
    let b = Arc::new(ErroringBackend("ANE offline"));
    let e = ArcticEmbedSEmbedder::new_query(b as Arc<dyn EmbedderBackend>);
    let err = e.embed_one("anything").unwrap_err();
    match err {
        EmbedError::Backend(msg) => assert!(msg.contains("ANE offline")),
        other => panic!("expected Backend, got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// 8. embed_batch round-trips against embed_one (default trait impl)
// ---------------------------------------------------------------------------

#[test]
fn batch_matches_per_item() {
    let b = Arc::new(RecordingBackend::new(ARCTIC_EMBED_S_DIMENSION));
    let e = ArcticEmbedSEmbedder::new_document(Arc::clone(&b) as Arc<dyn EmbedderBackend>);
    let texts = ["alpha", "bravo", "charlie"];
    let batched = e.embed_batch(&texts).expect("batch");
    assert_eq!(batched.len(), 3);
    for (i, t) in texts.iter().enumerate() {
        let single = e.embed_one(t).expect("single");
        assert_eq!(batched[i], single, "batch[{i}] must match embed_one({t:?})");
    }
}
