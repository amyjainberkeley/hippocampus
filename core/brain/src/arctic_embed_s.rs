//! `snowflake-arctic-embed-s` embedder wrapper — OS-free.
//!
//! # What this module is
//!
//! The OS-free wrapper for ADR-0011's embedder: `snowflake-arctic-embed-s`,
//! 33M params, 384-d, Apache-2.0, int8-quantized. Per ADR-0011 §3 the
//! wrapper is binding on two model-card invariants:
//!
//! 1. **Query / document prefix discipline.** The embedder prepends
//!    `"Represent this sentence for searching relevant passages: "` to every
//!    query call (model card; ADR-0011 §3). For documents the model card
//!    specifies **no** prefix — [`ARCTIC_EMBED_S_DOCUMENT_PREFIX`] is the
//!    empty string. The prefix is structural in the wrapper so a future
//!    contributor cannot quietly drop it (ADR-0011 §6).
//! 2. **Output L2-normalization.** Every returned vector is L2-normalized
//!    so cosine collapses to dot product at retrieval time (ADR-0009 +
//!    ADR-0011 §3). Preserves Matryoshka-readiness for any future
//!    MRL-capable swap.
//!
//! # Why this lives in `core/brain` and not under `adapters/<os>/`
//!
//! Prefix discipline + L2-norm + the 384-d shape are OS-free *contracts*
//! over a backend that does the raw forward pass. Splitting them out keeps
//! `core/brain` honest under ADR-0003 ("nothing above the seam may contain
//! OS-specific code") while still satisfying ADR-0011's structural mandate
//! that the prefix and the norm are *binding on the wrapper*. The
//! OS-specific backend lives behind [`EmbedderBackend`]:
//!
//! - **macOS:** `mci-embed-coreml` (Phase 3 P3.3) wraps Core ML / ANE
//!   via `objc2-core-ml`. New crate, FFI surface, NOT
//!   `#![forbid(unsafe_code)]`.
//! - **Windows:** Phase 8 wraps ONNX Runtime / `DirectML` via `ort`.
//!
//! The wiring from binary to backend is done at the `apps/agent` level
//! with `#[cfg(target_os = "macos")]`. Inside `core/brain` we hold the
//! trait — same discipline as `mci-core::capture::CaptureSource`.
//!
//! # Headless testability
//!
//! Production callers inject a `Box<dyn EmbedderBackend>` so headless
//! tests can substitute a deterministic fake. `tests/arctic_embed_s.rs`
//! pins the prefix discipline + L2-norm + 384-d contract using such a
//! fake; the real Core ML backend is exercised at P3.11 live-Mac audit.

use std::sync::Arc;

use crate::{EmbedError, Embedder};

/// Fixed embedding dimension (ADR-0009 + ADR-0011).
pub const ARCTIC_EMBED_S_DIMENSION: usize = 384;

/// Query-side prefix from the `snowflake-arctic-embed-s` model card.
/// Trailing space is part of the prefix; do not strip.
pub const ARCTIC_EMBED_S_QUERY_PREFIX: &str =
    "Represent this sentence for searching relevant passages: ";

/// Document-side prefix from the `snowflake-arctic-embed-s` model card.
///
/// The `-s` model's card specifies **no** document prefix (queries are
/// prefixed, documents are not). The constant exists so the wrapper's
/// shape mirrors the query-side: any future model swap that does add a
/// document prefix lands in one place. ADR-0011 §3 refers to "the
/// document-side prefix from the model card" — for arctic-embed-s that
/// resolves to the empty string.
pub const ARCTIC_EMBED_S_DOCUMENT_PREFIX: &str = "";

