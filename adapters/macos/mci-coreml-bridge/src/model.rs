//! Generic Core ML model wrapper — the model-agnostic half of
//! `mci-coreml-bridge`.
//!
//! [`CoreMLModel`] loads a compiled `.mlmodelc`, introspects its IO
//! schema, and runs feature-dict predictions through Apple's Core ML
//! framework (`objc2-core-ml` / `objc2-foundation`). It makes **no**
//! assumptions about a specific model: the per-model shims own
//! tokenization, the IO tensor names/dtypes, and output decoding on
//! top of this wrapper.
//!
//! - [`crate::qwen3`] — Qwen3-1.7B brief generation (autoregressive,
//!   `input_ids` + `attention_mask` → last-position `logits`).
//! - (V2-P5+) a GLiNER NER shim lands on top of this wrapper in a later
//!   phase of the same spike: multi-tensor IO + a span-grid decoder.
//!
//! This is the generic core introduced by the Path-A refactor
//! (ADR-0033): the crate was `mci-llama-coreml` and Qwen-only; it is
//! now `mci-coreml-bridge`, one Core ML adapter for every on-device
//! model MCI runs.
//!
//! # Unsafe surface
//!
//! Every `objc2` selector is an `unsafe fn`. The unsafe is audited per
//! call site here; crates above the `mci-coreml-bridge` seam
//! (`mci-brief`, `mci-brain`, `mci-agent`) stay `#![forbid(unsafe_code)]`.
//! Same adapter-below-the-seam split as `mci-embed-coreml`.

use std::path::Path;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::AllocAnyThread;
use objc2_core_ml::{
    MLDictionaryFeatureProvider, MLFeatureProvider, MLFeatureType, MLFeatureValue, MLModel,
    MLModelConfiguration, MLMultiArray, MLMultiArrayDataType,
};
use objc2_foundation::{NSArray, NSDictionary, NSNumber, NSString, NSURL};

/// Errors from the generic Core ML wrapper.
///
/// Per-model shims map these into their own error types — e.g. the
/// Qwen3 shim maps every variant into
/// `mci_brief::llama_backend::GenerateError::Backend` via its display
/// string, preserving the human-readable message.
#[derive(Debug, thiserror::Error)]
pub enum CoreMLError {
    /// The model path was invalid, missing, or the `.mlmodelc` failed
    /// to load.
    #[error("{0}")]
    Load(String),
    /// `MLMultiArray` allocation failed.
    #[error("{0}")]
    Alloc(String),
    /// Input/output shape or length mismatch (caller bug).
    #[error("{0}")]
    Shape(String),
    /// Prediction failed, or a named output was missing / the wrong
    /// feature type.
    #[error("{0}")]
    Predict(String),
    /// An `MLMultiArray` had an unsupported element dtype.
    #[error("{0}")]
    Dtype(String),
}

/// A loaded Core ML model.
///
/// Thread-safe for prediction: Apple documents `predictionFromFeatures:`
/// as concurrency-safe (Core ML Performance & Architecture, WWDC 2019)
/// — the same assertion `mci-embed-coreml` and the former
/// `Qwen3CoreMLBackend` already relied on.
pub struct CoreMLModel {
    model: Retained<MLModel>,
}

impl std::fmt::Debug for CoreMLModel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CoreMLModel").finish_non_exhaustive()
    }
}

// SAFETY: MLModel is documented thread-safe for predictionFromFeatures:.
unsafe impl Send for CoreMLModel {}
unsafe impl Sync for CoreMLModel {}

impl CoreMLModel {
    /// Load the compiled `.mlmodelc` at `model_path` with the default
    /// compute-unit policy (`MLComputeUnits.all` — Core ML schedules
    /// ANE/GPU/CPU). A compute-unit-pinned loader for the ANE-resident
    /// GLiNER path is added in a later phase of the same spike.
    pub fn load(model_path: &Path) -> Result<Self, CoreMLError> {
        let path_str = model_path
            .to_str()
            .ok_or_else(|| CoreMLError::Load("model path is not valid UTF-8".into()))?;
        if path_str.is_empty() {
            return Err(CoreMLError::Load("model path is empty".into()));
        }
        if !model_path.exists() {
            return Err(CoreMLError::Load(format!("model not found at: {path_str}")));
        }

        let url = NSURL::fileURLWithPath(&NSString::from_str(path_str));
        let config = unsafe { MLModelConfiguration::new() };
        let model = unsafe {
            MLModel::modelWithContentsOfURL_configuration_error(&url, &config).map_err(|err| {
                CoreMLError::Load(format!(
                    "MLModel load failed: code={} {}",
                    err.code(),
                    err.localizedDescription()
                ))
            })?
        };
        Ok(Self { model })
    }

