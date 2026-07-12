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
//! model-card prefix discipline above this crate. This crate's job:
//! load the `.mlpackage` / `.mlmodelc`, tokenize text in Rust, run a
//! forward pass on the resulting Int32 token-IDs tensors, return the
//! raw 384-d embedding vector (already CLS-pooled + L2-normalized inside
//! the Core ML graph).
//!
//! # Wave-17 architectural pivot
//!
//! The original BUNDLING.md plan said "tokenizer baked into the Core ML
//! graph; the runtime hands raw UTF-8 strings to the model." That plan
//! is **impossible** per the Core ML MIL spec — there are no string ops,
//! so `coremltools` cannot convert a graph whose input is a `String` and
//! whose first hidden layer is a tokenizer. CRS Arxiv/OSS scout
//! (2026-05-22) verified this and the CEO ratified the pivot the same
//! day. Industry-standard pattern (Apple ml-stable-diffusion, WhisperKit,
//! HuggingFace's own exporters): tokenize on the host, pass token-IDs
//! into the graph.
//!
//! The Rust-side tokenizer lives in [`tokenizer`] and uses the
//! HuggingFace `tokenizers` crate against the bundled
//! `Snowflake/snowflake-arctic-embed-s` `tokenizer.json` (embedded in
//! this crate's binary via `include_bytes!`). CLS-pool + L2-norm move
//! INTO the Core ML graph so the embedding the Rust side receives is
//! already a unit vector.
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
//! The `ArcticEmbedS_INT8.mlpackage` (~33 MB) is **not** checked into
//! the repo. The Phase-5 signed-app build pipeline runs
//! `scripts/convert_embedder.py` at release time to produce the
//! `.mlpackage` (and pre-compile it to `.mlmodelc` via
//! `xcrun coremlcompiler compile`). See `BUNDLING.md` for the conversion
//! contract + the expected input/output schema this crate calls.
//!
//! # Expected `.mlpackage` schema (Wave-17 corrected)
//!
//! - **Input feature `"input_ids"`:** `MLMultiArray<Int32>`, shape `[1, 128]`.
//! - **Input feature `"attention_mask"`:** `MLMultiArray<Int32>`, shape `[1, 128]`.
//! - **Output feature `"embedding"`:** `MLMultiArray<Float32>`, shape
//!   `[384]` or `[1, 384]`. **Already CLS-pooled and L2-normalized in
//!   the graph** — the Rust side does not post-process.
//!
//! A mismatch produces an [`EmbedError::Backend`] with the offending
//! schema described, never a silent corruption of the brain.
//!
//! # Tests
//!
//! Unit tests cover: tokenizer load + encode (`tokenizer::tests`),
//! missing-file open error, and the constructor error surface. The
//! end-to-end Core ML inference path is exercised by the
//! `tests/quality.rs` regression test against a Python-generated
//! reference fixture (skipped when the `.mlmodelc` + `.npy` aren't
//! present in `models/` — the orchestrator runs that pass).

pub mod tokenizer;

use std::path::Path;
use std::sync::Arc;

use mci_brain::{
    arctic_embed_s::{EmbedderBackend, ARCTIC_EMBED_S_DIMENSION},
    EmbedError,
};

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AllocAnyThread;
use objc2_core_ml::{
    MLComputeUnits, MLDictionaryFeatureProvider, MLFeatureProvider, MLFeatureType, MLFeatureValue,
    MLModel, MLModelConfiguration, MLMultiArray, MLMultiArrayDataType,
};
use objc2_foundation::{NSArray, NSDictionary, NSNumber, NSString, NSURL};

use crate::tokenizer::WordPieceTokenizer;

/// Per the Wave-17 erratum to ADR-0011, the expected input feature names.
/// The Python conversion script (`scripts/convert_embedder.py`) wires the
/// traced graph to these exact names.
const INPUT_IDS_FEATURE_NAME: &str = "input_ids";
const ATTENTION_MASK_FEATURE_NAME: &str = "attention_mask";

/// Per ADR-0011, the expected output feature name from the
/// `coremltools`-converted `.mlpackage`. The Wave-17 graph is now
/// CLS-pooled + L2-normalized inside the graph — the value the Rust
/// side reads is already a unit vector.
const OUTPUT_FEATURE_NAME: &str = "embedding";

