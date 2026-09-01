//! Where the ArcticEmbedS Core ML model is looked for, and how the two
//! embedder flavours are built.
//!
//! This lived inside the `mci-agent` binary, which meant anything else
//! wanting a real embedder — the benchmark harness, most immediately —
//! had to copy the probe order. A second copy is exactly how the
//! benchmark ends up measuring a different embedder from the one users
//! run, so there is one copy and both callers share it.
//!
//! Two flavours, and the distinction is load-bearing: `new_document`
//! embeds stored text, `new_query` adds the model-card query prefix
//! (ADR-0011 §3). Embedding a query with the document flavour quietly
//! degrades every result.

use std::sync::Arc;

/// Candidate on-disk paths for the `ArcticEmbedS` Core ML model, in probe
/// order. Shared by the ingest-side (document) and query-side embedder
/// loaders so both surfaces resolve the same bundle-first, dev-fallback
/// list. See ADR-0028 §4 for the bundle-path contract.
#[cfg(target_os = "macos")]
pub fn arctic_embed_s_model_candidates() -> Vec<std::path::PathBuf> {
    let home = std::env::var_os("HOME").map_or_else(
        || std::path::PathBuf::from("/tmp"),
        std::path::PathBuf::from,
    );
    let env_path = std::env::var_os("MCI_ARCTIC_MODEL_PATH").map(std::path::PathBuf::from);

    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Some(p) = &env_path {
        candidates.push(p.clone());
    }
    // Hippocampus.app bundle path (per ADR-0028 §4 — embedder bundled in
    // Contents/Resources/Models/ as produced by build-app.sh + Wave 16).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // exe at Contents/MacOS/mci-agent → Contents/Resources/Models/
            candidates.push(dir.join("../Resources/Models/ArcticEmbedS_INT8.mlmodelc"));
            candidates.push(dir.join("../Resources/Models/ArcticEmbedS_INT8.mlpackage"));
            // Dev/legacy paths (executable-relative)
            candidates.push(dir.join("ArcticEmbedS_INT8.mlmodelc"));
            candidates.push(dir.join("ArcticEmbedS_INT8.mlpackage"));
            candidates.push(dir.join("arctic-embed-s.mlpackage"));
            candidates.push(dir.join("../Resources/arctic-embed-s.mlpackage"));
        }
    }
    // The installed app, by absolute path. `doctor` has always probed this
    // location, so a machine with Hippocampus.app installed but running
    // `mci-agent` from a cargo target got `doctor` reporting the model
    // present while `embed-backfill` refused to run for want of it. The
    // executable-relative probes above only resolve when the binary is
    // itself inside the bundle.
    candidates.push(std::path::PathBuf::from(
        "/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc",
    ));
    candidates.push(home.join("Library/Application Support/MCI/Models/ArcticEmbedS_INT8.mlmodelc"));

    // Repo-root dev paths (when running mci-agent from cargo target)
    candidates.push(home.join("Documents/GitHub/mci/models/ArcticEmbedS_INT8.mlmodelc"));
    candidates.push(home.join("Documents/GitHub/mci/models/ArcticEmbedS_INT8.mlpackage"));
    // Old MCICaptureHelper.app path kept for legacy installs
    candidates.push(
        home.join("Applications/MCICaptureHelper.app/Contents/Resources/arctic-embed-s.mlpackage"),
    );
    candidates
}

/// Load the best available embedder backend for the idle-batch worker.
///
/// On macOS: tries to load the Core ML `.mlpackage` from candidate
/// paths; falls back to the zero-vector backend when the model isn't
/// bundled (development builds). Returns `(Arc<dyn Embedder>, is_real)`.
///
/// The ArcticEmbedSEmbedder wrapper applies the model-card prefix
/// discipline + L2-norm (ADR-0011 §3). Document-side prefix (empty
/// for arctic-embed-s) is used for idle-batch embedding.
#[cfg(target_os = "macos")]
pub fn load_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    use mci_brain::arctic_embed_s::ArcticEmbedSEmbedder;
    use mci_embed_coreml::load_backend_or_fallback;
    use std::path::Path;

    let candidates = arctic_embed_s_model_candidates();
    let path_refs: Vec<&Path> = candidates.iter().map(|p| p.as_path()).collect();
    let (backend, is_real) = load_backend_or_fallback(&path_refs);
    let embedder = ArcticEmbedSEmbedder::new_document(backend);

    // Load-time smoke embed: prove the model can actually PREDICT, not just
    // load. mci-embed-coreml's verify_schema is type-only and passes even on
    // a model whose predict path would throw — so a successful load does NOT
    // guarantee a working embedder. Probe once at startup so a dead embedder
    // is known loudly here, instead of inferred from a climbing embed_errors
    // aggregate at idle-batch worker exit. (Content-free: a fixed probe
    // string, never user content.)
    {
        use mci_brain::Embedder as _;
        let smoke = embedder.embed_one("mci embedder load-time smoke probe");
        match (&smoke, is_real) {
            (Ok(v), true) => {
                let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
                let healthy = v.len() == 384 && norm.is_finite() && (norm - 1.0).abs() < 1e-2;
                if healthy {
                    eprintln!(
                        "mci-agent: embedder smoke OK — CoreML (cpu_only pin), dim={} |v|={norm:.4}",
                        v.len(),
                    );
                } else {
                    eprintln!(
                        "mci-agent: WARNING embedder loaded but smoke vector looks wrong \
                         (dim={} |v|={norm:.4}, expected dim=384 |v|~1.0) — semantic ingest \
                         may be degraded.",
                        v.len(),
                    );
                }
            }
            (Err(e), true) => {
                eprintln!(
                    "mci-agent: WARNING embedder LOADED but smoke embed FAILED — semantic \
                     ingest is DEAD: {e}. Events will accumulate unembedded (embed_errors \
                     will climb). Check the bundled ArcticEmbedS model / compute-unit pin.",
                );
            }
            // is_real == false: ZeroBackend fallback. The degradation is
            // already reported at the call site via the `embedder=zero-fallback`
            // log line; the smoke "succeeds" trivially (zeros), so stay quiet.
            (_, false) => {}
        }
    }

    (Arc::new(embedder), is_real)
}

