// Gate the entire crate body on macOS — the objc2 deps are gated to the
// same target in `Cargo.toml`, so on Linux this crate compiles to an
// empty library and `cargo build --workspace` stays green for
// non-macOS contributors. The real adapter lives in
// `cfg(target_os = "macos")` below.
#![cfg(target_os = "macos")]

//! macOS Core ML / ANE backend for `snowflake-arctic-embed-s`.
//!
//! Implements [`mci_brain::arctic_embed_s::EmbedderBackend`] using Apple's
//! Core ML framework via the `objc2-core-ml` bindings. The wrapper
//! ([`mci_brain::arctic_embed_s::ArcticEmbedSEmbedder`]) handles the
//! model-card prefix discipline + L2-norm + dimension assertion above this
//! crate. This crate's job is one thing: load the `.mlpackage`, run a
//! forward pass on a text input, return the raw embedding vector.
//!
//! # Why this crate is NOT `#![forbid(unsafe_code)]`
//!
//! Core ML is an Objective-C framework. `objc2-core-ml` exposes its
//! selectors as `unsafe fn`, so any call site here is unsafe. The unsafe
//! surface is audited per call site and kept minimal. `mci-brain` upstream
//! keeps the `#![forbid(unsafe_code)]` attribute; the unsafe FFI lives
//! only in this adapter crate, mirroring the same split as
//! `adapters/macos/MCICaptureHelper` (Swift side of the OS-purity boundary
//! set in ADR-0003).
//!
//! # Model bundling
//!
//! The `arctic-embed-s.mlpackage` (~30-50 MB) is **not** checked into the
//! repo. The Phase-5 signed-app build pipeline runs
//! `scripts/download_model.sh` at release time to fetch the `HuggingFace`
//! release and convert it to a Core ML `.mlpackage` via `coremltools`.
//! See `BUNDLING.md` for the conversion contract + the expected
//! input/output schema this crate calls.
//!
//! # Expected `.mlpackage` schema
//!
//! - **Input feature:** `"text"`, [`MLFeatureType::String`] — a single UTF-8
//!   string. The tokenizer is baked into the model graph via the
//!   `coremltools` conversion script (see `BUNDLING.md` §2).
//! - **Output feature:** `"embedding"`, [`MLFeatureType::MultiArray`],
//!   [`MLMultiArrayDataType::Float32`], shape `[1, 384]` or `[384]`.
//!
//! A mismatch produces an [`EmbedError::Backend`] with the offending
//! schema described, never a silent corruption of the brain.
//!
//! # Tests
//!
//! Headless unit tests cover: missing-file open error; the trait shape
//! compiles; constructors return distinct error variants for distinct
//! failure modes. End-to-end inference against the real `.mlpackage`
//! runs at P3.11 live-Mac audit per ADR-0016 §7.

use std::path::Path;

use mci_brain::{
    arctic_embed_s::{EmbedderBackend, ARCTIC_EMBED_S_DIMENSION},
    EmbedError,
};

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AllocAnyThread;
use objc2_core_ml::{
    MLDictionaryFeatureProvider, MLFeatureProvider, MLFeatureType, MLFeatureValue, MLModel,
    MLModelConfiguration, MLMultiArray, MLMultiArrayDataType,
};
use objc2_foundation::{NSDictionary, NSString, NSURL};

/// Per ADR-0016 §1.3, the expected output feature name from the
/// `coremltools`-converted `.mlpackage`. The `BUNDLING.md` conversion
/// recipe pins this name in the model graph.
const OUTPUT_FEATURE_NAME: &str = "embedding";

/// Per ADR-0016 §1.3, the expected input feature name. The model graph
/// produced by `scripts/download_model.sh` exposes a single text input
/// under this name and tokenizes it internally.
const INPUT_FEATURE_NAME: &str = "text";

/// Core ML / ANE backend for `snowflake-arctic-embed-s`.
///
/// One instance per loaded `.mlpackage`. Held by `Arc<Self>` upstream so
/// query + document [`mci_brain::arctic_embed_s::ArcticEmbedSEmbedder`]
/// instances can share the model (per ADR-0016 §1.3: "model mmap'd,
/// shared between query + idle-batch embed").
pub struct CoreMLBackend {
    model: Retained<MLModel>,
}

impl std::fmt::Debug for CoreMLBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Don't dump the MLModel description — it leaks the bundled
        // model's input/output schema into logs, which we want
        // consistent across content-free telemetry. Identity only.
        f.debug_struct("CoreMLBackend").finish_non_exhaustive()
    }
}