/// Fixed sequence length the Python conversion script pins. Matches the
/// fixed `shape=(1, 128)` input in `scripts/convert_embedder.py`. Tokens
/// are padded with `[PAD]` (id 0) and truncated to fit. The Rust runtime
/// always feeds exactly this many tokens (see [`CoreMLBackend::forward`]),
/// so the graph's input shape is fixed rather than a `RangeDim` — that
/// fixed shape is what makes the `embedding` output statically `[1, 384]`
/// instead of the data-dependent `[?, 384]` that forced Espresso onto the
/// CPU-fallback path (see the compute-unit note on [`ComputeUnits`]).
pub const MAX_SEQ_LEN: usize = 128;

/// Compute-unit policy for the embedder load path.
///
/// A thin safe mirror of Core ML's `MLComputeUnits`, matching the enum in
/// `mci-coreml-bridge` so the whole codebase pins compute units the same
/// way. The crate-internal loader sets this on the `MLModelConfiguration`
/// *before* the model is loaded.
///
/// # Why this exists (the E5RT "Invalid blob shape" story)
///
/// Before this enum, the embedder loaded with a bare
/// `MLModelConfiguration` and never set a compute unit, defaulting to
/// `MLComputeUnits::All`. On the data-dependent-shape graph that
/// `scripts/convert_embedder.py` produced (the `embedding` output had no
/// declared shape, so the dynamic seq dim propagated to `[?, 384]`), the
/// ANE/GPU path emits
///
/// ```text
/// E5RT ... Espresso exception: "Invalid blob shape":
/// Data-dependent shapes were disabled: embedding - [?, 384]
/// ```
///
/// to stderr and **falls back to CPU** — predictions still succeed (the
/// live store's vectors are genuine unit vectors), but the failover wastes
/// an ANE/GPU compile attempt and spews an alarming-but-benign error.
/// Pinning the load to [`ComputeUnits::CpuOnly`] avoids the ANE/GPU path
/// entirely, so the error never appears and the idle-batch worker stays a
/// low-footprint CPU citizen. The companion fix in
/// `scripts/convert_embedder.py` pins the input/output shapes so the graph
/// is statically `[1, 384]` and re-eligible for GPU/ANE — but per the
/// [Core ML compute-units `.all` is a latency trap] lesson, the optimal
/// unit is model-dependent and chosen by measurement, not by default. For
/// this idle-batch (non-hot-path) embedder the measured numbers make
/// CPU-only the right pin: it tolerates both the current flexible artifact
/// and the future fixed-shape one (reship-ordering-robust) at a latency
/// (~3–29 ms) that is irrelevant on a 5-second idle loop.
///
/// [Core ML compute-units `.all` is a latency trap]: there is no ANE
/// residency for this BERT graph; the real choice is GPU vs CPU.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComputeUnits {
    /// CPU only (`MLComputeUnitsCPUOnly`). The production pin — see the
    /// type-level docs.
    CpuOnly,
    /// CPU + GPU, no ANE (`MLComputeUnitsCPUAndGPU`). Fastest measured
    /// clean unit on the fixed-shape graph (~1.9 ms); available for future
    /// tuning if the embedder ever moves to a hot path.
    CpuAndGpu,
    /// CPU + ANE, no GPU (`MLComputeUnitsCPUAndNeuralEngine`). The BERT
    /// graph fails ANE compile and falls back, emitting its own benign
    /// E5RT message — kept for completeness/measurement parity.
    CpuAndNeuralEngine,
    /// Core ML schedules across ANE/GPU/CPU (`MLComputeUnitsAll`). The
    /// pre-fix default that produced the data-dependent-shape failover.
    All,
}

impl ComputeUnits {
    fn to_ml(self) -> MLComputeUnits {
        match self {
            ComputeUnits::CpuOnly => MLComputeUnits::CPUOnly,
            ComputeUnits::CpuAndGpu => MLComputeUnits::CPUAndGPU,
            ComputeUnits::CpuAndNeuralEngine => MLComputeUnits::CPUAndNeuralEngine,
            ComputeUnits::All => MLComputeUnits::All,
        }
    }
}

/// The compute-unit policy the production loaders ([`CoreMLBackend::open`],
/// [`try_load_coreml_backend`], [`load_backend_or_fallback`]) pin. CPU-only
/// per the measured idle-batch rationale on [`ComputeUnits`].
pub const DEFAULT_COMPUTE_UNITS: ComputeUnits = ComputeUnits::CpuOnly;