#[cfg(not(target_os = "macos"))]
pub fn load_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    // Non-macOS: no Core ML / ONNX available yet (Phase 8).
    // Zero-vector embedder marks events "embedded" to avoid busy-loop.
    struct ZeroEmbedder;
    impl mci_brain::Embedder for ZeroEmbedder {
        fn dimension(&self) -> usize {
            384
        }
        fn embed_one(&self, _text: &str) -> Result<Vec<f32>, mci_brain::EmbedError> {
            Ok(vec![0.0_f32; 384])
        }
    }
    eprintln!("mci-agent: non-macOS platform — using zero-vector embedder fallback");
    (Arc::new(ZeroEmbedder), false)
}

/// Load the query-side embedder for `mci-agent mcp-serve` (recall path).
///
/// Mirrors [`load_embedder_backend`] but constructs `new_query` so the
/// `ArcticEmbedS` model-card query prefix (per ADR-0011 §3) is applied to
/// every recall-time embed call. Same Core ML backend + `cpu_only` pin
/// (per PR #310 lesson — the "all" compute-unit setting is the latency
/// trap [[reference-coreml-computeunits-all-trap]]); a separate wrapper
/// instance because the prefix is baked into the wrapper, not selectable
/// per call.
///
/// Returns `(Arc<dyn Embedder>, is_real)` where `is_real == false` means
/// the `ZeroBackend` fallback fired (no model on disk) — callers should
/// prefer FTS5-only recall in that case rather than feeding a zero
/// vector into `HybridRetriever`.
#[cfg(target_os = "macos")]
pub fn load_query_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    use mci_brain::arctic_embed_s::ArcticEmbedSEmbedder;
    use mci_embed_coreml::load_backend_or_fallback;
    use std::path::Path;

    let candidates = arctic_embed_s_model_candidates();
    let path_refs: Vec<&Path> = candidates.iter().map(|p| p.as_path()).collect();
    let (backend, is_real) = load_backend_or_fallback(&path_refs);
    let embedder = ArcticEmbedSEmbedder::new_query(backend);

    // Load-time smoke embed: same probe discipline as the ingest-side
    // loader (PR #310) — verify_schema is type-only, so a "loaded" model
    // whose predict path throws will still light up the recall path
    // producing errors on every user query. Probe once at startup so a
    // dead query embedder is known loudly here.
    if is_real {
        use mci_brain::Embedder as _;
        match embedder.embed_one("mci query embedder load-time smoke probe") {
            Ok(v) => {
                let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
                let healthy = v.len() == 384 && norm.is_finite() && (norm - 1.0).abs() < 1e-2;
                if healthy {
                    eprintln!(
                        "mci-agent: query embedder smoke OK — CoreML (cpu_only pin), dim={} |v|={norm:.4}",
                        v.len(),
                    );
                } else {
                    eprintln!(
                        "mci-agent: WARNING query embedder loaded but smoke vector looks wrong \
                         (dim={} |v|={norm:.4}, expected dim=384 |v|~1.0) — hybrid recall may \
                         be degraded.",
                        v.len(),
                    );
                }
            }
            Err(e) => {
                eprintln!(
                    "mci-agent: WARNING query embedder LOADED but smoke embed FAILED — hybrid \
                     recall is DEAD: {e}. Check the bundled ArcticEmbedS model / compute-unit pin.",
                );
            }
        }
    }

    (Arc::new(embedder), is_real)
}

#[cfg(not(target_os = "macos"))]
pub fn load_query_embedder_backend() -> (Arc<dyn mci_brain::Embedder>, bool) {
    // Non-macOS: no Core ML / ONNX yet (Phase 8). Return a zero-vector
    // embedder marked `is_real = false` so the caller stays on FTS5-only
    // rather than seeding HybridRetriever with a useless zero vector.
    struct ZeroEmbedder;
    impl mci_brain::Embedder for ZeroEmbedder {
        fn dimension(&self) -> usize {
            384
        }
        fn embed_one(&self, _text: &str) -> Result<Vec<f32>, mci_brain::EmbedError> {
            Ok(vec![0.0_f32; 384])
        }
    }
    (Arc::new(ZeroEmbedder), false)
}