    /// True if the model declares an input feature named `name`.
    #[must_use]
    pub fn has_input(&self, name: &str) -> bool {
        let desc = unsafe { self.model.modelDescription() };
        let inputs = unsafe { desc.inputDescriptionsByName() };
        inputs.objectForKey(&NSString::from_str(name)).is_some()
    }

    /// `None` if the model has no output feature named `name`;
    /// `Some(true)` if that output is an `MLMultiArray`, `Some(false)`
    /// otherwise.
    #[must_use]
    pub fn output_is_multi_array(&self, name: &str) -> Option<bool> {
        let desc = unsafe { self.model.modelDescription() };
        let outputs = unsafe { desc.outputDescriptionsByName() };
        let out = outputs.objectForKey(&NSString::from_str(name))?;
        let ty = unsafe { out.r#type() };
        Some(ty == MLFeatureType::MultiArray)
    }

    /// Run a prediction with the given named `MLMultiArray` inputs.
    ///
    /// Returns a [`Prediction`] from which named output features can be
    /// read with [`Prediction::multi_array`]. Any number of inputs is
    /// supported (Qwen3 passes two; GLiNER passes six), which is the
    /// whole point of the Path-A generic core.
    pub fn predict(&self, inputs: &[(&str, &MLMultiArray)]) -> Result<Prediction, CoreMLError> {
        let keys: Vec<Retained<NSString>> =
            inputs.iter().map(|(name, _)| NSString::from_str(name)).collect();
        let values: Vec<Retained<MLFeatureValue>> = inputs
            .iter()
            .map(|&(_, arr)| unsafe { MLFeatureValue::featureValueWithMultiArray(arr) })
            .collect();

        let key_refs: Vec<&NSString> = keys.iter().map(|k| &**k).collect();
        let val_refs: Vec<&AnyObject> = values
            .iter()
            .map(|v| {
                let obj: &AnyObject = v;
                obj
            })
            .collect();

        let dict: Retained<NSDictionary<NSString, AnyObject>> =
            NSDictionary::from_slices(&key_refs, &val_refs);

        let provider = unsafe {
            MLDictionaryFeatureProvider::initWithDictionary_error(
                MLDictionaryFeatureProvider::alloc(),
                &dict,
            )
            .map_err(|err| {
                CoreMLError::Predict(format!(
                    "feature-provider init failed: {}",
                    err.localizedDescription()
                ))
            })?
        };

        let output = unsafe {
            self.model
                .predictionFromFeatures_error(ProtocolObject::from_ref(&*provider))
                .map_err(|err| {
                    CoreMLError::Predict(format!(
                        "prediction failed: {}",
                        err.localizedDescription()
                    ))
                })?
        };

        Ok(Prediction { provider: output })
    }
}

/// The output of a [`CoreMLModel::predict`] call. Holds the Core ML
/// feature provider so named outputs can be read lazily.
pub struct Prediction {
    provider: Retained<ProtocolObject<dyn MLFeatureProvider>>,
}

impl Prediction {
    /// Read a named output feature as an `MLMultiArray`.
    pub fn multi_array(&self, name: &str) -> Result<Retained<MLMultiArray>, CoreMLError> {
        let key = NSString::from_str(name);
        let val = unsafe { self.provider.featureValueForName(&key) }.ok_or_else(|| {
            CoreMLError::Predict(format!("prediction missing output feature {name:?}"))
        })?;
        unsafe { val.multiArrayValue() }
            .ok_or_else(|| CoreMLError::Predict(format!("output {name:?} is not an MLMultiArray")))
    }
}

/// Allocate an `MLMultiArray` of the given row-major `shape` and dtype.
#[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
fn alloc_multi_array(
    shape: &[usize],
    dtype: MLMultiArrayDataType,
) -> Result<Retained<MLMultiArray>, CoreMLError> {
    let dims: Vec<Retained<NSNumber>> =
        shape.iter().map(|&d| NSNumber::new_i64(d as i64)).collect();
    let dim_refs: Vec<&NSNumber> = dims.iter().map(|d| &**d).collect();
    let ns_shape = NSArray::from_slice(&dim_refs);
    unsafe {
        MLMultiArray::initWithShape_dataType_error(MLMultiArray::alloc(), &ns_shape, dtype).map_err(
            |e| CoreMLError::Alloc(format!("MLMultiArray alloc: {}", e.localizedDescription())),
        )
    }
}

/// Build an `Int32` `MLMultiArray` of the given row-major `shape` from
/// `data`. `data.len()` must equal the product of `shape`.
#[allow(deprecated)] // dataPointer(): Apple-deprecated; no stable objc2 replacement yet.
pub fn multi_array_i32(
    shape: &[usize],
    data: &[i32],
) -> Result<Retained<MLMultiArray>, CoreMLError> {
    let total: usize = shape.iter().product();
    if data.len() != total {
        return Err(CoreMLError::Shape(format!(
            "i32 data len {} != shape product {total}",
            data.len()
        )));
    }
    let arr = alloc_multi_array(shape, MLMultiArrayDataType::Int32)?;
    unsafe {
        let dst = arr.dataPointer().as_ptr().cast::<i32>();
        std::ptr::copy_nonoverlapping(data.as_ptr(), dst, total);
    }
    Ok(arr)
}

/// Read `len` `f32` values starting at row-major element `offset` from
/// an `MLMultiArray`, converting from the array's element dtype
/// (`Float32` or `Float16`).
#[allow(deprecated)] // dataPointer(): Apple-deprecated; no stable objc2 replacement yet.
pub fn read_f32_slice(
    arr: &MLMultiArray,
    offset: usize,
    len: usize,
) -> Result<Vec<f32>, CoreMLError> {
    let mut out = vec![0.0_f32; len];
    let dtype = unsafe { arr.dataType() };
    if dtype == MLMultiArrayDataType::Float32 {
        unsafe {
            let src = arr.dataPointer().as_ptr().cast::<f32>();
            std::ptr::copy_nonoverlapping(src.add(offset), out.as_mut_ptr(), len);
        }
    } else if dtype == MLMultiArrayDataType::Float16 {
        unsafe {
            let src = arr.dataPointer().as_ptr().cast::<u16>();
            for (i, slot) in out.iter_mut().enumerate() {
                *slot = f16_to_f32(*src.add(offset + i));
            }
        }
    } else {
        return Err(CoreMLError::Dtype(format!(
            "array dtype is {:?}, expected Float32 or Float16",
            dtype.0
        )));
    }
    Ok(out)
}

/// IEEE-754 half-precision → single-precision conversion.
#[must_use]
#[allow(clippy::cast_sign_loss)]
pub fn f16_to_f32(bits: u16) -> f32 {
    let sign = u32::from((bits >> 15) & 1);
    let exp = u32::from((bits >> 10) & 0x1F);
    let mantissa = u32::from(bits & 0x3FF);

    if exp == 0 {
        if mantissa == 0 {
            return f32::from_bits(sign << 31);
        }
        // Subnormal
        let mut m = mantissa;
        let mut e: i32 = -14;
        while m & 0x400 == 0 {
            m <<= 1;
            e -= 1;
        }
        m &= 0x3FF;
        let f32_exp = (e + 127) as u32;
        return f32::from_bits((sign << 31) | (f32_exp << 23) | (m << 13));
    }
    if exp == 31 {
        return f32::from_bits((sign << 31) | (255_u32 << 23) | (mantissa << 13));
    }

    let f32_exp = exp + 112; // (exp - 15 + 127)
    f32::from_bits((sign << 31) | (f32_exp << 23) | (mantissa << 13))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_rejects_empty_path() {
        let err = CoreMLModel::load(Path::new("")).expect_err("empty path");
        assert!(matches!(err, CoreMLError::Load(_)), "{err:?}");
    }

    #[test]
    fn load_rejects_missing_file() {
        let err = CoreMLModel::load(Path::new("/tmp/mci-test-nonexistent.mlmodelc"))
            .expect_err("missing path");
        match err {
            CoreMLError::Load(msg) => {
                assert!(msg.contains("not found"), "expected 'not found', got {msg:?}");
            }
            other => panic!("expected Load, got {other:?}"),
        }
    }

    #[test]
    fn f16_to_f32_converts_common_values() {
        assert_eq!(f16_to_f32(0x0000), 0.0);
        assert!((f16_to_f32(0x3C00) - 1.0).abs() < 1e-6);
        assert!((f16_to_f32(0xBC00) - (-1.0)).abs() < 1e-6);
        assert!((f16_to_f32(0x3800) - 0.5).abs() < 1e-6);
    }
}