/// Core ML / ANE backend for `snowflake-arctic-embed-s`.
///
/// One instance per loaded `.mlpackage` / `.mlmodelc`. Held by `Arc<Self>`
/// upstream so query + document
/// [`mci_brain::arctic_embed_s::ArcticEmbedSEmbedder`] instances can
/// share the model (per ADR-0016 §1.3: "model mmap'd, shared between
/// query + idle-batch embed"). The tokenizer is similarly `Arc`-shared.
pub struct CoreMLBackend {
    model: Retained<MLModel>,
    tokenizer: Arc<WordPieceTokenizer>,
}

impl std::fmt::Debug for CoreMLBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Don't dump the MLModel description — it leaks the bundled
        // model's input/output schema into logs, which we want
        // consistent across content-free telemetry. Identity only.
        f.debug_struct("CoreMLBackend")
            .field("tokenizer", &self.tokenizer)
            .finish_non_exhaustive()
    }
}

// `MLModel` is documented thread-safe for `predictionFromFeatures:`
// (Apple — Core ML Performance & Architecture WWDC 2019 §"Thread Safety").
// The objc2 binding exposes `Retained<MLModel>` which itself is `!Send`
// by default because of Objective-C runtime nuances. We assert Send + Sync
// by hand and keep the unsafe impl narrow + commented. Same pattern as
// `mci-llama-coreml` and `mci-core::ipc::wire`'s `OwnedFd` carriers.
unsafe impl Send for CoreMLBackend {}
unsafe impl Sync for CoreMLBackend {}

impl CoreMLBackend {
    /// Load the `.mlpackage` / `.mlmodelc` at `path`, using the bundled
    /// `tokenizer.json`.
    ///
    /// Production callers use this. The tokenizer is embedded in the
    /// binary via `include_bytes!` so the only runtime input is the
    /// Core ML model itself.
    ///
    /// # Errors
    ///
    /// - `EmbedError::InvalidInput` — `path` is not a non-empty
    ///   filesystem path string.
    /// - `EmbedError::Backend` — Core ML refused the load, the tokenizer
    ///   resource failed to deserialize, or the loaded model has an
    ///   unexpected feature schema.
    pub fn open(path: &Path) -> Result<Self, EmbedError> {
        Self::open_with_compute_units(path, DEFAULT_COMPUTE_UNITS)
    }

    /// Load the `.mlpackage` / `.mlmodelc` at `path` with an explicit
    /// [`ComputeUnits`] policy, pinned on the `MLModelConfiguration` before
    /// the model loads. Production uses [`Self::open`] (which pins
    /// [`DEFAULT_COMPUTE_UNITS`]); this variant exists for compute-unit
    /// measurement / tuning, mirroring
    /// `mci-coreml-bridge::CoreMLModel::load_with_compute_units`.
    ///
    /// # Errors
    ///
    /// As for [`Self::open`].
    pub fn open_with_compute_units(path: &Path, units: ComputeUnits) -> Result<Self, EmbedError> {
        let tokenizer = WordPieceTokenizer::load_bundled()
            .map_err(|e| EmbedError::Backend(format!("tokenizer: {e}")))?;
        Self::open_with_tokenizer_arc(path, tokenizer, units)
    }

    /// Load the model + an explicit tokenizer file. Dev override for
    /// custom tokenizers (e.g. testing a model swap eval).
    ///
    /// # Errors
    ///
    /// As for [`Self::open`], plus `EmbedError::Backend` if the
    /// tokenizer file does not exist or cannot be parsed.
    pub fn open_with_tokenizer(
        model_path: &Path,
        tokenizer_path: &Path,
    ) -> Result<Self, EmbedError> {
        let tokenizer = WordPieceTokenizer::load_from_file(tokenizer_path)
            .map_err(|e| EmbedError::Backend(format!("tokenizer: {e}")))?;
        Self::open_with_tokenizer_arc(model_path, tokenizer, DEFAULT_COMPUTE_UNITS)
    }

    fn open_with_tokenizer_arc(
        path: &Path,
        tokenizer: Arc<WordPieceTokenizer>,
        units: ComputeUnits,
    ) -> Result<Self, EmbedError> {
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
        // Pin the compute unit BEFORE load. Without this the config
        // defaults to `MLComputeUnits::All`, which routes the
        // data-dependent-shape `embedding` output onto the ANE/GPU path and
        // emits the benign-but-alarming E5RT "Invalid blob shape" failover
        // to stderr (predictions still succeed on CPU fallback). Pinning
        // here mirrors `mci-coreml-bridge::CoreMLModel::load_with_compute_units`.
        // SAFETY: `setComputeUnits:` is a setter on the freshly-allocated
        // configuration object; no aliasing, no escape.
        unsafe { config.setComputeUnits(units.to_ml()) };
        // SAFETY: Core ML's `+[MLModel modelWithContentsOfURL:configuration:error:]`
        // is a class method that builds a new MLModel from a file URL. The
        // call blocks briefly on compile-then-load for `.mlpackage`.
        // Returns either a retained MLModel or an NSError — we map both arms.
        let model = unsafe {
            MLModel::modelWithContentsOfURL_configuration_error(&url, &config)
                .map_err(|err| EmbedError::Backend(format_ns_error("MLModel load failed", &err)))?
        };

        let me = Self { model, tokenizer };
        me.verify_schema()?;
        Ok(me)
    }