// `MLModel` is documented thread-safe for `predictionFromFeatures:`
// (Apple — Core ML Performance & Architecture WWDC 2019 §"Thread Safety").
// The objc2 binding exposes `Retained<MLModel>` which itself is `!Send`
// by default because of Objective-C runtime nuances. We assert Send + Sync
// by hand and keep the unsafe impl narrow + commented. Same pattern as
// `mci-core::ipc::wire` uses for its `OwnedFd` carriers.
unsafe impl Send for CoreMLBackend {}
unsafe impl Sync for CoreMLBackend {}

impl CoreMLBackend {
    /// Load the `.mlpackage` at `path`.
    ///
    /// Returns [`EmbedError::Backend`] if the path does not exist, if
    /// Core ML refuses to load the model (e.g. wrong format, signature
    /// mismatch under notarization), or if the loaded model's
    /// input/output schema does not match the contract documented in
    /// the module docs.
    ///
    /// # Errors
    ///
    /// - `EmbedError::InvalidInput` — `path` is not a non-empty
    ///   filesystem path string.
    /// - `EmbedError::Backend` — Core ML refused the load, or the
    ///   resulting model has an unexpected feature schema.
    pub fn open(path: &Path) -> Result<Self, EmbedError> {
        let path_str = path
            .to_str()
            .ok_or_else(|| EmbedError::InvalidInput("model path is not valid UTF-8".into()))?;
        if path_str.is_empty() {
            return Err(EmbedError::InvalidInput("model path is empty".into()));
        }
        if !path.exists() {
            return Err(EmbedError::Backend(format!(
                "model not found at: {path_str}"
            )));
        }

        let url = NSURL::fileURLWithPath(&NSString::from_str(path_str));
        let config = unsafe { MLModelConfiguration::new() };
        // SAFETY: Core ML's `+[MLModel modelWithContentsOfURL:configuration:error:]`
        // is a class method that builds a new MLModel from a file URL. The
        // call blocks briefly on compile-then-load for `.mlpackage`.
        // Returns either a retained MLModel or an NSError — we map both arms.
        let model = unsafe {
            MLModel::modelWithContentsOfURL_configuration_error(&url, &config)
                .map_err(|err| EmbedError::Backend(format_ns_error("MLModel load failed", &err)))?
        };

        let me = Self { model };
        me.verify_schema()?;
        Ok(me)
    }

    /// Construct from an already-loaded `MLModel`. For internal use by
    /// alternate loaders (e.g. a future loader that pulls from the
    /// Phase-5 encrypted-bundle path).
    #[must_use]
    pub fn from_loaded(model: Retained<MLModel>) -> Self {
        Self { model }
    }

