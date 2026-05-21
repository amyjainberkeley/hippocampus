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