    /// Construct from an already-loaded `MLModel` + tokenizer. For
    /// internal use by alternate loaders.
    #[must_use]
    pub fn from_loaded(model: Retained<MLModel>, tokenizer: Arc<WordPieceTokenizer>) -> Self {
        Self { model, tokenizer }
    }

    /// Verify the loaded model's input/output feature schema matches
    /// the Wave-17 contract documented in the module docs. Called once
    /// at load. Output shape check is loose — Core ML may report
    /// data-dependent shapes for `[384]` vs `[1, 384]`, both are fine.
    fn verify_schema(&self) -> Result<(), EmbedError> {
        // SAFETY: `modelDescription` is a property accessor that returns a
        // retained MLModelDescription. `inputDescriptionsByName` /
        // `outputDescriptionsByName` are NSDictionary accessors.
        let desc = unsafe { self.model.modelDescription() };
        let inputs = unsafe { desc.inputDescriptionsByName() };
        let outputs = unsafe { desc.outputDescriptionsByName() };

        let ids_key = NSString::from_str(INPUT_IDS_FEATURE_NAME);
        let mask_key = NSString::from_str(ATTENTION_MASK_FEATURE_NAME);
        let out_key = NSString::from_str(OUTPUT_FEATURE_NAME);

        let ids_desc = inputs.objectForKey(&ids_key).ok_or_else(|| {
            EmbedError::Backend(format!(
                "model is missing required input feature {INPUT_IDS_FEATURE_NAME:?}; \
                 see BUNDLING.md for the expected Wave-17 schema"
            ))
        })?;
        let mask_desc = inputs.objectForKey(&mask_key).ok_or_else(|| {
            EmbedError::Backend(format!(
                "model is missing required input feature {ATTENTION_MASK_FEATURE_NAME:?}; \
                 see BUNDLING.md for the expected Wave-17 schema"
            ))
        })?;
        let out_desc = outputs.objectForKey(&out_key).ok_or_else(|| {
            EmbedError::Backend(format!(
                "model is missing required output feature {OUTPUT_FEATURE_NAME:?}; \
                 see BUNDLING.md for the expected Wave-17 schema"
            ))
        })?;

        for (name, fdesc) in [
            (INPUT_IDS_FEATURE_NAME, &ids_desc),
            (ATTENTION_MASK_FEATURE_NAME, &mask_desc),
        ] {
            let ftype = unsafe { fdesc.r#type() };
            if ftype != MLFeatureType::MultiArray {
                return Err(EmbedError::Backend(format!(
                    "input {name:?} has feature type {:?}, expected MultiArray (Int32 [1,128])",
                    ftype.0
                )));
            }
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
        // 1. Tokenize on the Rust side.
        let enc = self
            .tokenizer
            .encode(text, MAX_SEQ_LEN)
            .map_err(|e| EmbedError::Backend(format!("tokenize: {e}")))?;

        // 2. Build two MLMultiArray Int32 shape [1, 128] from the
        //    encoded tensors. Same pattern as `mci-llama-coreml::forward_pass`.
        let input_ids_arr = build_int32_multiarray_1xn(&enc.input_ids)?;
        let mask_arr = build_int32_multiarray_1xn(&enc.attention_mask)?;

        // 3. Wrap in MLFeatureValue, build a feature-provider dictionary.
        // SAFETY: `featureValueWithMultiArray:` is a class method returning
        // a retained MLFeatureValue wrapping the MLMultiArray.
        let ids_value: Retained<MLFeatureValue> =
            unsafe { MLFeatureValue::featureValueWithMultiArray(&input_ids_arr) };
        let mask_value: Retained<MLFeatureValue> =
            unsafe { MLFeatureValue::featureValueWithMultiArray(&mask_arr) };

        let ids_key = NSString::from_str(INPUT_IDS_FEATURE_NAME);
        let mask_key = NSString::from_str(ATTENTION_MASK_FEATURE_NAME);
        let ids_obj: &AnyObject = &ids_value;
        let mask_obj: &AnyObject = &mask_value;
        let dict: Retained<NSDictionary<NSString, AnyObject>> =
            NSDictionary::from_slices(&[&*ids_key, &*mask_key], &[ids_obj, mask_obj]);

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

        // 4. Run the prediction. ProtocolObject<dyn MLFeatureProvider> is
        //    the required input type; MLDictionaryFeatureProvider conforms.
        // SAFETY: predictionFromFeatures:error: is synchronous + thread-safe.
        let output = unsafe {
            self.model
                .predictionFromFeatures_error(objc2::runtime::ProtocolObject::from_ref(&*provider))
                .map_err(|err| EmbedError::Backend(format_ns_error("prediction failed", &err)))?
        };

        // 5. Extract the "embedding" output and copy into Vec<f32>.
        //    The graph already CLS-pooled + L2-normalized; we do not
        //    post-process.
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

/// Build an `MLMultiArray<Int32>` of shape `[1, N]` from a slice of i32s,
/// copying the slice into the array's backing buffer.
///
/// Same approach as `mci-llama-coreml::forward_pass`.
#[allow(deprecated)]
fn build_int32_multiarray_1xn(values: &[i32]) -> Result<Retained<MLMultiArray>, EmbedError> {
    let dim0 = NSNumber::new_i64(1);
    let dim1 = NSNumber::new_i64(values.len() as i64);
    let shape = NSArray::from_slice(&[&*dim0, &*dim1]);

    // SAFETY: `initWithShape:dataType:error:` allocates a fresh
    // MLMultiArray with the given shape + dtype. We map the error path
    // explicitly.
    let arr = unsafe {
        MLMultiArray::initWithShape_dataType_error(
            MLMultiArray::alloc(),
            &shape,
            MLMultiArrayDataType::Int32,
        )
        .map_err(|err| EmbedError::Backend(format_ns_error("MLMultiArray alloc failed", &err)))?
    };

    // SAFETY: We just created this MLMultiArray with dtype Int32 and
    // total element count = values.len(), so the backing buffer has at
    // least values.len() * sizeof(i32) bytes. Writing values.len() i32s
    // starting at dataPointer() is in-bounds.
    unsafe {
        let dst = arr.dataPointer().as_ptr().cast::<i32>();
        std::ptr::copy_nonoverlapping(values.as_ptr(), dst, values.len());
    }

    Ok(arr)
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
    fn feature_names_match_bundling_contract() {
        assert_eq!(OUTPUT_FEATURE_NAME, "embedding");
        assert_eq!(INPUT_IDS_FEATURE_NAME, "input_ids");
        assert_eq!(ATTENTION_MASK_FEATURE_NAME, "attention_mask");
    }

    #[test]
    fn dimension_constant_pinned_at_384() {
        // Sanity tripwire: a regression in mci_brain's dimension
        // constant must not silently propagate here.
        assert_eq!(ARCTIC_EMBED_S_DIMENSION, 384);
    }

    #[test]
    fn max_seq_len_is_128() {
        // Pinned in scripts/convert_embedder.py via the fixed input
        // shape=(1, 128). The Rust runtime always feeds exactly 128 tokens.
        assert_eq!(MAX_SEQ_LEN, 128);
    }

    #[test]
    fn default_compute_units_is_cpu_only() {
        // Production pin: idle-batch is non-hot-path; CPU-only tolerates
        // both the flexible and fixed-shape artifacts and never triggers
        // the ANE/GPU E5RT failover. If this ever changes, re-measure per
        // the ComputeUnits doc rationale.
        assert_eq!(DEFAULT_COMPUTE_UNITS, ComputeUnits::CpuOnly);
    }

    #[test]
    fn open_with_compute_units_still_errors_on_missing_file() {
        // Negative control: pinning a compute unit must NOT change the
        // load-failure trigger that drives ZeroBackend graceful
        // degradation. A missing model still surfaces a Backend error
        // (which load_backend_or_fallback maps to ZeroBackend).
        let err = CoreMLBackend::open_with_compute_units(
            Path::new("/tmp/mci-test-nonexistent-arctic.mlpackage"),
            ComputeUnits::CpuAndGpu,
        )
        .expect_err("missing path must still error under a pinned compute unit");
        assert!(matches!(err, EmbedError::Backend(_)), "{err:?}");
    }
}