    /// Verify the loaded model's input/output feature schema matches
    /// the contract in the module docs. Called once at load.
    fn verify_schema(&self) -> Result<(), EmbedError> {
        // SAFETY: `modelDescription` is a property accessor that returns a
        // retained MLModelDescription. `inputDescriptionsByName` /
        // `outputDescriptionsByName` are NSDictionary accessors.
        let desc = unsafe { self.model.modelDescription() };
        let inputs = unsafe { desc.inputDescriptionsByName() };
        let outputs = unsafe { desc.outputDescriptionsByName() };

        let in_key = NSString::from_str(INPUT_FEATURE_NAME);
        let out_key = NSString::from_str(OUTPUT_FEATURE_NAME);

        let in_desc = inputs.objectForKey(&in_key).ok_or_else(|| {
            EmbedError::Backend(format!(
                "model is missing required input feature {INPUT_FEATURE_NAME:?}; \
                 see BUNDLING.md for the expected schema"
            ))
        })?;
        let out_desc = outputs.objectForKey(&out_key).ok_or_else(|| {
            EmbedError::Backend(format!(
                "model is missing required output feature {OUTPUT_FEATURE_NAME:?}; \
                 see BUNDLING.md for the expected schema"
            ))
        })?;

        let in_type = unsafe { in_desc.r#type() };
        if in_type != MLFeatureType::String {
            return Err(EmbedError::Backend(format!(
                "input {INPUT_FEATURE_NAME:?} has feature type {:?}, expected String",
                in_type.0
            )));
        }
        let out_type = unsafe { out_desc.r#type() };
        if out_type != MLFeatureType::MultiArray {
            return Err(EmbedError::Backend(format!(
                "output {OUTPUT_FEATURE_NAME:?} has feature type {:?}, expected MultiArray",
                out_type.0
            )));
        }
        Ok(())
    }
}

impl EmbedderBackend for CoreMLBackend {
    fn forward(&self, text: &str) -> Result<Vec<f32>, EmbedError> {
        // Build the single-feature input dictionary.
        let ns_text = NSString::from_str(text);
        // SAFETY: `featureValueWithString:` is a class method that returns
        // a retained MLFeatureValue wrapping the NSString.
        let value: Retained<MLFeatureValue> =
            unsafe { MLFeatureValue::featureValueWithString(&ns_text) };

        let key = NSString::from_str(INPUT_FEATURE_NAME);
        // NSDictionary<NSString, AnyObject>: upcast the MLFeatureValue to
        // its NSObject / AnyObject ancestor — type-erased dictionaries are
        // how Core ML accepts feature collections.
        let val_obj: &AnyObject = &value;
        let dict: Retained<NSDictionary<NSString, AnyObject>> =
            NSDictionary::from_slices(&[&*key], &[val_obj]);

        // SAFETY: `initWithDictionary:error:` consumes a fresh allocation
        // and returns an initialized MLDictionaryFeatureProvider or NSError.
        let provider = unsafe {
            MLDictionaryFeatureProvider::initWithDictionary_error(
                MLDictionaryFeatureProvider::alloc(),
                &dict,
            )
            .map_err(|err| {
                EmbedError::Backend(format_ns_error("feature-provider init failed", &err))
            })?
        };

        // Run the prediction. ProtocolObject<dyn MLFeatureProvider> is the
        // required input type; MLDictionaryFeatureProvider conforms.
        // SAFETY: predictionFromFeatures:error: is synchronous + thread-safe.
        let output = unsafe {
            self.model
                .predictionFromFeatures_error(objc2::runtime::ProtocolObject::from_ref(&*provider))
                .map_err(|err| EmbedError::Backend(format_ns_error("prediction failed", &err)))?
        };

        let out_name = NSString::from_str(OUTPUT_FEATURE_NAME);
        // SAFETY: featureValueForName: returns Option<Retained<MLFeatureValue>>.
        let out_value = unsafe { output.featureValueForName(&out_name) }.ok_or_else(|| {
            EmbedError::Backend(format!(
                "prediction missing output feature {OUTPUT_FEATURE_NAME:?}"
            ))
        })?;

        // SAFETY: multiArrayValue: returns Option<Retained<MLMultiArray>>.
        let arr: Retained<MLMultiArray> = unsafe { out_value.multiArrayValue() }
            .ok_or_else(|| EmbedError::Backend("output is not an MLMultiArray".into()))?;

        copy_multiarray_to_f32_vec(&arr)
    }
}

/// Copy an `MLMultiArray` of `Float32` into a `Vec<f32>`. Returns
/// [`EmbedError::Backend`] if the dtype isn't Float32 or the element
/// count isn't [`ARCTIC_EMBED_S_DIMENSION`] (384).
///
/// Uses `dataPointer` (Apple-deprecated in favor of `getBytesWithHandler:`
/// for Swift RAII ergonomics). Functionally identical for our use case:
/// we hold the `Retained<MLMultiArray>` for the full duration of the
/// copy, then drop it — no lifetime risk. Pulling in the `block2`
/// feature on `objc2-core-ml` purely to use the handler variant would
/// expand the supply-chain surface (and the unsafe FFI surface) for
/// zero behavioral gain.
#[allow(deprecated)]
fn copy_multiarray_to_f32_vec(arr: &MLMultiArray) -> Result<Vec<f32>, EmbedError> {
    // SAFETY: dataType, count, dataPointer are property accessors with
    // no side effects beyond returning the model's existing buffer
    // metadata.
    let dtype = unsafe { arr.dataType() };
    if dtype != MLMultiArrayDataType::Float32 {
        return Err(EmbedError::Backend(format!(
            "output MultiArray dtype is {:?}, expected Float32",
            dtype.0
        )));
    }
    let count = unsafe { arr.count() };
    if count < 0 {
        return Err(EmbedError::Backend(format!(
            "output MultiArray count is negative: {count}"
        )));
    }
    let count_usize: usize = count.try_into().map_err(|_| {
        EmbedError::Backend(format!("output MultiArray count overflows usize: {count}"))
    })?;
    if count_usize != ARCTIC_EMBED_S_DIMENSION {
        return Err(EmbedError::Backend(format!(
            "output MultiArray has {count_usize} elements, expected {ARCTIC_EMBED_S_DIMENSION}"
        )));
    }

    // SAFETY: `dataPointer` returns a NonNull<c_void> over the model's
    // contiguous Float32 backing buffer. We just verified dtype == Float32
    // and that the count fits, so reading `count_usize` f32s starting at
    // the pointer is in-bounds. We copy immediately into an owned Vec
    // rather than holding the raw pointer — the buffer's lifetime is
    // tied to the MLMultiArray Retained ref, and copying keeps us
    // pointer-discipline-honest for the upstream wrapper.
    let mut out = vec![0.0_f32; count_usize];
    unsafe {
        let src = arr.dataPointer().as_ptr().cast::<f32>();
        std::ptr::copy_nonoverlapping(src, out.as_mut_ptr(), count_usize);
    }
    Ok(out)
}

/// Render an `NSError` into a human-readable diagnostic without leaking
/// pointer formatting into log files.
fn format_ns_error(prefix: &str, err: &objc2_foundation::NSError) -> String {
    let desc = err.localizedDescription();
    let code = err.code();
    format!("{prefix}: code={code} {desc}")
}

/// Zero-vector fallback backend for when the `.mlpackage` is not bundled.
///
/// Produces a deterministic 384-d zero vector for every input. Events
/// embedded with this backend are marked "embedded" in `event_vectors`
/// so the idle-batch worker does not re-process them, but they carry no
/// semantic signal — recall falls back to FTS5-only for these events.
///
/// This is the graceful-degradation arm documented in ADR-0016 §1.3:
/// development / early builds that don't bundle the Core ML model can
/// still run the full pipeline without the embedder busy-looping on
/// the same un-embedded events forever.
pub struct ZeroBackend;

impl std::fmt::Debug for ZeroBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ZeroBackend").finish()
    }
}

