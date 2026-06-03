// Gate the entire crate body on macOS — the objc2 deps are gated to the
// same target in `Cargo.toml`, so on Linux this crate compiles to an
// empty library. Same pattern as `mci-embed-coreml`.
#![cfg(target_os = "macos")]

//! `mci-coreml-bridge` — the macOS Core ML bridge for MCI's on-device
//! models.
//!
//! Renamed from `mci-llama-coreml` in the Path-A refactor (ADR-0033).
//! It was Qwen-only; it is now one Core ML adapter for every on-device
//! transformer MCI runs, split into a generic core plus per-model shims:
//!
//! - [`model`] — the generic [`CoreMLModel`] wrapper: load a
//!   `.mlmodelc`, introspect its IO schema, run feature-dict
//!   predictions. No model-specific assumptions.
//! - [`qwen3`] — [`Qwen3CoreMLBackend`], the Qwen3-1.7B brief-author
//!   shim (ADR-0028) implementing
//!   `mci_brief::llama_backend::LlamaBackend`.
//! - [`tokenizer`] — Qwen3 byte-level BPE, used by [`qwen3`].
//! - (V2-P5+) a GLiNER NER shim lands on top of [`model`] in a later
//!   phase of the same spike.
//!
//! # Adapter-below-the-seam
//!
//! This crate is the only place that calls Apple's Core ML through
//! `objc2-core-ml` / `objc2-foundation`. The unsafe surface is audited
//! per call site in [`model`]; crates above the seam (`mci-brief`,
//! `mci-brain`, `mci-agent`) stay `#![forbid(unsafe_code)]`.

pub mod model;
pub mod qwen3;
pub mod tokenizer;

// Backward-compatible crate-root re-exports: consumers keep using
// `mci_coreml_bridge::Qwen3CoreMLBackend` etc. unchanged — only the
// crate name moved (was `mci_llama_coreml`).
pub use model::{CoreMLError, CoreMLModel, Prediction};
pub use qwen3::{load_backend_or_stub, try_load_qwen3_backend, Qwen3CoreMLBackend};
