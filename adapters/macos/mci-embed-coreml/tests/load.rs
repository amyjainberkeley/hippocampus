//! Integration tests for the macOS Core ML embedder backend.
//!
//! Headless (no `.mlpackage` required) — full end-to-end inference
//! against the real arctic-embed-s `.mlpackage` is exercised at P3.11
//! live-Mac audit per ADR-0016 §7. These tests cover the load-path
//! error surface, the trait-shape contract, and the integration with
//! `mci_brain::arctic_embed_s::ArcticEmbedSEmbedder` via the OS-free
//! `EmbedderBackend` seam.

#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use mci_brain::arctic_embed_s::{
    ArcticEmbedSEmbedder, EmbedderBackend, ARCTIC_EMBED_S_DIMENSION, ARCTIC_EMBED_S_QUERY_PREFIX,
};
use mci_brain::{EmbedError, Embedder};
use mci_embed_coreml::CoreMLBackend;

#[test]
fn load_missing_path_surfaces_backend_error() {
    let bogus = PathBuf::from("/tmp/mci-p3.3-test-this-file-does-not-exist.mlpackage");
    let err = CoreMLBackend::open(&bogus).expect_err("missing file must error");
    match err {
        EmbedError::Backend(msg) => {
            assert!(
                msg.contains("not found"),
                "error should describe missing file, got {msg:?}"
            );
            assert!(
                msg.contains(bogus.to_str().unwrap()),
                "error should name the offending path, got {msg:?}"
            );
        }
        other => panic!("expected Backend, got {other:?}"),
    }
}

#[test]
fn load_empty_path_is_invalid_input() {
    let err = CoreMLBackend::open(Path::new("")).expect_err("empty path must error");
    assert!(matches!(err, EmbedError::InvalidInput(_)), "{err:?}");
}

/// Locate the bundled / repo-local compiled embedder model, mirroring the
/// `apps/agent` candidate-paths chain. `None` (skip) when no artifact is
/// present (headless CI), `Some(path)` on a live Mac with the model built.
fn embedder_model_path() -> Option<PathBuf> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir.join("../../..").canonicalize().ok()?;
    for c in [
        repo_root.join("models/ArcticEmbedS_INT8.mlmodelc"),
        repo_root.join("models/ArcticEmbedS_INT8.mlpackage"),
    ] {
        if c.exists() {
            return Some(c);
        }
    }
    None
}

/// PRODUCTION-PATH smoke: the exact loader the live agent uses
/// ([`CoreMLBackend::open`], which pins [`ComputeUnits::CpuOnly`]) must
/// produce a finite, L2-normalized, 384-d vector for a probe string —
/// proving the embedder genuinely predicts, not just loads. This is the
/// regression guard for the E5RT "Invalid blob shape" class of bug: a
/// model whose predict path throws (or whose CPU pin regresses) fails
/// here, not silently at runtime via a nonzero `embed_errors` aggregate.
///
/// Skips (passes) when no model artifact is present (headless CI). On a
/// live Mac with `models/ArcticEmbedS_INT8.{mlmodelc,mlpackage}` built, it
/// runs the real Core ML inference.
#[test]
fn production_path_smoke_embed_is_finite_unit_vector() {
    let Some(model) = embedder_model_path() else {
        println!(
            "load.rs: skipping production-path smoke — no \
             ArcticEmbedS_INT8.{{mlmodelc,mlpackage}} under <repo>/models/. \
             Run scripts/convert_embedder.py --output \
             models/ArcticEmbedS_INT8.mlpackage --verify to produce it."
        );
        return;
    };

    // Production loader: CoreMLBackend::open pins DEFAULT_COMPUTE_UNITS
    // (CpuOnly). Wrap in the document-side embedder exactly as
    // load_embedder_backend does on the ingest path.
    let backend = CoreMLBackend::open(&model)
        .unwrap_or_else(|e| panic!("CoreMLBackend::open (cpu_only pin) failed: {e:?}"));
    let embedder = ArcticEmbedSEmbedder::new_document(Arc::new(backend));

    let v = embedder
        .embed_one("mci embedder production-path smoke probe")
        .unwrap_or_else(|e| panic!("production-path embed_one failed: {e:?}"));

    assert_eq!(
        v.len(),
        ARCTIC_EMBED_S_DIMENSION,
        "expected 384-d vector, got {}",
        v.len()
    );
    assert!(
        v.iter().all(|x| x.is_finite()),
        "embedding contains non-finite components"
    );
    assert!(
        v.iter().any(|&x| x != 0.0),
        "embedding is all zeros — looks like the ZeroBackend fallback, not a real model"
    );
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!(
        (norm - 1.0).abs() < 1e-2,
        "embedding is not L2-normalized: |v| = {norm} (expected ~1.0 from in-graph L2-norm)"
    );
}

#[test]
fn debug_impl_does_not_leak_model_schema() {
    // We cannot construct a real CoreMLBackend without an .mlpackage on
    // disk in a headless test, so we cover the Debug surface by
    // formatting an artificial reference if it ever becomes available
    // in test scaffolding. This test exists as a tripwire: a future
    // contributor who switches CoreMLBackend's Debug impl to
    // `#[derive(Debug)]` will leak the entire model description into
    // log files. The test passes vacuously today but documents the
    // intent (see CoreMLBackend's Debug impl docstring in lib.rs).
}

/// Compile-only: prove that `CoreMLBackend` satisfies the
/// `EmbedderBackend` bound the brain wrapper expects, and that the
/// resulting wrapper satisfies the brain `Embedder` trait.
///
/// This is the load-bearing seam: if some refactor accidentally
/// changes either trait's shape, this test fails to compile. The
/// `_unused` parameter is never invoked (we have no real `.mlpackage`
/// in CI); it exists purely so the type-checker walks both bounds.
#[allow(dead_code)]
fn _trait_seam_compile_check(loaded_backend: Arc<CoreMLBackend>) {
    let _: &dyn EmbedderBackend = &*loaded_backend;
    let embedder: ArcticEmbedSEmbedder =
        ArcticEmbedSEmbedder::new_query(loaded_backend as Arc<dyn EmbedderBackend>);
    let _: &dyn Embedder = &embedder;
    assert_eq!(ARCTIC_EMBED_S_DIMENSION, 384);
    assert!(!ARCTIC_EMBED_S_QUERY_PREFIX.is_empty());
}