impl EmbedderBackend for ZeroBackend {
    fn forward(&self, _text: &str) -> Result<Vec<f32>, EmbedError> {
        Ok(vec![0.0_f32; ARCTIC_EMBED_S_DIMENSION])
    }
}

/// Attempt to load the Core ML backend from a list of candidate paths.
///
/// Tries each path in order. On the first successful load, returns
/// `Ok(CoreMLBackend)`. If all paths fail (typically because the
/// `.mlpackage` isn't bundled in this build), returns `Err` with the
/// last error encountered.
///
/// Candidate paths follow the Bundle.module fallback pattern from
/// PR #86's `AllowlistTOMLLoader` resolver chain:
///
/// 1. `Bundle.module` resource path (`SwiftPM` / Xcode build)
/// 2. Executable-relative `../Resources/` (`.app` bundle layout)
/// 3. Explicit override via env var `MCI_ARCTIC_MODEL_PATH`
pub fn try_load_coreml_backend(candidate_paths: &[&Path]) -> Result<CoreMLBackend, EmbedError> {
    let mut last_err = EmbedError::Backend("no candidate paths provided".into());
    for path in candidate_paths {
        match CoreMLBackend::open(path) {
            Ok(backend) => return Ok(backend),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

/// Load the best available embedder backend: Core ML if the `.mlpackage`
/// exists at any candidate path, otherwise the zero-vector fallback.
///
/// Returns `(backend, is_real)` where `is_real` is `true` when the
/// Core ML model loaded successfully. Callers should log the
/// degradation when `is_real == false`.
#[must_use]
pub fn load_backend_or_fallback(
    candidate_paths: &[&Path],
) -> (std::sync::Arc<dyn EmbedderBackend>, bool) {
    match try_load_coreml_backend(candidate_paths) {
        Ok(backend) => (std::sync::Arc::new(backend), true),
        Err(_) => (std::sync::Arc::new(ZeroBackend), false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_backend_produces_384_zeros() {
        let b = ZeroBackend;
        let v = b.forward("hello").unwrap();
        assert_eq!(v.len(), ARCTIC_EMBED_S_DIMENSION);
        assert!(v.iter().all(|x| *x == 0.0));
    }

    #[test]
    fn load_backend_or_fallback_returns_zero_for_missing_paths() {
        let paths: Vec<&Path> = vec![Path::new("/nonexistent/model.mlpackage")];
        let (backend, is_real) = load_backend_or_fallback(&paths);
        assert!(!is_real);
        let v = backend.forward("test").unwrap();
        assert_eq!(v.len(), ARCTIC_EMBED_S_DIMENSION);
    }

    #[test]
    fn open_rejects_empty_path() {
        let err = CoreMLBackend::open(Path::new("")).expect_err("empty path");
        assert!(matches!(err, EmbedError::InvalidInput(_)), "{err:?}");
    }

    #[test]
    fn open_returns_backend_error_for_missing_file() {
        let err = CoreMLBackend::open(Path::new(
            "/tmp/mci-test-nonexistent-arctic-embed-s.mlpackage",
        ))
        .expect_err("missing path");
        match err {
            EmbedError::Backend(msg) => assert!(
                msg.contains("not found"),
                "expected 'not found' in message, got {msg:?}"
            ),
            other => panic!("expected Backend error, got {other:?}"),
        }
    }

    #[test]
    fn output_feature_name_matches_bundling_contract() {
        assert_eq!(OUTPUT_FEATURE_NAME, "embedding");
        assert_eq!(INPUT_FEATURE_NAME, "text");
    }

    #[test]
    fn dimension_constant_pinned_at_384() {
        // Sanity tripwire: a regression in mci_brain's dimension
        // constant must not silently propagate here.
        assert_eq!(ARCTIC_EMBED_S_DIMENSION, 384);
    }
}