/// The raw forward-pass surface a runtime backend exposes.
///
/// One method, one job: take a text string (already prefixed by the
/// wrapper), run it through the model, return the raw embedding. The
/// wrapper handles prefixing + L2-norm + dimension assertion above this
/// trait. Returned vector length is checked by the wrapper, not the
/// backend — so a backend that misconfigures the output shape produces
/// a clear `EmbedError::Backend("backend returned N dims, expected 384")`
/// instead of corrupting the store.
///
/// `Send + Sync` so the wrapper can hold `Arc<dyn EmbedderBackend>` and
/// share one loaded model between query + document embedders (per
/// ADR-0016 §1.3: "model mmap'd, shared between query + idle-batch
/// embed").
pub trait EmbedderBackend: Send + Sync {
    /// Run the model on `text`. Length contract is asserted upstream;
    /// returning a vector of any non-zero length is acceptable here.
    fn forward(&self, text: &str) -> Result<Vec<f32>, EmbedError>;
}

/// Which side of the model card's prefix discipline this wrapper applies.
///
/// Production deployments typically construct two instances sharing one
/// backend: one [`PrefixMode::Document`] for the ingest path, one
/// [`PrefixMode::Query`] for the retriever. [`PrefixMode::None`] is the
/// opt-out escape hatch (ADR-0011 §3 mandates "default is on" — the
/// constructors that take a mode are explicit about which side).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrefixMode {
    /// Prepend [`ARCTIC_EMBED_S_QUERY_PREFIX`]. Use at retrieval time.
    Query,
    /// Prepend [`ARCTIC_EMBED_S_DOCUMENT_PREFIX`]. Use at ingest time.
    Document,
    /// No prefix. Escape hatch for callers that have already prefixed the
    /// text upstream or are running diagnostics. ADR-0011 §3 mandates
    /// "default is on" — this variant is never produced by the default
    /// constructors.
    None,
}

/// Production embedder for `snowflake-arctic-embed-s` (ADR-0011).
///
/// Holds a runtime-backend trait object and applies the model-card
/// prefix + L2-norm contract on every call. The dimension reported by
/// [`Embedder::dimension`] is [`ARCTIC_EMBED_S_DIMENSION`] (384) — fixed,
/// not derived from the backend, because a backend that returns the wrong
/// shape is an *error* (caught in [`Embedder::embed_one`]) rather than a
/// silently-renegotiated contract.
pub struct ArcticEmbedSEmbedder {
    backend: Arc<dyn EmbedderBackend>,
    mode: PrefixMode,
}

impl ArcticEmbedSEmbedder {
    /// Construct a query-side embedder. Every [`Embedder::embed_one`]
    /// call prepends [`ARCTIC_EMBED_S_QUERY_PREFIX`].
    #[must_use]
    pub fn new_query(backend: Arc<dyn EmbedderBackend>) -> Self {
        Self {
            backend,
            mode: PrefixMode::Query,
        }
    }

    /// Construct a document-side embedder. Every [`Embedder::embed_one`]
    /// call prepends [`ARCTIC_EMBED_S_DOCUMENT_PREFIX`] (empty for the
    /// `-s` model).
    #[must_use]
    pub fn new_document(backend: Arc<dyn EmbedderBackend>) -> Self {
        Self {
            backend,
            mode: PrefixMode::Document,
        }
    }

    /// Construct with an explicit [`PrefixMode`]. Used by callers that
    /// know what they're doing (e.g. tests, eval harness, diagnostic
    /// tooling). Production ingest / retrieval paths use the named
    /// constructors above.
    #[must_use]
    pub fn with_mode(backend: Arc<dyn EmbedderBackend>, mode: PrefixMode) -> Self {
        Self { backend, mode }
    }

    /// Which prefix mode this wrapper was constructed with.
    #[must_use]
    pub fn mode(&self) -> PrefixMode {
        self.mode
    }

    /// The prefix string this wrapper prepends. Empty for
    /// [`PrefixMode::None`] *and* for [`PrefixMode::Document`] (the
    /// `-s` model card has no document prefix).
    #[must_use]
    pub fn prefix(&self) -> &'static str {
        match self.mode {
            PrefixMode::Query => ARCTIC_EMBED_S_QUERY_PREFIX,
            PrefixMode::Document => ARCTIC_EMBED_S_DOCUMENT_PREFIX,
            PrefixMode::None => "",
        }
    }
}

impl Embedder for ArcticEmbedSEmbedder {
    fn dimension(&self) -> usize {
        ARCTIC_EMBED_S_DIMENSION
    }

    fn embed_one(&self, text: &str) -> Result<Vec<f32>, EmbedError> {
        if text.is_empty() {
            return Err(EmbedError::InvalidInput("empty text".into()));
        }
        let prefix = self.prefix();
        let prefixed: String = if prefix.is_empty() {
            text.to_owned()
        } else {
            let mut s = String::with_capacity(prefix.len() + text.len());
            s.push_str(prefix);
            s.push_str(text);
            s
        };
        let mut v = self.backend.forward(&prefixed)?;
        if v.len() != ARCTIC_EMBED_S_DIMENSION {
            return Err(EmbedError::Backend(format!(
                "backend returned {} dims, expected {}",
                v.len(),
                ARCTIC_EMBED_S_DIMENSION
            )));
        }
        l2_normalize_in_place(&mut v);
        Ok(v)
    }
}

/// In-place L2-normalize. ADR-0009 mandate: every stored vector is
/// L2-normalized so cosine equals dot product. The zero-magnitude case
/// returns an error rather than corrupting the store with NaN.
fn l2_normalize_in_place(v: &mut [f32]) {
    let mag_sq: f32 = v.iter().map(|x| x * x).sum();
    let mag = mag_sq.sqrt();
    if mag > 0.0 {
        for x in v.iter_mut() {
            *x /= mag;
        }
    }
    // Zero-vector case: leave as zeros. The retrieval-time cosine on a
    // zero vector is 0, which is the right "no signal" answer. We do
    // NOT NaN-propagate.
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Backend that records every text it was asked to forward, so tests
    /// can pin the wrapper's prefix discipline.
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
        fn last(&self) -> Option<String> {
            self.calls.lock().unwrap().last().cloned()
        }
    }

    impl EmbedderBackend for RecordingBackend {
        fn forward(&self, text: &str) -> Result<Vec<f32>, EmbedError> {
            self.calls.lock().unwrap().push(text.to_owned());
            // Return a non-unit vector so the wrapper's L2-norm has work to do.
            let mut v = vec![0.0_f32; self.out_dim];
            for (i, slot) in v.iter_mut().enumerate() {
                #[allow(clippy::cast_precision_loss)]
                {
                    *slot = (i as f32) + 1.0;
                }
            }
            Ok(v)
        }
    }

    fn rec_backend(dim: usize) -> Arc<RecordingBackend> {
        Arc::new(RecordingBackend::new(dim))
    }

    #[test]
    fn dimension_is_384() {
        let b: Arc<dyn EmbedderBackend> = rec_backend(ARCTIC_EMBED_S_DIMENSION);
        let e = ArcticEmbedSEmbedder::new_query(b);
        assert_eq!(e.dimension(), 384);
    }

    #[test]
    fn document_mode_has_empty_prefix() {
        // arctic-embed-s model card: no document prefix.
        assert_eq!(ARCTIC_EMBED_S_DOCUMENT_PREFIX, "");
        let b: Arc<dyn EmbedderBackend> = rec_backend(ARCTIC_EMBED_S_DIMENSION);
        let e = ArcticEmbedSEmbedder::new_document(b);
        assert_eq!(e.prefix(), "");
        assert_eq!(e.mode(), PrefixMode::Document);
    }

    #[test]
    fn query_mode_uses_the_model_card_prefix() {
        let b = rec_backend(ARCTIC_EMBED_S_DIMENSION);
        let e =
            ArcticEmbedSEmbedder::new_query(Arc::clone(&b) as Arc<dyn EmbedderBackend>);
        let _ = e.embed_one("how do I configure tokio?").unwrap();
        let seen = b.last().expect("backend was called");
        assert!(
            seen.starts_with(ARCTIC_EMBED_S_QUERY_PREFIX),
            "query embed must prepend the model-card prefix; saw {seen:?}"
        );
        assert!(
            seen.ends_with("how do I configure tokio?"),
            "original text must be preserved after the prefix; saw {seen:?}"
        );
    }
}
